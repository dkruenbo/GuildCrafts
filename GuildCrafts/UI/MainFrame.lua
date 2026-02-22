----------------------------------------------------------------------
-- GuildCrafts — UI/MainFrame.lua
-- Main window: title bar, two-panel split, sync indicator,
-- resize, drag, ESC-to-close
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"
local GuildCrafts = _G.GuildCrafts

-- UI namespace
GuildCrafts.UI = GuildCrafts.UI or {}
local UI = GuildCrafts.UI

-- Frame dimensions
local DEFAULT_WIDTH  = 700
local DEFAULT_HEIGHT = 500
local MIN_WIDTH      = 500
local MIN_HEIGHT     = 350
local LEFT_PANEL_WIDTH = 200

-- Frame pool for left-panel row recycling
UI._leftRowPool = {}

-- Colors
local COLOR_BG       = { 0.05, 0.05, 0.05, 0.92 }
local COLOR_TITLE_BG = { 0.12, 0.12, 0.12, 1 }
local COLOR_BORDER   = { 0.3, 0.3, 0.3, 0.8 }
local COLOR_DIVIDER  = { 0.25, 0.25, 0.25, 1 }
local COLOR_GREEN    = { 0.2, 0.9, 0.2, 1 }
local COLOR_YELLOW   = { 1.0, 0.8, 0.0, 1 }
local COLOR_RED      = { 0.9, 0.2, 0.2, 1 }

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
    self:CreateCraftQueueBar(f)
    self:CreateResizeGrip(f)

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
        local users = 0
        if GuildCrafts.Comms and GuildCrafts.Comms.addonUsers then
            for _ in pairs(GuildCrafts.Comms.addonUsers) do users = users + 1 end
        end
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

    grip:SetScript("OnMouseDown", function()
        parent:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        parent:StopMovingOrSizing()
        UI:OnResize()
    end)
end

function UI:OnResize()
    -- Panels auto-adjust via anchoring
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
    search:SetPoint("RIGHT", container, "RIGHT", -90, 0)
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
    breadcrumb:SetScript("OnLeave", function(self)
        breadcrumbText:SetTextColor(0.4, 0.7, 1.0)
    end)

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
    self._navState = "professions" -- "professions", "members", "allMembers"
    self._selectedProfession = nil
    self._selectedMember = nil

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

    -- Welcome text (default state) — child of panel so it layers independently
    local welcome = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    welcome:SetPoint("CENTER", panel, "CENTER", 0, 0)
    welcome:SetText("Select a profession to browse,\nor use the search bar to find a recipe.")
    welcome:SetTextColor(0.5, 0.5, 0.5)
    welcome:SetJustifyH("CENTER")

    self.detailPanel = panel
    self.detailScrollFrame = scrollFrame
    self.detailContent = content
    self.detailWelcome = welcome
    self.detailRows = {}
end

----------------------------------------------------------------------
-- Craft Queue Bar
----------------------------------------------------------------------

function UI:CreateCraftQueueBar(parent)
    local bar = CreateFrame("Button", nil, parent, "BackdropTemplate")
    bar:SetHeight(24)
    bar:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -1, 1)
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    bar:SetBackdropColor(0.12, 0.12, 0.12, 1)

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", bar, "LEFT", 10, 0)
    text:SetText("Craft Queue (empty)")
    text:SetTextColor(0.7, 0.7, 0.7)

    local arrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    arrow:SetText("^")
    arrow:SetTextColor(0.5, 0.5, 0.5)

    self.craftQueueBar = bar
    self.craftQueueBarText = text
    self.craftQueueExpanded = false

    bar:SetScript("OnClick", function()
        UI:ToggleCraftQueue()
    end)
end

----------------------------------------------------------------------
-- Profession Icon Textures (TBC)
----------------------------------------------------------------------

local PROFESSION_ICONS = {
    ["Alchemy"]        = "Interface\\Icons\\Trade_Alchemy",
    ["Blacksmithing"]  = "Interface\\Icons\\Trade_BlackSmithing",
    ["Enchanting"]     = "Interface\\Icons\\Trade_Engraving",
    ["Engineering"]    = "Interface\\Icons\\Trade_Engineering",
    ["Jewelcrafting"]  = "Interface\\Icons\\INV_Misc_Gem_01",
    ["Leatherworking"] = "Interface\\Icons\\INV_Misc_ArmorKit_17",
    ["Tailoring"]      = "Interface\\Icons\\Trade_Tailoring",
}

----------------------------------------------------------------------
-- Populate Left Panel: Profession List
----------------------------------------------------------------------

function UI:PopulateProfessionList()
    self._navState = "professions"
    self._selectedProfession = nil
    self._selectedMember = nil
    self.leftBreadcrumb:Hide()

    -- Clear existing rows
    self:ClearLeftRows()

    local professions = GuildCrafts.Data:GetTrackedProfessions()
    local yOffset = 0

    for _, profName in ipairs(professions) do
        local count = GuildCrafts.Data:GetProfessionMemberCount(profName)
        local row = self:CreateLeftRow(self.leftContent, yOffset, profName, "(" .. count .. ")", PROFESSION_ICONS[profName])
        row:SetScript("OnClick", function()
            UI:NavigateToMembers(profName)
        end)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
    self:UpdateDetailWelcome()
end

----------------------------------------------------------------------
-- Populate Left Panel: Member List for a Profession
----------------------------------------------------------------------

function UI:NavigateToMembers(profName)
    self._navState = "members"
    self._selectedProfession = profName
    self._selectedMember = nil

    -- Show breadcrumb
    self.leftBreadcrumb:Show()
    self.leftBreadcrumbText:SetText("< Back")

    self:ClearLeftRows()

    local membersByProf = GuildCrafts.Data:GetMembersByProfession()
    local members = membersByProf[profName] or {}

    -- Sort: online first, then alphabetical
    self:SortMemberList(members)

    local yOffset = 0
    for _, memberInfo in ipairs(members) do
        local isOnline = GuildCrafts.Data:IsMemberOnline(memberInfo.key)
        local dot = isOnline and "|cff00ff00O|r " or "|cff666666O|r "
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
        -- Staleness indicator
        if memberInfo.entry then
            local stale = GuildCrafts.Data:GetStalenessTag(memberInfo.entry.lastUpdate)
            if stale then
                staleTag = "  |cffff6666[" .. stale .. "]|r"
            end
        end
        local label = dot .. memberInfo.key:match("^(.+)-") .. skillTag .. "  |cff888888" .. memberInfo.recipeCount .. " recipes|r" .. specTag .. staleTag
        local row = self:CreateLeftRow(self.leftContent, yOffset, label)
        row.memberKey = memberInfo.key
        row:SetScript("OnClick", function()
            UI:ShowMemberRecipes(memberInfo.key, profName)
        end)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end

    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
    self:UpdateDetailWelcome()
end

----------------------------------------------------------------------
-- Navigate Back
----------------------------------------------------------------------

function UI:NavigateBack()
    if self._navState == "members" then
        self:PopulateProfessionList()
    elseif self._navState == "allMembers" then
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

    local db = GuildCrafts.Data.db.global
    local entry = db[memberKey]
    if not entry or not entry.professions or not entry.professions[profName] then
        self:ShowDetailEmpty(memberKey, profName)
        return
    end

    local recipes = entry.professions[profName].recipes
    if not recipes then
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
    if spec then
        headerText = headerText .. "  |cffaaddff(" .. spec .. ")|r"
    end
    -- Staleness warning in header
    local stale = GuildCrafts.Data:GetStalenessTag(entry.lastUpdate)
    if stale then
        headerText = headerText .. "  |cffff6666[" .. stale .. "]|r"
    end
    header:SetText(headerText)
    header:SetTextColor(1, 0.82, 0)
    self.detailRows[#self.detailRows + 1] = header

    local yOffset = -32

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
        sorted[#sorted + 1] = { key = key, name = data.name or "Unknown", source = data.source or "", reagents = data.reagents, category = data.category or "" }
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

    local lastCategory = nil
    for _, recipe in ipairs(sorted) do
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
        -- Recipe name
        local nameText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 12, yOffset)
        nameText:SetText(recipe.name)
        nameText:SetTextColor(1, 1, 1)
        self.detailRows[#self.detailRows + 1] = nameText

        -- Source (subdued)
        if recipe.source and recipe.source ~= "" then
            local sourceText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            sourceText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset - 14)
            sourceText:SetText(recipe.source)
            sourceText:SetTextColor(0.5, 0.5, 0.5)
            self.detailRows[#self.detailRows + 1] = sourceText
            yOffset = yOffset - 14
        end

        -- Reagents
        if recipe.reagents and #recipe.reagents > 0 then
            local parts = {}
            for _, r in ipairs(recipe.reagents) do
                parts[#parts + 1] = r.count .. "x " .. r.name
            end
            local reagentStr = table.concat(parts, ", ")
            local reagentText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            reagentText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset - 14)
            reagentText:SetText("Reagents: " .. reagentStr)
            reagentText:SetTextColor(0.6, 0.8, 1.0)
            reagentText:SetWordWrap(true)
            reagentText:SetWidth(360)
            self.detailRows[#self.detailRows + 1] = reagentText
            -- Measure actual height for wrapped text
            local textHeight = reagentText:GetStringHeight()
            if not textHeight or textHeight < 12 then textHeight = 12 end
            yOffset = yOffset - 14 - textHeight - 4
        else
            yOffset = yOffset - 6
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
    self.detailWelcome:Hide()
    self:ClearDetailRows()

    if #results == 0 then
        local noResult = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noResult:SetPoint("CENTER", self.detailPanel, "CENTER", 0, 0)
        noResult:SetText("No results found.")
        noResult:SetTextColor(0.5, 0.5, 0.5)
        self.detailRows[#self.detailRows + 1] = noResult
        return
    end

    local yOffset = -8
    for _, result in ipairs(results) do
        -- Recipe name
        local nameText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 8, yOffset)
        nameText:SetText("|cffffd100" .. result.recipeName .. "|r  |cff888888(" .. result.profName .. ")|r")
        self.detailRows[#self.detailRows + 1] = nameText
        yOffset = yOffset - 18

        -- Source
        if result.source and result.source ~= "" then
            local sourceText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            sourceText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 12, yOffset)
            sourceText:SetText(result.source)
            sourceText:SetTextColor(0.5, 0.5, 0.5)
            self.detailRows[#self.detailRows + 1] = sourceText
            yOffset = yOffset - 14
        end

        -- Crafters
        for _, crafter in ipairs(result.crafters) do
            local isOnline = GuildCrafts.Data:IsMemberOnline(crafter.key)
            local dot = isOnline and "|cff00ff00O|r " or "|cff666666O|r "
            local crafterName = crafter.key:match("^(.+)-") or crafter.key

            -- Crafter row with optional Request Craft button
            local crafterRow = CreateFrame("Frame", nil, self.detailContent)
            crafterRow:SetSize(380, 18)
            crafterRow:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset)

            local crafterLabel = crafterRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            crafterLabel:SetPoint("LEFT", crafterRow, "LEFT", 0, 0)
            crafterLabel:SetText(dot .. crafterName)

            if isOnline then
                local reqBtn = CreateFrame("Button", nil, crafterRow, "BackdropTemplate")
                reqBtn:SetSize(80, 16)
                reqBtn:SetPoint("LEFT", crafterLabel, "RIGHT", 8, 0)
                reqBtn:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = 1,
                })
                reqBtn:SetBackdropColor(0.15, 0.4, 0.15, 0.8)
                reqBtn:SetBackdropBorderColor(0.3, 0.6, 0.3, 0.5)
                local btnText = reqBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                btnText:SetPoint("CENTER")
                btnText:SetText("Request Craft")
                btnText:SetTextColor(0.8, 1, 0.8)

                local capturedCrafterKey = crafter.key
                local capturedItemName = result.recipeName
                reqBtn:SetScript("OnClick", function()
                    if GuildCrafts.Comms then
                        GuildCrafts.Comms:SendCraftRequest(capturedCrafterKey, capturedItemName)
                    end
                end)
                reqBtn:SetScript("OnEnter", function(self)
                    self:SetBackdropColor(0.2, 0.5, 0.2, 0.9)
                end)
                reqBtn:SetScript("OnLeave", function(self)
                    self:SetBackdropColor(0.15, 0.4, 0.15, 0.8)
                end)
                self.detailRows[#self.detailRows + 1] = reqBtn
            end

            self.detailRows[#self.detailRows + 1] = crafterRow
            yOffset = yOffset - 18
        end

        -- Reagents
        if result.reagents and #result.reagents > 0 then
            local parts = {}
            for _, r in ipairs(result.reagents) do
                parts[#parts + 1] = r.count .. "x " .. r.name
            end
            local reagentStr = table.concat(parts, ", ")
            local reagentText = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            reagentText:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 16, yOffset)
            reagentText:SetText("Reagents: " .. reagentStr)
            reagentText:SetTextColor(0.6, 0.8, 1.0)
            reagentText:SetWordWrap(true)
            reagentText:SetWidth(360)
            self.detailRows[#self.detailRows + 1] = reagentText
            local textHeight = reagentText:GetStringHeight()
            if not textHeight or textHeight < 12 then textHeight = 12 end
            yOffset = yOffset - textHeight - 4
        end

        yOffset = yOffset - 8  -- spacing between recipes
    end

    self.detailContent:SetHeight(math.max(math.abs(yOffset) + 8, 1))
end

----------------------------------------------------------------------
-- Show Craft Request Popup
----------------------------------------------------------------------

function UI:ShowCraftRequestPopup(request)
    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetSize(280, 120)
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", function(self) self:StartMoving() end)
    popup:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Stack popups vertically
    local existingPopups = self._activePopups or {}
    local yOff = -60 * #existingPopups
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 100 + yOff)

    popup:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    popup:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    popup:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    -- Title
    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", popup, "TOP", 0, -10)
    title:SetText("|cffffd100Craft Request|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -2)

    -- Body text
    local body = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    body:SetPoint("CENTER", popup, "CENTER", 0, 10)
    body:SetText((request.requester:match("^(.+)-") or request.requester) ..
        " wants you to craft:\n|cffffd100" .. request.item .. "|r")
    body:SetJustifyH("CENTER")

    -- Accept button
    local accept = CreateFrame("Button", nil, popup, "BackdropTemplate")
    accept:SetSize(80, 24)
    accept:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -8, 12)
    accept:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    accept:SetBackdropColor(0.15, 0.4, 0.15, 0.9)
    accept:SetBackdropBorderColor(0.3, 0.6, 0.3, 0.5)
    local acceptText = accept:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    acceptText:SetPoint("CENTER")
    acceptText:SetText("Accept")
    acceptText:SetTextColor(0.8, 1, 0.8)

    -- Decline button
    local decline = CreateFrame("Button", nil, popup, "BackdropTemplate")
    decline:SetSize(80, 24)
    decline:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 8, 12)
    decline:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    decline:SetBackdropColor(0.4, 0.15, 0.15, 0.9)
    decline:SetBackdropBorderColor(0.6, 0.3, 0.3, 0.5)
    local declineText = decline:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    declineText:SetPoint("CENTER")
    declineText:SetText("Decline")
    declineText:SetTextColor(1, 0.8, 0.8)

    -- Handlers — hide popup FIRST to ensure it disappears even if
    -- downstream logic (queue refresh, comms) throws an error.
    accept:SetScript("OnClick", function()
        self:RemovePopup(popup)
        if GuildCrafts.CraftRequest then
            GuildCrafts.CraftRequest:AcceptRequest(request)
        end
    end)

    decline:SetScript("OnClick", function()
        self:RemovePopup(popup)
        if GuildCrafts.CraftRequest then
            GuildCrafts.CraftRequest:DeclineRequest(request)
        end
    end)

    closeBtn:SetScript("OnClick", function()
        self:RemovePopup(popup)
        if GuildCrafts.CraftRequest then
            GuildCrafts.CraftRequest:DeclineRequest(request)
        end
    end)

    -- Track popup
    self._activePopups = self._activePopups or {}
    self._activePopups[#self._activePopups + 1] = popup
end

function UI:RemovePopup(popup)
    popup:Hide()
    if self._activePopups then
        for i = #self._activePopups, 1, -1 do
            if self._activePopups[i] == popup then
                table.remove(self._activePopups, i)
            end
        end
    end
end

----------------------------------------------------------------------
-- Craft Queue Panel
----------------------------------------------------------------------

function UI:ToggleCraftQueue()
    self.craftQueueExpanded = not self.craftQueueExpanded
    if self.craftQueueExpanded then
        self:ShowCraftQueuePanel()
    else
        self:HideCraftQueuePanel()
    end
end

function UI:ShowCraftQueuePanel()
    if not self._craftQueuePanel then
        local panel = CreateFrame("Frame", nil, self.mainFrame, "BackdropTemplate")
        panel:SetHeight(120)
        panel:SetPoint("BOTTOMLEFT", self.craftQueueBar, "TOPLEFT", 0, 0)
        panel:SetPoint("BOTTOMRIGHT", self.craftQueueBar, "TOPRIGHT", 0, 0)
        panel:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        panel:SetBackdropColor(0.08, 0.08, 0.08, 1)
        panel:SetBackdropBorderColor(unpack(COLOR_DIVIDER))

        self._craftQueuePanel = panel
        self._craftQueueRows = {}
    end

    self._craftQueuePanel:Show()
    self:RefreshCraftQueue()
end

function UI:HideCraftQueuePanel()
    if self._craftQueuePanel then
        self._craftQueuePanel:Hide()
    end
end

function UI:RefreshCraftQueue()
    -- Update bar text
    local count = GuildCrafts.CraftRequest and GuildCrafts.CraftRequest:GetQueueCount() or 0
    if count > 0 then
        self.craftQueueBarText:SetText("Craft Queue (" .. count .. " pending)")
        self.craftQueueBarText:SetTextColor(1, 0.82, 0)
    else
        self.craftQueueBarText:SetText("Craft Queue (empty)")
        self.craftQueueBarText:SetTextColor(0.5, 0.5, 0.5)
    end

    -- Refresh panel content if visible
    if not self._craftQueuePanel or not self._craftQueuePanel:IsShown() then return end

    -- Clear old rows
    if self._craftQueueRows then
        for _, row in ipairs(self._craftQueueRows) do
            row:Hide()
        end
    end
    self._craftQueueRows = {}

    local queue = GuildCrafts.CraftRequest and GuildCrafts.CraftRequest:GetQueue() or {}
    local yOffset = -4
    for _, req in ipairs(queue) do
        local row = CreateFrame("Frame", nil, self._craftQueuePanel)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", self._craftQueuePanel, "TOPLEFT", 8, yOffset)
        row:SetPoint("TOPRIGHT", self._craftQueuePanel, "TOPRIGHT", -8, yOffset)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", row, "LEFT", 0, 0)
        label:SetText("|cffffd100" .. req.item .. "|r — for " ..
            (req.requester:match("^(.+)-") or req.requester))

        -- Complete button
        local completeBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        completeBtn:SetSize(40, 18)
        completeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        completeBtn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        completeBtn:SetBackdropColor(0.15, 0.4, 0.15, 0.8)
        completeBtn:SetBackdropBorderColor(0.3, 0.6, 0.3, 0.5)
        local cText = completeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cText:SetPoint("CENTER")
        cText:SetText("Done")
        completeBtn:SetScript("OnClick", function()
            GuildCrafts.CraftRequest:CompleteRequest(req)
        end)

        -- Dismiss button
        local dismissBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        dismissBtn:SetSize(24, 18)
        dismissBtn:SetPoint("RIGHT", completeBtn, "LEFT", -4, 0)
        dismissBtn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        dismissBtn:SetBackdropColor(0.4, 0.15, 0.15, 0.8)
        dismissBtn:SetBackdropBorderColor(0.6, 0.3, 0.3, 0.5)
        local dText = dismissBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dText:SetPoint("CENTER")
        dText:SetText("X")
        dismissBtn:SetScript("OnClick", function()
            GuildCrafts.CraftRequest:DismissRequest(req)
        end)

        self._craftQueueRows[#self._craftQueueRows + 1] = row
        yOffset = yOffset - 24
    end

    local panelHeight = math.max(math.abs(yOffset) + 8, 40)
    self._craftQueuePanel:SetHeight(panelHeight)
end

----------------------------------------------------------------------
-- Search Handler
----------------------------------------------------------------------

function UI:OnSearch(text)
    if not text or text == "" then
        -- Restore default view
        self._searchActive = false
        self:PopulateProfessionList()
        self:UpdateDetailWelcome()
        return
    end

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

    local db = GuildCrafts.Data.db.global
    local members = {}
    for memberKey, entry in pairs(db) do
        if type(entry) == "table" and memberKey:lower():find(query, 1, true) then
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
        local isOnline = GuildCrafts.Data:IsMemberOnline(memberInfo.key)
        local dot = isOnline and "|cff00ff00O|r " or "|cff666666O|r "
        local label = dot .. memberInfo.key:match("^(.+)-") .. "  |cff888888" .. memberInfo.recipeCount .. " recipes|r"
        local row = self:CreateLeftRow(self.leftContent, yOffset, label)
        self.leftRows[#self.leftRows + 1] = row
        yOffset = yOffset + 24
    end
    self.leftContent:SetHeight(math.max(yOffset + 8, 1))
end

----------------------------------------------------------------------
-- Detail Panel Helpers
----------------------------------------------------------------------

function UI:UpdateDetailWelcome()
    -- During a Refresh cycle, skip — Refresh will call us at the end
    -- with the correct state to avoid flashing the welcome text.
    if self._refreshing then return end

    if self._selectedMember or self._searchActive then
        self.detailWelcome:Hide()
    else
        self.detailWelcome:Show()
    end
end

function UI:ShowDetailEmpty(memberKey, profName)
    self:ClearDetailRows()
    self.detailWelcome:Hide()

    local msg = self.detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    msg:SetPoint("CENTER", self.detailPanel, "CENTER", 0, 0)
    msg:SetText("No recipes synced yet.\nThis member's data will appear after they open\ntheir profession window with the addon installed.")
    msg:SetTextColor(0.5, 0.5, 0.5)
    msg:SetJustifyH("CENTER")
    self.detailRows[#self.detailRows + 1] = msg
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
        -- Update text
        row._label:ClearAllPoints()
        row._label:SetText(text)
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
            row._label:SetPoint("LEFT", row, "LEFT", 26, 0)
        else
            if row._icon then row._icon:Hide() end
            row._label:SetPoint("LEFT", row, "LEFT", 6, 0)
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

    -- Hover highlight
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(0.3, 0.3, 0.5, 0.2)

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

    -- Text
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", row, "LEFT", labelAnchorX, 0)
    label:SetTextColor(0.9, 0.9, 0.9)
    label:SetText(text)
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
        row:SetScript("OnClick", nil)
        row.memberKey = nil
        self._leftRowPool[#self._leftRowPool + 1] = row
    end
    self.leftRows = {}
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

    -- Suppress intermediate UpdateDetailWelcome calls during refresh
    -- to prevent the welcome text from flashing over content.
    self._refreshing = true

    if self._navState == "professions" then
        self:PopulateProfessionList()
    elseif self._navState == "members" and self._selectedProfession then
        self:NavigateToMembers(self._selectedProfession)
    end

    self._refreshing = false

    -- Restore state cleared by the left-panel rebuild
    self._selectedMember = savedMember
    self._searchActive = savedSearch

    -- Refresh detail if a member was selected
    if self._selectedMember and self._selectedProfession then
        self:ShowMemberRecipes(self._selectedMember, self._selectedProfession)
    end

    -- Make sure welcome state is correct after all updates
    self:UpdateDetailWelcome()

    self:RefreshCraftQueue()
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
        self:Refresh()
    end
end
