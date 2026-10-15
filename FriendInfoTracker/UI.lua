local addon = FriendInfoTracker

local FRAME_WIDTH = 780
local FRAME_HEIGHT = 440
local ROW_WIDTH = 728
local LINE_HEIGHT = 14 -- one profession per line
local ROW_PADDING = 6
local HEADER_ROW_HEIGHT = 26
local RECIPE_PANEL_WIDTH = 300
local STALE_AFTER_SECONDS = 7 * 86400

-- Column layout shared by the column headers and every character row.
local COLUMNS = {
	{ key = "name", label = "Character", x = 6, width = 130 },
	{ key = "level", label = "Level", x = 140, width = 40, justify = "CENTER" },
	{ key = "zone", label = "Zone", x = 186, width = 150 },
	{ key = "primary", label = "Primary", x = 342, width = 150 },
	{ key = "secondary", label = "Secondary", x = 498, width = 150 },
	{ key = "updated", label = "Updated", x = 654, width = 54 },
}

local frame, recipePanel
local selectedID

---------------------------------------------------------------------------
-- Formatting helpers
---------------------------------------------------------------------------

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

local function Gray(text)
	return "|cff808080" .. text .. "|r"
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

-- Returns two lists of "Name rank" lines: primary and secondary.
local function ProfessionLines(record)
	local primary, secondary = {}, {}
	for _, prof in pairs(record.professions or {}) do
		if type(prof) == "table" and prof.name then
			local line = string.format("%s |cffffd100%d|r", Safe(prof.name), prof.rank or 0)
			table.insert(prof.type == "primary" and primary or secondary, line)
		end
	end
	table.sort(primary)
	table.sort(secondary)
	return primary, secondary
end

-- Profession name -> recipe list, skipping the section's metadata fields.
local function RecipeLists(record)
	local lists = {}
	for key, list in pairs(record.recipes or {}) do
		if type(list) == "table" and #list > 0 then
			lists[#lists + 1] = { profession = key, recipes = list }
		end
	end
	table.sort(lists, function(a, b)
		return a.profession < b.profession
	end)
	return lists
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
		how = "relayed via " .. Safe(ShortTag(record.receivedFrom))
	end
	return string.format("%s (%s)", RelativeTime(data.updatedAt), how)
end

---------------------------------------------------------------------------
-- Recipe fold-out panel
---------------------------------------------------------------------------

local function CreateRecipePanel(parent)
	local panel = CreateFrame("Frame", "FriendInfoTrackerRecipes", parent, "BasicFrameTemplateWithInset")
	panel:SetSize(RECIPE_PANEL_WIDTH, FRAME_HEIGHT)
	panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", -2, 0)

	panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.title:SetPoint("TOP", panel, "TOP", 0, -6)

	panel.subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -32)
	panel.subtitle:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
	panel.subtitle:SetJustifyH("LEFT")

	local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -52)
	scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 10)

	local content = CreateFrame("Frame", nil, scrollFrame)
	content:SetSize(RECIPE_PANEL_WIDTH - 48, 1)
	scrollFrame:SetScrollChild(content)

	panel.text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.text:SetPoint("TOPLEFT", content, "TOPLEFT", 2, 0)
	panel.text:SetWidth(RECIPE_PANEL_WIDTH - 52)
	panel.text:SetJustifyH("LEFT")
	panel.text:SetJustifyV("TOP")
	panel.text:SetSpacing(3)

	panel.content = content
	panel.scrollFrame = scrollFrame
	panel:SetScript("OnHide", function()
		selectedID = nil
		addon.RefreshFrame()
	end)
	panel:Hide()
	return panel
end

local function RefreshRecipePanel()
	if not recipePanel or not recipePanel:IsShown() or not selectedID then
		return
	end
	local record = FriendInfoTrackerDB.characters[selectedID]
	if not record then
		recipePanel:Hide()
		return
	end
	local identity = record.identity or {}
	recipePanel.title:SetText(ClassColorString(Safe(identity.name or selectedID), identity.class) .. " - Recipes")
	recipePanel.subtitle:SetText(record.recipes and ("Updated " .. SourceText(record, "recipes")) or "")

	local lines = {}
	local lists = RecipeLists(record)
	if #lists > 0 then
		for index, entry in ipairs(lists) do
			if index > 1 then
				lines[#lines + 1] = " "
			end
			lines[#lines + 1] = string.format("|cffffd100%s|r %s", Safe(entry.profession), Gray("(" .. #entry.recipes .. ")"))
			for _, recipe in ipairs(entry.recipes) do
				lines[#lines + 1] = "   " .. Safe(recipe)
			end
		end
	elseif record.level and record.level.source == "bnet" then
		lines[1] = Gray("This friend isn't running FriendInfoTracker, so their recipes aren't available.")
	else
		lines[1] = Gray("No recipes recorded yet.")
		lines[2] = " "
		lines[3] = Gray("Recipes are recorded when each profession window is opened on this character.")
	end

	recipePanel.text:SetText(table.concat(lines, "\n"))
	recipePanel.content:SetHeight(math.max(1, recipePanel.text:GetStringHeight() + 8))
	recipePanel.scrollFrame:SetVerticalScroll(0)
end

local function ToggleRecipePanel(id)
	if not recipePanel then
		recipePanel = CreateRecipePanel(frame)
	end
	if recipePanel:IsShown() and selectedID == id then
		recipePanel:Hide() -- OnHide clears the selection
		return
	end
	selectedID = id
	recipePanel:Show()
	RefreshRecipePanel()
	addon.RefreshFrame()
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------

local function ShowRowTooltip(row)
	local entry = row.entry
	if not entry or entry.header then
		return
	end
	local record = entry.record
	local identity = record.identity or {}

	GameTooltip:SetOwner(row, "ANCHOR_CURSOR")
	GameTooltip:AddLine(ClassColorString(Safe(identity.name or entry.id), identity.class))
	if identity.realmDisplay then
		GameTooltip:AddLine(Safe(identity.realmDisplay) .. (identity.region and (" (" .. Safe(identity.region) .. ")") or ""), 1, 1, 1)
	end
	if record.owner then
		GameTooltip:AddLine(Safe(record.owner), 0.6, 0.6, 0.6)
	end
	if record.location and record.location.subzone and record.location.subzone ~= "" then
		GameTooltip:AddLine(Safe(record.location.subzone), 1, 1, 1)
	end

	GameTooltip:AddLine(" ")
	local sections = {
		{ "level", "Level" },
		{ "location", "Location" },
		{ "professions", "Professions" },
		{ "recipes", "Recipes" },
	}
	for _, section in ipairs(sections) do
		local text = SourceText(record, section[1])
		if text then
			GameTooltip:AddDoubleLine(section[2], text, 1, 0.82, 0, 0.7, 0.7, 0.7)
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click to show recipes", 0.5, 0.8, 1)
	GameTooltip:Show()
end

local function CreateMainFrame()
	local f = CreateFrame("Frame", "FriendInfoTrackerFrame", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "FriendInfoTrackerFrame") -- close with Escape

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.title:SetPoint("TOP", f, "TOP", 0, -6)
	f.title:SetText("FriendInfoTracker")

	-- Column headers
	for _, column in ipairs(COLUMNS) do
		local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + column.x, -34)
		label:SetWidth(column.width)
		label:SetJustifyH(column.justify or "LEFT")
		label:SetText(column.label)
	end
	local divider = f:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 0.82, 0, 0.25)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -50)
	divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -50)

	local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -54)
	scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 10)

	local scrollChild = CreateFrame("Frame", nil, scrollFrame)
	scrollChild:SetSize(ROW_WIDTH, 1)
	scrollFrame:SetScrollChild(scrollChild)

	f.scrollChild = scrollChild
	f.rows = {}

	-- Closing the main window also closes the recipe panel, so it doesn't
	-- reappear with a stale selection next time.
	f:SetScript("OnHide", function()
		if recipePanel then
			recipePanel:Hide()
		end
	end)

	f:Hide()
	return f
end

local function CreateCell(row, column, template)
	local cell = row:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
	cell:SetPoint("TOPLEFT", row, "TOPLEFT", column.x, -ROW_PADDING / 2)
	cell:SetWidth(column.width)
	cell:SetJustifyH(column.justify or "LEFT")
	cell:SetJustifyV("TOP")
	cell:SetWordWrap(false)
	return cell
end

local function GetOrCreateRow(parent, index)
	local row = parent.rows[index]
	if row then
		return row
	end

	row = CreateFrame("Button", nil, parent.scrollChild)
	row:SetWidth(ROW_WIDTH)
	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:SetScript("OnClick", function(self)
		if self.entry and not self.entry.header then
			ToggleRecipePanel(self.entry.id)
		end
	end)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()

	row.hover = row:CreateTexture(nil, "HIGHLIGHT")
	row.hover:SetAllPoints()
	row.hover:SetColorTexture(1, 1, 1, 0.06)

	row.separator = row:CreateTexture(nil, "ARTWORK")
	row.separator:SetColorTexture(1, 1, 1, 0.05)
	row.separator:SetHeight(1)
	row.separator:SetPoint("BOTTOMLEFT")
	row.separator:SetPoint("BOTTOMRIGHT")

	row.header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.header:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 4)
	row.headerLine = row:CreateTexture(nil, "ARTWORK")
	row.headerLine:SetColorTexture(1, 0.82, 0, 0.35)
	row.headerLine:SetHeight(1)
	row.headerLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 1)
	row.headerLine:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 1)

	row.cells = {}
	for _, column in ipairs(COLUMNS) do
		local template = column.key == "name" and "GameFontNormal"
			or column.key == "updated" and "GameFontDisableSmall"
			or "GameFontHighlightSmall"
		row.cells[column.key] = CreateCell(row, column, template)
	end
	row.cells.primary:SetWordWrap(true)
	row.cells.secondary:SetWordWrap(true)
	row.cells.primary:SetSpacing(LINE_HEIGHT - 12)
	row.cells.secondary:SetSpacing(LINE_HEIGHT - 12)

	row.arrow = row:CreateTexture(nil, "OVERLAY")
	row.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
	row.arrow:SetSize(12, 12)
	row.arrow:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -ROW_PADDING / 2)

	parent.rows[index] = row
	return row
end

-- Flattens the DB into display entries: a header per owner (this account
-- first, then friends alphabetically), each followed by its characters
-- sorted most-recently-updated first.
local function BuildEntries()
	local myTag = addon.GetMyBattleTag()
	local groups, order = {}, {}
	for id, record in pairs(FriendInfoTrackerDB.characters) do
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

local function ShowCharacterRow(row, entry, currentID)
	local record = entry.record
	local identity = record.identity or {}
	local primary, secondary = ProfessionLines(record)
	local lineCount = math.max(1, #primary, #secondary)
	row:SetHeight(lineCount * LINE_HEIGHT + ROW_PADDING)

	local cells = row.cells
	cells.name:SetText(ClassColorString(Safe(identity.name or entry.id), identity.class))
	cells.level:SetText((record.level and record.level.value) or "-")
	cells.zone:SetText(Safe((record.location and record.location.zone) or "-"))
	cells.primary:SetText(#primary > 0 and table.concat(primary, "\n") or Gray("-"))
	cells.secondary:SetText(#secondary > 0 and table.concat(secondary, "\n") or Gray("-"))
	cells.updated:SetText(RelativeTime(entry.updatedAt > 0 and entry.updatedAt or nil))
	cells.primary:SetHeight(lineCount * LINE_HEIGHT)
	cells.secondary:SetHeight(lineCount * LINE_HEIGHT)

	if entry.id == selectedID then
		row.bg:SetColorTexture(0.2, 0.5, 1, 0.22)
		row.bg:Show()
	elseif entry.id == currentID then
		row.bg:SetColorTexture(1, 0.82, 0, 0.10)
		row.bg:Show()
	else
		row.bg:Hide()
	end

	row.arrow:SetShown(#RecipeLists(record) > 0)
	local isStale = entry.updatedAt > 0 and (time() - entry.updatedAt) > STALE_AFTER_SECONDS
	row:SetAlpha(isStale and 0.5 or 1)
end

local function RefreshFrame()
	if not frame or not frame:IsShown() then
		return
	end

	local currentID = addon.GetCharacterID()
	local entries = BuildEntries()
	local offset = 0

	for index, entry in ipairs(entries) do
		local row = GetOrCreateRow(frame, index)
		row.entry = entry

		local isHeader = entry.header ~= nil
		row.header:SetShown(isHeader)
		row.headerLine:SetShown(isHeader)
		row.separator:SetShown(not isHeader)
		for _, cell in pairs(row.cells) do
			cell:SetShown(not isHeader)
		end

		if isHeader then
			row:SetHeight(HEADER_ROW_HEIGHT)
			row.header:SetText(entry.header)
			row.bg:Hide()
			row.arrow:Hide()
			row:SetAlpha(1)
			row:EnableMouse(false)
		else
			ShowCharacterRow(row, entry, currentID)
			row:EnableMouse(true)
		end

		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.scrollChild, "TOPLEFT", 0, -offset)
		offset = offset + row:GetHeight()
		row:Show()
	end

	for index = #entries + 1, #frame.rows do
		frame.rows[index].entry = nil
		frame.rows[index]:Hide()
	end

	frame.scrollChild:SetHeight(math.max(1, offset))
	RefreshRecipePanel()
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
	print("|cff33ff99FriendInfoTracker:|r commands")
	print("  /fit - toggle the window")
	print("  /fit sync - re-sync with online friends now")
	print("  /fit status - list online friends running the addon")
	print("  /fit minimap - show/hide the minimap button")
end

SLASH_FRIENDINFOTRACKER1 = "/fit"
SLASH_FRIENDINFOTRACKER2 = "/friendinfotracker"
SlashCmdList["FRIENDINFOTRACKER"] = function(input)
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
