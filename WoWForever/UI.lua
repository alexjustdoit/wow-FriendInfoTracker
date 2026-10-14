local addon = WoWForever

local ROW_HEIGHT = 20
local ROW_WIDTH = 460
local STALE_AFTER_SECONDS = 7 * 86400

local frame

local function RelativeTime(epoch)
	if not epoch then
		return "never"
	end
	local diff = time() - epoch
	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m ago"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h ago"
	else
		return math.floor(diff / 86400) .. "d ago"
	end
end

-- Escapes UI markup in strings that may have come from other players.
local function Safe(text)
	return (tostring(text):gsub("|", "||"))
end

-- "Name#1234" -> "Name"
local function ShortTag(battleTag)
	return battleTag and battleTag:match("^([^#]+)") or "Unknown"
end

local function ClassColorString(text, classToken)
	local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if not color then
		return text
	end
	return string.format("|c%s%s|r", color.colorStr, text)
end

local function LastUpdated(record)
	local latest
	for _, section in ipairs(addon.SECTIONS) do
		local updatedAt = record[section] and record[section].updatedAt
		if updatedAt and (not latest or updatedAt > latest) then
			latest = updatedAt
		end
	end
	return latest
end

local function SortedProfessions(record)
	local list = {}
	for _, prof in pairs(record.professions or {}) do
		if type(prof) == "table" and prof.name then
			list[#list + 1] = prof
		end
	end
	table.sort(list, function(a, b)
		if a.type ~= b.type then
			return a.type == "primary"
		end
		return a.name < b.name
	end)
	return list
end

local function ProfessionSummary(record)
	local parts = {}
	for _, prof in ipairs(SortedProfessions(record)) do
		parts[#parts + 1] = string.format("%s %d", Safe(prof.name), prof.rank or 0)
	end
	return #parts > 0 and table.concat(parts, ", ") or "-"
end

local function SourceText(record, section)
	local data = record[section]
	if not data then
		return nil
	end
	local how
	if data.source == "self" then
		how = "this account"
	elseif data.source == "bnet" then
		how = "friend list"
	elseif record.receivedFrom and record.receivedFrom == record.owner then
		how = "their addon"
	else
		how = "their addon, relayed via " .. Safe(ShortTag(record.receivedFrom))
	end
	return string.format("%s (%s)", RelativeTime(data.updatedAt), how)
end

local function ShowRowTooltip(row)
	local entry = row.entry
	if not entry or entry.header then
		return
	end
	local record = entry.record
	local identity = record.identity or {}

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(ClassColorString(Safe(identity.name or entry.id), identity.class))
	if identity.realmDisplay then
		GameTooltip:AddLine(Safe(identity.realmDisplay) .. (identity.region and (" (" .. Safe(identity.region) .. ")") or ""), 1, 1, 1)
	end
	if record.owner then
		GameTooltip:AddLine(Safe(record.owner), 0.6, 0.6, 0.6)
	end

	GameTooltip:AddLine(" ")
	if record.level then
		GameTooltip:AddDoubleLine("Level " .. (record.level.value or "?"), SourceText(record, "level"), 1, 1, 1, 0.6, 0.6, 0.6)
	end
	if record.location then
		local where = Safe(record.location.zone or "?")
		if record.location.subzone and record.location.subzone ~= "" then
			where = where .. " - " .. Safe(record.location.subzone)
		end
		GameTooltip:AddDoubleLine(where, SourceText(record, "location"), 1, 1, 1, 0.6, 0.6, 0.6)
	end

	local professions = SortedProfessions(record)
	if #professions > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Professions", SourceText(record, "professions"), 1, 0.82, 0, 0.6, 0.6, 0.6)
		for _, prof in ipairs(professions) do
			GameTooltip:AddDoubleLine(Safe(prof.name), string.format("%d / %d", prof.rank or 0, prof.maxRank or 0), 1, 1, 1, 1, 1, 1)
		end
	elseif record.level and record.level.source == "bnet" then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Professions unknown: this friend isn't running WoW Forever.", 0.6, 0.6, 0.6, true)
	end
	GameTooltip:Show()
end

local function CreateMainFrame()
	local f = CreateFrame("Frame", "WoWForeverFrame", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(520, 360)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", f, "TOP", 0, -6)
	f.title:SetText("WoW Forever")

	local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -32)
	scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 8)

	local scrollChild = CreateFrame("Frame", nil, scrollFrame)
	scrollChild:SetSize(1, 1)
	scrollFrame:SetScrollChild(scrollChild)

	f.scrollChild = scrollChild
	f.rows = {}

	f:Hide()
	return f
end

local function GetOrCreateRow(parent, index)
	local row = parent.rows[index]
	if row then
		return row
	end

	row = CreateFrame("Frame", nil, parent.scrollChild)
	row:SetSize(ROW_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent.scrollChild, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 0, 0.12)
	row.bg:Hide()

	row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.header:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.header:SetWidth(ROW_WIDTH - 4)
	row.header:SetJustifyH("LEFT")

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.name:SetWidth(100)
	row.name:SetJustifyH("LEFT")

	row.level = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.level:SetPoint("LEFT", row, "LEFT", 102, 0)
	row.level:SetWidth(30)

	row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.zone:SetPoint("LEFT", row, "LEFT", 137, 0)
	row.zone:SetWidth(140)
	row.zone:SetJustifyH("LEFT")

	row.profs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.profs:SetPoint("LEFT", row, "LEFT", 282, 0)
	row.profs:SetWidth(140)
	row.profs:SetJustifyH("LEFT")

	row.updated = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	row.updated:SetPoint("LEFT", row, "LEFT", 422, 0)
	row.updated:SetWidth(60)
	row.updated:SetJustifyH("LEFT")

	parent.rows[index] = row
	return row
end

-- Flattens the DB into display entries: a header per owner (this account
-- first, then friends alphabetically), each followed by its characters
-- sorted most-recently-updated first.
local function BuildEntries()
	local myTag = addon.GetMyBattleTag()
	local groups, order = {}, {}
	for id, record in pairs(WoWForeverDB.characters) do
		local isMine = (record.isMine or (myTag ~= nil and record.owner == myTag)) and true or false
		local key = isMine and "" or (record.owner or "?")
		if not groups[key] then
			groups[key] = { key = key, isMine = isMine, characters = {} }
			order[#order + 1] = groups[key]
		end
		table.insert(groups[key].characters, { id = id, record = record, updatedAt = LastUpdated(record) or 0 })
	end

	table.sort(order, function(a, b)
		if a.isMine ~= b.isMine then
			return a.isMine
		end
		return ShortTag(a.key):lower() < ShortTag(b.key):lower()
	end)

	local entries = {}
	for _, group in ipairs(order) do
		local title = group.isMine and "Your characters" or Safe(ShortTag(group.key))
		entries[#entries + 1] = { header = title }
		table.sort(group.characters, function(a, b)
			return a.updatedAt > b.updatedAt
		end)
		for _, character in ipairs(group.characters) do
			entries[#entries + 1] = character
		end
	end
	return entries
end

local function RefreshFrame()
	if not frame or not frame:IsShown() then
		return
	end

	local currentID = addon.GetCharacterID()
	local entries = BuildEntries()

	for index, entry in ipairs(entries) do
		local row = GetOrCreateRow(frame, index)
		row.entry = entry

		local isHeader = entry.header ~= nil
		row.header:SetShown(isHeader)
		row.name:SetShown(not isHeader)
		row.level:SetShown(not isHeader)
		row.zone:SetShown(not isHeader)
		row.profs:SetShown(not isHeader)
		row.updated:SetShown(not isHeader)

		if isHeader then
			row.header:SetText(entry.header)
			row.bg:Hide()
			row:SetAlpha(1)
		else
			local record = entry.record
			local identity = record.identity or {}
			row.name:SetText(ClassColorString(Safe(identity.name or entry.id), identity.class))
			row.level:SetText((record.level and record.level.value) or "-")
			row.zone:SetText(Safe((record.location and record.location.zone) or "-"))
			row.profs:SetText(ProfessionSummary(record))
			row.updated:SetText(RelativeTime(entry.updatedAt > 0 and entry.updatedAt or nil))

			row.bg:SetShown(entry.id == currentID)

			local isStale = entry.updatedAt > 0 and (time() - entry.updatedAt) > STALE_AFTER_SECONDS
			row:SetAlpha(isStale and 0.5 or 1)
		end
		row:Show()
	end

	for index = #entries + 1, #frame.rows do
		frame.rows[index].entry = nil
		frame.rows[index]:Hide()
	end

	frame.scrollChild:SetHeight(math.max(1, #entries * ROW_HEIGHT))
end
addon.RefreshFrame = RefreshFrame

local function ToggleUI()
	if not frame then
		frame = CreateMainFrame()
	end
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
		RefreshFrame()
	end
end
addon.ToggleUI = ToggleUI

local function PrintHelp()
	print("|cff33ff99WoW Forever:|r commands")
	print("  /wowf - toggle the window")
	print("  /wowf sync - re-sync with online friends now")
	print("  /wowf status - list online friends running the addon")
	print("  /wowf minimap - show/hide the minimap button")
end

SLASH_WOWFOREVER1 = "/wowf"
SLASH_WOWFOREVER2 = "/wowforever"
SlashCmdList["WOWFOREVER"] = function(input)
	local command = strtrim(input or ""):lower()
	if command == "" then
		ToggleUI()
	elseif command == "sync" then
		addon.ForceSync()
	elseif command == "status" then
		addon.PrintStatus()
	elseif command == "minimap" then
		addon.ToggleMinimapButton()
	else
		PrintHelp()
	end
end
