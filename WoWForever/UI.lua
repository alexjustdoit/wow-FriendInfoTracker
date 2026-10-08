local addon = WoWForever

local ROW_HEIGHT = 20
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

local function ClassColorString(text, classToken)
	local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if not color then
		return text
	end
	return string.format("|c%s%s|r", color.colorStr, text)
end

local function ProfessionSummary(record)
	if not record.professions then
		return "-"
	end
	local parts = {}
	for _, prof in pairs(record.professions) do
		if type(prof) == "table" and prof.name then
			table.insert(parts, string.format("%s %d", prof.name, prof.rank or 0))
		end
	end
	if #parts == 0 then
		return "-"
	end
	table.sort(parts)
	return table.concat(parts, ", ")
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
	row:SetSize(460, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent.scrollChild, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 1, 0, 0.12)
	row.bg:Hide()

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

local function RefreshFrame()
	if not frame or not frame:IsShown() then
		return
	end

	local currentID = addon.GetCharacterID()

	local characters = {}
	for id, record in pairs(WoWForeverDB.characters) do
		table.insert(characters, { id = id, record = record })
	end

	table.sort(characters, function(a, b)
		local aTime = (a.record.level and a.record.level.updatedAt) or 0
		local bTime = (b.record.level and b.record.level.updatedAt) or 0
		return aTime > bTime
	end)

	for index, entry in ipairs(characters) do
		local record = entry.record
		local identity = record.identity or {}
		local row = GetOrCreateRow(frame, index)

		local displayName = identity.name or entry.id
		row.name:SetText(ClassColorString(displayName, identity.class))
		row.level:SetText((record.level and record.level.value) or "-")
		row.zone:SetText((record.location and record.location.zone) or "-")
		row.profs:SetText(ProfessionSummary(record))

		local updatedAt = record.level and record.level.updatedAt
		row.updated:SetText(RelativeTime(updatedAt))

		row.bg:SetShown(entry.id == currentID)

		local isStale = updatedAt ~= nil and (time() - updatedAt) > STALE_AFTER_SECONDS
		row:SetAlpha(isStale and 0.5 or 1)
		row:Show()
	end

	for index = #characters + 1, #frame.rows do
		frame.rows[index]:Hide()
	end

	frame.scrollChild:SetHeight(math.max(1, #characters * ROW_HEIGHT))
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

SLASH_WOWFOREVER1 = "/wowf"
SLASH_WOWFOREVER2 = "/wowforever"
SlashCmdList["WOWFOREVER"] = ToggleUI
