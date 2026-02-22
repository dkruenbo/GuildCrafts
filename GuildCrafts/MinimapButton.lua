----------------------------------------------------------------------
-- GuildCrafts Minimap Button
-- Lightweight minimap icon — toggle the main window with one click.
----------------------------------------------------------------------

local GuildCrafts = LibStub("AceAddon-3.0"):GetAddon("GuildCrafts")
local MinimapButton = GuildCrafts:NewModule("MinimapButton", "AceEvent-3.0")

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Book_11"
local BUTTON_SIZE  = 31
local DRAG_RADIUS  = 80  -- distance from minimap centre

----------------------------------------------------------------------
-- Button Creation
----------------------------------------------------------------------

local function CreateButton()
    local btn = CreateFrame("Button", "GuildCraftsMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Border overlay (standard minimap button look)
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    -- Icon
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 1)
    btn.icon = icon

    return btn
end

----------------------------------------------------------------------
-- Position Helpers
----------------------------------------------------------------------

local function UpdatePosition(btn, angle)
    local x = math.cos(angle) * DRAG_RADIUS
    local y = math.sin(angle) * DRAG_RADIUS
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function AngleFromCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale   = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    return math.atan2(cy - my, cx - mx)
end

----------------------------------------------------------------------
-- Module Lifecycle
----------------------------------------------------------------------

function MinimapButton:OnEnable()
    self.btn = CreateButton()

    -- Restore saved angle or default to top-right
    local db = GuildCrafts.db
    if not db.global._minimapAngle then
        db.global._minimapAngle = 0.785  -- ~45° (top-right)
    end
    UpdatePosition(self.btn, db.global._minimapAngle)

    -- Visibility
    if db.global._minimapHide then
        self.btn:Hide()
    end

    -- Click handler
    self.btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            GuildCrafts.UI:Toggle()
        elseif button == "RightButton" then
            GuildCrafts:Print("Use /gc to toggle the window. Right-click options coming soon.")
        end
    end)

    -- Tooltip
    self.btn:SetScript("OnEnter", function(frame)
        GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
        GameTooltip:AddLine("GuildCrafts")
        GameTooltip:AddLine("|cffffffffLeft-click|r to toggle window", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    self.btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Drag
    self.btn:SetScript("OnDragStart", function(frame)
        frame.isDragging = true
        frame:SetScript("OnUpdate", function()
            local angle = AngleFromCursor()
            UpdatePosition(frame, angle)
            db.global._minimapAngle = angle
        end)
    end)
    self.btn:SetScript("OnDragStop", function(frame)
        frame.isDragging = false
        frame:SetScript("OnUpdate", nil)
    end)
end

--- Toggle minimap button visibility (e.g. from slash command).
function MinimapButton:Toggle()
    if not self.btn then return end
    local db = GuildCrafts.db
    if self.btn:IsShown() then
        self.btn:Hide()
        db.global._minimapHide = true
        GuildCrafts:Print("Minimap button hidden. Type /gc minimap to show it again.")
    else
        self.btn:Show()
        db.global._minimapHide = false
        GuildCrafts:Print("Minimap button shown.")
    end
end
