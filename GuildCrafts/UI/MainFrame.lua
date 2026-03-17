----------------------------------------------------------------------
-- GuildCrafts — UI/MainFrame.lua
-- Main window: title bar, two-panel split, sync indicator,
-- resize, drag, ESC-to-close
----------------------------------------------------------------------
local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)
local GuildCrafts = _G.GuildCrafts

-- UI namespace
GuildCrafts.UI = GuildCrafts.UI or {}
local UI = GuildCrafts.UI

-- Frame dimensions
local DEFAULT_WIDTH  = 820
local DEFAULT_HEIGHT = 540
local MIN_WIDTH      = 560
local MIN_HEIGHT     = 380
local LEFT_PANEL_WIDTH = 240

-- Frame pools for left-panel recycling
UI._leftRowPool       = {}
UI._leftSeparatorPool = {}

-- Colors
local COLOR_BG       = { 0.05, 0.05, 0.05, 0.92 }
local COLOR_TITLE_BG = { 0.12, 0.12, 0.12, 1 }
local COLOR_BORDER   = { 0.3, 0.3, 0.3, 0.8 }
local COLOR_DIVIDER  = { 0.25, 0.25, 0.25, 1 }
local COLOR_GREEN    = { 0.2, 0.9, 0.2, 1 }
local COLOR_YELLOW   = { 1.0, 0.8, 0.0, 1 }
local COLOR_RED      = { 0.9, 0.2, 0.2, 1 }

-- Quality color codes (Blizzard standard)
local QUALITY_COLORS = {
    [0] = "|cff9d9d9d", -- Poor (grey)
    [1] = "|cffffffff", -- Common (white)
    [2] = "|cff1eff00", -- Uncommon (green)
    [3] = "|cff0070dd", -- Rare (blue)
    [4] = "|cffa335ee", -- Epic (purple)
    [5] = "|cffff8000", -- Legendary (orange)
}

-- Raid target star texture — used for favorites and self-indicator in recipe view
local STAR_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

-- Item quality lookup cache (avoids repeated GetItemInfo calls per frame render)
local _qualityCache = {}

--- Return the dot color-string and live online/addon state for a member.
--- dot states: green = online + addon active; yellow = online, no addon; grey = offline.
local function MemberDotState(memberKey)
    local isOnline = GuildCrafts.Data:IsMemberOnline(memberKey)
    local isAddon  = GuildCrafts.Comms and GuildCrafts.Comms:IsActiveAddonUser(memberKey)
    local dot
    if isOnline and isAddon then
        dot = "|cff00ff00O|r "
    elseif isOnline then
        dot = "|cffffff00O|r "
    else
        dot = "|cff666666O|r "
    end
    return dot, isOnline, isAddon
end

--- Attach the online-indicator tooltip to a member row.
local function SetMemberDotTooltip(row, isOnline, isAddon)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if isOnline and isAddon then
            GameTooltip:AddLine("Online", 0.2, 0.9, 0.2)
            GameTooltip:AddLine("GuildCrafts active", 0.7, 0.7, 0.7)
        elseif isOnline then
            GameTooltip:AddLine("Online", 1, 1, 0)
            GameTooltip:AddLine("GuildCrafts not detected", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Offline", 0.4, 0.4, 0.4)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Format a Unix timestamp as a human-readable age string.
local function FormatAge(ts)
    if not ts or ts == 0 then return "never" end
    local delta = time() - ts
    if delta < 120   then return "just now" end
    if delta < 3600  then return math.floor(delta / 60)   .. "m ago" end
    if delta < 86400 then return math.floor(delta / 3600) .. "h ago" end
    return math.floor(delta / 86400) .. "d ago"
end

----------------------------------------------------------------------
-- Main Frame Creation
----------------------------------------------------------------------

function UI:CreateMainFrame()
    if self.mainFrame then return self.mainFrame end

    -- Main frame
    local f = CreateFrame("Frame", "GuildCraftsMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)

    -- Backdrop
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(COLOR_BG))
    f:SetBackdropBorderColor(unpack(COLOR_BORDER))

    -- Resize bounds
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
    end

    -- ESC to close
    table.insert(UISpecialFrames, "GuildCraftsMainFrame")

    -- Dragging
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Hide by default
    f:Hide()

    -- Build components (DetailPanel before LeftPanel because
    -- PopulateProfessionList references detailWelcome)
    self:CreateTitleBar(f)
    self:CreateSearchBar(f)
    self:CreateDetailPanel(f)
    self:CreateLeftPanel(f)
    self:CreateResizeGrip(f)
    self:CreateBottomBar(f)

    self.mainFrame = f
    return f
end

----------------------------------------------------------------------
-- Title Bar
----------------------------------------------------------------------

function UI:CreateTitleBar(parent)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetHeight(28)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -1, -1)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    bar:SetBackdropColor(unpack(COLOR_TITLE_BG))

    -- Title text
    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", bar, "LEFT", 10, 0)
    title:SetText("GuildCrafts")
    title:SetTextColor(1, 0.82, 0)

    -- Close button
    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    close:SetSize(22, 22)
    close:SetScript("OnClick", function()
        parent:Hide()
    end)

    -- Sync indicator (colored dot)
    local syncDot = bar:CreateTexture(nil, "OVERLAY")
    syncDot:SetSize(10, 10)
    syncDot:SetPoint("RIGHT", close, "LEFT", -8, 0)
    syncDot:SetTexture("Interface\\Buttons\\WHITE8x8")
    syncDot:SetVertexColor(unpack(COLOR_GREEN))
    self.syncDot = syncDot

    -- Sync label
    local syncLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    syncLabel:SetPoint("RIGHT", syncDot, "LEFT", -4, 0)
    syncLabel:SetText("Sync")
    syncLabel:SetTextColor(0.7, 0.7, 0.7)

    -- Sync tooltip
    syncDot:EnableMouse(true)
    syncDot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Sync Status", 1, 1, 1)
        local status = GuildCrafts.Comms and GuildCrafts.Comms:GetSyncStatus() or "unknown"
        local dr = GuildCrafts.Comms and GuildCrafts.Comms.currentDR or "none"
        local users = GuildCrafts.Comms and GuildCrafts.Comms:GetActiveAddonUserCount() or 0
        GameTooltip:AddDoubleLine("Status:", status, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("DR:", dr, 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("Addon users:", tostring(users), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:Show()
    end)
    syncDot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self.titleBar = bar
end

----------------------------------------------------------------------
-- Resize Grip
----------------------------------------------------------------------

function UI:CreateResizeGrip(parent)
    local grip = CreateFrame("Button", nil, parent)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetFrameLevel(parent:GetFrameLevel() + 20)

    grip:SetScript("OnMouseDown", function()
        parent:StartSizing("BOTTOMRIGHT")
        -- Safety: poll every frame in case OnMouseUp is missed
        grip:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then
                parent:StopMovingOrSizing()
                grip:SetScript("OnUpdate", nil)
                UI:OnResize()
            end
        end)
    end)
    grip:SetScript("OnMouseUp", function()
        parent:StopMovingOrSizing()
        grip:SetScript("OnUpdate", nil)
        UI:OnResize()
    end)
end

function UI:OnResize()
    -- Panels auto-adjust via anchoring
end

----------------------------------------------------------------------
-- Bottom Bar  ([Online] + [Tooltip] filter buttons)
----------------------------------------------------------------------

function UI:CreateBottomBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(20)
    bar:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  8, 8)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, 8)

    local function makeBarBtn(label, rightOffset, width)
        local btn = CreateFrame("Button", nil, bar, "BackdropTemplate")
        btn:SetSize(width, 16)
        btn:SetPoint("RIGHT", bar, "RIGHT", rightOffset, 0)
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        fs:SetText(label)
        fs:SetTextColor(0.4, 0.4, 0.4)
        btn._textFS = fs
        return btn
    end

    local tooltipBtn  = makeBarBtn("[Tooltip]",  0,    60)
    local onlineBtn   = makeBarBtn("[Online]",   -64,  52)
    local minimapBtn  = makeBarBtn("[Minimap]",  -120, 60)

    onlineBtn:SetScript("OnClick", function() UI:ToggleOnlineFilter() end)
    onlineBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Online Filter", 1, 1, 1)
        GameTooltip:AddLine("Show only online crafters.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    onlineBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    tooltipBtn:SetScript("OnClick", function() UI:ToggleTooltipCrafters() end)
    tooltipBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Tooltip Crafters", 1, 1, 1)
        GameTooltip:AddLine("Show crafters in item tooltips.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    tooltipBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapBtn:SetScript("OnClick", function() UI:ToggleMinimapBtn() end)
    minimapBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Minimap Button", 1, 1, 1)
        GameTooltip:AddLine("Show or hide the minimap icon.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self._onlineBtn  = onlineBtn
    self._tooltipBtn = tooltipBtn
    self._minimapBtn = minimapBtn
end

----------------------------------------------------------------------
-- Search Bar
----------------------------------------------------------------------

function UI:CreateSearchBar(parent)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetHeight(30)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -34)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -34)

    -- Search icon
    local icon = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    icon:SetPoint("LEFT", container, "LEFT", 4, 0)
    icon:SetText("|cff888888Search...|r")

    -- Search EditBox
    local search = CreateFrame("EditBox", "GuildCraftsSearchBox", container, "BackdropTemplate")
    search:SetHeight(24)
    search:SetPoint("LEFT", container, "LEFT", 2, 0)
    search:SetPoint("RIGHT", container, "RIGHT", -188, 0)
    search:SetFontObject(ChatFontNormal)
    search:SetAutoFocus(false)
    search:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    search:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    search:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
    search:SetTextInsets(8, 8, 0, 0)
    search:SetMaxLetters(100)

    -- Placeholder
    local placeholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", search, "LEFT", 10, 0)
    placeholder:SetText("Search recipes, members...")

    search:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        placeholder:SetShown(text == "")
        -- Debounced search
        if UI._searchTimer then
            GuildCrafts:CancelTimer(UI._searchTimer)
        end
        UI._searchTimer = GuildCrafts:ScheduleTimer(function()
            UI:OnSearch(text)
        end, 0.2)
    end)

    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    -- Scope dropdown button
    local scopeBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    scopeBtn:SetSize(80, 24)
    scopeBtn:SetPoint("RIGHT", container, "RIGHT", 0, 0)
    scopeBtn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    scopeBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
    scopeBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)

    local scopeText = scopeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scopeText:SetPoint("CENTER")
    scopeText:SetText("All  v")
    self._searchScope = "All"

    scopeBtn:SetScript("OnClick", function()
        local scopes = { "All", "Item", "Profession", "Member" }
        local idx = 1
        for i, s in ipairs(scopes) do
            if s == UI._searchScope then idx = i break end
        end
        idx = (idx % #scopes) + 1
        UI._searchScope = scopes[idx]
        scopeText:SetText(scopes[idx] .. "  v")
        -- Re-trigger search with new scope
        local text = search:GetText()
        if text and text ~= "" then
            UI:OnSearch(text)
        end
    end)

    -- Expansion filter buttons: [Orig] and [TBC]
    local function makeExpBtn(label, rightOffset, width)
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        btn:SetSize(width, 24)
        btn:SetPoint("RIGHT", container, "RIGHT", rightOffset, 0)
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        btn:SetBackdropBorderColor(1, 0.82, 0, 1)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        fs:SetText(label)
        fs:SetTextColor(1, 0.82, 0)
        btn._textFS = fs
        return btn
    end
    local tbcBtn  = makeExpBtn("TBC",     -84, 40)
    local origBtn = makeExpBtn("Vanilla", -128, 56)
    tbcBtn:SetScript("OnClick",  function() UI:ToggleExpansionFilter("TBC")  end)
    origBtn:SetScript("OnClick", function() UI:ToggleExpansionFilter("ORIG") end)
    tbcBtn:SetScript("OnEnter",  function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("TBC Recipes", 1, 1, 1)
        GameTooltip:AddLine("Show The Burning Crusade recipes.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    tbcBtn:SetScript("OnLeave",  function() GameTooltip:Hide() end)
    origBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Vanilla Recipes", 1, 1, 1)
        GameTooltip:AddLine("Show Vanilla Classic recipes.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    origBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self._expFilterTBCBtn  = tbcBtn
    self._expFilterOrigBtn = origBtn

    self.searchBox = search
    self.scopeButton = scopeBtn
end

----------------------------------------------------------------------
-- Left Panel
----------------------------------------------------------------------

function UI:CreateLeftPanel(parent)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetWidth(LEFT_PANEL_WIDTH)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -68)
    panel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 32)
    panel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0.08, 0.08, 0.08, 1)
    panel:SetBackdropBorderColor(unpack(COLOR_DIVIDER))

    -- Breadcrumb navigation
    local breadcrumb = CreateFrame("Button", nil, panel)
    breadcrumb:SetHeight(20)
    breadcrumb:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -4)
    breadcrumb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -4)
    local breadcrumbText = breadcrumb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    breadcrumbText:SetPoint("LEFT")
    breadcrumbText:SetTextColor(0.4, 0.7, 1.0)
    breadcrumbText:SetText("")
    breadcrumb:Hide()
    breadcrumb:SetScript("OnClick", function()
        UI:NavigateBack()
    end)
    breadcrumb:SetScript("OnEnter", function(self)
        breadcrumbText:SetTextColor(0.6, 0.9, 1.0)
    end)
    breadcrumb:SetScript("OnLeave", function(_self)
        breadcrumbText:SetTextColor(0.4, 0.7, 1.0)
    end)

    -- Favorites toggle button (top-right of left panel header)
    local favBtn = CreateFrame("Frame", nil, panel)
    favBtn:SetSize(20, 20)
    favBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -3)
    favBtn:EnableMouse(true)
    local favBtnTex = favBtn:CreateTexture(nil, "OVERLAY")
    favBtnTex:SetAllPoints()
    favBtnTex:SetTexture(STAR_TEXTURE)
    favBtnTex:SetVertexColor(1.0, 0.82, 0.0)  -- gold always (favorites nav button)
    favBtn:SetScript("OnMouseDown", function()
        if UI._navState == "favorites" then
            UI:PopulateProfessionList()
        else
            UI:ShowFavoritesTab()
        end
    end)
    favBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Favorites", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    favBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.favButton = favBtn

    -- Scroll frame for list content
    local scrollFrame = CreateFrame("ScrollFrame", "GuildCraftsLeftScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -26)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 4)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(LEFT_PANEL_WIDTH - 28, 1) -- height set dynamically
    scrollFrame:SetScrollChild(content)

    self.leftPanel = panel
    self.leftBreadcrumb = breadcrumb
    self.leftBreadcrumbText = breadcrumbText
    self.leftScrollFrame = scrollFrame
    self.leftContent = content
    self.leftRows = {}

    -- Navigation state
    self._navState = "professions" -- "professions", "members", "allMembers", "favorites"
    self._selectedProfession = nil
    self._selectedMember = nil
    self._favSubTab = "members" -- "members" or "recipes"
    self._viewMode   = "members" -- profession view mode: "members" or "recipes"

    -- Populate default view
    self:PopulateProfessionList()
end

----------------------------------------------------------------------
-- Detail Panel (Right)
----------------------------------------------------------------------

function UI:CreateDetailPanel(parent)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", LEFT_PANEL_WIDTH + 14, -68)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 32)
    panel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0.08, 0.08, 0.08, 1)
    panel:SetBackdropBorderColor(unpack(COLOR_DIVIDER))

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "GuildCraftsDetailScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 4)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(400, 1)
    scrollFrame:SetScrollChild(content)

    -- Profession header bar (hidden until a profession is selected)
    local profHeader = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    profHeader:SetHeight(28)
    profHeader:SetPoint("TOPLEFT",  panel, "TOPLEFT",  4, -4)
    profHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    profHeader:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    profHeader:SetBackdropColor(0.10, 0.10, 0.10, 1)
    profHeader:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    profHeader:Hide()

    local profHeaderIcon = profHeader:CreateTexture(nil, "ARTWORK")
    profHeaderIcon:SetSize(20, 20)
    profHeaderIcon:SetPoint("LEFT", profHeader, "LEFT", 6, 0)
    profHeaderIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local profHeaderText = profHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    profHeaderText:SetPoint("LEFT", profHeaderIcon, "RIGHT", 6, 0)
    profHeaderText:SetTextColor(1, 0.82, 0)

    -- View toggle container (Members / Recipes buttons), anchored below header
    local toggleContainer = CreateFrame("Frame", nil, panel)
    toggleContainer:SetHeight(26)
    toggleContainer:SetPoint("TOPLEFT",  profHeader, "BOTTOMLEFT",  0, -2)
    toggleContainer:SetPoint("TOPRIGHT", profHeader, "BOTTOMRIGHT", 0, -2)
    toggleContainer:Hide()

    local function makeToggleBtn(label, anchorLeft, anchorPoint, offX)
        local btn = CreateFrame("Button", nil, toggleContainer, "BackdropTemplate")
        btn:SetSize(80, 22)
        btn:SetPoint("LEFT", anchorLeft, anchorPoint, offX, 0)
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        fs:SetText(label)
        fs:SetTextColor(0.7, 0.7, 0.7)
        btn._textFS = fs
        btn:SetScript("OnEnter", function(self)
            if self:IsEnabled() then
                self:SetBackdropColor(0.15, 0.35, 0.6, 0.4)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if self:IsEnabled() then
                self:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
            end
        end)
        return btn
    end

    local membersBtn = makeToggleBtn("Members", toggleContainer, "LEFT", 4)
    local recipesBtn = makeToggleBtn("Recipes",  membersBtn,      "RIGHT", 4)

    membersBtn:SetScript("OnClick", function() UI:SetViewMode("members") end)
    recipesBtn:SetScript("OnClick", function() UI:SetViewMode("recipes") end)

    -- Welcome text (default state) — child of panel so it layers independently
    local welcome = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    welcome:SetPoint("CENTER", panel, "CENTER", 0, 0)
    welcome:SetText("Select a profession to browse,\nor use the search bar to find a recipe.")
    welcome:SetTextColor(0.5, 0.5, 0.5)
    welcome:SetJustifyH("CENTER")

    self.detailPanel           = panel
    self.detailScrollFrame     = scrollFrame
    self.detailContent         = content
    self.detailWelcome         = welcome
    self._profHeader           = profHeader
    self._profHeaderIcon       = profHeaderIcon
    self._profHeaderText       = profHeaderText
    self._viewToggleContainer  = toggleContainer
    self._viewToggleMembersBtn = membersBtn
    self._viewToggleRecipesBtn = recipesBtn
    self.detailRows = {}
end

----------------------------------------------------------------------
-- Profession Icon Textures (TBC)
----------------------------------------------------------------------

local PROFESSION_ICONS = {
    -- Primary
    ["Alchemy"]        = "Interface\\Icons\\Trade_Alchemy",
    ["Blacksmithing"]  = "Interface\\Icons\\Trade_BlackSmithing",
    ["Enchanting"]     = "Interface\\Icons\\Trade_Engraving",
    ["Engineering"]    = "Interface\\Icons\\Trade_Engineering",
    ["Jewelcrafting"]  = "Interface\\Icons\\INV_Misc_Gem_01",
    ["Leatherworking"] = "Interface\\Icons\\INV_Misc_ArmorKit_17",
    ["Tailoring"]      = "Interface\\Icons\\Trade_Tailoring",
    -- Secondary
    ["Mining"]         = "Interface\\Icons\\Trade_Mining",
    ["Herbalism"]      = "Interface\\Icons\\Trade_Herbalism",
    ["Skinning"]       = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    ["Cooking"]        = "Interface\\Icons\\INV_Misc_Food_15",
}

----------------------------------------------------------------------
-- Populate Left Panel: Profession List
----------------------------------------------------------------------

function UI:PopulateProfessionList()
    self._navState = "professions"
    self._selectedProfession = nil
    self._selectedMember = nil
    self.leftBreadcrumb:Hide()
    self:HideProfessionToggle()

    -- Clear existing rows
    self:ClearLeftRows()

    local primaryProfs, secondaryProfs = GuildCrafts.Data:GetProfessionGroups()
    local showOnlineOnly = GuildCrafts.db and GuildCrafts.db.profile.showOnlineOnly
    local yOffset = 0

    local function addProfRow(profName)
        local count
        if showOnlineOnly then
            count = GuildCrafts.Data:GetProfessionMemberCount(profName, true)
        else
            count = GuildCrafts.Data:GetProfessionMemberCount(profName)
        end
        local row = self:CreateLeftRow(self.leftContent, yOffset, profName, "(" .. count .. ")", PROFESSION_ICONS[profName])
        local capturedProfName = profName
        local capturedRow = row
        row.profName = profName  -- stored so active-row restoration can find the correct row
        row:SetScript("OnClick", function()
            UI:SetActiveLeftRow(capturedRow)
            UI:NavigateToProfession(capturedProfName)
        end)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end

    for _, profName in ipairs(primaryProfs) do
        addProfRow(profName)
    end

    -- Divider between primary crafting and secondary (gathering + cooking) professions
    local sep = self:CreateLeftSeparator(self.leftContent, yOffset, "Secondary")
    self.leftRows[#self.leftRows + 1] = sep
    yOffset = yOffset + 20

    for _, profName in ipairs(secondaryProfs) do
        addProfRow(profName)
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
    self:ClearDetailRows()   -- remove any leftover detail content before showing welcome
    self:UpdateDetailWelcome()
end

--- Create (or reuse) a non-interactive separator row for the left panel.
function UI:CreateLeftSeparator(parent, yOffset, label)
    local sep = table.remove(self._leftSeparatorPool)
    if sep then
        sep:SetParent(parent)
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT",  parent, "TOPLEFT",  4, -yOffset)
        sep:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -yOffset)
        sep._sepLabel:SetText(label)
        sep:Show()
        return sep
    end

    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(20)
    f:SetPoint("TOPLEFT",  parent, "TOPLEFT",  4, -yOffset)
    f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -yOffset)
    f._isSeparator = true

    -- Thin horizontal rule
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT",  f, "LEFT",  0, 2)
    line:SetPoint("RIGHT", f, "RIGHT", 0, 2)
    line:SetTexture("Interface\\Buttons\\WHITE8x8")
    line:SetVertexColor(0.25, 0.25, 0.25, 0.8)

    -- Label
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", f, "LEFT", 4, 0)
    fs:SetText(label)
    fs:SetTextColor(0.45, 0.45, 0.45)
    f._sepLabel = fs

    return f
end

----------------------------------------------------------------------
-- Populate Left Panel: Member List for a Profession
----------------------------------------------------------------------

function UI:NavigateToMembers(profName)
    self._navState = "members"
    self._selectedProfession = profName
    self._selectedMember = nil
    self.expandedRecipes = {}

    -- Show profession title + view toggle in detail panel
    self:ShowProfessionToggle(profName)

    -- Show breadcrumb
    self.leftBreadcrumb:Show()
    self.leftBreadcrumbText:SetText("< Back")

    self:ClearLeftRows()

    local membersByProf = GuildCrafts.Data:GetMembersByProfession()
    local members = membersByProf[profName] or {}

    -- Sort: online first, then alphabetical
    self:SortMemberList(members)

    local showOnlineOnly = GuildCrafts.db and GuildCrafts.db.profile.showOnlineOnly
    local yOffset = 0
    for _, memberInfo in ipairs(members) do
        local isOnline = GuildCrafts.Data:IsMemberOnline(memberInfo.key)
        if not showOnlineOnly or isOnline then
            local dot, _, isAddon = MemberDotState(memberInfo.key)
            local specTag = ""
            local skillTag = ""
            local staleTag = ""
            if memberInfo.entry and memberInfo.entry.professions and memberInfo.entry.professions[profName] then
                local profData = memberInfo.entry.professions[profName]
                local spec = profData.specialisation
                if spec then
                    specTag = "  |cffaaddff[" .. spec .. "]|r"
                end
                if profData.skillLevel and profData.maxSkillLevel then
                    skillTag = "  |cffffff99" .. profData.skillLevel .. "/" .. profData.maxSkillLevel .. "|r"
                end
            end
            -- Staleness / absent indicator
            if memberInfo.entry then
                local stale = GuildCrafts.Data:GetStalenessTag(memberInfo.entry.lastUpdate)
                if stale then
                    staleTag = "  |cffff6666[" .. stale .. "]|r"
                end
                if memberInfo.entry._absentSince then
                    staleTag = staleTag .. "  |cff999999(left guild)|r"
                end
            end
            local label = dot .. memberInfo.key:match("^(.+)-") .. skillTag .. specTag .. staleTag
            local row = self:CreateLeftRow(self.leftContent, yOffset, label)
            row.memberKey = memberInfo.key
            row:SetScript("OnClick", function()
                UI:ShowMemberRecipes(memberInfo.key, profName)
            end)
            SetMemberDotTooltip(row, isOnline, isAddon)
            -- Member star
            local capturedMemberKey = memberInfo.key
            local memberStar = self:CreateStarButton(row, 14, function(btn)
                local nowFav = GuildCrafts.Favorites:ToggleMember(capturedMemberKey)
                UI:UpdateStarAppearance(btn, nowFav)
            end)
            memberStar:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            self:UpdateStarAppearance(memberStar, GuildCrafts.Favorites:IsMemberFavorite(memberInfo.key))
            row._star = memberStar
            self.leftRows[#self.leftRows + 1] = row
            yOffset = yOffset + 24
        end
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
    self:UpdateDetailWelcome()
end

----------------------------------------------------------------------
-- Navigate Back
----------------------------------------------------------------------

function UI:NavigateBack()
    self._viewMode = "members"  -- reset view mode on back navigation
    if self._navState == "members" then
        self:PopulateProfessionList()
    elseif self._navState == "allMembers" then
        self:PopulateProfessionList()
    elseif self._navState == "favorites" then
        self:PopulateProfessionList()
    end
end

----------------------------------------------------------------------
-- Show Member Recipes (Detail Panel)
----------------------------------------------------------------------

function UI:ShowMemberRecipes(memberKey, profName)
    self._selectedMember = memberKey
    self.detailWelcome:Hide()
    self:ClearDetailRows()

    local db = GuildCrafts.Data:GetGuildDB()
    if not db then return end
    local entry = db[memberKey]
    if not entry or not entry.professions or not entry.professions[profName] then
        self:ShowDetailEmpty(memberKey, profName)
        return
    end

    local recipes = entry.professions[profName].recipes
    if not recipes or next(recipes) == nil then
        self:ShowDetailEmpty(memberKey, profName)
        return
    end

    -- Header
    local header = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, -8)
    local headerText = memberKey:match("^(.+)-") .. " — " .. profName
    local profData = entry.professions[profName]
    if profData.skillLevel and profData.maxSkillLevel then
        headerText = headerText .. "  " .. profData.skillLevel .. "/" .. profData.maxSkillLevel
    end
    local spec = profData.specialisation
    -- Staleness warning in header
    local stale = GuildCrafts.Data:GetStalenessTag(entry.lastUpdate)
    if stale then
        headerText = headerText .. "  |cffff6666[" .. stale .. "]|r"
    end
    header:SetText(headerText)
    header:SetTextColor(1, 0.82, 0)
    self.detailRows[#self.detailRows + 1] = header

    -- Last-scanned timestamp
    local scanLabel = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanLabel:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, -26)
    scanLabel:SetText("|cff808080Scanned: " .. FormatAge(entry.lastUpdate) .. "|r")
    self.detailRows[#self.detailRows + 1] = scanLabel

    -- Specialisation hover label in right panel
    if spec then
        local specBtn = CreateFrame("Frame", nil, self.detailContent)
        specBtn:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, -40)
        specBtn:SetPoint("RIGHT",   self.detailContent, "RIGHT",  -8,  0)
        specBtn:SetHeight(14)
        specBtn:EnableMouse(true)
        local specFS = specBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        specFS:SetPoint("LEFT", specBtn, "LEFT", 0, 0)
        specFS:SetText("|cffaaddff[" .. spec .. "]|r")
        local capturedSpec = spec
        specBtn:SetScript("OnEnter", function(self)
            local desc = GuildCrafts.Data:GetSpecialisationDescription(capturedSpec)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(capturedSpec, 0.67, 0.87, 1)
            if desc then GameTooltip:AddLine(desc, 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        specBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.detailRows[#self.detailRows + 1] = specBtn
    end

    local yOffset = spec and -58 or -42

    -- Cooldowns section (if any active)
    if profData.cooldowns then
        local hasCooldowns = false
        -- Collect and sort active cooldowns
        local cdList = {}
        for cdName, cdInfo in pairs(profData.cooldowns) do
            local remaining = GuildCrafts.Data:FormatCooldownRemaining(cdInfo.endTime)
            if remaining then
                cdList[#cdList + 1] = { name = cdName, remaining = remaining }
                hasCooldowns = true
            end
        end
        if hasCooldowns then
            table.sort(cdList, function(a, b) return a.name < b.name end)
            local cdHeader = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            cdHeader:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
            cdHeader:SetText("Active Cooldowns")
            cdHeader:SetTextColor(1, 0.5, 0.2)
            self.detailRows[#self.detailRows + 1] = cdHeader
            yOffset = yOffset - 16
            for _, cd in ipairs(cdList) do
                local cdText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                cdText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset)
                cdText:SetText(cd.name .. "  |cffff8800" .. cd.remaining .. " remaining|r")
                cdText:SetTextColor(0.9, 0.9, 0.9)
                self.detailRows[#self.detailRows + 1] = cdText
                yOffset = yOffset - 14
            end
            yOffset = yOffset - 8
        end
    end

    -- Sort recipes by category then name
    local sorted = {}
    for key, data in pairs(recipes) do
        sorted[#sorted + 1] = {
            key = key,
            name = GuildCrafts.Data:GetLocalizedRecipeName(key, data.name),
            source = data.source or "",
            reagents = data.reagents or GuildCrafts.Data:GetRecipeReagents(key),
            category = data.category or GuildCrafts.Data:GetRecipeCategory(key) or "",
        }
    end
    table.sort(sorted, function(a, b)
        if a.category ~= b.category then
            -- Empty category sorts last
            if a.category == "" then return false end
            if b.category == "" then return true end
            return a.category < b.category
        end
        return a.name < b.name
    end)

    local filteredSorted = {}
    for _, recipe in ipairs(sorted) do
        local expTag = GuildCrafts.Data:GetExpansionTag(profName, recipe.key)
        if not expTag or not GuildCrafts.db or GuildCrafts.db.profile.expansionFilter[expTag] then
            filteredSorted[#filteredSorted + 1] = recipe
        end
    end

    local lastCategory = nil
    self.expandedRecipes = self.expandedRecipes or {}
    for _, recipe in ipairs(filteredSorted) do
        -- Category header
        local displayCategory = recipe.category ~= "" and recipe.category or nil
        if displayCategory and displayCategory ~= lastCategory then
            lastCategory = displayCategory
            local catText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            catText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
            catText:SetText(displayCategory)
            catText:SetTextColor(0.9, 0.7, 0.3)
            self.detailRows[#self.detailRows + 1] = catText
            yOffset = yOffset - 18
        elseif not displayCategory and lastCategory and lastCategory ~= "" then
            -- Transitioning from categorized to uncategorized recipes
            lastCategory = ""
            local catText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            catText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
            catText:SetText("Other")
            catText:SetTextColor(0.9, 0.7, 0.3)
            self.detailRows[#self.detailRows + 1] = catText
            yOffset = yOffset - 18
        end

        -- Determine expand state for this recipe
        local hasReagents = recipe.reagents and #recipe.reagents > 0
        local isExpanded  = self.expandedRecipes[recipe.key] or false

        -- Recipe row (clickable when has reagents, for expand/collapse)
        local recipeRow = CreateFrame("Frame", nil, self.detailContent)
        recipeRow:SetSize(400, 16)
        recipeRow:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
        self.detailRows[#self.detailRows + 1] = recipeRow

        -- Expand/collapse indicator (+/-) or ~ when no reagent data synced
        local expandIcon
        if hasReagents then
            expandIcon = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            expandIcon:SetPoint("LEFT", recipeRow, "LEFT", 0, 0)
            expandIcon:SetWidth(14)
            expandIcon:SetText(isExpanded and "-" or "+")
            expandIcon:SetTextColor(0.6, 0.6, 0.6)
        else
            -- Tilde placeholder: reagents not yet synced for this recipe
            local noReagIcon = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noReagIcon:SetPoint("LEFT", recipeRow, "LEFT", 0, 0)
            noReagIcon:SetWidth(14)
            noReagIcon:SetText("~")
            noReagIcon:SetTextColor(0.35, 0.35, 0.35)
        end

        -- Star toggle (always offset 16 to align with the icon column)
        local capturedKey = recipe.key
        local star = self:CreateStarButton(recipeRow, 14, function(btn)
            local nowFav = GuildCrafts.Favorites:ToggleRecipe(capturedKey)
            UI:UpdateStarAppearance(btn, nowFav)
        end)
        star:SetPoint("LEFT", recipeRow, "LEFT", 16, 0)
        self:UpdateStarAppearance(star, GuildCrafts.Favorites:IsRecipeFavorite(recipe.key))
        self.detailRows[#self.detailRows + 1] = star

        -- Recipe name (quality colored)
        local nameText = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT", star, "RIGHT", 2, 0)
        local qColor = self:GetRecipeQualityColor(recipe.key)
        nameText:SetText(qColor .. recipe.name .. "|r")

        -- Name overlay: item/spell tooltip on hover (name area only)
        local nameHit = CreateFrame("Frame", nil, recipeRow)
        nameHit:SetPoint("TOPLEFT",     star,      "TOPRIGHT",    2, 0)
        nameHit:SetPoint("BOTTOMRIGHT", recipeRow, "BOTTOMRIGHT", 0, 0)
        nameHit:EnableMouse(true)
        nameHit:SetScript("OnEnter", function(self)
            UI:ShowRecipeTooltip(self, capturedKey)
        end)
        nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Click recipe row to toggle reagents (only when has reagents)
        if hasReagents then
            local capturedMemberKey = memberKey
            local capturedProfName  = profName
            local capturedExpKey    = recipe.key
            recipeRow:EnableMouse(true)
            recipeRow:SetScript("OnMouseDown", function(_, button)
                if button == "LeftButton" then
                    UI.expandedRecipes[capturedExpKey] = not UI.expandedRecipes[capturedExpKey]
                    UI:ShowMemberRecipes(capturedMemberKey, capturedProfName)
                end
            end)
            recipeRow:SetScript("OnEnter", function()
                if expandIcon then expandIcon:SetTextColor(1, 1, 1) end
            end)
            recipeRow:SetScript("OnLeave", function()
                if expandIcon then expandIcon:SetTextColor(0.6, 0.6, 0.6) end
            end)
        end

        -- Source (subdued)
        if recipe.source and recipe.source ~= "" then
            local sourceText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            sourceText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset - 14)
            sourceText:SetText(recipe.source)
            sourceText:SetTextColor(0.5, 0.5, 0.5)
            self.detailRows[#self.detailRows + 1] = sourceText
            yOffset = yOffset - 14
        end

        -- Reagents (vertical list, only rendered when expanded)
        if hasReagents and isExpanded then
            for _, r in ipairs(recipe.reagents) do
                local reagentFrame = CreateFrame("Frame", nil, self.detailContent)
                reagentFrame:SetSize(300, 14)
                reagentFrame:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 32, yOffset - 14)
                reagentFrame:EnableMouse(true)
                local reagentLine = reagentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                reagentLine:SetAllPoints()
                reagentLine:SetJustifyH("LEFT")
                reagentLine:SetText(r.count .. "x " .. GuildCrafts.Data:GetLocalizedReagentName(r))
                reagentLine:SetTextColor(0.6, 0.8, 1.0)
                if r.itemID then
                    local capturedItemID = r.itemID
                    reagentFrame:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetHyperlink("item:" .. capturedItemID)
                        GameTooltip:Show()
                    end)
                    reagentFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                self.detailRows[#self.detailRows + 1] = reagentFrame
                yOffset = yOffset - 14
            end
            yOffset = yOffset - 4
        end

        yOffset = yOffset - 14
    end

    self.detailContent:SetHeight(math.max(math.abs(yOffset) + 8, 1))
end

----------------------------------------------------------------------
-- Show Search Results (Detail Panel)
----------------------------------------------------------------------

function UI:ShowSearchResults(results)
    self._searchActive = true
    self._lastSearchResults = results  -- cached for reagent expand/collapse re-render
    self.detailWelcome:Hide()
    self:HideProfessionToggle()
    self:ClearDetailRows()

    if #results == 0 then
        local query = self.searchBox and self.searchBox:GetText() or ""
        local noResult = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noResult:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -80)
        noResult:SetWidth(360)
        noResult:SetJustifyH("CENTER")
        if query ~= "" then
            noResult:SetText("Nobody in the guild knows '" .. query .. "'.")
        else
            noResult:SetText("No results found.")
        end
        noResult:SetTextColor(0.5, 0.5, 0.5)
        self.detailContent:SetHeight(160)
        self.detailRows[#self.detailRows + 1] = noResult
        return
    end

    self.expandedRecipes = self.expandedRecipes or {}
    local myKey = GuildCrafts.Data:GetPlayerKey()
    local filteredResults = {}
    for _, result in ipairs(results) do
        local expTag = GuildCrafts.Data:GetExpansionTag(result.profName, result.recipeKey)
        if not expTag or not GuildCrafts.db or GuildCrafts.db.profile.expansionFilter[expTag] then
            filteredResults[#filteredResults + 1] = result
        end
    end

    local yOffset = -8
    for _, result in ipairs(filteredResults) do
        local hasReagents = result.reagents and #result.reagents > 0
        local isExpanded  = self.expandedRecipes[result.recipeKey] or false

        -- Main compact row (matches Recipes-view layout)
        local recipeRow = CreateFrame("Frame", nil, self.detailContent)
        recipeRow:SetHeight(20)
        recipeRow:SetPoint("TOPLEFT",  self.detailContent, "TOPLEFT",  8, yOffset)
        recipeRow:SetPoint("TOPRIGHT", self.detailContent, "TOPRIGHT", -8, yOffset)
        recipeRow:EnableMouse(true)
        self.detailRows[#self.detailRows + 1] = recipeRow

        -- +/- toggle or ~ placeholder (always 16px icon column)
        local expandIcon
        if hasReagents then
            expandIcon = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            expandIcon:SetPoint("LEFT", recipeRow, "LEFT", 0, 0)
            expandIcon:SetWidth(14)
            expandIcon:SetText(isExpanded and "-" or "+")
            expandIcon:SetTextColor(0.6, 0.6, 0.6)
            local capturedKey = result.recipeKey
            recipeRow:SetScript("OnMouseDown", function(_, button)
                if button == "LeftButton" then
                    UI.expandedRecipes[capturedKey] = not UI.expandedRecipes[capturedKey]
                    UI:ShowSearchResults(UI._lastSearchResults)
                end
            end)
        else
            local noReagIcon = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noReagIcon:SetPoint("LEFT", recipeRow, "LEFT", 0, 0)
            noReagIcon:SetWidth(14)
            noReagIcon:SetText("~")
            noReagIcon:SetTextColor(0.35, 0.35, 0.35)
        end

        -- Hover: highlight expand/collapse icon
        local capturedExpandIcon = expandIcon
        local capturedRecipeKey  = result.recipeKey
        recipeRow:SetScript("OnEnter", function()
            if capturedExpandIcon then capturedExpandIcon:SetTextColor(1, 1, 1) end
        end)
        recipeRow:SetScript("OnLeave", function()
            if capturedExpandIcon then capturedExpandIcon:SetTextColor(0.6, 0.6, 0.6) end
        end)

        -- Star button (always at 16px offset)
        local capturedKey = result.recipeKey
        local star = self:CreateStarButton(recipeRow, 16, function(btn)
            local nowFav = GuildCrafts.Favorites:ToggleRecipe(capturedKey)
            UI:UpdateStarAppearance(btn, nowFav)
        end)
        star:SetPoint("LEFT", recipeRow, "LEFT", 16, 0)
        self:UpdateStarAppearance(star, GuildCrafts.Favorites:IsRecipeFavorite(result.recipeKey))
        self.detailRows[#self.detailRows + 1] = star

        -- Quality-colored recipe name + profession (left section)
        local qColor = self:GetRecipeQualityColor(result.recipeKey)
        local nameText = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT",  star,      "RIGHT", 2, 0)
        nameText:SetPoint("RIGHT", recipeRow, "RIGHT", -175, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetText(qColor .. result.recipeName .. "|r  |cff666666(" .. result.profName .. ")|r")

        -- Name overlay: item/spell tooltip on hover (name area only)
        local nameHit = CreateFrame("Frame", nil, recipeRow)
        nameHit:SetPoint("TOPLEFT",     star,      "TOPRIGHT",    2,    0)
        nameHit:SetPoint("BOTTOMRIGHT", recipeRow, "BOTTOMRIGHT", -175, 0)
        nameHit:EnableMouse(true)
        nameHit:SetScript("OnEnter", function(self)
            UI:ShowRecipeTooltip(self, capturedRecipeKey)
        end)
        nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Inline crafter preview (right section, max 2 + overflow count)
        table.sort(result.crafters, function(a, b)
            if a.key == myKey then return true end
            if b.key == myKey then return false end
            local aOn = GuildCrafts.Data:IsMemberOnline(a.key)
            local bOn = GuildCrafts.Data:IsMemberOnline(b.key)
            if aOn ~= bOn then return aOn end
            return a.key < b.key
        end)
        local showOnlineOnly = GuildCrafts.db and GuildCrafts.db.profile.showOnlineOnly
        local displayCrafters = {}
        for _, c in ipairs(result.crafters) do
            if not showOnlineOnly or c.key == myKey or GuildCrafts.Data:IsMemberOnline(c.key) then
                displayCrafters[#displayCrafters + 1] = c
            end
        end
        local total = #displayCrafters
        local cParts = {}
        for i = 1, math.min(total, 2) do
            local c = displayCrafters[i]
            local cname = c.key:match("^(.+)-") or c.key
            if c.key == myKey then
                cname = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t" .. cname
            end
            cParts[#cParts + 1] = cname
        end
        local crafterStr = table.concat(cParts, ", ")
        if total > 2 then crafterStr = crafterStr .. " |cff1eff00(+" .. (total - 2) .. ")|r" end
        if total == 0 and showOnlineOnly then crafterStr = "|cff666666—|r" end
        -- Post-to-guild-chat button (always right-most)
        local capturedSearchResult = result
        local postBtn = self:CreatePostButton(recipeRow, function()
            GuildCrafts:PostCraftersToGuildChat(capturedSearchResult.recipeName, capturedSearchResult.recipeKey, capturedSearchResult.crafters)
        end)
        postBtn:SetPoint("RIGHT", recipeRow, "RIGHT", 0, 0)
        self.detailRows[#self.detailRows + 1] = postBtn

        -- Whisper button (left of post button)
        local whisperBtn    = self:CreateWhisperButton(recipeRow, result.crafters, result.recipeName, myKey)
        local whisperAnchor = postBtn
        if whisperBtn then
            whisperBtn:SetPoint("RIGHT", postBtn, "LEFT", -2, 0)
            self.detailRows[#self.detailRows + 1] = whisperBtn
            whisperAnchor = whisperBtn
        end

        local crafterText = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        crafterText:SetPoint("RIGHT", whisperAnchor, "LEFT", -2, 0)
        crafterText:SetWidth(140)
        crafterText:SetJustifyH("RIGHT")
        crafterText:SetWordWrap(false)
        crafterText:SetText(crafterStr)
        crafterText:SetTextColor(0.8, 0.8, 0.8)

        -- Crafter list tooltip on hover (right side, over crafter text)
        if total > 0 then
            local capturedCrafters = displayCrafters
            local capturedMyKey    = myKey
            local capturedName     = result.recipeName
            local crafterHit = CreateFrame("Frame", nil, recipeRow)
            crafterHit:SetPoint("RIGHT", whisperAnchor, "LEFT", -2, 0)
            crafterHit:SetSize(140, 20)
            crafterHit:EnableMouse(true)
            crafterHit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(capturedName, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                for _, c in ipairs(capturedCrafters) do
                    local cname  = c.key:match("^(.+)-") or c.key
                    local isSelf = (c.key == capturedMyKey)
                    local isOn   = GuildCrafts.Data:IsMemberOnline(c.key)
                    local line   = (isSelf and "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t" or "  ") .. cname
                    if isOn then line = line .. " |cff00ff00(online)|r" end
                    GameTooltip:AddLine(line, 0.9, 0.9, 0.9)
                end
                GameTooltip:Show()
            end)
            crafterHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        yOffset = yOffset - 22

        -- Expanded section: vertical reagents only (crafters already shown inline on the right)
        if isExpanded then
            if hasReagents then
                for _, r in ipairs(result.reagents) do
                    local reagentFrame = CreateFrame("Frame", nil, self.detailContent)
                    reagentFrame:SetSize(300, 14)
                    reagentFrame:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 36, yOffset)
                    reagentFrame:EnableMouse(true)
                    local reagentLine = reagentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    reagentLine:SetAllPoints()
                    reagentLine:SetJustifyH("LEFT")
                    reagentLine:SetText(r.count .. "x " .. GuildCrafts.Data:GetLocalizedReagentName(r))
                    reagentLine:SetTextColor(0.6, 0.8, 1.0)
                    if r.itemID then
                        local capturedItemID = r.itemID
                        reagentFrame:SetScript("OnEnter", function(self)
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetHyperlink("item:" .. capturedItemID)
                            GameTooltip:Show()
                        end)
                        reagentFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    end
                    self.detailRows[#self.detailRows + 1] = reagentFrame
                    yOffset = yOffset - 14
                end
                yOffset = yOffset - 2
            end
            yOffset = yOffset - 4
        end

        yOffset = yOffset - 6  -- gap between recipes
    end

    self.detailContent:SetHeight(math.max(math.abs(yOffset) + 8, 1))
end

----------------------------------------------------------------------
-- Search Handler
----------------------------------------------------------------------

function UI:OnSearch(text)
    if not text or text == "" then
        -- Restore default view
        self._searchActive = false
        self._lastSearchResults = nil
        self.expandedRecipes = {}
        self:PopulateProfessionList()
        self:UpdateDetailWelcome()
        return
    end

    -- Clear expand state when starting a fresh search
    self.expandedRecipes = {}

    local scope = self._searchScope or "All"

    if scope == "All" then
        local results = GuildCrafts.Data:SearchRecipes(text)
        self:ShowSearchResults(results)
        self:FilterMemberList(text)
    elseif scope == "Item" then
        local results = GuildCrafts.Data:SearchRecipes(text)
        self:ShowSearchResults(results)
    elseif scope == "Profession" then
        self:FilterProfessionList(text)
    elseif scope == "Member" then
        self:FilterMemberList(text)
    end
end

function UI:FilterProfessionList(query)
    query = query:lower()
    self._navState = "professions"
    self:ClearLeftRows()

    local professions = GuildCrafts.Data:GetTrackedProfessions()
    local yOffset = 0
    for _, profName in ipairs(professions) do
        if profName:lower():find(query, 1, true) then
            local count = GuildCrafts.Data:GetProfessionMemberCount(profName)
            local row = self:CreateLeftRow(self.leftContent, yOffset, profName, "(" .. count .. ")")
            row:SetScript("OnClick", function()
                UI:NavigateToMembers(profName)
            end)
            self.leftRows[#self.leftRows + 1] = row
            yOffset = yOffset + 24
        end
    end
    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
end

function UI:FilterMemberList(query)
    query = query:lower()
    self._navState = "allMembers"
    self._selectedProfession = nil
    self._selectedMember = nil
    self:ClearLeftRows()
    self.leftBreadcrumb:Hide()

    local db = GuildCrafts.Data:GetGuildDB()
    if not db then return end
    local members = {}
    for memberKey, entry in pairs(db) do
        if type(entry) == "table" and entry.lastUpdate and memberKey:lower():find(query, 1, true) then
            local totalRecipes = 0
            for _, profData in pairs(entry.professions or {}) do
                for _ in pairs(profData.recipes or {}) do totalRecipes = totalRecipes + 1 end
            end
            members[#members + 1] = { key = memberKey, recipeCount = totalRecipes }
        end
    end

    self:SortMemberList(members)

    local yOffset = 0
    for _, memberInfo in ipairs(members) do
        local dot, isOnline, isAddon = MemberDotState(memberInfo.key)
        local label = dot .. memberInfo.key:match("^(.+)-")
        local row = self:CreateLeftRow(self.leftContent, yOffset, label, memberInfo.recipeCount .. " rec")
        SetMemberDotTooltip(row, isOnline, isAddon)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end
    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
end

----------------------------------------------------------------------
-- Favorites Tab
----------------------------------------------------------------------

function UI:ShowFavoritesTab()
    self._navState = "favorites"
    self._selectedProfession = nil
    self._selectedMember = nil
    self._searchActive = false
    self:HideProfessionToggle()
    -- Ensure welcome text is always hidden when entering favorites
    if self.detailWelcome then self.detailWelcome:Hide() end

    -- Breadcrumb
    self.leftBreadcrumb:Show()
    self.leftBreadcrumbText:SetText("< Back")

    self:ClearLeftRows()

    -- Sub-tab buttons (Members / Recipes) at top of left panel
    local subTabHeight = 22
    local tabContainer = CreateFrame("Frame", nil, self.leftContent)
    tabContainer:SetSize(LEFT_PANEL_WIDTH - 28, subTabHeight)
    tabContainer:SetPoint("TOPLEFT", self.leftContent, "TOPLEFT", 0, 0)
    self.leftRows[#self.leftRows + 1] = tabContainer

    local membersTab = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
    membersTab:SetSize((LEFT_PANEL_WIDTH - 28) / 2, subTabHeight)
    membersTab:SetPoint("LEFT", tabContainer, "LEFT", 0, 0)
    membersTab:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local membersTabText = membersTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    membersTabText:SetPoint("CENTER")
    membersTabText:SetText("Members")

    local recipesTab = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
    recipesTab:SetSize((LEFT_PANEL_WIDTH - 28) / 2, subTabHeight)
    recipesTab:SetPoint("RIGHT", tabContainer, "RIGHT", 0, 0)
    recipesTab:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local recipesTabText = recipesTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recipesTabText:SetPoint("CENTER")
    recipesTabText:SetText("Recipes")

    -- Style active/inactive tabs
    local function styleSubTabs()
        if UI._favSubTab == "members" then
            membersTab:SetBackdropColor(0.2, 0.2, 0.3, 1)
            membersTab:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)
            membersTabText:SetTextColor(1, 0.82, 0)
            recipesTab:SetBackdropColor(0.1, 0.1, 0.1, 1)
            recipesTab:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            recipesTabText:SetTextColor(0.6, 0.6, 0.6)
        else
            recipesTab:SetBackdropColor(0.2, 0.2, 0.3, 1)
            recipesTab:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)
            recipesTabText:SetTextColor(1, 0.82, 0)
            membersTab:SetBackdropColor(0.1, 0.1, 0.1, 1)
            membersTab:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
            membersTabText:SetTextColor(0.6, 0.6, 0.6)
        end
    end

    membersTab:SetScript("OnClick", function()
        UI._favSubTab = "members"
        UI:ShowFavoritesTab()
    end)
    recipesTab:SetScript("OnClick", function()
        UI._favSubTab = "recipes"
        UI:ShowFavoritesTab()
    end)

    styleSubTabs()

    local yOffset = subTabHeight + 4

    if self._favSubTab == "members" then
        self:PopulateFavMembers(yOffset)
    else
        self:PopulateFavRecipes(yOffset)
    end

    self:UpdateDetailWelcome()
end

--- Favorites: Members sub-tab
function UI:PopulateFavMembers(yOffset)
    -- Members sub-tab doesn't rebuild the detail panel, so explicitly hide welcome
    if self.detailWelcome then self.detailWelcome:Hide() end
    local members = GuildCrafts.Favorites:GetFavoriteMembersInfo()

    if #members == 0 then
        local empty = self.leftContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", self.leftContent, "TOPLEFT", 8, -yOffset)
        empty:SetWidth(LEFT_PANEL_WIDTH - 30)
        empty:SetWordWrap(true)
        empty:SetText("No favorite members yet.\nClick the * star on a member row to add one.")
        empty:SetTextColor(0.5, 0.5, 0.5)
        empty:SetJustifyH("LEFT")
        self.leftRows[#self.leftRows + 1] = empty
        self.leftContent:SetHeight(yOffset + 80)
        return
    end

    for _, info in ipairs(members) do
        local dot, isOnline, isAddon = MemberDotState(info.key)
        local label = dot .. info.key:match("^(.+)-")
        local row = self:CreateLeftRow(self.leftContent, yOffset, label)
        row.memberKey = info.key

        -- Clicking shows first profession's recipes
        local capturedKey = info.key
        row:SetScript("OnClick", function()
            local entry = info.entry
            if entry and entry.professions then
                local profName = next(entry.professions)
                if profName then
                    UI:ShowMemberRecipes(capturedKey, profName)
                end
            end
        end)
        SetMemberDotTooltip(row, isOnline, isAddon)

        -- Unfavorite star
        local capturedMemberKey = info.key
        local memberStar = self:CreateStarButton(row, 14, function(btn)
            local nowFav = GuildCrafts.Favorites:ToggleMember(capturedMemberKey)
            UI:UpdateStarAppearance(btn, nowFav)
            -- Refresh favorites view after a short delay
            GuildCrafts:ScheduleTimer(function() UI:ShowFavoritesTab() end, 0.1)
        end)
        memberStar:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        self:UpdateStarAppearance(memberStar, true)
        row._star = memberStar

        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
end

--- Favorites: Recipes sub-tab (grouped by profession, shown in detail panel)
function UI:PopulateFavRecipes(yOffset)
    local grouped = GuildCrafts.Favorites:GetFavoriteRecipesGrouped()

    -- Show professions in left panel, recipes in detail panel
    local profNames = {}
    for profName in pairs(grouped) do
        profNames[#profNames + 1] = profName
    end
    table.sort(profNames)

    if #profNames == 0 then
        local empty = self.leftContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", self.leftContent, "TOPLEFT", 8, -yOffset)
        empty:SetWidth(LEFT_PANEL_WIDTH - 30)
        empty:SetWordWrap(true)
        empty:SetText("No favorite recipes yet.\nClick the * star on a recipe row to add one.")
        empty:SetTextColor(0.5, 0.5, 0.5)
        empty:SetJustifyH("LEFT")
        self.leftRows[#self.leftRows + 1] = empty
        self.leftContent:SetHeight(yOffset + 80)
        -- Show all favorites in detail panel
        self:ShowFavRecipesDetail(grouped, nil)
        return
    end

    -- "All" entry at top
    local allRow = self:CreateLeftRow(self.leftContent, yOffset, "All Favorites")
    allRow:SetScript("OnClick", function()
        UI:ShowFavRecipesDetail(grouped, nil)
    end)
    self.leftRows[#self.leftRows + 1] = allRow
    yOffset = yOffset + 24

    for _, profName in ipairs(profNames) do
        local count = #grouped[profName]
        local row = self:CreateLeftRow(self.leftContent, yOffset, profName, "(" .. count .. ")", PROFESSION_ICONS[profName])
        local capturedProfName = profName
        row:SetScript("OnClick", function()
            UI:ShowFavRecipesDetail(grouped, capturedProfName)
        end)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))

    -- Default: show all
    self:ShowFavRecipesDetail(grouped, nil)
end

--- Show favorited recipes in the detail panel.
--- If filterProf is nil, show all; otherwise show only that profession.
function UI:ShowFavRecipesDetail(grouped, filterProf)
    self.detailWelcome:Hide()
    self:ClearDetailRows()

    -- Collect professions to show
    local profNames = {}
    if filterProf then
        if grouped[filterProf] then
            profNames[#profNames + 1] = filterProf
        end
    else
        for profName in pairs(grouped) do
            profNames[#profNames + 1] = profName
        end
        table.sort(profNames)
    end

    if #profNames == 0 then
        local msg = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -80)
        msg:SetWidth(400)
        msg:SetWordWrap(true)
        msg:SetText("No favorite recipes yet.\nClick the * star on any recipe to add it.")
        msg:SetTextColor(0.5, 0.5, 0.5)
        msg:SetJustifyH("CENTER")
        self.detailContent:SetHeight(160)
        self.detailRows[#self.detailRows + 1] = msg
        return
    end

    local yOffset = -8

    for _, profName in ipairs(profNames) do
        -- Profession header
        local profHeader = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        profHeader:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
        profHeader:SetText(profName)
        profHeader:SetTextColor(1, 0.82, 0)
        self.detailRows[#self.detailRows + 1] = profHeader
        yOffset = yOffset - 22

        for _, recipe in ipairs(grouped[profName]) do
            -- Star + recipe name row
            local recipeRow = CreateFrame("Frame", nil, self.detailContent)
            recipeRow:SetSize(400, 16)
            recipeRow:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
            self.detailRows[#self.detailRows + 1] = recipeRow

            local capturedKey = recipe.recipeKey
            local star = self:CreateStarButton(recipeRow, 16, function(btn)
                local nowFav = GuildCrafts.Favorites:ToggleRecipe(capturedKey)
                UI:UpdateStarAppearance(btn, nowFav)
                -- Refresh after unfavorite
                if not nowFav then
                    GuildCrafts:ScheduleTimer(function()
                        local newGrouped = GuildCrafts.Favorites:GetFavoriteRecipesGrouped()
                        UI:ShowFavRecipesDetail(newGrouped, filterProf)
                    end, 0.1)
                end
            end)
            star:SetPoint("LEFT", recipeRow, "LEFT", 0, 0)
            self:UpdateStarAppearance(star, true)
            self.detailRows[#self.detailRows + 1] = star

            local nameText = recipeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("LEFT", star, "RIGHT", 2, 0)
            local qColor = self:GetRecipeQualityColor(recipe.recipeKey)
            nameText:SetText(qColor .. recipe.recipeName .. "|r")

            -- Name overlay: item/spell tooltip on hover (name area only)
            local nameHit = CreateFrame("Frame", nil, recipeRow)
            nameHit:SetPoint("TOPLEFT",     star,      "TOPRIGHT",    2, 0)
            nameHit:SetPoint("BOTTOMRIGHT", recipeRow, "BOTTOMRIGHT", 0, 0)
            nameHit:EnableMouse(true)
            nameHit:SetScript("OnEnter", function(self)
                UI:ShowRecipeTooltip(self, capturedKey)
            end)
            nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            yOffset = yOffset - 18

            -- Crafters list
            for _, crafter in ipairs(recipe.crafters) do
                local dot = crafter.online and "|cff00ff00O|r " or "|cff666666O|r "
                local crafterName = crafter.key:match("^(.+)-") or crafter.key
                local crafterText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                crafterText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 24, yOffset)
                crafterText:SetText(dot .. crafterName)
                crafterText:SetTextColor(0.8, 0.8, 0.8)
                self.detailRows[#self.detailRows + 1] = crafterText
                yOffset = yOffset - 14
            end

            -- Reagents
            if recipe.reagents and #recipe.reagents > 0 then
                local parts = {}
                for _, r in ipairs(recipe.reagents) do
                    parts[#parts + 1] = r.count .. "x " .. GuildCrafts.Data:GetLocalizedReagentName(r)
                end
                local reagentStr = table.concat(parts, ", ")
                local reagentText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                reagentText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 24, yOffset)
                reagentText:SetText("Reagents: " .. reagentStr)
                reagentText:SetTextColor(0.6, 0.8, 1.0)
                reagentText:SetWordWrap(true)
                reagentText:SetWidth(340)
                self.detailRows[#self.detailRows + 1] = reagentText
                local textHeight = reagentText:GetStringHeight()
                if not textHeight or textHeight < 12 then textHeight = 12 end
                yOffset = yOffset - textHeight - 4
            end

            yOffset = yOffset - 6
        end

        yOffset = yOffset - 8
    end

    self.detailContent:SetHeight(math.max(math.abs(yOffset) + 8, 1))
end

----------------------------------------------------------------------
-- Detail Panel Helpers
----------------------------------------------------------------------

function UI:UpdateDetailWelcome()
    -- During a Refresh cycle, skip — Refresh will call us at the end
    -- with the correct state to avoid flashing the welcome text.
    if self._refreshing then return end

    -- Only show the welcome message at the true root idle state:
    -- profession list visible, nothing drilled into, no search active.
    local atRoot = (self._navState == "professions" or self._navState == nil)
                   and not self._selectedProfession
                   and not self._selectedMember
                   and not self._searchActive
    if atRoot then
        self.detailWelcome:Show()
    else
        self.detailWelcome:Hide()
    end
end

function UI:ShowDetailEmpty(_memberKey, _profName)
    self:ClearDetailRows()
    self.detailWelcome:Hide()

    local msg = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    msg:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -80)
    msg:SetWidth(360)
    msg:SetWordWrap(true)
    msg:SetText("No recipes synced yet.\nThis member's data will appear after they open\ntheir profession window with the addon installed.")
    msg:SetTextColor(0.5, 0.5, 0.5)
    msg:SetJustifyH("CENTER")
    self.detailContent:SetHeight(160)
    self.detailRows[#self.detailRows + 1] = msg
end

----------------------------------------------------------------------
-- Star Button Factory
----------------------------------------------------------------------

--- Create a small "post to guild chat" button used on recipe rows.
function UI:CreatePostButton(parent, onClick)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(26, 16)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.1, 0.1, 0.1, 0)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("|cff666666[>]|r")
    btn:SetScript("OnEnter", function()
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        label:SetText("|cffdddddd[>]|r")
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Post crafters to guild chat", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
        label:SetText("|cff666666[>]|r")
        GameTooltip:Hide()
    end)
    btn:SetScript("OnClick", function()
        if onClick then onClick() end
    end)
    return btn
end

--- Pre-fill a whisper to a crafter in the chat edit box.
function UI:OpenWhisper(charKey, itemName)
    local name = charKey:match("^(.+)-") or charKey
    ChatFrame_OpenChat("/w " .. name .. " Can you craft " .. itemName .. " for me?")
end

--- Create a [W] whisper button for the given crafter list.
--- Returns nil when all crafters are self (no one to whisper).
function UI:CreateWhisperButton(parent, crafters, itemName, myKey)
    -- Collect non-self crafters, online first
    local targets = {}
    for _, c in ipairs(crafters) do
        if c.key ~= myKey then
            targets[#targets + 1] = c
        end
    end
    if #targets == 0 then return nil end
    table.sort(targets, function(a, b)
        local aOn = GuildCrafts.Data:IsMemberOnline(a.key)
        local bOn = GuildCrafts.Data:IsMemberOnline(b.key)
        if aOn ~= bOn then return aOn end
        return a.key < b.key
    end)

    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(26, 16)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.1, 0.1, 0.1, 0)
    btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("|cff666666[W]|r")
    btn:SetScript("OnEnter", function()
        btn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        label:SetText("|cffdddddd[W]|r")
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Whisper a crafter", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
        label:SetText("|cff666666[W]|r")
        GameTooltip:Hide()
    end)

    local capturedTargets = targets
    local capturedItem    = itemName
    if #targets == 1 then
        btn:SetScript("OnClick", function()
            UI:OpenWhisper(capturedTargets[1].key, capturedItem)
        end)
    else
        btn:SetScript("OnClick", function()
            UI:ShowWhisperPicker(btn, capturedTargets, capturedItem)
        end)
    end

    return btn
end

--- Show a small dropdown picker to choose which crafter to whisper.
function UI:ShowWhisperPicker(anchor, targets, itemName)
    -- Close any existing picker first
    if self._whisperPicker then
        self._whisperPicker:Hide()
        self._whisperPicker = nil
    end

    local rowH   = 18
    local picker = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    picker:SetSize(130, #targets * rowH + 4)
    picker:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMLEFT", -2, 0)
    picker:SetFrameStrata("TOOLTIP")
    picker:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    picker:SetBackdropColor(0.08, 0.08, 0.08, 0.97)
    picker:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    picker:EnableMouse(true)

    for i, c in ipairs(targets) do
        local cname = c.key:match("^(.+)-") or c.key
        local isOn  = GuildCrafts.Data:IsMemberOnline(c.key)
        local row = CreateFrame("Button", nil, picker, "BackdropTemplate")
        row:SetSize(126, rowH)
        row:SetPoint("TOPLEFT", picker, "TOPLEFT", 2, -(i - 1) * rowH - 2)
        row:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", row, "LEFT", 4, 0)
        fs:SetText(isOn and "|cff00ff00" .. cname .. "|r" or "|cff888888" .. cname .. "|r")
        row:SetScript("OnEnter", function()
            row:SetBackdropColor(0.2, 0.2, 0.2, 0.8)
            row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.5)
        end)
        row:SetScript("OnLeave", function()
            row:SetBackdropColor(0, 0, 0, 0)
            row:SetBackdropBorderColor(0, 0, 0, 0)
        end)
        local capturedKey  = c.key
        local capturedItem = itemName
        row:SetScript("OnClick", function()
            UI:OpenWhisper(capturedKey, capturedItem)
            picker:Hide()
            UI._whisperPicker = nil
        end)
    end

    -- Transparent catch-all backdrop to close on outside click
    local backdrop = CreateFrame("Frame", nil, UIParent)
    backdrop:SetAllPoints(UIParent)
    backdrop:SetFrameStrata("TOOLTIP")
    backdrop:SetFrameLevel(picker:GetFrameLevel() - 1)
    backdrop:EnableMouse(true)
    backdrop:SetScript("OnMouseDown", function()
        picker:Hide()
        backdrop:Hide()
        UI._whisperPicker = nil
    end)
    backdrop:Show()
    picker:SetScript("OnHide", function() backdrop:Hide() end)
    picker:Show()
    self._whisperPicker = picker
end

function UI:CreateStarButton(parent, size, onClick)
    local btn = CreateFrame("Frame", nil, parent)
    btn:SetSize(size, size)
    btn:EnableMouse(true)

    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    icon:SetTexture(STAR_TEXTURE)
    icon:SetVertexColor(0.5, 0.5, 0.5)  -- grey by default
    btn._starIcon = icon

    btn:SetScript("OnMouseDown", function()
        if onClick then onClick(btn) end
    end)

    return btn
end

function UI:UpdateStarAppearance(btn, isFavorite)
    if btn._starIcon then
        if isFavorite then
            btn._starIcon:SetVertexColor(1.0, 0.82, 0.0)  -- gold
        else
            btn._starIcon:SetVertexColor(0.5, 0.5, 0.5)  -- grey
        end
    end
end

----------------------------------------------------------------------
-- Row Factory
----------------------------------------------------------------------

function UI:CreateLeftRow(parent, yOffset, text, badge, iconPath)
    -- Try to reuse a pooled row
    local row = table.remove(self._leftRowPool)
    if row then
        row:SetParent(parent)
        row:SetHeight(22)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -yOffset)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -yOffset)
        -- Reset active-state visuals
        if row._bg     then row._bg:SetVertexColor(0.07, 0.07, 0.07, 0.95) end
        if row._accent then row._accent:Hide() end
        -- Update text
        row._label:ClearAllPoints()
        row._label:SetText(text)
        row._label:SetJustifyH("LEFT")
        -- Update icon
        if iconPath then
            if not row._icon then
                row._icon = row:CreateTexture(nil, "ARTWORK")
                row._icon:SetSize(18, 18)
                row._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            row._icon:SetPoint("LEFT", row, "LEFT", 4, 0)
            row._icon:SetTexture(iconPath)
            row._icon:Show()
            row._label:SetPoint("LEFT",  row, "LEFT",  26, 0)
            row._label:SetPoint("RIGHT", row, "RIGHT", -22, 0)
        else
            if row._icon then row._icon:Hide() end
            row._label:SetPoint("LEFT",  row, "LEFT",  6, 0)
            row._label:SetPoint("RIGHT", row, "RIGHT", -22, 0)
        end
        -- Update badge
        if badge then
            if not row._badge then
                row._badge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            end
            row._badge:ClearAllPoints()
            row._badge:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row._badge:SetText(badge)
            row._badge:SetTextColor(0.5, 0.5, 0.5)
            row._badge:Show()
        else
            if row._badge then row._badge:Hide() end
        end
        row:Show()
        return row
    end

    -- Create new row
    row = CreateFrame("Button", nil, parent)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -yOffset)

    -- Dark background
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0.07, 0.07, 0.07, 0.95)
    row._bg = bg

    -- Gold accent bar (left edge, shown only for active row)
    local accent = row:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(3)
    accent:SetTexture("Interface\\Buttons\\WHITE8x8")
    accent:SetVertexColor(1, 0.82, 0, 1)
    accent:SetPoint("TOPLEFT",    row, "TOPLEFT",    0, -2)
    accent:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0,  2)
    accent:Hide()
    row._accent = accent

    -- Blue hover highlight
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(0.15, 0.35, 0.6, 0.35)

    -- Optional profession icon
    local labelAnchorX = 6
    if iconPath then
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        icon:SetTexture(iconPath)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row._icon = icon
        labelAnchorX = 26
    end

    -- Text (right-anchored to leave room for the star button; no word-wrap)
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT",  row, "LEFT",  labelAnchorX, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    label:SetTextColor(0.9, 0.9, 0.9)
    label:SetText(text)
    label:SetWordWrap(false)
    label:SetJustifyH("LEFT")
    row._label = label

    -- Badge (count)
    if badge then
        local badgeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        badgeText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        badgeText:SetText(badge)
        badgeText:SetTextColor(0.5, 0.5, 0.5)
        row._badge = badgeText
    end

    return row
end

----------------------------------------------------------------------
-- Clear Helpers
----------------------------------------------------------------------

function UI:ClearLeftRows()
    for _, row in ipairs(self.leftRows) do
        row:Hide()
        row:ClearAllPoints()
        if row._isSeparator then
            self._leftSeparatorPool[#self._leftSeparatorPool + 1] = row
        elseif row._label then
            -- Only pool proper row frames (have _label), skip FontStrings/misc frames
            row:SetScript("OnClick",  nil)
            row:SetScript("OnEnter",  nil)
            row:SetScript("OnLeave",  nil)
            row.memberKey = nil
            -- Hide and detach any star buttons that were added as children
            if row._star then
                row._star:Hide()
                row._star:SetScript("OnMouseDown", nil)
                row._star = nil
            end
            self._leftRowPool[#self._leftRowPool + 1] = row
        end
    end
    self.leftRows = {}
    self._activeLeftRow = nil
end

function UI:ClearDetailRows()
    for _, obj in ipairs(self.detailRows) do
        if obj.Hide then obj:Hide() end
        if obj.ClearAllPoints then obj:ClearAllPoints() end
    end
    self.detailRows = {}
end

----------------------------------------------------------------------
-- Sort Members: Online first, then alphabetical
----------------------------------------------------------------------

function UI:SortMemberList(members)
    table.sort(members, function(a, b)
        local aOnline = GuildCrafts.Data:IsMemberOnline(a.key)
        local bOnline = GuildCrafts.Data:IsMemberOnline(b.key)
        if aOnline ~= bOnline then
            return aOnline -- online first
        end
        return a.key < b.key
    end)
end

----------------------------------------------------------------------
-- Sync Indicator Update
----------------------------------------------------------------------

function UI:UpdateSyncIndicator()
    if not self.syncDot then return end
    local status = GuildCrafts.Comms and GuildCrafts.Comms:GetSyncStatus() or "disconnected"
    if status == "synced" then
        self.syncDot:SetVertexColor(unpack(COLOR_GREEN))
    elseif status == "syncing" then
        self.syncDot:SetVertexColor(unpack(COLOR_YELLOW))
    else
        self.syncDot:SetVertexColor(unpack(COLOR_RED))
    end
end

----------------------------------------------------------------------
-- Refresh (called by Comms after sync/delta events)
----------------------------------------------------------------------

function UI:Refresh()
    if not self.mainFrame or not self.mainFrame:IsShown() then return end

    self:UpdateSyncIndicator()

    -- Save state that will be cleared by NavigateToMembers/PopulateProfessionList
    local savedMember = self._selectedMember
    local savedSearch = self._searchActive
    local savedProfession = self._selectedProfession

    -- Suppress intermediate UpdateDetailWelcome calls during refresh
    -- to prevent the welcome text from flashing over content.
    self._refreshing = true

    if self._navState == "professions" then
        self:PopulateProfessionList()
    elseif self._navState == "members" and self._selectedProfession then
        self:NavigateToMembers(self._selectedProfession)
    elseif self._navState == "favorites" then
        self:ShowFavoritesTab()
    end

    self._refreshing = false

    -- Restore state cleared by the left-panel rebuild
    self._selectedMember = savedMember
    self._searchActive = savedSearch
    self._selectedProfession = savedProfession

    -- Restore recipe view if in recipe mode
    if savedSearch and self.searchBox then
        -- Re-run search with current search box text so results reflect any
        -- guild-sync updates while preserving the search panel state.
        local text = self.searchBox:GetText()
        if text and text ~= "" then
            self:OnSearch(text)
        end
    elseif self._viewMode == "recipes" and savedProfession then
        self:ShowRecipesView(savedProfession)
        self:ShowProfessionToggle(savedProfession)
        -- Re-highlight the active profession row in the left panel
        self:RestoreActiveRow(savedProfession)
    elseif self._selectedMember and self._selectedProfession then
        -- Refresh detail if a member was selected (members mode)
        self:ShowMemberRecipes(self._selectedMember, self._selectedProfession)
    end

    -- Make sure welcome state is correct after all updates
    self:UpdateDetailWelcome()
end

----------------------------------------------------------------------
-- Recipe Tooltip Helper
----------------------------------------------------------------------

--- Show the native WoW item or spell tooltip for a recipe key.
--- Positive key = itemID, negative key = spellID (Enchanting / spell-based).
function UI:ShowRecipeTooltip(owner, recipeKey)
    local k = tonumber(recipeKey)
    if not k then return end

    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")

    if k > 0 then
        GameTooltip:SetHyperlink("item:" .. k)
        GameTooltip:Show()
        return
    end

    if k < 0 then
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(-k)
            GameTooltip:Show()
            return
        end
        -- Fallback for clients where SetSpellByID is unavailable
        local link = GetSpellLink(-k)
        if link then
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
            return
        end
    end

    GameTooltip:Hide()
end

----------------------------------------------------------------------
-- Quality Color Helper (#38)
----------------------------------------------------------------------

--- Return a quality color escape code for a recipe key.
--- Positive key = itemID → query GetItemInfo for quality.
--- Negative key = spellID (Enchanting) → no quality, returns white.
function UI:GetRecipeQualityColor(recipeKey)
    local key = tonumber(recipeKey)
    if not key or key <= 0 then
        return QUALITY_COLORS[1]  -- white for Enchanting / unknown
    end
    -- Return cached value if available
    if _qualityCache[key] ~= nil then
        return QUALITY_COLORS[_qualityCache[key]] or QUALITY_COLORS[1]
    end
    -- Query WoW client item cache.
    -- GetItemInfo returns nil when the item is not yet loaded into the client cache.
    -- Do NOT store a nil result — leave the cache empty so the next render attempt
    -- retries the lookup (the client loads items progressively in the background).
    local _, _, q = GetItemInfo(key)
    if q then
        _qualityCache[key] = q
        return QUALITY_COLORS[q] or QUALITY_COLORS[1]
    end
    return QUALITY_COLORS[1]  -- not loaded yet, show white until next render
end

----------------------------------------------------------------------
-- Profession Navigation Entry Point (#44/#45)
----------------------------------------------------------------------

--- Navigate into a profession, respecting the current view mode.
--- Members mode: drill into member list (left panel).
--- Recipes mode: show all recipes in detail panel, profession list stays left.
function UI:NavigateToProfession(profName)
    self._selectedProfession = profName
    if self._viewMode == "recipes" then
        self:ShowRecipesView(profName)
        self:ShowProfessionToggle(profName)
    else
        self:NavigateToMembers(profName)
        -- ShowProfessionToggle is called inside NavigateToMembers
    end
end

----------------------------------------------------------------------
-- Active Left Row Tracking (#37)
----------------------------------------------------------------------

--- Find and re-activate the row in the current left panel that matches profName.
--- Called after a panel rebuild (Refresh, SetViewMode) to restore visual state.
function UI:RestoreActiveRow(profName)
    if not profName then return end
    for _, row in ipairs(self.leftRows) do
        if row.profName == profName then
            self:SetActiveLeftRow(row)
            return
        end
    end
end

--- Highlight a left-panel row as the active (selected) item.
--- Shows gold accent bar; restores previous row to default.
function UI:SetActiveLeftRow(newRow)
    if self._activeLeftRow and self._activeLeftRow ~= newRow then
        local prev = self._activeLeftRow
        if prev._bg     then prev._bg:SetVertexColor(0.07, 0.07, 0.07, 0.95) end
        if prev._accent then prev._accent:Hide() end
    end
    self._activeLeftRow = newRow
    if newRow then
        if newRow._bg     then newRow._bg:SetVertexColor(0.12, 0.12, 0.12, 0.98) end
        if newRow._accent then newRow._accent:Show() end
    end
end

----------------------------------------------------------------------
-- Profession Header + View Toggle (#45)
----------------------------------------------------------------------

--- Show profession title + Members/Recipes toggle in the detail panel.
--- Reanchors the scroll frame below the toggle bar.
function UI:ShowProfessionToggle(profName)
    if not self._profHeader then return end

    -- Update header text and icon
    self._profHeaderText:SetText(profName)
    local icon = PROFESSION_ICONS[profName]
    if icon then
        self._profHeaderIcon:SetTexture(icon)
        self._profHeaderIcon:Show()
    else
        self._profHeaderIcon:Hide()
    end
    self._profHeader:Show()
    self._viewToggleContainer:Show()

    -- Sync toggle button visuals with current view mode
    self:_UpdateViewToggleVisuals()
    self:_UpdateOnlineBtnVisuals()
    self:_UpdateTooltipBtnVisuals()
    self:_UpdateMinimapBtnVisuals()
    self:_UpdateExpansionFilterVisuals()

    -- Reanchor scroll frame below toggle bar
    self.detailScrollFrame:ClearAllPoints()
    self.detailScrollFrame:SetPoint("TOPLEFT",     self._viewToggleContainer, "BOTTOMLEFT",  0, -2)
    self.detailScrollFrame:SetPoint("BOTTOMRIGHT", self.detailPanel,          "BOTTOMRIGHT", -22, 4)
end

--- Hide profession title and toggle; restore scroll frame to full height.
function UI:HideProfessionToggle()
    if not self._profHeader then return end
    self._profHeader:Hide()
    self._viewToggleContainer:Hide()
    -- Restore default scroll frame anchoring
    self.detailScrollFrame:ClearAllPoints()
    self.detailScrollFrame:SetPoint("TOPLEFT",     self.detailPanel, "TOPLEFT",     4,   -4)
    self.detailScrollFrame:SetPoint("BOTTOMRIGHT", self.detailPanel, "BOTTOMRIGHT", -22,  4)
end

--- Update visual state of Members/Recipes toggle buttons.
function UI:_UpdateViewToggleVisuals()
    if not self._viewToggleMembersBtn then return end
    local mem = self._viewToggleMembersBtn
    local rec = self._viewToggleRecipesBtn
    if self._viewMode == "members" then
        mem:SetBackdropColor(0.12, 0.12, 0.12, 1)
        mem:SetBackdropBorderColor(1, 0.82, 0, 1)
        mem._textFS:SetTextColor(1, 0.82, 0)
        mem:Disable()
        rec:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        rec:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        rec._textFS:SetTextColor(0.7, 0.7, 0.7)
        rec:Enable()
    else
        rec:SetBackdropColor(0.12, 0.12, 0.12, 1)
        rec:SetBackdropBorderColor(1, 0.82, 0, 1)
        rec._textFS:SetTextColor(1, 0.82, 0)
        rec:Disable()
        mem:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        mem:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        mem._textFS:SetTextColor(0.7, 0.7, 0.7)
        mem:Enable()
    end
end

--- Update the [Online] button visual to match the current filter state.
function UI:_UpdateOnlineBtnVisuals()
    if not self._onlineBtn then return end
    local on = GuildCrafts.db and GuildCrafts.db.profile.showOnlineOnly
    if on then
        self._onlineBtn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        self._onlineBtn:SetBackdropBorderColor(1, 0.82, 0, 1)
        self._onlineBtn._textFS:SetTextColor(1, 0.82, 0)
    else
        self._onlineBtn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        self._onlineBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        self._onlineBtn._textFS:SetTextColor(0.4, 0.4, 0.4)
    end
end

--- Update the [Minimap] button visual to match the current setting.
function UI:_UpdateMinimapBtnVisuals()
    if not self._minimapBtn then return end
    local hidden = GuildCrafts.db and GuildCrafts.db.global._minimapHide
    if not hidden then
        self._minimapBtn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        self._minimapBtn:SetBackdropBorderColor(1, 0.82, 0, 1)
        self._minimapBtn._textFS:SetTextColor(1, 0.82, 0)
    else
        self._minimapBtn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        self._minimapBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        self._minimapBtn._textFS:SetTextColor(0.4, 0.4, 0.4)
    end
end

--- Update the [Tooltip] button visual to match the current setting.
function UI:_UpdateTooltipBtnVisuals()
    if not self._tooltipBtn then return end
    local on = not (GuildCrafts.db and GuildCrafts.db.profile.showTooltipCrafters == false)
    if on then
        self._tooltipBtn:SetBackdropColor(0.12, 0.12, 0.12, 1)
        self._tooltipBtn:SetBackdropBorderColor(1, 0.82, 0, 1)
        self._tooltipBtn._textFS:SetTextColor(1, 0.82, 0)
    else
        self._tooltipBtn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
        self._tooltipBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        self._tooltipBtn._textFS:SetTextColor(0.4, 0.4, 0.4)
    end
end

--- Update visual state of the [Orig] and [TBC] expansion filter buttons.
function UI:_UpdateExpansionFilterVisuals()
    if not self._expFilterOrigBtn then return end
    local f = GuildCrafts.db and GuildCrafts.db.profile.expansionFilter
    if not f then return end
    for _, info in ipairs({
        { btn = self._expFilterOrigBtn, tag = "ORIG" },
        { btn = self._expFilterTBCBtn,  tag = "TBC"  },
    }) do
        if f[info.tag] then
            info.btn:SetBackdropColor(0.12, 0.12, 0.12, 1)
            info.btn:SetBackdropBorderColor(1, 0.82, 0, 1)
            info.btn._textFS:SetTextColor(1, 0.82, 0)
        else
            info.btn:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
            info.btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            info.btn._textFS:SetTextColor(0.4, 0.4, 0.4)
        end
    end
end

--- Toggle an expansion filter tag ("ORIG" or "TBC") and refresh the active view.
function UI:ToggleExpansionFilter(tag)
    if not GuildCrafts.db then return end
    local f = GuildCrafts.db.profile.expansionFilter
    local other = tag == "ORIG" and "TBC" or "ORIG"
    -- Prevent both being off
    if f[tag] and not f[other] then return end
    f[tag] = not f[tag]
    self:_UpdateExpansionFilterVisuals()
    if self._searchActive and self._lastSearchResults then
        self:ShowSearchResults(self._lastSearchResults)
    elseif self._viewMode == "recipes" and self._selectedProfession then
        self:ShowRecipesView(self._selectedProfession)
    elseif self._selectedMember and self._selectedProfession then
        self:ShowMemberRecipes(self._selectedMember, self._selectedProfession)
    end
end

--- Toggle the "show online crafters only" filter and refresh the active view.
function UI:ToggleOnlineFilter()
    if not GuildCrafts.db then return end
    GuildCrafts.db.profile.showOnlineOnly = not GuildCrafts.db.profile.showOnlineOnly
    self:_UpdateOnlineBtnVisuals()
    if self._searchActive and self._lastSearchResults then
        self:ShowSearchResults(self._lastSearchResults)
    elseif self._viewMode == "recipes" and self._selectedProfession then
        self:ShowRecipesView(self._selectedProfession)
    elseif self._navState == "members" and self._selectedProfession then
        self:NavigateToMembers(self._selectedProfession)
    else
        -- On the profession list: just repopulate so counts refresh
        self:PopulateProfessionList()
    end
end

--- Toggle the minimap button visibility.
function UI:ToggleMinimapBtn()
    if GuildCrafts.MinimapButton then
        GuildCrafts.MinimapButton:Toggle(true)  -- silent: visual feedback from button state
    end
    self:_UpdateMinimapBtnVisuals()
end

--- Toggle whether crafters are shown in item tooltips.
function UI:ToggleTooltipCrafters()
    if not GuildCrafts.db then return end
    GuildCrafts.db.profile.showTooltipCrafters = not GuildCrafts.db.profile.showTooltipCrafters
    self:_UpdateTooltipBtnVisuals()
end

--- Switch the profession view mode and refresh content accordingly.
function UI:SetViewMode(mode)
    self._viewMode = mode
    self:_UpdateViewToggleVisuals()
    local profName = self._selectedProfession
    if not profName then return end

    if mode == "recipes" then
        -- Ensure left panel shows profession list
        if self._navState ~= "professions" then
            local savedProf = profName
            self:PopulateProfessionList()   -- resets left panel + clears _selectedProfession
            self._selectedProfession = savedProf
        end
        self:ShowRecipesView(profName)
        self:ShowProfessionToggle(profName)
        -- Re-highlight the active profession row in the left panel
        self:RestoreActiveRow(profName)
    else  -- "members"
        self:NavigateToMembers(profName)
        -- ShowProfessionToggle called inside NavigateToMembers
    end
end

----------------------------------------------------------------------
-- Recipe-Centric View (#44)
----------------------------------------------------------------------

--- Show all guild recipes for a profession in the detail panel.
--- Left panel remains on the profession list.
--- Each row: +/- toggle, quality-colored name (left), inline crafter preview (right).
--- Click +/- to expand vertical reagent list below the row.
function UI:ShowRecipesView(profName)
    self._navState         = "professions"
    self._selectedMember   = nil
    self._selectedProfession = profName
    self.detailWelcome:Hide()
    self:ClearDetailRows()

    local recipes = GuildCrafts.Data:GetAllRecipesForProfession(profName)

    if not recipes or #recipes == 0 then
        local msg = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        msg:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, -80)
        msg:SetWidth(self.detailScrollFrame:GetWidth() - 20)
        msg:SetWordWrap(true)
        msg:SetText("No recipes found for " .. profName .. ".\nMembers need to open their profession window\nwhile the addon is active.")
        msg:SetTextColor(0.5, 0.5, 0.5)
        msg:SetJustifyH("CENTER")
        self.detailContent:SetHeight(160)
        self.detailRows[#self.detailRows + 1] = msg
        return
    end

    local myKey   = GuildCrafts.Data:GetPlayerKey()
    self.expandedRecipes = self.expandedRecipes or {}
    local filteredRecipes = {}
    for _, recipe in ipairs(recipes) do
        local expTag = GuildCrafts.Data:GetExpansionTag(profName, recipe.key)
        if not expTag or not GuildCrafts.db or GuildCrafts.db.profile.expansionFilter[expTag] then
            filteredRecipes[#filteredRecipes + 1] = recipe
        end
    end

    local yOffset = -8
    for _, recipe in ipairs(filteredRecipes) do
        local hasReagents = recipe.reagents and #recipe.reagents > 0
        local isExpanded  = self.expandedRecipes[recipe.key] or false

        local row = CreateFrame("Frame", nil, self.detailContent)
        row:SetHeight(20)
        row:SetPoint("TOPLEFT",  self.detailContent, "TOPLEFT",  8, yOffset)
        row:SetPoint("TOPRIGHT", self.detailContent, "TOPRIGHT", -8, yOffset)
        row:EnableMouse(true)
        self.detailRows[#self.detailRows + 1] = row

        -- +/- toggle or ~ placeholder (always 16px icon column)
        local expandIcon
        if hasReagents then
            expandIcon = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            expandIcon:SetPoint("LEFT", row, "LEFT", 0, 0)
            expandIcon:SetWidth(14)
            expandIcon:SetText(isExpanded and "-" or "+")
            expandIcon:SetTextColor(0.6, 0.6, 0.6)
            local capturedKey  = recipe.key
            local capturedProf = profName
            row:SetScript("OnMouseDown", function(_, button)
                if button == "LeftButton" then
                    UI.expandedRecipes[capturedKey] = not UI.expandedRecipes[capturedKey]
                    UI:ShowRecipesView(capturedProf)
                end
            end)
        else
            local noReagIcon = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noReagIcon:SetPoint("LEFT", row, "LEFT", 0, 0)
            noReagIcon:SetWidth(14)
            noReagIcon:SetText("~")
            noReagIcon:SetTextColor(0.35, 0.35, 0.35)
        end

        -- Quality-colored recipe name (shifted 16px for icon column)
        local qColor   = self:GetRecipeQualityColor(recipe.key)
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("LEFT",  row, "LEFT",  16, 0)
        nameText:SetPoint("RIGHT", row, "RIGHT", -180, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetText(qColor .. recipe.name .. "|r")

        -- Name overlay: item/spell tooltip on hover (name area only)
        local capturedNameKey = recipe.key
        local nameHit = CreateFrame("Frame", nil, row)
        nameHit:SetPoint("TOPLEFT",     row, "TOPLEFT",     16,   0)
        nameHit:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -180, 0)
        nameHit:EnableMouse(true)
        nameHit:SetScript("OnEnter", function(self)
            UI:ShowRecipeTooltip(self, capturedNameKey)
        end)
        nameHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Sort crafters: self first, then online, then alphabetical
        table.sort(recipe.crafters, function(a, b)
            local aSelf = (a.key == myKey)
            local bSelf = (b.key == myKey)
            if aSelf ~= bSelf then return aSelf end
            local aOn = GuildCrafts.Data:IsMemberOnline(a.key)
            local bOn = GuildCrafts.Data:IsMemberOnline(b.key)
            if aOn ~= bOn then return aOn end
            return a.key < b.key
        end)

        -- Inline crafter preview (max 2 names, right-aligned)
        local showOnlineOnly = GuildCrafts.db and GuildCrafts.db.profile.showOnlineOnly
        local displayCrafters = {}
        for _, c in ipairs(recipe.crafters) do
            if not showOnlineOnly or c.key == myKey or GuildCrafts.Data:IsMemberOnline(c.key) then
                displayCrafters[#displayCrafters + 1] = c
            end
        end
        local total = #displayCrafters
        local parts = {}
        for i = 1, math.min(total, 2) do
            local c    = displayCrafters[i]
            local name = c.key:match("^(.+)-") or c.key
            if c.key == myKey then
                name = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t" .. name
            end
            parts[#parts + 1] = name
        end
        local crafterStr = table.concat(parts, ", ")
        if total > 2 then crafterStr = crafterStr .. " |cff1eff00(+" .. (total - 2) .. ")|r" end
        if total == 0 and showOnlineOnly then crafterStr = "|cff666666—|r" end

        -- Post-to-guild-chat button (always right-most)
        local capturedPostRecipe = recipe
        local postBtn = self:CreatePostButton(row, function()
            GuildCrafts:PostCraftersToGuildChat(capturedPostRecipe.name, capturedPostRecipe.key, capturedPostRecipe.crafters)
        end)
        postBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        self.detailRows[#self.detailRows + 1] = postBtn

        -- Whisper button (left of post button)
        local whisperBtn    = self:CreateWhisperButton(row, recipe.crafters, recipe.name, myKey)
        local whisperAnchor = postBtn
        if whisperBtn then
            whisperBtn:SetPoint("RIGHT", postBtn, "LEFT", -2, 0)
            self.detailRows[#self.detailRows + 1] = whisperBtn
            whisperAnchor = whisperBtn
        end

        local crafterText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        crafterText:SetPoint("RIGHT", whisperAnchor, "LEFT", -2, 0)
        crafterText:SetWidth(145)
        crafterText:SetJustifyH("RIGHT")
        crafterText:SetWordWrap(false)
        crafterText:SetText(crafterStr)
        crafterText:SetTextColor(0.8, 0.8, 0.8)

        -- Crafter list tooltip on hover (right side, over crafter text)
        if total > 0 then
            local capturedCrafters = displayCrafters
            local capturedMyKey    = myKey
            local capturedName     = recipe.name
            local crafterHit = CreateFrame("Frame", nil, row)
            crafterHit:SetPoint("RIGHT", whisperAnchor, "LEFT", -2, 0)
            crafterHit:SetSize(145, 20)
            crafterHit:EnableMouse(true)
            crafterHit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:ClearLines()
                GameTooltip:AddLine(capturedName, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                for _, c in ipairs(capturedCrafters) do
                    local cname  = c.key:match("^(.+)-") or c.key
                    local isSelf = (c.key == capturedMyKey)
                    local isOn   = GuildCrafts.Data:IsMemberOnline(c.key)
                    local line   = (isSelf and "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:10:10:0:0|t" or "  ") .. cname
                    if isOn then line = line .. " |cff00ff00(online)|r" end
                    GameTooltip:AddLine(line, 0.9, 0.9, 0.9)
                end
                GameTooltip:Show()
            end)
            crafterHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        -- Hover: highlight expand/collapse icon
        local capturedExpandIcon = expandIcon
        row:SetScript("OnEnter", function()
            if capturedExpandIcon then capturedExpandIcon:SetTextColor(1, 1, 1) end
        end)
        row:SetScript("OnLeave", function()
            if capturedExpandIcon then capturedExpandIcon:SetTextColor(0.6, 0.6, 0.6) end
        end)

        yOffset = yOffset - 22

        -- Vertical reagent list (collapsed by default, shown when expanded)
        if hasReagents and isExpanded then
            for _, r in ipairs(recipe.reagents) do
                local reagentFrame = CreateFrame("Frame", nil, self.detailContent)
                reagentFrame:SetSize(300, 14)
                reagentFrame:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 28, yOffset)
                reagentFrame:EnableMouse(true)
                local reagentLine = reagentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                reagentLine:SetAllPoints()
                reagentLine:SetJustifyH("LEFT")
                reagentLine:SetText(r.count .. "x " .. GuildCrafts.Data:GetLocalizedReagentName(r))
                reagentLine:SetTextColor(0.6, 0.8, 1.0)
                if r.itemID then
                    local capturedItemID = r.itemID
                    reagentFrame:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetHyperlink("item:" .. capturedItemID)
                        GameTooltip:Show()
                    end)
                    reagentFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                self.detailRows[#self.detailRows + 1] = reagentFrame
                yOffset = yOffset - 14
            end
            yOffset = yOffset - 4
        end
    end

    self.detailContent:SetHeight(math.max(math.abs(yOffset) + 8, 1))
end

----------------------------------------------------------------------
-- Toggle Visibility (called from Core.lua slash command)
----------------------------------------------------------------------

function UI:Toggle()
    local frame = self:CreateMainFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:_UpdateOnlineBtnVisuals()
        self:_UpdateTooltipBtnVisuals()
        self:_UpdateMinimapBtnVisuals()
        self:Refresh()
    end
end
