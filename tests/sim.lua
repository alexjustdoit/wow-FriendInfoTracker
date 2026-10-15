-- Simulates several WoW clients running the addon, wired together over a fake
-- Battle.net transport. Usage: lua sim.lua <addon dir>
local ADDON_DIR = arg[1]
local FILES = { "Core.lua", "Serialize.lua", "Sync.lua", "UI.lua", "Minimap.lua" }

local clock = 1000000
local timers = {}
local clients = {} -- by name
local byGameID = {}

local function schedule(delay, fn)
	timers[#timers + 1] = { at = clock + delay, fn = fn }
end

local function advance(seconds)
	local target = clock + seconds
	while true do
		table.sort(timers, function(a, b) return a.at < b.at end)
		local t = timers[1]
		if not t or t.at > target then break end
		table.remove(timers, 1)
		clock = math.max(clock, t.at)
		t.fn()
	end
	clock = target
end

local function stubFrame(env)
	local f = { events = {}, scripts = {} }
	local mt = {
		__index = function(_, k)
			if k == "RegisterEvent" then return function(self, e) self.events[e] = true end end
			if k == "SetScript" then return function(self, n, fn) self.scripts[n] = fn end end
			if k == "CreateTexture" or k == "CreateFontString" then return function() return stubFrame(env) end end
			return function() end
		end,
	}
	setmetatable(f, mt)
	env.__frames[#env.__frames + 1] = f
	return f
end

local function fire(client, event, ...)
	for _, f in ipairs(client.env.__frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end

local function newClient(spec)
	local env = setmetatable({}, { __index = _G })
	env._G = env
	env.__frames = {}
	local client = { name = spec.name, spec = spec, env = env, friends = {}, online = false, hasAddon = spec.hasAddon ~= false }
	clients[spec.name] = client
	byGameID[spec.gameID] = client

	env.print = function(...) end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	env.time = function() return math.floor(clock) end
	env.GetTime = function() return clock end
	env.CreateFrame = function() return stubFrame(env) end
	env.C_Timer = {
		After = function(d, fn) schedule(d, function() if client.online then fn() end end) end,
		NewTicker = function(d, fn)
			local function tick() if client.online then fn() schedule(d, tick) end end
			schedule(d, tick)
		end,
	}
	env.UnitName = function() return spec.char end
	env.GetNormalizedRealmName = function() return spec.realm end
	env.GetRealmName = function() return spec.realm end
	env.GetCurrentRegionName = function() return "US" end
	env.BNGetInfo = function() return 1, spec.tag end
	env.UnitClass = function() return "Mage", "MAGE" end
	env.UnitRace = function() return "Human", "Human" end
	env.UnitFactionGroup = function() return "Alliance" end
	env.UnitGUID = function() return "Player-1-" .. spec.gameID end
	env.UnitLevel = function() return spec.level end
	env.GetProfessions = function() return 1, nil, nil, nil, 2 end
	env.GetProfessionInfo = function(i)
		if i == 1 then return "Alchemy", nil, spec.alchemy, 100, nil, nil, 171 end
		return "Cooking", nil, 50, 100, nil, nil, 185
	end
	env.IsInInstance = function() return false end
	env.GetZoneText = function() return spec.zone end
	env.GetSubZoneText = function() return "" end
	env.C_Map = { GetBestMapForUnit = function() return 2339 end }
	env.C_ChatInfo = { RegisterAddonMessagePrefix = function() end }
	env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage", WARRIOR = "Warrior" }
	env.BNET_CLIENT_WOW = "WoW"
	env.WOW_PROJECT_ID = 1
	env.BNConnected = function() return true end
	env.SlashCmdList = {}
	env.Minimap = { GetWidth = function() return 140 end }

	local function onlineFriends()
		local list = {}
		for _, other in ipairs(client.friends) do
			if other.online then list[#list + 1] = other end
		end
		return list
	end
	env.BNGetNumFriends = function() return #onlineFriends() end
	env.C_BattleNet = {
		GetFriendAccountInfo = function(i) return { battleTag = onlineFriends()[i].spec.tag } end,
		GetFriendNumGameAccounts = function() return 1 end,
		GetFriendGameAccountInfo = function(i)
			local o = onlineFriends()[i].spec
			return {
				isOnline = true, gameAccountID = o.gameID, clientProgram = "WoW", wowProjectID = 1,
				characterName = o.char, realmName = o.realm, regionID = 1, characterLevel = o.level,
				className = "Mage", raceName = "Human", factionName = "Alliance", areaName = o.zone,
			}
		end,
	}
	client.sent = 0
	env.BNSendGameData = function(target, prefix, text)
		assert(#text <= 4078, "message too long: " .. #text)
		client.sent = client.sent + 1
		local dest = byGameID[target]
		schedule(0.05, function()
			if dest.online and dest.hasAddon then
				fire(dest, "BN_CHAT_MSG_ADDON", prefix, text, "WHISPER", spec.gameID)
			end
		end)
	end

	if client.hasAddon then
		for _, file in ipairs(FILES) do
			local chunk = assert(loadfile(ADDON_DIR .. "/" .. file, "t", env))
			chunk()
		end
	end
	return client
end

local function befriend(a, b)
	table.insert(a.friends, b)
	table.insert(b.friends, a)
end

local function login(client)
	client.online = true
	if not client.hasAddon then return end
	fire(client, "ADDON_LOADED", "FriendInfoTracker")
	fire(client, "PLAYER_LOGIN")
	for _, other in ipairs(client.friends) do
		if other.online and other.hasAddon then fire(other, "BN_FRIEND_INFO_CHANGED") end
	end
end

local function logout(client)
	fire(client, "PLAYER_LOGOUT")
	client.online = false
end

local function db(client) return client.env.FriendInfoTrackerDB.characters end

local passed, failed = 0, 0
local function check(label, cond)
	if cond then passed = passed + 1 print("PASS " .. label)
	else failed = failed + 1 print("FAIL " .. label) end
end

---------------------------------------------------------------------------
local A = newClient({ name = "A", tag = "Alice#1111", gameID = 11, char = "Alys", realm = "Stormrage", level = 70, alchemy = 40, zone = "Dornogal" })
local B = newClient({ name = "B", tag = "Bob#2222", gameID = 22, char = "Bobb", realm = "AreaFiftyTwo", level = 80, alchemy = 90, zone = "Hallowfall" })
local C = newClient({ name = "C", tag = "Cara#3333", gameID = 33, char = "Cara", realm = "Stormrage", level = 60, alchemy = 10, zone = "Azj-Kahet" })
local D = newClient({ name = "D", tag = "Dan#4444", gameID = 44, char = "Dano", realm = "Area 52", level = 75, zone = "Orgrimmar", hasAddon = false })
befriend(A, B); befriend(B, C); befriend(A, D)

-- 1. Direct sync A <-> B
login(A); login(B); login(D)
advance(120)
local bobOnA = db(A)["Bobb-AreaFiftyTwo-US"]
check("A has B's character", bobOnA ~= nil)
check("A has B's profession rank", bobOnA and bobOnA.professions and bobOnA.professions["171"].rank == 90)
check("B's data on A is marked direct from addon", bobOnA and bobOnA.level.source == "addon" and bobOnA.receivedFrom == "Bob#2222" and bobOnA.owner == "Bob#2222")
check("B has A's character", db(B)["Alys-Stormrage-US"] ~= nil)
check("isMine not leaked over wire", bobOnA and bobOnA.isMine == nil)

-- 2. Passive capture of D (no addon)
local danOnA = db(A)["Dano-Area52-US"]
check("A passively captured D (realm normalized)", danOnA ~= nil and danOnA.level.value == 75 and danOnA.level.source == "bnet")
check("passive capture has class token", danOnA and danOnA.identity.class == "MAGE")
check("passive capture has no professions", danOnA and danOnA.professions == nil)
check("passive data relayed A->B", db(B)["Dano-Area52-US"] ~= nil)
check("B did not passively capture A (A runs addon)", db(B)["Alys-Stormrage-US"].level.source == "addon")

-- 3. Relay: A levels alchemy and logs out; C never overlaps with A
A.spec.alchemy = 55
fire(A, "SKILL_LINES_CHANGED")
advance(60) -- flush pushes the change to B
logout(A)
login(C)
advance(120)
local alysOnC = db(C)["Alys-Stormrage-US"]
check("C received A's data via B without overlapping A", alysOnC ~= nil and alysOnC.professions["171"].rank == 55)
check("C sees it as relayed via Bob", alysOnC and alysOnC.receivedFrom == "Bob#2222" and alysOnC.owner == "Alice#1111")
check("C got D's passive data via relay", db(C)["Dano-Area52-US"] ~= nil)

-- 4. Live push: B levels up while C online
B.spec.level = 81
fire(B, "PLAYER_LEVEL_UP")
advance(60)
check("level-up pushed B->C", db(C)["Bobb-AreaFiftyTwo-US"].level.value == 81)

-- 5. Own records can't be overwritten by others
local Senv = C.env
local evil = Senv.FriendInfoTracker.Serialize({
	["Cara-Stormrage-US"] = { owner = "Mallory#9", level = { value = 1, updatedAt = clock + 10, source = "addon" } },
	["Fake-Realm-US"] = {
		identity = { name = "Other", realm = "Realm", region = "US", updatedAt = clock },
		level = { value = 5, updatedAt = clock + 99999999, source = "addon" },
		location = { zone = "|cffff0000red|r", updatedAt = clock },
		professions = { ["171"] = { name = "X", rank = "lots" }, ["evil"] = { name = "Y" }, updatedAt = clock },
	},
	["bad id with no hyphens"] = { level = { value = 3, updatedAt = clock } },
})
fire(C, "BN_CHAT_MSG_ADDON", "FIT", "1:DATA:999:1:1:" .. evil, "WHISPER", 22)
check("own record not overwritten", db(C)["Cara-Stormrage-US"].level.value == 60)
local fake = db(C)["Fake-Realm-US"]
check("future timestamp clamped", fake and fake.level.updatedAt <= clock + 3600)
check("identity not matching id dropped", fake and fake.identity == nil)
check("non-numeric profession key dropped", fake and fake.professions.evil == nil)
check("non-number rank sanitized to nil", fake and fake.professions["171"].rank == nil)
check("bad id rejected", db(C)["bad id with no hyphens"] == nil)

-- 6. Malformed input never errors
local ok = pcall(function()
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "1:DATA:1000:1:1:{s999:abc", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "garbage", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "1:DATA:1001:5:3:x", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "1:DIGEST:1002:1:1:" .. string.rep("{", 50), "WHISPER", 22)
end)
check("malformed messages handled without error", ok)

-- 7. Serializer round trip incl. UTF-8 and chunking of a large payload
local S = A.env.FriendInfoTracker
local big = {}
for i = 1, 400 do big["Ñame" .. i .. "-Réalm-EU"] = { identity = { name = "Ñäme" .. i }, level = { value = i, updatedAt = 1.5 } } end
local round = S.Deserialize(S.Serialize(big))
check("serializer round trip", round and round["Ñame400-Réalm-EU"].identity.name == "Ñäme400" and round["Ñame7-Réalm-EU"].level.updatedAt == 1.5)
check("deserialize rejects trailing junk", S.Deserialize(S.Serialize({ a = 1 }) .. "x") == nil)

-- 8. Large sync across many chunks
local E = newClient({ name = "E", tag = "Eve#5555", gameID = 55, char = "Evee", realm = "Stormrage", level = 70, alchemy = 1, zone = "Dornogal" })
login(E)
for i = 1, 300 do
	db(E)["Alt" .. i .. "-Stormrage-US"] = { isMine = true, owner = "Eve#5555",
		identity = { name = "Alt" .. i, realm = "Stormrage", region = "US", updatedAt = clock, source = "self" },
		level = { value = i % 80, updatedAt = clock, source = "self" } }
end
befriend(C, E)
fire(C, "BN_FRIEND_INFO_CHANGED"); fire(E, "BN_FRIEND_INFO_CHANGED")
advance(300)
local count = 0
for id in pairs(db(C)) do if id:match("^Alt%d+") then count = count + 1 end end
check("300-record multi-chunk sync delivered all records", count == 300)

-- 9. Idempotence: no ping-pong traffic once in sync
local before = A.sent + B.sent + C.sent + E.sent
advance(600)
check("no traffic churn once synced", (A.sent + B.sent + C.sent + E.sent) == before)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
