local ADDON_NAME = "FriendInfoTracker"
FriendInfoTracker = FriendInfoTracker or {}
local addon = FriendInfoTracker

local SCHEMA_VERSION = 3

local REGION_NAMES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
addon.REGION_NAMES = REGION_NAMES

-- Sections of a character record that carry their own updatedAt and are
-- merged independently (latest updatedAt wins) when syncing with friends.
addon.SECTIONS = { "identity", "level", "professions", "location", "recipes" }

local function GetRegion()
	if GetCurrentRegionName then
		local ok, region = pcall(GetCurrentRegionName)
		if ok and region then
			return region
		end
	end
	local regionID = GetCurrentRegion and GetCurrentRegion() or nil
	return REGION_NAMES[regionID] or "US"
end
addon.GetRegion = GetRegion

-- Returns the stable "Name-Realm-Region" id used as the characters table key,
-- plus the three components individually.
local function GetCharacterID()
	local name = UnitName("player")
	local realm = GetNormalizedRealmName()
	local region = GetRegion()
	return string.format("%s-%s-%s", name, realm, region), name, realm, region
end
addon.GetCharacterID = GetCharacterID

-- BattleTag of the logged-in Battle.net account. Cached in the DB because
-- BNGetInfo() returns nil while Battle.net is disconnected.
local function GetMyBattleTag()
	local _, battleTag = BNGetInfo()
	if battleTag then
		FriendInfoTrackerDB.myBattleTag = battleTag
	end
	return FriendInfoTrackerDB.myBattleTag
end
addon.GetMyBattleTag = GetMyBattleTag

local function MigrateDB()
	local db = FriendInfoTrackerDB
	if db.schemaVersion < 2 then
		-- v1 only ever stored this account's own characters.
		for _, record in pairs(db.characters) do
			record.isMine = true
			for _, section in ipairs(addon.SECTIONS) do
				if record[section] then
					record[section].source = "self"
				end
			end
			if record.identity and not record.identity.updatedAt then
				record.identity.updatedAt = (record.level and record.level.updatedAt) or time()
			end
		end
		db.schemaVersion = 2
	end
	if db.schemaVersion < 3 then
		-- Professions were keyed by skillLineID; now keyed by name to line up
		-- with recipes (Vanilla-based clients have no skillLineID).
		for _, record in pairs(db.characters) do
			local professions = record.professions
			if professions then
				local rekeyed = { updatedAt = professions.updatedAt, source = professions.source }
				for key, prof in pairs(professions) do
					if type(prof) == "table" and prof.name then
						prof.skillLine = prof.skillLine or tonumber(key)
						rekeyed[prof.name] = prof
					end
				end
				record.professions = rekeyed
			end
		end
		db.schemaVersion = 3
	end
end

local function InitDB()
	FriendInfoTrackerDB = FriendInfoTrackerDB or {}
	FriendInfoTrackerDB.schemaVersion = FriendInfoTrackerDB.schemaVersion or SCHEMA_VERSION
	FriendInfoTrackerDB.characters = FriendInfoTrackerDB.characters or {}
	MigrateDB()
	FriendInfoTrackerCharDB = FriendInfoTrackerCharDB or {}
end

local function GetCharacterRecord()
	local id = GetCharacterID()
	FriendInfoTrackerDB.characters[id] = FriendInfoTrackerDB.characters[id] or {}
	local record = FriendInfoTrackerDB.characters[id]
	record.isMine = true
	return record, id
end
addon.GetCharacterRecord = GetCharacterRecord

-- Queues the record for pushing to online friends and redraws the window.
local function OnRecordChanged(id)
	if addon.MarkDirty then
		addon.MarkDirty(id)
	end
	if addon.RefreshFrame then
		addon.RefreshFrame()
	end
end

local function CaptureIdentity()
	local record, id = GetCharacterRecord()
	local _, name, realm, region = GetCharacterID()
	local _, classToken = UnitClass("player")
	local _, raceToken = UnitRace("player")
	local faction = UnitFactionGroup("player")
	record.owner = GetMyBattleTag()
	record.identity = {
		name = name,
		realm = realm,
		realmDisplay = GetRealmName(),
		region = region,
		class = classToken,
		race = raceToken,
		faction = faction,
		guid = UnitGUID("player"),
		updatedAt = time(),
		source = "self",
	}
	OnRecordChanged(id)
end

local function CaptureLevel(newLevel)
	local record, id = GetCharacterRecord()
	record.level = {
		value = tonumber(newLevel) or UnitLevel("player"),
		updatedAt = time(),
		source = "self",
	}
	OnRecordChanged(id)
end

-- Professions are keyed by name in both capture paths, so recipes (also keyed
-- by profession name) line up with them.

-- Modern clients: GetProfessions() returns up to five slot indices (two
-- primary, then archaeology/fishing/cooking). Returns nil if the API is
-- missing or the character has no professions.
local function ReadProfessionsModern()
	if not GetProfessions then
		return nil
	end
	local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
	local slots = {
		{ index = prof1, type = "primary" },
		{ index = prof2, type = "primary" },
		{ index = archaeology, type = "secondary" },
		{ index = fishing, type = "secondary" },
		{ index = cooking, type = "secondary" },
	}
	local professions, any = {}, false
	for _, slot in ipairs(slots) do
		if slot.index then
			local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(slot.index)
			if name then
				professions[name] = { name = name, type = slot.type, rank = rank, maxRank = maxRank, skillLine = skillLine }
				any = true
			end
		end
	end
	return any and professions or nil
end

-- Vanilla-based clients: walk the skill list (the Skills tab), where
-- professions sit under "Professions" and "Secondary Skills" headers.
-- Returns nil if one of those headers is collapsed, because collapsed
-- sections hide their skills and we'd wrongly record them as unlearned.
local PRIMARY_HEADERS = { ["Professions"] = true }
local SECONDARY_HEADERS = { ["Secondary Skills"] = true }
if TRADE_SKILLS then
	PRIMARY_HEADERS[TRADE_SKILLS] = true
end
if SECONDARY_SKILLS then
	SECONDARY_HEADERS[(SECONDARY_SKILLS:gsub(":$", ""))] = true
end

local function ReadProfessionsFromSkillLines()
	if not GetNumSkillLines then
		return nil
	end
	local professions = {}
	local sectionType
	for index = 1, GetNumSkillLines() do
		local name, isHeader, isExpanded, rank, _, _, maxRank = GetSkillLineInfo(index)
		if isHeader then
			sectionType = (PRIMARY_HEADERS[name] and "primary") or (SECONDARY_HEADERS[name] and "secondary") or nil
			if sectionType and not isExpanded then
				return nil
			end
		elseif sectionType and name then
			professions[name] = { name = name, type = sectionType, rank = rank, maxRank = maxRank }
		end
	end
	return professions
end

-- Drops recipe lists for professions the character no longer has.
local function PruneRecipes(record)
	local recipes = record.recipes
	if not recipes or not record.professions then
		return
	end
	local pruned = false
	for key in pairs(recipes) do
		if key ~= "updatedAt" and key ~= "source" and not record.professions[key] then
			recipes[key] = nil
			pruned = true
		end
	end
	if pruned then
		recipes.updatedAt = time()
	end
end

local function CaptureProfessions()
	local professions = ReadProfessionsModern() or ReadProfessionsFromSkillLines()
	if not professions and GetProfessions and not GetNumSkillLines then
		professions = {} -- modern client, genuinely no professions
	end
	if not professions then
		return -- API unavailable or a profession header is collapsed
	end
	local record, id = GetCharacterRecord()
	professions.updatedAt = time()
	professions.source = "self"
	record.professions = professions
	PruneRecipes(record)
	OnRecordChanged(id)
end

-- Recipes can only be read while that profession's window is open.
-- Returns professionName, { recipeName, ... } for the open window, or nil.
local function ReadOpenRecipes(isCraftWindow)
	local names = {}
	if isCraftWindow then
		-- Vanilla Enchanting uses the separate Craft window/API.
		local professionName = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
		if not professionName or not GetNumCrafts then
			return nil
		end
		for index = 1, GetNumCrafts() do
			local name, _, craftType = GetCraftInfo(index)
			if name and craftType ~= "header" then
				names[#names + 1] = name
			end
		end
		return professionName, names
	end

	if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetBaseProfessionInfo then
		local info = C_TradeSkillUI.GetBaseProfessionInfo()
		local professionName = info and info.professionName
		if not professionName then
			return nil
		end
		for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
			local recipe = C_TradeSkillUI.GetRecipeInfo(recipeID)
			if recipe and recipe.learned and recipe.name then
				names[#names + 1] = recipe.name
			end
		end
		return professionName, names
	end

	local professionName = GetTradeSkillLine and GetTradeSkillLine()
	if not professionName or professionName == "UNKNOWN" or not GetNumTradeSkills then
		return nil
	end
	for index = 1, GetNumTradeSkills() do
		local name, skillType = GetTradeSkillInfo(index)
		if name and skillType ~= "header" and skillType ~= "subheader" then
			names[#names + 1] = name
		end
	end
	return professionName, names
end

-- Merges the open window's recipes into what's already stored. Lists only
-- grow, so a filtered or collapsed window never erases known recipes.
local function CaptureRecipes(isCraftWindow)
	local professionName, names = ReadOpenRecipes(isCraftWindow)
	if not professionName or #names == 0 then
		return
	end
	local record, id = GetCharacterRecord()
	record.recipes = record.recipes or { source = "self" }
	local recipes = record.recipes

	local known, list = {}, recipes[professionName] or {}
	for _, name in ipairs(list) do
		known[name] = true
	end
	local added = false
	for _, name in ipairs(names) do
		if not known[name] then
			known[name] = true
			list[#list + 1] = name
			added = true
		end
	end
	if not added then
		return
	end
	table.sort(list)
	recipes[professionName] = list
	recipes.updatedAt = time()
	recipes.source = "self"
	OnRecordChanged(id)
end

-- The recipe window fires its update event repeatedly while it populates.
local recipeCapturePending = {}
local function ScheduleRecipeCapture(isCraftWindow)
	local key = isCraftWindow and "craft" or "trade"
	if recipeCapturePending[key] then
		return
	end
	recipeCapturePending[key] = true
	C_Timer.After(0.5, function()
		recipeCapturePending[key] = false
		CaptureRecipes(isCraftWindow)
	end)
end

local function CaptureLocation()
	local record, id = GetCharacterRecord()
	local inInstance, instanceType = IsInInstance()
	record.location = {
		zone = GetZoneText(),
		subzone = GetSubZoneText(),
		mapID = C_Map.GetBestMapForUnit("player"),
		inInstance = inInstance,
		instanceType = inInstance and instanceType or nil,
		updatedAt = time(),
		source = "self",
	}
	OnRecordChanged(id)
end
addon.CaptureLocation = CaptureLocation

local function CaptureAll()
	CaptureIdentity()
	CaptureLevel()
	CaptureProfessions()
	CaptureLocation()
end
addon.CaptureAll = CaptureAll

local function GetAddonVersion()
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
	end
	return "unknown"
end

local eventFrame = CreateFrame("Frame")
-- Not every event exists in every client flavor (e.g. CRAFT_* is Vanilla-only,
-- NEW_RECIPE_LEARNED is modern-only), and registering an unknown one errors.
for _, event in ipairs({
	"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED",
	"TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "NEW_RECIPE_LEARNED",
	"CRAFT_SHOW", "CRAFT_UPDATE",
	"ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_LOGOUT",
}) do
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "PLAYER_LOGIN" then
		CaptureAll()
	elseif event == "PLAYER_LEVEL_UP" then
		-- UnitLevel() can still report the old level while this event fires.
		CaptureLevel(arg1)
	elseif event == "SKILL_LINES_CHANGED" then
		CaptureProfessions()
	elseif event == "TRADE_SKILL_SHOW" then
		CaptureProfessions()
		ScheduleRecipeCapture(false)
	elseif event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE" or event == "NEW_RECIPE_LEARNED" then
		ScheduleRecipeCapture(false)
	elseif event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
		ScheduleRecipeCapture(true)
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
		CaptureLocation()
	elseif event == "PLAYER_LOGOUT" then
		CaptureLocation()
		local record = GetCharacterRecord()
		record.meta = {
			addonVersion = GetAddonVersion(),
			lastLogout = time(),
		}
	end
end)
