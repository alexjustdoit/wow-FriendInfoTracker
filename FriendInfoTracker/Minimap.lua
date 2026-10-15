local addon = FriendInfoTracker

-- Standalone minimap button (no LibDBIcon dependency). Drag to move it around
-- the minimap edge; position and visibility are stored per character.

local DEFAULT_ANGLE = 220

local button

local function UpdatePosition()
	local angle = math.rad(FriendInfoTrackerCharDB.minimapAngle or DEFAULT_ANGLE)
	local radius = (Minimap:GetWidth() / 2) + 10
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
	local centerX, centerY = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	cursorX, cursorY = cursorX / scale, cursorY / scale
	FriendInfoTrackerCharDB.minimapAngle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX))
	UpdatePosition()
end

local function CreateButton()
	button = CreateFrame("Button", "FriendInfoTrackerMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:RegisterForClicks("LeftButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnClick", function()
		addon.ToggleUI()
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("FriendInfoTracker")
		GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)

	UpdatePosition()
end

function addon.SetMinimapButtonShown(shown)
	FriendInfoTrackerCharDB.hideMinimapButton = not shown
	if not button then
		CreateButton()
	end
	button:SetShown(shown)
	if addon.RefreshSettings then
		addon.RefreshSettings()
	end
end

function addon.IsMinimapButtonShown()
	return not FriendInfoTrackerCharDB.hideMinimapButton
end

function addon.ToggleMinimapButton()
	addon.SetMinimapButtonShown(not addon.IsMinimapButtonShown())
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function()
	CreateButton()
	button:SetShown(not FriendInfoTrackerCharDB.hideMinimapButton)
end)
