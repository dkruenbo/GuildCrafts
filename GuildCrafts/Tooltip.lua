----------------------------------------------------------------------
-- GuildCrafts — Tooltip.lua
-- Hooks GameTooltip to show guild crafters for hovered items
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"
local GuildCrafts = _G.GuildCrafts

local Tooltip = GuildCrafts:NewModule("Tooltip", "AceHook-3.0")
GuildCrafts.Tooltip = Tooltip

-- Local references
local pairs = pairs
local type = type
local tonumber = tonumber
local GetItemInfo = GetItemInfo

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
end

----------------------------------------------------------------------
-- Tooltip Hook
----------------------------------------------------------------------

function Tooltip:OnTooltipSetItem(tooltip)
    if not GuildCrafts.Data or not GuildCrafts.Data.db then return end

    -- Get the item from the tooltip
    local _, itemLink = tooltip:GetItem()
    if not itemLink then return end

    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if not itemID then return end

    -- Also get item name for fallback matching (enchants store by name)
    local itemName = GetItemInfo(itemLink)

    -- Find crafters for this item
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
        local isOnline = self:IsCrafterOnline(crafter.key)

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
-- Crafter Lookup
----------------------------------------------------------------------

--- Find all guild members who can craft an item, by itemID or name.
--- Returns a sorted list: online first, then alphabetical.
function Tooltip:FindCrafters(itemID, itemName)
    local db = GuildCrafts.Data.db.global
    local crafters = {}
    local seen = {} -- avoid duplicate entries for same player+profession

    for memberKey, entry in pairs(db) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        local match = false

                        -- Match by itemID (positive keys)
                        if recipeKey == itemID then
                            match = true
                        end

                        -- Match by item name (for enchants with negative spellID keys)
                        if not match and itemName and recipeData.name then
                            if recipeData.name == itemName then
                                match = true
                            end
                        end

                        if match then
                            local dedupKey = memberKey .. "|" .. profName
                            if not seen[dedupKey] then
                                seen[dedupKey] = true
                                crafters[#crafters + 1] = {
                                    key      = memberKey,
                                    profName = profName,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort: online first, then alphabetical
    table.sort(crafters, function(a, b)
        local aOnline = self:IsCrafterOnline(a.key)
        local bOnline = self:IsCrafterOnline(b.key)
        if aOnline ~= bOnline then
            return aOnline
        end
        return a.key < b.key
    end)

    return crafters
end

----------------------------------------------------------------------
-- Online Status
----------------------------------------------------------------------

function Tooltip:IsCrafterOnline(memberKey)
    if not IsInGuild() then return false end
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            if not name:find("-") then
                name = name .. "-" .. GetRealmName()
            end
            if name == memberKey then
                return isOnline
            end
        end
    end
    return false
end
