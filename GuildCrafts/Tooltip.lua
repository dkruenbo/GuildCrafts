----------------------------------------------------------------------
-- GuildCrafts — Tooltip.lua
-- Hooks GameTooltip to show guild crafters for hovered items
----------------------------------------------------------------------
local GuildCrafts = _G.GuildCrafts

local Tooltip = GuildCrafts:NewModule("Tooltip", "AceHook-3.0")
GuildCrafts.Tooltip = Tooltip

-- Local references
local pairs = pairs
local type = type
local tonumber = tonumber
local GetItemInfo = GetItemInfo

----------------------------------------------------------------------
-- Reverse Lookup Index
-- Maps itemID → { {key, profName}, ... } and itemName → same
-- Rebuilt when data changes; makes tooltip lookups O(1).
----------------------------------------------------------------------

local indexByID   = {}   -- [itemID]   = { {key=memberKey, profName=...}, ... }
local indexByName = {}   -- [itemName] = { {key=memberKey, profName=...}, ... }
local indexDirty  = true -- flag to rebuild on next tooltip

--- Mark the index as stale so it rebuilds on next hover.
function Tooltip:InvalidateIndex()
    indexDirty = true
end

--- Rebuild the reverse lookup index from the full database.
function Tooltip:RebuildIndex()
    indexByID   = {}
    indexByName = {}

    local db = GuildCrafts.Data and GuildCrafts.Data.GetGuildDB and GuildCrafts.Data:GetGuildDB()
    if not db then return end

    for memberKey, entry in pairs(db) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        local crafterEntry = { key = memberKey, profName = profName }

                        -- Index by recipeKey (itemID for items, negative spellID for enchants)
                        if type(recipeKey) == "number" and recipeKey > 0 then
                            if not indexByID[recipeKey] then
                                indexByID[recipeKey] = {}
                            end
                            indexByID[recipeKey][#indexByID[recipeKey] + 1] = crafterEntry
                        end

                        -- Index by recipe name in the *viewer's* locale so that
                        -- GetItemInfo(hoveredItem) matches even when the recipe
                        -- was scanned by a different-language client.
                        local localName = GuildCrafts.Data:GetLocalizedRecipeName(recipeKey, recipeData.name)
                        if localName then
                            if not indexByName[localName] then
                                indexByName[localName] = {}
                            end
                            indexByName[localName][#indexByName[localName] + 1] = crafterEntry
                        end
                        -- Also index the stored (possibly foreign-locale) name as
                        -- a fallback for uncached items.
                        if recipeData.name and recipeData.name ~= localName then
                            if not indexByName[recipeData.name] then
                                indexByName[recipeData.name] = {}
                            end
                            indexByName[recipeData.name][#indexByName[recipeData.name] + 1] = crafterEntry
                        end
                    end
                end
            end
        end
    end

    indexDirty = false
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Tooltip:OnEnable()
    -- Hook GameTooltip's OnTooltipSetItem to inject crafter info
    self:SecureHookScript(GameTooltip, "OnTooltipSetItem", "OnTooltipSetItem")

    -- Also hook ItemRefTooltip (shift-clicked links in chat)
    if ItemRefTooltip then
        self:SecureHookScript(ItemRefTooltip, "OnTooltipSetItem", "OnTooltipSetItem")
    end

    indexDirty = true
end

----------------------------------------------------------------------
-- Tooltip Hook
----------------------------------------------------------------------

function Tooltip:OnTooltipSetItem(tooltip)
    if not GuildCrafts.Data or not GuildCrafts.Data.db then return end
    if GuildCrafts.db and GuildCrafts.db.profile.showTooltipCrafters == false then return end

    -- Rebuild index if stale
    if indexDirty then
        self:RebuildIndex()
    end

    -- Get the item from the tooltip
    local _, itemLink = tooltip:GetItem()
    if not itemLink then return end

    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if not itemID then return end

    -- Also get item name for fallback matching (enchants store by name)
    local itemName = GetItemInfo(itemLink)

    -- Find crafters for this item using the index
    local crafters = self:FindCrafters(itemID, itemName)
    if not crafters or #crafters == 0 then return end

    -- Add a blank line separator
    tooltip:AddLine(" ")

    -- Header
    tooltip:AddLine("|cffffd100GuildCrafts:|r")

    -- List crafters (max 10 to avoid tooltip overflow)
    local shown = 0
    for _, crafter in ipairs(crafters) do
        if shown >= 10 then
            local remaining = #crafters - shown
            tooltip:AddLine(string.format("  |cff888888... and %d more|r", remaining))
            break
        end

        local name = crafter.key:match("^(.+)-") or crafter.key
        local isOnline = GuildCrafts.Data:IsMemberOnline(crafter.key)

        if isOnline then
            tooltip:AddDoubleLine(
                "  |cff00ff00" .. name .. "|r",
                "|cff888888" .. crafter.profName .. "|r"
            )
        else
            tooltip:AddDoubleLine(
                "  |cff666666" .. name .. "|r",
                "|cff666666" .. crafter.profName .. "|r"
            )
        end
        shown = shown + 1
    end

    tooltip:Show() -- recalculate tooltip size
end

----------------------------------------------------------------------
-- Crafter Lookup (using reverse index)
----------------------------------------------------------------------

--- Find all guild members who can craft an item, by itemID or name.
--- Returns a sorted list: online first, then alphabetical.
function Tooltip:FindCrafters(itemID, itemName)
    local seen = {}
    local crafters = {}

    -- Lookup by itemID
    local byID = indexByID[itemID]
    if byID then
        for _, entry in pairs(byID) do
            local dedupKey = entry.key .. "|" .. entry.profName
            if not seen[dedupKey] then
                seen[dedupKey] = true
                crafters[#crafters + 1] = entry
            end
        end
    end

    -- Lookup by item name (fallback for enchants with negative spellID keys)
    if itemName then
        local byName = indexByName[itemName]
        if byName then
            for _, entry in pairs(byName) do
                local dedupKey = entry.key .. "|" .. entry.profName
                if not seen[dedupKey] then
                    seen[dedupKey] = true
                    crafters[#crafters + 1] = entry
                end
            end
        end
    end

    if #crafters == 0 then return nil end

    -- Sort: online first, then alphabetical
    table.sort(crafters, function(a, b)
        local aOnline = GuildCrafts.Data:IsMemberOnline(a.key)
        local bOnline = GuildCrafts.Data:IsMemberOnline(b.key)
        if aOnline ~= bOnline then
            return aOnline
        end
        return a.key < b.key
    end)

    return crafters
end
