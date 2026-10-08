local ADDON_NAME = "WoWForever"
WoWForever = WoWForever or {}
local addon = WoWForever

local SCHEMA_VERSION = 1

local REGION_NAMES = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }

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

local function InitDB()
	WoWForeverDB = WoWForeverDB or {}
	WoWForeverDB.schemaVersion = WoWForeverDB.schemaVersion or SCHEMA_VERSION
	WoWForeverDB.characters = WoWForeverDB.characters or {}
	-- Future schema migrations go here, keyed off WoWForeverDB.schemaVersion.
end

local function GetCharacterRecord()
	local id = GetCharacterID()
	WoWForeverDB.characters[id] = WoWForeverDB.characters[id] or {}
	return WoWForeverDB.characters[id], id
end
addon.GetCharacterRecord = GetCharacterRecord

local function CaptureIdentity()
	local record = GetCharacterRecord()
	local _, name, realm, region = GetCharacterID()
	local _, classToken = UnitClass("player")
	local _, raceToken = UnitRace("player")
	local faction = UnitFactionGroup("player")
	record.identity = {
		name = name,
		realm = realm,
		realmDisplay = GetRealmName(),
		region = region,
		class = classToken,
		race = raceToken,
		faction = faction,
		guid = UnitGUID("player"),
	}
end

local function CaptureLevel()
	local record = GetCharacterRecord()
	record.level = {
		value = UnitLevel("player"),
		updatedAt = time(),
	}
end

-- GetProfessions() returns up to five slot indices: two primary, then
-- archaeology/fishing/cooking. GetProfessionInfo's 7th return value is the
-- skillLineID, which we use as the stable key (e.g. 164 = Blacksmithing).
local function CaptureProfessions()
	local record = GetCharacterRecord()
	local professions = { updatedAt = time() }

	local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
	local slots = {
		{ index = prof1, type = "primary" },
		{ index = prof2, type = "primary" },
		{ index = archaeology, type = "secondary" },
		{ index = fishing, type = "secondary" },
		{ index = cooking, type = "secondary" },
	}

	for _, slot in ipairs(slots) do
		if slot.index then
			local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(slot.index)
			if skillLine then
				professions[tostring(skillLine)] = {
					name = name,
					type = slot.type,
					rank = rank,
					maxRank = maxRank,
				}
			end
		end
	end

	record.professions = professions
end

local function CaptureLocation()
	local record = GetCharacterRecord()
	local inInstance, instanceType = IsInInstance()
	record.location = {
		zone = GetZoneText(),
		subzone = GetSubZoneText(),
		mapID = C_Map.GetBestMapForUnit("player"),
		inInstance = inInstance,
		instanceType = inInstance and instanceType or nil,
		updatedAt = time(),
	}
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
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
		end
	elseif event == "PLAYER_LOGIN" then
		CaptureAll()
	elseif event == "PLAYER_LEVEL_UP" then
		CaptureLevel()
	elseif event == "SKILL_LINES_CHANGED" or event == "TRADE_SKILL_SHOW" then
		CaptureProfessions()
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
