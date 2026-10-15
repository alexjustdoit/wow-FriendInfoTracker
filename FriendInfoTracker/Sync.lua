local addon = FriendInfoTracker

-- Peer-to-peer sync between Battle.net friends running the addon, plus
-- passive capture of online friends who don't run it.
--
-- Protocol (all over BNSendGameData, prefix "FIT"):
--   PING    sent to every online WoW friend once per session
--   PONG    reply to a PING; tells the sender we run the addon
--   DIGEST  { [characterID] = { identityAt, levelAt, professionsAt, locationAt } }
--   DATA    { [characterID] = record } -- only records newer than the peer's digest
-- After PING/PONG both sides exchange digests, then each sends what the other
-- lacks. Changes made later (own captures, merged data) are pushed as DATA to
-- every known peer after a short debounce, which is what relays data onward.
--
-- Wire format per message: "<protocol>:<TYPE>:<msgID>:<seq>:<total>:<chunk>"

local PREFIX = "FIT"
local PROTOCOL = "1"
local CHUNK_SIZE = 3800 -- BNSendGameData caps a message at ~4KB
local SEND_INTERVAL = 0.3 -- seconds between queued messages
local SCAN_INTERVAL = 60 -- seconds between friend-list scans
local SCAN_DEBOUNCE = 3
local PING_GRACE = 30 -- seconds to wait for a PONG before falling back to the friend list
local FLUSH_DELAY = 30 -- debounce before pushing changed records to peers
local BNET_REFRESH_SECONDS = 30 * 60 -- passive capture rewrites unchanged data at most this often
local REASSEMBLY_TIMEOUT = 120
local MAX_CHUNKS = 200
local MAX_RECORDS_PER_MESSAGE = 2000
local MAX_FUTURE_SKEW = 3600 -- clamp timestamps further in the future than this

local SECTIONS = addon.SECTIONS

local peers = {} -- [gameAccountID] = { battleTag, lastSeen, digestSent }
local onlineWoW = {} -- [gameAccountID] = battleTag, from the latest scan
local greeted = {} -- [gameAccountID] = GetTime() of the PING sent this session
local dirty = {} -- [characterID] = gameAccountID not to echo back to, or true
local inbound = {} -- ["senderID:msgID"] = reassembly buffer
local sendQueue = {}
local nextMessageID = 0
local sending = false
local flushPending = false
local scanPending = false

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Splits on UTF-8 boundaries so no chunk carries half a multibyte character.
local function SplitChunks(body)
	local chunks = {}
	local pos, len = 1, #body
	while pos <= len do
		local stop = math.min(pos + CHUNK_SIZE - 1, len)
		while stop < len and stop > pos do
			local nextByte = body:byte(stop + 1)
			if nextByte < 0x80 or nextByte >= 0xC0 then
				break
			end
			stop = stop - 1
		end
		chunks[#chunks + 1] = body:sub(pos, stop)
		pos = stop + 1
	end
	if #chunks == 0 then
		chunks[1] = ""
	end
	return chunks
end

local function PumpQueue()
	local item = table.remove(sendQueue, 1)
	if not item then
		sending = false
		return
	end
	-- The target may have logged off since the message was queued.
	pcall(BNSendGameData, item.target, PREFIX, item.text)
	C_Timer.After(SEND_INTERVAL, PumpQueue)
end

local function Send(target, msgType, payload)
	local body = payload and addon.Serialize(payload) or ""
	nextMessageID = (nextMessageID % 1000000) + 1
	local chunks = SplitChunks(body)
	for seq, chunk in ipairs(chunks) do
		local header = table.concat({ PROTOCOL, msgType, nextMessageID, seq, #chunks }, ":")
		sendQueue[#sendQueue + 1] = { target = target, text = header .. ":" .. chunk }
	end
	if not sending then
		sending = true
		PumpQueue()
	end
end

---------------------------------------------------------------------------
-- Records: export, sanitize, merge
---------------------------------------------------------------------------

local function CopyTable(source)
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = type(value) == "table" and CopyTable(value) or value
	end
	return copy
end

-- Only sections and owner go over the wire; local-only fields (isMine, meta,
-- receivedFrom) stay local. "self" becomes "addon" from the receiver's view.
local function ExportRecord(record)
	local out = { owner = record.owner }
	for _, section in ipairs(SECTIONS) do
		if record[section] then
			local copy = CopyTable(record[section])
			if copy.source ~= "bnet" then
				copy.source = "addon"
			end
			out[section] = copy
		end
	end
	return out
end

local function Str(value, maxLen)
	if type(value) == "string" then
		return value:sub(1, maxLen or 64)
	end
end

local function Num(value)
	if type(value) == "number" and value == value and value > -1e12 and value < 1e12 then
		return value
	end
end

local function Timestamp(value, now)
	value = Num(value)
	if not value or value <= 0 then
		return nil
	end
	return value > now + MAX_FUTURE_SKEW and now or value
end

local function Source(value)
	return value == "bnet" and "bnet" or "addon"
end

local SANITIZERS = {
	identity = function(data)
		return {
			name = Str(data.name),
			realm = Str(data.realm),
			realmDisplay = Str(data.realmDisplay),
			region = Str(data.region, 4),
			class = Str(data.class, 32),
			race = Str(data.race, 32),
			faction = Str(data.faction, 32),
			guid = Str(data.guid),
		}
	end,
	level = function(data)
		return { value = Num(data.value) }
	end,
	professions = function(data)
		local out, count = {}, 0
		for key, prof in pairs(data) do
			if type(key) == "string" and key:match("^%d+$") and type(prof) == "table" and count < 10 then
				count = count + 1
				out[key] = {
					name = Str(prof.name),
					type = prof.type == "primary" and "primary" or "secondary",
					rank = Num(prof.rank),
					maxRank = Num(prof.maxRank),
				}
			end
		end
		return out
	end,
	location = function(data)
		return {
			zone = Str(data.zone),
			subzone = Str(data.subzone),
			mapID = Num(data.mapID),
			inInstance = data.inInstance == true,
			instanceType = Str(data.instanceType, 32),
		}
	end,
}

-- Rebuilds an incoming record from scratch keeping only known fields of the
-- right type. Returns nil if nothing usable remains.
local function SanitizeRecord(id, incoming, now)
	if type(id) ~= "string" or #id > 100 or not id:match("^[^%-]+%-[^%-]+%-%u%u$") then
		return nil
	end
	if type(incoming) ~= "table" then
		return nil
	end
	local out, any = { owner = Str(incoming.owner) }, false
	for _, section in ipairs(SECTIONS) do
		local data = incoming[section]
		if type(data) == "table" then
			local updatedAt = Timestamp(data.updatedAt, now)
			if updatedAt then
				local clean = SANITIZERS[section](data)
				clean.updatedAt = updatedAt
				clean.source = Source(data.source)
				out[section] = clean
				any = true
			end
		end
	end
	-- Identity must describe the character it's filed under.
	local identity = out.identity
	if identity and string.format("%s-%s-%s", tostring(identity.name), tostring(identity.realm), tostring(identity.region)) ~= id then
		out.identity = nil
	end
	return any and out or nil
end

-- Per-section merge: newer updatedAt wins. Own characters are never
-- overwritten by data from others.
local function MergeRecord(id, incoming, senderTag)
	local characters = FriendInfoTrackerDB.characters
	local record = characters[id]
	if record and record.isMine then
		return false
	end
	record = record or {}
	local changed = false
	for _, section in ipairs(SECTIONS) do
		local new, old = incoming[section], record[section]
		if new and (not old or new.updatedAt > (old.updatedAt or 0)) then
			record[section] = new
			changed = true
		end
	end
	if changed then
		record.owner = incoming.owner or record.owner
		record.receivedFrom = senderTag
		record.receivedAt = time()
		characters[id] = record
	end
	return changed
end

---------------------------------------------------------------------------
-- Pushing changes
---------------------------------------------------------------------------

local function Flush()
	flushPending = false
	local characters = FriendInfoTrackerDB.characters
	for target in pairs(peers) do
		local payload, any = {}, false
		for id, skipTarget in pairs(dirty) do
			if skipTarget ~= target and characters[id] then
				payload[id] = ExportRecord(characters[id])
				any = true
			end
		end
		if any then
			Send(target, "DATA", payload)
		end
	end
	-- With no peers online, nothing is lost: the next digest exchange catches up.
	wipe(dirty)
end

-- Marks a record as changed so it's pushed to online peers. skipTarget is the
-- peer the change came from, so it isn't echoed straight back.
function addon.MarkDirty(id, skipTarget)
	local previous = dirty[id]
	if previous == nil then
		dirty[id] = skipTarget or true
	elseif previous ~= skipTarget then
		dirty[id] = true
	end
	if not flushPending then
		flushPending = true
		C_Timer.After(FLUSH_DELAY, Flush)
	end
end

---------------------------------------------------------------------------
-- Passive capture of friends who don't run the addon
---------------------------------------------------------------------------

local classTokenByName
local function ClassTokenFromLocalized(className)
	if not classTokenByName then
		classTokenByName = {}
		for token, name in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
			classTokenByName[name] = token
		end
		for token, name in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do
			classTokenByName[name] = token
		end
	end
	return className and classTokenByName[className]
end

-- Owners whose data has ever arrived from their own addon. Their addon sends
-- richer data, so the friend list isn't used for them.
local function AddonOwners()
	local owners = {}
	for _, record in pairs(FriendInfoTrackerDB.characters) do
		if record.owner and record.level and record.level.source == "addon" then
			owners[record.owner] = true
		end
	end
	return owners
end

local function CapturePassive(battleTag, game, addonOwners)
	if addonOwners[battleTag] or peers[game.gameAccountID] then
		return
	end
	local name, realmDisplay = game.characterName, game.realmName
	if not name or name == "" or not realmDisplay or realmDisplay == "" then
		return
	end
	-- Mirrors GetNormalizedRealmName(): display name with spaces/hyphens removed.
	local realm = realmDisplay:gsub("[%s%-]", "")
	local region = addon.REGION_NAMES[game.regionID] or addon.GetRegion()
	local id = string.format("%s-%s-%s", name, realm, region)

	local characters = FriendInfoTrackerDB.characters
	local record = characters[id]
	if record and record.isMine then
		return
	end

	local now = time()
	local level, zone = game.characterLevel, game.areaName
	if record and record.level and record.level.value == level
		and record.location and record.location.zone == zone
		and now - (record.level.updatedAt or 0) < BNET_REFRESH_SECONDS then
		return
	end

	record = record or {}
	record.owner = battleTag
	if not record.identity or record.identity.source == "bnet" then
		record.identity = {
			name = name,
			realm = realm,
			realmDisplay = realmDisplay,
			region = region,
			class = ClassTokenFromLocalized(game.className),
			race = game.raceName,
			faction = game.factionName,
			guid = game.playerGuid,
			updatedAt = now,
			source = "bnet",
		}
	end
	record.level = { value = level, updatedAt = now, source = "bnet" }
	record.location = { zone = zone, updatedAt = now, source = "bnet" }
	characters[id] = record
	addon.MarkDirty(id)
end

---------------------------------------------------------------------------
-- Friend scan
---------------------------------------------------------------------------

local function ScanFriends()
	scanPending = false
	if not FriendInfoTrackerDB or not BNConnected() then
		return
	end

	wipe(onlineWoW)
	local games = {}
	for friendIndex = 1, BNGetNumFriends() do
		local account = C_BattleNet.GetFriendAccountInfo(friendIndex)
		if account and account.battleTag then
			for gameIndex = 1, C_BattleNet.GetFriendNumGameAccounts(friendIndex) or 0 do
				local game = C_BattleNet.GetFriendGameAccountInfo(friendIndex, gameIndex)
				if game and game.isOnline and game.gameAccountID
					and game.clientProgram == BNET_CLIENT_WOW
					and game.wowProjectID == WOW_PROJECT_ID
					and game.isInCurrentRegion ~= false then
					onlineWoW[game.gameAccountID] = account.battleTag
					games[#games + 1] = game
				end
			end
		end
	end

	for id in pairs(peers) do
		if not onlineWoW[id] then
			peers[id] = nil
		end
	end
	for id in pairs(greeted) do
		if not onlineWoW[id] then
			greeted[id] = nil
		end
	end
	-- PING friends we haven't greeted yet. Friends who stayed silent past the
	-- grace period aren't running the addon, so record what the friend list
	-- shows instead. Capturing before the grace period would stamp friend-list
	-- data newer than the real addon data that's about to arrive.
	local now = GetTime()
	local addonOwners = AddonOwners()
	local captured = false
	for _, game in ipairs(games) do
		local id = game.gameAccountID
		if not greeted[id] then
			greeted[id] = now
			Send(id, "PING")
		elseif now - greeted[id] >= PING_GRACE then
			CapturePassive(onlineWoW[id], game, addonOwners)
			captured = true
		end
	end

	for key, buffer in pairs(inbound) do
		if now - buffer.started > REASSEMBLY_TIMEOUT then
			inbound[key] = nil
		end
	end

	if captured and addon.RefreshFrame then
		addon.RefreshFrame()
	end
end

local function ScheduleScan()
	if not scanPending then
		scanPending = true
		C_Timer.After(SCAN_DEBOUNCE, ScanFriends)
	end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function EnsurePeer(senderID)
	greeted[senderID] = greeted[senderID] or GetTime()
	if not onlineWoW[senderID] then
		ScanFriends()
	end
	local peer = peers[senderID]
	if not peer then
		peer = {}
		peers[senderID] = peer
	end
	peer.battleTag = onlineWoW[senderID] or peer.battleTag
	peer.lastSeen = time()
	return peer
end

local function BuildDigest()
	local digest = {}
	for id, record in pairs(FriendInfoTrackerDB.characters) do
		local entry = {}
		for index, section in ipairs(SECTIONS) do
			entry[index] = (record[section] and record[section].updatedAt) or 0
		end
		digest[id] = entry
	end
	return digest
end

local function SendDigest(target, peer)
	if not peer.digestSent then
		peer.digestSent = true
		Send(target, "DIGEST", BuildDigest())
	end
end

local function RecordsNewerThan(digest)
	local payload, any = {}, false
	for id, record in pairs(FriendInfoTrackerDB.characters) do
		local theirs = type(digest[id]) == "table" and digest[id] or {}
		for index, section in ipairs(SECTIONS) do
			local ours = (record[section] and record[section].updatedAt) or 0
			if ours > (tonumber(theirs[index]) or 0) then
				payload[id] = ExportRecord(record)
				any = true
				break
			end
		end
	end
	return payload, any
end

local function HandleMessage(senderID, msgType, body)
	local peer = EnsurePeer(senderID)

	if msgType == "PING" then
		Send(senderID, "PONG")
		SendDigest(senderID, peer)
	elseif msgType == "PONG" then
		SendDigest(senderID, peer)
	elseif msgType == "DIGEST" then
		local digest = addon.Deserialize(body)
		if type(digest) == "table" then
			local payload, any = RecordsNewerThan(digest)
			if any then
				Send(senderID, "DATA", payload)
			end
		end
	elseif msgType == "DATA" then
		local records = addon.Deserialize(body)
		if type(records) ~= "table" then
			return
		end
		local now, count, changed = time(), 0, false
		for id, incoming in pairs(records) do
			count = count + 1
			if count > MAX_RECORDS_PER_MESSAGE then
				break
			end
			local clean = SanitizeRecord(id, incoming, now)
			if clean and MergeRecord(id, clean, peer.battleTag) then
				addon.MarkDirty(id, senderID)
				changed = true
			end
		end
		if changed and addon.RefreshFrame then
			addon.RefreshFrame()
		end
	end
end

local function OnAddonMessage(prefix, text, _, senderID)
	if prefix ~= PREFIX or not senderID or type(text) ~= "string" then
		return
	end
	local version, msgType, msgID, seq, total, chunk = text:match("^(%d+):(%u+):(%d+):(%d+):(%d+):(.*)$")
	if version ~= PROTOCOL then
		return
	end
	seq, total = tonumber(seq), tonumber(total)
	if seq < 1 or total < 1 or seq > total or total > MAX_CHUNKS then
		return
	end

	local key = senderID .. ":" .. msgID
	local buffer = inbound[key]
	if not buffer then
		buffer = { parts = {}, count = 0, total = total, msgType = msgType, started = GetTime() }
		inbound[key] = buffer
	end
	if buffer.total ~= total or buffer.msgType ~= msgType then
		inbound[key] = nil
		return
	end
	if not buffer.parts[seq] then
		buffer.parts[seq] = chunk
		buffer.count = buffer.count + 1
	end
	if buffer.count < total then
		return
	end
	inbound[key] = nil
	HandleMessage(senderID, msgType, table.concat(buffer.parts))
end

---------------------------------------------------------------------------
-- Commands / status
---------------------------------------------------------------------------

function addon.ForceSync()
	wipe(greeted)
	for _, peer in pairs(peers) do
		peer.digestSent = false
	end
	ScanFriends()
	print("|cff33ff99FriendInfoTracker:|r syncing with online friends...")
end

function addon.PrintStatus()
	local names = {}
	for _, peer in pairs(peers) do
		names[#names + 1] = peer.battleTag or "?"
	end
	table.sort(names)
	local online = 0
	for _ in pairs(onlineWoW) do
		online = online + 1
	end
	print(string.format("|cff33ff99FriendInfoTracker:|r %d friend(s) in WoW, %d running the addon%s",
		online, #names, #names > 0 and (": " .. table.concat(names, ", ")) or ""))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BN_CHAT_MSG_ADDON")
eventFrame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
eventFrame:RegisterEvent("BN_CONNECTED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		C_Timer.After(5, ScanFriends)
		C_Timer.NewTicker(SCAN_INTERVAL, ScanFriends)
	elseif event == "BN_CHAT_MSG_ADDON" then
		OnAddonMessage(...)
	elseif event == "BN_FRIEND_INFO_CHANGED" or event == "BN_CONNECTED" then
		ScheduleScan()
	end
end)
