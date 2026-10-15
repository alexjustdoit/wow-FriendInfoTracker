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
	local f = { events = {}, scripts = {}, shown = true, height = 0 }
	local methods = {
		RegisterEvent = function(self, e) self.events[e] = true end,
		SetScript = function(self, n, fn) self.scripts[n] = fn end,
		CreateTexture = function() return stubFrame(env) end,
		CreateFontString = function() return stubFrame(env) end,
		Show = function(self) self.shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end,
		Hide = function(self)
			local was = self.shown
			self.shown = false
			if was and self.scripts.OnHide then self.scripts.OnHide(self) end
		end,
		SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
		IsShown = function(self) return self.shown end,
		SetHeight = function(self, h) self.height = h end,
		GetHeight = function(self) return self.height end,
		SetText = function(self, t) self.text = t end,
		GetStringHeight = function() return 12 end,
		SetChecked = function(self, v) self.checked = v and true or false end,
		GetChecked = function(self) return self.checked end,
	}
	local mt = {
		__index = function(_, k)
			if methods[k] then return methods[k] end
			if k:match("^Get") then return function() return 0 end end
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
	env.CreateFrame = function(_, name)
		local f = stubFrame(env)
		if name then env[name] = f end
		return f
	end
	env.UISpecialFrames = {}
	env.tinsert = table.insert
	env.GameTooltip = stubFrame(env)
	env.GameTooltip_Hide = function() end
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
	client.texts = {}
	env.BNSendGameData = function(target, prefix, text)
		assert(#text <= 4078, "message too long: " .. #text)
		client.sent = client.sent + 1
		client.texts[#client.texts + 1] = text
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
check("A has B's profession rank", bobOnA and bobOnA.professions and bobOnA.professions["Alchemy"].rank == 90)
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
check("C received A's data via B without overlapping A", alysOnC ~= nil and alysOnC.professions["Alchemy"].rank == 55)
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
		professions = { ["Alchemy"] = { name = "X", rank = "lots" }, [string.rep("e", 80)] = { name = "Y" }, updatedAt = clock },
		recipes = { ["Alchemy"] = { "Elixir", 42, string.rep("r", 500) }, updatedAt = clock },
	},
	["bad id with no hyphens"] = { level = { value = 3, updatedAt = clock } },
})
fire(C, "BN_CHAT_MSG_ADDON", "FIT", "2:DATA:999:1:1:" .. evil, "WHISPER", 22)
check("own record not overwritten", db(C)["Cara-Stormrage-US"].level.value == 60)
local fake = db(C)["Fake-Realm-US"]
check("future timestamp clamped", fake and fake.level.updatedAt <= clock + 3600)
check("identity not matching id dropped", fake and fake.identity == nil)
check("over-long profession key dropped", fake and fake.professions[string.rep("e", 80)] == nil)
check("non-number rank sanitized to nil", fake and fake.professions["Alchemy"].rank == nil)
check("recipe list sanitized (non-strings dropped, long names capped)", fake and #fake.recipes.Alchemy == 2 and #fake.recipes.Alchemy[2] == 96)
check("bad id rejected", db(C)["bad id with no hyphens"] == nil)

-- 6. Malformed input never errors
local ok = pcall(function()
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "2:DATA:1000:1:1:{s999:abc", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "garbage", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "2:DATA:1001:5:3:x", "WHISPER", 22)
	fire(C, "BN_CHAT_MSG_ADDON", "FIT", "2:DIGEST:1002:1:1:" .. string.rep("{", 50), "WHISPER", 22)
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


-- 10. Recipes: capture, grow-only merge, sync
local bobID = "Bobb-AreaFiftyTwo-US"
local function openTrade(client, name, recipes)
	client.env.GetTradeSkillLine = function() return name, 100, 300 end
	client.env.GetNumTradeSkills = function() return #recipes end
	client.env.GetTradeSkillInfo = function(i) return recipes[i][1], recipes[i][2] end
	fire(client, "TRADE_SKILL_SHOW")
	fire(client, "TRADE_SKILL_UPDATE")
	advance(1)
end
openTrade(B, "Alchemy", { { "Flasks", "header" }, { "Flask of Titans", "optimal" }, { "Elixir of Giants", "trivial" } })
check("recipes captured, headers skipped", db(B)[bobID].recipes and #db(B)[bobID].recipes.Alchemy == 2)
local before = db(B)[bobID].recipes.updatedAt
advance(5)
openTrade(B, "Alchemy", { { "Flask of Titans", "optimal" } })
check("filtered window doesn't shrink recipe list", #db(B)[bobID].recipes.Alchemy == 2)
check("reopening with nothing new doesn't bump updatedAt", db(B)[bobID].recipes.updatedAt == before)
openTrade(B, "Alchemy", { { "Flask of Titans", "optimal" }, { "Major Healing Potion", "easy" } })
check("newly learned recipe added", #db(B)[bobID].recipes.Alchemy == 3)
advance(60)
check("recipes synced to C", db(C)[bobID].recipes and #db(C)[bobID].recipes.Alchemy == 3)

-- Vanilla Craft window (Enchanting)
B.env.GetCraftDisplaySkillLine = function() return "Cooking", 50, 100 end
B.env.GetNumCrafts = function() return 2 end
B.env.GetCraftInfo = function(i)
	if i == 1 then return "Meats", "", "header" end
	return "Spiced Wolf Meat", "", "easy"
end
fire(B, "CRAFT_SHOW")
advance(1)
check("craft window recipes captured", db(B)[bobID].recipes.Cooking and #db(B)[bobID].recipes.Cooking == 1)

-- Unlearning a profession prunes its recipes
B.env.GetProfessions = function() return nil, nil, nil, nil, 2 end
fire(B, "SKILL_LINES_CHANGED")
check("unlearned profession's recipes pruned", db(B)[bobID].recipes.Alchemy == nil and db(B)[bobID].recipes.Cooking ~= nil)
check("unlearned profession removed", db(B)[bobID].professions.Alchemy == nil)

-- 11. Vanilla-based client: skill-line profession capture
local F = newClient({ name = "F", tag = "Finn#6666", gameID = 66, char = "Finn", realm = "Stormrage", level = 40, alchemy = 1, zone = "Ironforge" })
F.env.GetProfessions = nil
F.skillLines = {
	{ "Class Skills", true, true }, { "Fire", false, false, 1, 1 },
	{ "Professions", true, true }, { "Tailoring", false, false, 120, 150 }, { "Enchanting", false, false, 90, 150 },
	{ "Secondary Skills", true, true }, { "First Aid", false, false, 75, 75 }, { "Fishing", false, false, 1, 75 },
	{ "Weapon Skills", true, true }, { "Staves", false, false, 200, 200 },
}
F.env.GetNumSkillLines = function() return #F.skillLines end
F.env.GetSkillLineInfo = function(i)
	local l = F.skillLines[i]
	return l[1], l[2], l[3], l[4], 0, 0, l[5]
end
login(F)
local finn = db(F)["Finn-Stormrage-US"].professions
check("classic: primary professions from skill lines", finn.Tailoring and finn.Tailoring.type == "primary" and finn.Tailoring.rank == 120 and finn.Enchanting ~= nil)
check("classic: secondary professions from skill lines", finn["First Aid"] and finn["First Aid"].type == "secondary" and finn.Fishing ~= nil)
check("classic: non-profession skills ignored", finn.Staves == nil and finn.Fire == nil)
F.skillLines = {
	{ "Class Skills", true, true }, { "Fire", false, false, 1, 1 },
	{ "Professions", true, false },
	{ "Secondary Skills", true, true }, { "First Aid", false, false, 75, 75 },
}
fire(F, "SKILL_LINES_CHANGED")
check("classic: collapsed header doesn't wipe professions", db(F)["Finn-Stormrage-US"].professions.Tailoring ~= nil)

-- 12. Large recipe payload is split into several DATA messages
for i = 1, 300 do
	local list = {}
	for r = 1, 100 do list[r] = "Recipe number " .. r end
	db(E)["Alt" .. i .. "-Stormrage-US"].recipes = { Alchemy = list, updatedAt = clock, source = "self" }
end
local G = newClient({ name = "G", tag = "Gus#7777", gameID = 77, char = "Guss", realm = "Stormrage", level = 10, alchemy = 1, zone = "Dornogal" })
befriend(E, G)
login(G)
fire(E, "BN_FRIEND_INFO_CHANGED")
advance(900)
local dataMessages, withRecipes = 0, 0
for _, text in ipairs(E.texts) do
	if text:match("^2:DATA:%d+:1:") then dataMessages = dataMessages + 1 end
end
for id, rec in pairs(db(G)) do
	if id:match("^Alt%d+") and rec.recipes and #rec.recipes.Alchemy == 100 then withRecipes = withRecipes + 1 end
end
check("large sync split into multiple DATA messages (" .. dataMessages .. ")", dataMessages > 5)
check("all 300 alts' recipes delivered", withRecipes == 300)

-- 13. UI smoke test: open window, click a character, recipe panel renders
local CA = C.env.FriendInfoTracker
local ok, err = pcall(function()
	CA.ToggleUI()
	local mainFrame = C.env.FriendInfoTrackerFrame
	local clicked
	for _, row in ipairs(mainFrame.rows) do
		if row.entry and row.entry.id == bobID then
			row.scripts.OnClick(row)
			clicked = row
		end
	end
	assert(clicked, "Bob's row not found")
	local row = clicked
	row.scripts.OnEnter(row)
	local panelText = C.env.FriendInfoTrackerRecipes.text.text
	assert(panelText:find("Cooking") and panelText:find("Spiced Wolf Meat"), "recipe panel missing recipes: " .. tostring(panelText))
	local secondary = clicked.cells.secondary.text
	assert(secondary:find("Cooking"), "secondary column missing Cooking: " .. tostring(secondary))
	row.scripts.OnClick(row) -- toggles panel closed
	assert(not C.env.FriendInfoTrackerRecipes:IsShown(), "panel didn't close")
	CA.ToggleUI()
end)
check("UI renders rows, columns, and recipe panel" .. (ok and "" or (": " .. tostring(err))), ok)

-- 14. Hidden friends section and Settings panel
local ok2, err2 = pcall(function()
	local UI = C.env.FriendInfoTracker
	UI.ToggleUI()
	local mainFrame = C.env.FriendInfoTrackerFrame
	local function visibleEntries()
		local list = {}
		for _, row in ipairs(mainFrame.rows) do
			if row.shown and row.entry then list[#list + 1] = row.entry end
		end
		return list
	end
	local function find(pred)
		for _, row in ipairs(mainFrame.rows) do
			if row.shown and row.entry and pred(row.entry) then return row end
		end
	end

	assert(not find(function(e) return e.kind == "hiddenHeader" end), "no Hidden section before hiding anyone")

	-- Hide Bob with the group header's Hide button
	local bobHeader = find(function(e) return e.kind == "group" and e.key == "Bob#2222" end)
	assert(bobHeader and bobHeader.toggle.text == "Hide", "Bob's header has a Hide button")
	bobHeader.toggle.scripts.OnClick(bobHeader.toggle)
	assert(C.env.FriendInfoTrackerSettings.hiddenFriends["Bob#2222"], "Bob stored as hidden")

	local entries = visibleEntries()
	local last = entries[#entries]
	assert(last.kind == "hiddenHeader" and last.count == 1, "Hidden section is last, with 1 friend")
	assert(not find(function(e) return e.kind == "character" and e.id == bobID end), "Bob's characters collapsed away")
	local ownHeader = find(function(e) return e.kind == "group" and e.isMine end)
	assert(ownHeader and not ownHeader.toggle.shown, "own group has no Hide button")

	-- Expand the Hidden section
	local hiddenRow = find(function(e) return e.kind == "hiddenHeader" end)
	hiddenRow.scripts.OnClick(hiddenRow)
	local bobRow = find(function(e) return e.kind == "character" and e.id == bobID end)
	assert(bobRow and bobRow.entry.dimmed, "expanded Hidden section shows Bob dimmed")
	entries = visibleEntries()
	local sawHidden = false
	for _, e in ipairs(entries) do
		if e.kind == "hiddenHeader" then sawHidden = true end
		if e.kind == "character" and e.id == bobID then assert(sawHidden, "Bob listed below the Hidden header") end
	end

	-- Show Bob again via the header button inside the Hidden section
	bobHeader = find(function(e) return e.kind == "group" and e.key == "Bob#2222" end)
	assert(bobHeader.toggle.text == "Show", "hidden friend's button says Show")
	bobHeader.toggle.scripts.OnClick(bobHeader.toggle)
	assert(not C.env.FriendInfoTrackerSettings.hiddenFriends["Bob#2222"], "Bob unhidden")
	assert(not find(function(e) return e.kind == "hiddenHeader" end), "Hidden section gone when empty")

	-- Settings panel: friend checkboxes, minimap toggle
	UI.ToggleSettings()
	local panel = C.env.FriendInfoTrackerSettingsPanel
	assert(panel:IsShown(), "settings panel open")
	local bobCheck
	for _, check in ipairs(panel.friendChecks) do
		if check.shown and check.friendKey == "Bob#2222" then bobCheck = check end
	end
	assert(bobCheck and bobCheck.checked == true, "Bob listed and checked (visible)")
	bobCheck:SetChecked(false)
	bobCheck.scripts.OnClick(bobCheck)
	assert(C.env.FriendInfoTrackerSettings.hiddenFriends["Bob#2222"], "unchecking hides Bob")
	assert(find(function(e) return e.kind == "hiddenHeader" end), "Hidden section appears")
	bobCheck:SetChecked(true)
	bobCheck.scripts.OnClick(bobCheck)
	assert(not C.env.FriendInfoTrackerSettings.hiddenFriends["Bob#2222"], "checking shows Bob")

	panel.minimapCheck:SetChecked(false)
	panel.minimapCheck.scripts.OnClick(panel.minimapCheck)
	assert(C.env.FriendInfoTrackerCharDB.hideMinimapButton == true, "minimap hidden via settings")
	panel.minimapCheck:SetChecked(true)
	panel.minimapCheck.scripts.OnClick(panel.minimapCheck)
	assert(C.env.FriendInfoTrackerCharDB.hideMinimapButton == false, "minimap shown via settings")

	-- Recipe panel and settings are mutually exclusive
	bobRow = find(function(e) return e.kind == "character" and e.id == bobID end)
	bobRow.scripts.OnClick(bobRow)
	assert(C.env.FriendInfoTrackerRecipes:IsShown() and not panel:IsShown(), "opening recipes closes settings")
	UI.ToggleSettings()
	assert(panel:IsShown() and not C.env.FriendInfoTrackerRecipes:IsShown(), "opening settings closes recipes")

	-- Closing the main window closes the panels
	UI.ToggleUI()
	assert(not panel:IsShown(), "closing main window closes settings")
end)
check("hidden friends + settings panel" .. (ok2 and "" or (": " .. tostring(err2))), ok2)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
