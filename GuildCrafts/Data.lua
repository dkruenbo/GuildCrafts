----------------------------------------------------------------------
-- GuildCrafts — Data.lua
-- SavedVariables management, recipe scanning, data merging,
-- guild roster pruning, and simulation mode
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"
local GuildCrafts = _G.GuildCrafts

-- Create the Data module
local Data = GuildCrafts:NewModule("Data")
GuildCrafts.Data = Data

-- Local references for performance
local GetNumTradeSkills = GetNumTradeSkills
local GetTradeSkillInfo = GetTradeSkillInfo
local GetTradeSkillItemLink = GetTradeSkillItemLink
local GetTradeSkillRecipeLink = GetTradeSkillRecipeLink
local ExpandTradeSkillSubClass = ExpandTradeSkillSubClass
local GetNumSkillLines = GetNumSkillLines
local GetSkillLineInfo = GetSkillLineInfo
local GetNumGuildMembers = GetNumGuildMembers
local GetGuildRosterInfo = GetGuildRosterInfo
-- Craft API (Enchanting in Classic TBC)
local GetNumCrafts = GetNumCrafts
local GetCraftInfo = GetCraftInfo
local GetCraftItemLink = GetCraftItemLink
local GetCraftRecipeLink = GetCraftRecipeLink
-- Reagent APIs
local GetTradeSkillNumReagents = GetTradeSkillNumReagents
local GetTradeSkillReagentInfo = GetTradeSkillReagentInfo
local GetTradeSkillReagentItemLink = GetTradeSkillReagentItemLink
local GetCraftNumReagents = GetCraftNumReagents
local GetCraftReagentInfo = GetCraftReagentInfo
local GetCraftReagentItemLink = GetCraftReagentItemLink
-- Cooldown APIs
local GetTradeSkillCooldown = GetTradeSkillCooldown
local GetCraftCooldown = GetCraftCooldown
local time = time
local pairs = pairs
local tonumber = tonumber

-- Data staleness threshold (seconds) — 30 days
local STALE_THRESHOLD = 30 * 24 * 3600

-- TBC crafting professions we track
local TRACKED_PROFESSIONS = {
    ["Alchemy"] = true,
    ["Blacksmithing"] = true,
    ["Enchanting"] = true,
    ["Engineering"] = true,
    ["Jewelcrafting"] = true,
    ["Leatherworking"] = true,
    ["Tailoring"] = true,
}

-- TBC profession specialisations keyed by spellID
-- Each entry maps to { profession, specName }
local SPECIALISATION_SPELLS = {
    -- Alchemy
    [28675] = { prof = "Alchemy",         spec = "Potion Master" },
    [28677] = { prof = "Alchemy",         spec = "Elixir Master" },
    [28672] = { prof = "Alchemy",         spec = "Transmutation Master" },
    -- Blacksmithing
    [9788]  = { prof = "Blacksmithing",   spec = "Armorsmith" },
    [9787]  = { prof = "Blacksmithing",   spec = "Weaponsmith" },
    [17039] = { prof = "Blacksmithing",   spec = "Master Swordsmith" },
    [17040] = { prof = "Blacksmithing",   spec = "Master Hammersmith" },
    [17041] = { prof = "Blacksmithing",   spec = "Master Axesmith" },
    -- Engineering
    [20219] = { prof = "Engineering",     spec = "Gnomish Engineer" },
    [20222] = { prof = "Engineering",     spec = "Goblin Engineer" },
    -- Leatherworking
    [10656] = { prof = "Leatherworking",  spec = "Dragonscale Leatherworking" },
    [10658] = { prof = "Leatherworking",  spec = "Elemental Leatherworking" },
    [10660] = { prof = "Leatherworking",  spec = "Tribal Leatherworking" },
    -- Tailoring
    [26798] = { prof = "Tailoring",       spec = "Mooncloth Tailoring" },
    [26801] = { prof = "Tailoring",       spec = "Shadoweave Tailoring" },
    [26797] = { prof = "Tailoring",       spec = "Spellfire Tailoring" },
}

-- AceDB defaults
local DB_DEFAULTS = {
    global = {
        -- [memberKey] = {
        --     professions = {
        --         [profName] = {
        --             recipes = {
        --                 [recipeKey] = { name = "...", source = "..." },
        --             },
        --         },
        --     },
        --     lastUpdate = timestamp,
        --     _simulated = nil,  -- only set on simulated entries
        -- }
    },
}

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Data:OnInitialize()
    -- Set up AceDB
    GuildCrafts.db = LibStub("AceDB-3.0"):New("GuildCraftsDB", DB_DEFAULTS, true)
    self.db = GuildCrafts.db
end

function Data:OnEnable()
end

----------------------------------------------------------------------
-- Online Status Cache
-- Rebuilt once per GUILD_ROSTER_UPDATE; shared by UI and Tooltip.
----------------------------------------------------------------------

Data._onlineCache = {}

function Data:RebuildOnlineCache()
    self._onlineCache = {}
    if not IsInGuild() then return end

    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            if not name:find("-") then
                name = name .. "-" .. GetRealmName()
            end
            self._onlineCache[name] = isOnline or false
        end
    end
end

function Data:IsMemberOnline(memberKey)
    return self._onlineCache[memberKey] or false
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

--- Get the current player's "CharacterName-Realm" key.
function Data:GetPlayerKey()
    if not self._playerKey then
        local name = UnitName("player")
        local realm = GetRealmName()
        self._playerKey = name .. "-" .. realm
    end
    return self._playerKey
end

--- Get or create a member entry in the DB.
function Data:GetMemberEntry(memberKey, create)
    local entry = self.db.global[memberKey]
    if not entry and create then
        entry = {
            professions = {},
            lastUpdate = 0,
        }
        self.db.global[memberKey] = entry
    end
    return entry
end

----------------------------------------------------------------------
-- Profession Detection (login-time, no window needed)
----------------------------------------------------------------------

function Data:DetectProfessions()
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, true)
    local currentProfs = {}

    -- GetSkillLineInfo enumerates all skills including professions
    local skillLevels = {}  -- profName -> { rank, max }
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank, _, _, skillMaxRank, _, _, _, _, _, _ = GetSkillLineInfo(i)
        if not isHeader and TRACKED_PROFESSIONS[skillName] then
            currentProfs[skillName] = true
            skillLevels[skillName] = { rank = skillRank, max = skillMaxRank }
        end
    end

    -- Detect dropped professions — collect names before nil'ing
    local profChanged = false
    local droppedProfs = {}
    for profName, _ in pairs(entry.professions) do
        if TRACKED_PROFESSIONS[profName] and not currentProfs[profName] then
            droppedProfs[#droppedProfs + 1] = profName
        end
    end
    for _, profName in ipairs(droppedProfs) do
        GuildCrafts:Printf("Profession dropped: %s — purging recipes.", profName)
        entry.professions[profName] = nil
        profChanged = true
    end

    -- Ensure entries exist for current professions and update skill levels
    local dataChanged = false
    for profName, _ in pairs(currentProfs) do
        if not entry.professions[profName] then
            entry.professions[profName] = { recipes = {} }
        end
        local sl = skillLevels[profName]
        if sl then
            local profData = entry.professions[profName]
            if profData.skillLevel ~= sl.rank or profData.maxSkillLevel ~= sl.max then
                profData.skillLevel = sl.rank
                profData.maxSkillLevel = sl.max
                dataChanged = true
            end
        end
    end

    if profChanged or dataChanged then
        entry.lastUpdate = time()
    end

    -- Broadcast each dropped profession individually so receivers know which one
    if profChanged then
        if GuildCrafts.Comms and GuildCrafts.Comms.BroadcastProfessionRemoval then
            for _, profName in ipairs(droppedProfs) do
                GuildCrafts.Comms:BroadcastProfessionRemoval(playerKey, profName)
            end
        end
    end

    self._currentProfs = currentProfs
    GuildCrafts:Debug("Detected professions:", table.concat(self:GetProfessionList(), ", "))

    -- Detect specialisations immediately after professions
    self:DetectSpecialisations()
end

----------------------------------------------------------------------
-- Specialisation Detection (login-time, uses IsSpellKnown)
----------------------------------------------------------------------

function Data:DetectSpecialisations()
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, false)
    if not entry then return end

    -- Build a set of which professions have specs detected this pass
    local detectedSpecs = {}  -- prof -> spec

    local changed = false
    for spellID, info in pairs(SPECIALISATION_SPELLS) do
        local profData = entry.professions[info.prof]
        if profData and IsSpellKnown(spellID) then
            detectedSpecs[info.prof] = info.spec
            if profData.specialisation ~= info.spec then
                profData.specialisation = info.spec
                changed = true
                GuildCrafts:Debug("Specialisation detected:", info.prof, "→", info.spec)
            end
        end
    end

    -- Clear specialisations for professions that no longer have a known spec
    for profName, profData in pairs(entry.professions) do
        if profData.specialisation and not detectedSpecs[profName] then
            profData.specialisation = nil
            changed = true
            GuildCrafts:Debug("Specialisation cleared:", profName)
        end
    end

    if changed then
        entry.lastUpdate = time()
    end
end

function Data:GetProfessionList()
    local list = {}
    if self._currentProfs then
        for name, _ in pairs(self._currentProfs) do
            list[#list + 1] = name
        end
    end
    return list
end

----------------------------------------------------------------------
-- Reagent Scanning Helpers
----------------------------------------------------------------------

--- Scan reagents for a TradeSkill recipe at the given index.
--- @return table|nil  Array of {name, count, itemID} or nil if none
function Data:ScanTradeSkillReagents(index)
    local numReagents = GetTradeSkillNumReagents(index)
    if not numReagents or numReagents == 0 then
        return nil
    end
    local reagents = {}
    for j = 1, numReagents do
        local reagentName, _, reagentCount = GetTradeSkillReagentInfo(index, j)
        if reagentName then
            local itemID
            local link = GetTradeSkillReagentItemLink(index, j)
            if link then
                itemID = tonumber(link:match("item:(%d+)"))
            end
            reagents[#reagents + 1] = {
                name = reagentName,
                count = reagentCount or 1,
                itemID = itemID,
            }
        end
    end
    return #reagents > 0 and reagents or nil
end

--- Scan reagents for an Enchanting craft at the given index.
--- @return table|nil  Array of {name, count, itemID} or nil if none
function Data:ScanCraftReagents(index)
    local numReagents = GetCraftNumReagents(index)
    if not numReagents or numReagents == 0 then
        return nil
    end
    local reagents = {}
    for j = 1, numReagents do
        local reagentName, _, reagentCount = GetCraftReagentInfo(index, j)
        if reagentName then
            local itemID
            local link = GetCraftReagentItemLink(index, j)
            if link then
                itemID = tonumber(link:match("item:(%d+)"))
            end
            reagents[#reagents + 1] = {
                name = reagentName,
                count = reagentCount or 1,
                itemID = itemID,
            }
        end
    end
    return #reagents > 0 and reagents or nil
end

----------------------------------------------------------------------
-- Cooldown Scanning Helpers
----------------------------------------------------------------------

--- Scan cooldowns for all TradeSkill recipes in the current open window.
function Data:ScanTradeSkillCooldowns(profName, numSkills)
    if not GetTradeSkillCooldown then return end

    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, false)
    if not entry or not entry.professions[profName] then return end

    local profData = entry.professions[profName]
    local cooldowns = {}
    local now = time()

    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType ~= "header" and skillName then
            local cdRemaining = GetTradeSkillCooldown(i)
            if cdRemaining and cdRemaining > 0 then
                cooldowns[skillName] = {
                    endTime = now + cdRemaining,
                    duration = cdRemaining,
                }
            end
        end
    end

    -- Only update if cooldown state actually changed
    local hasCD = false
    for _ in pairs(cooldowns) do hasCD = true; break end

    local hadCD = profData.cooldowns ~= nil
    local changed = false

    if hasCD ~= hadCD then
        changed = true
    elseif hasCD and hadCD then
        -- Check if the set of cooldown names changed
        for name in pairs(cooldowns) do
            if not profData.cooldowns[name] then changed = true; break end
        end
        if not changed then
            for name in pairs(profData.cooldowns) do
                if not cooldowns[name] then changed = true; break end
            end
        end
    end

    if changed then
        profData.cooldowns = hasCD and cooldowns or nil
        entry.lastUpdate = now
        GuildCrafts:Debug("Cooldowns changed for", profName, ":", hasCD and "active" or "cleared")
    else
        -- Update endTimes locally without triggering a sync
        if hasCD then profData.cooldowns = cooldowns end
    end
end

--- Scan cooldowns for all Craft API recipes (Enchanting).
function Data:ScanCraftCooldowns(profName, numCrafts)
    if not GetCraftCooldown then return end

    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, false)
    if not entry or not entry.professions[profName] then return end

    local profData = entry.professions[profName]
    local cooldowns = {}
    local now = time()

    for i = 1, numCrafts do
        local craftName, _, craftType = GetCraftInfo(i)
        if craftType ~= "header" and craftName then
            local cdRemaining = GetCraftCooldown(i)
            if cdRemaining and cdRemaining > 0 then
                cooldowns[craftName] = {
                    endTime = now + cdRemaining,
                    duration = cdRemaining,
                }
            end
        end
    end

    local hasCD = false
    for _ in pairs(cooldowns) do hasCD = true; break end

    local hadCD = profData.cooldowns ~= nil
    local changed = false

    if hasCD ~= hadCD then
        changed = true
    elseif hasCD and hadCD then
        for name in pairs(cooldowns) do
            if not profData.cooldowns[name] then changed = true; break end
        end
        if not changed then
            for name in pairs(profData.cooldowns) do
                if not cooldowns[name] then changed = true; break end
            end
        end
    end

    if changed then
        profData.cooldowns = hasCD and cooldowns or nil
        entry.lastUpdate = now
        GuildCrafts:Debug("Cooldowns changed for", profName, ":", hasCD and "active" or "cleared")
    else
        if hasCD then profData.cooldowns = cooldowns end
    end
end

--- Format a duration in seconds to a human-readable string.
function Data:FormatCooldownRemaining(endTime)
    local remaining = endTime - time()
    if remaining <= 0 then
        return nil -- cooldown expired
    end

    local days = math.floor(remaining / 86400)
    local hours = math.floor((remaining % 86400) / 3600)
    local mins = math.floor((remaining % 3600) / 60)

    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, mins)
    else
        return string.format("%dm", mins)
    end
end

----------------------------------------------------------------------
-- Data Staleness Helpers
----------------------------------------------------------------------

--- Check if a member's data is stale (not updated in 30+ days).
--- Returns nil if fresh, or a human-readable age string if stale.
function Data:GetStalenessTag(lastUpdate)
    if not lastUpdate or lastUpdate == 0 then return nil end
    local age = time() - lastUpdate
    if age < STALE_THRESHOLD then return nil end

    local days = math.floor(age / 86400)
    if days < 60 then
        return days .. "d ago"
    else
        local months = math.floor(days / 30)
        return months .. "mo ago"
    end
end

----------------------------------------------------------------------
-- Recipe Scanning (requires profession window to be open)
----------------------------------------------------------------------

function Data:ScanTradeSkill()
    local numSkills = GetNumTradeSkills()
    if not numSkills or numSkills == 0 then
        return
    end

    -- Determine which profession is open by looking at the first header or skill
    local profName = self:GetOpenProfessionName()
    if not profName or not TRACKED_PROFESSIONS[profName] then
        GuildCrafts:Debug("Open profession not tracked:", profName or "nil")
        return
    end

    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, true)
    if not entry.professions[profName] then
        entry.professions[profName] = { recipes = {} }
    end

    -- Refresh skill level while the profession window is open
    if GetTradeSkillLine then
        local _, currentLevel, maxLevel = GetTradeSkillLine()
        if currentLevel and maxLevel then
            local profDataLocal = entry.professions[profName]
            if profDataLocal.skillLevel ~= currentLevel or profDataLocal.maxSkillLevel ~= maxLevel then
                profDataLocal.skillLevel = currentLevel
                profDataLocal.maxSkillLevel = maxLevel
                entry.lastUpdate = time()
            end
        end
    end

    -- Expand all collapsed headers (iterate backwards to avoid index shifting)
    for i = numSkills, 1, -1 do
        local _, skillType, _, isExpanded = GetTradeSkillInfo(i)
        if skillType == "header" and not isExpanded then
            ExpandTradeSkillSubClass(i)
        end
    end

    -- Re-read count after expanding
    numSkills = GetNumTradeSkills()

    local recipes = entry.professions[profName].recipes
    local newCount = 0
    local newRecipes = {}
    local currentCategory = nil

    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType == "header" then
            currentCategory = skillName
        elseif skillName then
            local recipeKey = self:GetRecipeKey(i)
            if recipeKey then
                if not recipes[recipeKey] then
                    local recipeData = {
                        name = skillName,
                        source = "",
                        reagents = self:ScanTradeSkillReagents(i),
                        category = currentCategory,
                    }
                    recipes[recipeKey] = recipeData
                    newRecipes[recipeKey] = recipeData
                    newCount = newCount + 1
                else
                    if not recipes[recipeKey].reagents then
                        -- Backfill reagent data for recipes scanned before reagent tracking
                        recipes[recipeKey].reagents = self:ScanTradeSkillReagents(i)
                    end
                    if not recipes[recipeKey].category and currentCategory then
                        -- Backfill category for recipes scanned before categorization
                        recipes[recipeKey].category = currentCategory
                    end
                end
            end
        end
    end

    if newCount > 0 then
        entry.lastUpdate = time()
        GuildCrafts:Printf("Scanned %s: %d new recipe(s) found.", profName, newCount)

        -- Only broadcast the newly discovered recipes, not the entire set
        if GuildCrafts.Comms and GuildCrafts.Comms.BroadcastNewRecipes then
            GuildCrafts.Comms:BroadcastNewRecipes(playerKey, profName, newRecipes)
        end

        -- Invalidate tooltip index so new recipes appear in tooltips
        if GuildCrafts.Tooltip then
            GuildCrafts.Tooltip:InvalidateIndex()
        end
    else
        GuildCrafts:Debug("Scanned " .. profName .. ": no new recipes.")
    end

    -- Scan cooldowns while the window is open
    self:ScanTradeSkillCooldowns(profName, numSkills)
end

--- Get the recipe key (itemID or spellID) for a given trade skill index.
function Data:GetRecipeKey(index)
    -- Try itemID first (most professions)
    local itemLink = GetTradeSkillItemLink(index)
    if itemLink then
        local itemID = tonumber(itemLink:match("item:(%d+)"))
        if itemID then
            return itemID
        end
    end

    -- Fallback to spellID (Enchanting and other recipes without items)
    local recipeLink = GetTradeSkillRecipeLink(index)
    if recipeLink then
        local spellID = tonumber(recipeLink:match("enchant:(%d+)") or recipeLink:match("spell:(%d+)"))
        if spellID then
            -- Use negative spellID to distinguish from itemIDs in the key space
            return -spellID
        end
    end

    return nil
end

--- Get the name of the currently open profession window.
function Data:GetOpenProfessionName()
    -- The first entry in the trade skill list is typically a header with the profession name,
    -- or we can use GetTradeSkillLine() if available (TBC)
    if GetTradeSkillLine then
        local lineName = GetTradeSkillLine()
        return lineName
    end

    -- Fallback: check first header
    for i = 1, GetNumTradeSkills() do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType == "header" then
            return skillName
        end
    end

    return nil
end

----------------------------------------------------------------------
-- Enchanting Scan (Classic TBC uses Craft API, not TradeSkill API)
----------------------------------------------------------------------

function Data:ScanCraft()
    if not GetNumCrafts then
        GuildCrafts:Debug("GetNumCrafts API not available — Enchanting scan skipped.")
        return
    end

    local numCrafts = GetNumCrafts()
    if not numCrafts or numCrafts == 0 then
        return
    end

    local profName = "Enchanting"
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, true)
    if not entry.professions[profName] then
        entry.professions[profName] = { recipes = {} }
    end

    -- Refresh Enchanting skill level while the window is open
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and skillName == profName then
            local profDataLocal = entry.professions[profName]
            if profDataLocal.skillLevel ~= skillRank or profDataLocal.maxSkillLevel ~= skillMaxRank then
                profDataLocal.skillLevel = skillRank
                profDataLocal.maxSkillLevel = skillMaxRank
                entry.lastUpdate = time()
            end
            break
        end
    end

    -- Expand collapsed headers
    if ExpandCraftSkillLine then
        for i = numCrafts, 1, -1 do
            local _, _, craftType, isExpanded = GetCraftInfo(i)
            if craftType == "header" and not isExpanded then
                ExpandCraftSkillLine(i)
            end
        end
        numCrafts = GetNumCrafts()
    end

    local recipes = entry.professions[profName].recipes
    local newCount = 0
    local newRecipes = {}
    local currentCategory = nil

    for i = 1, numCrafts do
        local craftName, _, craftType = GetCraftInfo(i)
        if craftType == "header" then
            currentCategory = craftName
        elseif craftName then
            local recipeKey = self:GetCraftRecipeKey(i)
            if recipeKey then
                if not recipes[recipeKey] then
                    local recipeData = {
                        name = craftName,
                        source = "",
                        reagents = self:ScanCraftReagents(i),
                        category = currentCategory,
                    }
                    recipes[recipeKey] = recipeData
                    newRecipes[recipeKey] = recipeData
                    newCount = newCount + 1
                else
                    if not recipes[recipeKey].reagents then
                        -- Backfill reagent data for recipes scanned before reagent tracking
                        recipes[recipeKey].reagents = self:ScanCraftReagents(i)
                    end
                    if not recipes[recipeKey].category and currentCategory then
                        -- Backfill category for recipes scanned before categorization
                        recipes[recipeKey].category = currentCategory
                    end
                end
            end
        end
    end

    if newCount > 0 then
        entry.lastUpdate = time()
        GuildCrafts:Printf("Scanned %s: %d new recipe(s) found.", profName, newCount)

        if GuildCrafts.Comms and GuildCrafts.Comms.BroadcastNewRecipes then
            GuildCrafts.Comms:BroadcastNewRecipes(playerKey, profName, newRecipes)
        end

        -- Invalidate tooltip index so new recipes appear in tooltips
        if GuildCrafts.Tooltip then
            GuildCrafts.Tooltip:InvalidateIndex()
        end
    else
        GuildCrafts:Debug("Scanned " .. profName .. ": no new recipes.")
    end

    -- Scan cooldowns while the window is open
    self:ScanCraftCooldowns(profName, numCrafts)
end

function Data:GetCraftRecipeKey(index)
    -- Try item link first
    if GetCraftItemLink then
        local itemLink = GetCraftItemLink(index)
        if itemLink then
            local itemID = tonumber(itemLink:match("item:(%d+)"))
            if itemID then
                return itemID
            end
        end
    end

    -- Fallback: spell link (most enchants)
    if GetCraftRecipeLink then
        local recipeLink = GetCraftRecipeLink(index)
        if recipeLink then
            local spellID = tonumber(recipeLink:match("enchant:(%d+)") or recipeLink:match("spell:(%d+)"))
            if spellID then
                return -spellID
            end
        end
    end

    -- Last resort: use craft name hash as key
    local craftName = GetCraftInfo(index)
    if craftName then
        -- Simple string hash to create a stable negative key
        local hash = 0
        for c = 1, #craftName do
            hash = (hash * 31 + craftName:byte(c)) % 1000000
        end
        return -(hash + 1000000)
    end

    return nil
end

----------------------------------------------------------------------
-- Sync Payload Stripping
-- Removes fields that are only meaningful locally (cooldowns, reagents)
-- from outgoing sync data to reduce payload size and avoid clock issues.
----------------------------------------------------------------------

function Data:StripSyncFields(entry)
    if type(entry) ~= "table" then return entry end

    local copy = {
        lastUpdate = entry.lastUpdate,
        _simulated = entry._simulated,
        professions = {},
    }

    for profName, profData in pairs(entry.professions or {}) do
        local profCopy = {
            recipes = {},
            skillLevel = profData.skillLevel,
            maxSkillLevel = profData.maxSkillLevel,
            specialisation = profData.specialisation,
            -- cooldowns intentionally omitted
        }
        for recipeKey, recipeData in pairs(profData.recipes or {}) do
            profCopy.recipes[recipeKey] = {
                name = recipeData.name,
                source = recipeData.source,
                category = recipeData.category,
                -- reagents intentionally omitted
            }
        end
        copy.professions[profName] = profCopy
    end

    return copy
end

--- Strip reagents from a recipes table (for delta payloads).
function Data:StripRecipeReagents(recipes)
    if type(recipes) ~= "table" then return recipes end

    local copy = {}
    for recipeKey, recipeData in pairs(recipes) do
        copy[recipeKey] = {
            name = recipeData.name,
            source = recipeData.source,
            category = recipeData.category,
        }
    end
    return copy
end

----------------------------------------------------------------------
-- Version Vector
----------------------------------------------------------------------

function Data:GetVersionVector()
    local vector = {}
    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.lastUpdate then
            vector[memberKey] = entry.lastUpdate
        end
    end
    return vector
end

----------------------------------------------------------------------
-- Data Merging
----------------------------------------------------------------------

--- Merge incoming member data (full replacement at member level).
-- If incoming lastUpdate > local lastUpdate, replace entire member entry.
-- Returns true if any data was merged.
function Data:MergeIncoming(incomingData)
    local changed = false
    local playerKey = self:GetPlayerKey()
    for memberKey, incomingEntry in pairs(incomingData) do
        if type(incomingEntry) == "table" and incomingEntry.lastUpdate then
            -- Never overwrite our own data — we're always authoritative
            -- for ourselves (local scans have reagents/cooldowns that
            -- sync payloads strip out)
            if memberKey == playerKey then
                GuildCrafts:Debug("Skipped merge for own data:", memberKey)
            else
                local localEntry = self.db.global[memberKey]
                if not localEntry or incomingEntry.lastUpdate > localEntry.lastUpdate then
                    self.db.global[memberKey] = incomingEntry
                    changed = true
                    GuildCrafts:Debug("Merged data for:", memberKey)
                end
            end
        end
    end
    if changed and GuildCrafts.Tooltip then
        GuildCrafts.Tooltip:InvalidateIndex()
    end
    return changed
end

--- Merge a single delta (one recipe added to a member's profession).
function Data:MergeDelta(memberKey, profName, recipeKey, recipeData, newLastUpdate)
    local entry = self:GetMemberEntry(memberKey, true)
    if not entry.professions[profName] then
        entry.professions[profName] = { recipes = {} }
    end
    entry.professions[profName].recipes[recipeKey] = recipeData
    if newLastUpdate and newLastUpdate > (entry.lastUpdate or 0) then
        entry.lastUpdate = newLastUpdate
    end
    if GuildCrafts.Tooltip then
        GuildCrafts.Tooltip:InvalidateIndex()
    end
    GuildCrafts:Debug("Delta merged:", memberKey, profName, recipeKey)
end

--- Handle a profession removal delta.
function Data:MergeProfessionRemoval(memberKey, profName, newLastUpdate)
    local entry = self.db.global[memberKey]
    if entry and entry.professions[profName] then
        entry.professions[profName] = nil
        if newLastUpdate and newLastUpdate > (entry.lastUpdate or 0) then
            entry.lastUpdate = newLastUpdate
        end
        if GuildCrafts.Tooltip then
            GuildCrafts.Tooltip:InvalidateIndex()
        end
        GuildCrafts:Debug("Profession removed:", memberKey, profName)
    end
end

----------------------------------------------------------------------
-- Guild Roster Pruning
----------------------------------------------------------------------

function Data:PruneRoster()
    if not IsInGuild() then return end

    -- Build set of current guild member keys
    local rosterKeys = {}
    local numMembers = GetNumGuildMembers()

    -- Safety: don't prune if the roster hasn't fully loaded yet.
    -- On login the first GUILD_ROSTER_UPDATE can fire before the server
    -- has sent the full member list, returning 0 or very few members.
    if numMembers < 2 then
        GuildCrafts:Debug("PruneRoster skipped — roster not ready yet (", numMembers, "members)")
        return
    end

    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ = GetGuildRosterInfo(i)
        if name then
            -- GetGuildRosterInfo may return "Name-Realm" or just "Name"
            if not name:find("-") then
                name = name .. "-" .. GetRealmName()
            end
            rosterKeys[name] = true
        end
    end

    -- Extra safety: if we resolved very few names from the roster,
    -- the data probably isn't fully loaded yet — skip pruning.
    local resolvedCount = 0
    for _ in pairs(rosterKeys) do resolvedCount = resolvedCount + 1 end
    if resolvedCount < 2 then
        GuildCrafts:Debug("PruneRoster skipped — too few names resolved (", resolvedCount, ")")
        return
    end

    -- Prune entries not in the roster
    local pruned = 0
    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and not rosterKeys[memberKey] then
            -- Don't prune simulated entries (they won't be in the roster)
            if not entry._simulated then
                self.db.global[memberKey] = nil
                pruned = pruned + 1
            end
        end
    end

    if pruned > 0 then
        GuildCrafts:Debug("Pruned", pruned, "ex-guild member(s) from database.")
    end
end

----------------------------------------------------------------------
-- Debug: Dump Summary
----------------------------------------------------------------------

function Data:DumpSummary()
    local playerKey = self:GetPlayerKey()
    GuildCrafts:Printf("Local player: %s", playerKey)

    local totalMembers = 0
    local totalRecipes = 0
    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.professions then
            totalMembers = totalMembers + 1
            local memberRecipes = 0
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for _ in pairs(profData.recipes) do
                        memberRecipes = memberRecipes + 1
                    end
                end
            end
            totalRecipes = totalRecipes + memberRecipes

            -- Show detail for the local player
            if memberKey == playerKey then
                GuildCrafts:Printf("  [YOU] %s (lastUpdate: %s)", memberKey, tostring(entry.lastUpdate))
                for profName, profData in pairs(entry.professions) do
                    local count = 0
                    if profData.recipes then
                        for _ in pairs(profData.recipes) do count = count + 1 end
                    end
                    GuildCrafts:Printf("    %s: %d recipes", profName, count)
                end
            end
        end
    end

    GuildCrafts:Printf("Total: %d members, %d recipes in database.", totalMembers, totalRecipes)
end

----------------------------------------------------------------------
-- Simulation System
----------------------------------------------------------------------

local SAMPLE_RECIPES = {
    "Flask of Supreme Power", "Flask of Fortification", "Flask of Mighty Restoration",
    "Elixir of Major Agility", "Elixir of Major Firepower", "Elixir of Draenic Wisdom",
    "Super Mana Potion", "Super Healing Potion", "Haste Potion", "Destruction Potion",
    "Lionheart Helm", "Felsteel Longblade", "Khorium Champion", "Dirge",
    "Drakefist Hammer", "Thunder", "Deep Thunder", "Stormherald",
    "Enchant Weapon - Mongoose", "Enchant Chest - Exceptional Stats",
    "Enchant Cloak - Subtlety", "Enchant Boots - Cat's Swiftness",
    "Gyro-Balanced Khorium Destroyer", "Tankatronic Goggles", "Deathblow X11 Goggles",
    "Delicate Living Ruby", "Bold Living Ruby", "Solid Star of Elune", "Lustrous Star of Elune",
    "Brilliant Dawnstone", "Smooth Dawnstone", "Rigid Dawnstone",
    "Primal Mooncloth Robe", "Spellfire Robe", "Frozen Shadoweave Robe",
    "Belt of Blasting", "Belt of Natural Power", "Battlecast Pants",
    "Nethercobra Leg Armor", "Nethercleft Leg Armor", "Heavy Knothide Armor Kit",
    "Windhawk Armor", "Thick Draenic Vest", "Fel Leather Boots",
    "Felsteel Helm", "Adamantite Breastplate", "Flamebane Helm",
    "Major Mana Potion", "Ironshield Potion", "Insane Strength Potion",
    "Greater Planar Essence", "Large Prismatic Shard", "Void Crystal",
}

local SAMPLE_CATEGORIES = {
    "Flasks", "Elixirs", "Potions", "Weapons", "Armor", "Enchantments",
    "Goggles", "Gems", "Robes", "Leg Armor", "Leather Armor", "Plate Armor",
    "Reagents",
}

local PROF_NAMES = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Jewelcrafting", "Leatherworking", "Tailoring" }

-- Sample reagent lists (arrays of {name, count, itemID})
local SAMPLE_REAGENTS = {
    { { name = "Fel Lotus", count = 1, itemID = 22794 }, { name = "Mana Thistle", count = 3, itemID = 22793 }, { name = "Imbued Vial", count = 1, itemID = 18256 } },
    { { name = "Felsteel Bar", count = 6, itemID = 23449 }, { name = "Hardened Adamantite Bar", count = 2, itemID = 23573 }, { name = "Primal Fire", count = 4, itemID = 21884 } },
    { { name = "Large Prismatic Shard", count = 4, itemID = 22449 }, { name = "Greater Planar Essence", count = 6, itemID = 22446 }, { name = "Void Crystal", count = 2, itemID = 22450 } },
    { { name = "Khorium Bar", count = 8, itemID = 23449 }, { name = "Felsteel Stabilizer", count = 2, itemID = 23787 }, { name = "Hardened Adamantite Tube", count = 1, itemID = 23784 } },
    { { name = "Living Ruby", count = 1, itemID = 24036 } },
    { { name = "Heavy Knothide Leather", count = 4, itemID = 23793 }, { name = "Primal Earth", count = 2, itemID = 22452 } },
    { { name = "Bolt of Imbued Netherweave", count = 8, itemID = 21844 }, { name = "Netherweb Spider Silk", count = 2, itemID = 21881 }, { name = "Primal Mooncloth", count = 4, itemID = 21845 } },
    { { name = "Primal Nether", count = 1, itemID = 23572 }, { name = "Hardened Adamantite Bar", count = 8, itemID = 23573 } },
    { { name = "Dawnstone", count = 1, itemID = 24048 } },
    { { name = "Star of Elune", count = 1, itemID = 24051 } },
}

-- Profession → possible specialisation names
local SAMPLE_SPECIALISATIONS = {
    ["Alchemy"]         = { "Potion Master", "Elixir Master", "Transmutation Master" },
    ["Blacksmithing"]   = { "Armorsmith", "Weaponsmith", "Master Swordsmith", "Master Hammersmith", "Master Axesmith" },
    ["Engineering"]     = { "Gnomish Engineer", "Goblin Engineer" },
    ["Leatherworking"]  = { "Dragonscale Leatherworking", "Elemental Leatherworking", "Tribal Leatherworking" },
    ["Tailoring"]       = { "Mooncloth Tailoring", "Shadoweave Tailoring", "Spellfire Tailoring" },
}

-- Profession → possible cooldown recipe names
local SAMPLE_COOLDOWNS = {
    ["Alchemy"]    = { "Transmute: Primal Might", "Transmute: Earthstorm Diamond", "Transmute: Skyfire Diamond" },
    ["Tailoring"]  = { "Primal Mooncloth", "Spellcloth", "Shadowcloth" },
}

function Data:HandleSimCommand(arg)
    if not GuildCrafts.debugMode then
        GuildCrafts:Print("Simulation requires debug mode. Run /gc debug first.")
        return
    end

    if arg == "clear" then
        self:SimClear()
    elseif arg == "sync" then
        self:SimSync()
    elseif arg == "delta" then
        self:SimDelta()
    elseif arg == "craft" then
        self:SimCraft()
    else
        local count = tonumber(arg)
        if count and count > 0 then
            self:SimGenerate(count)
        else
            GuildCrafts:Print("Usage: /gc sim <N> | /gc sim clear | /gc sim sync | /gc sim delta | /gc sim craft")
        end
    end
end

function Data:SimGenerate(count)
    local generated = 0
    local realm = GetRealmName() or "SimRealm"

    for i = 1, count do
        local memberKey = string.format("SimPlayer%03d-%s", i, realm)

        -- Pick 2 random professions
        local prof1 = PROF_NAMES[math.random(#PROF_NAMES)]
        local prof2 = prof1
        while prof2 == prof1 do
            prof2 = PROF_NAMES[math.random(#PROF_NAMES)]
        end

        -- Some members have stale data (30-90 days old) for testing
        local maxAge = (i % 5 == 0) and math.random(30 * 86400, 90 * 86400) or math.random(0, 604800)
        local entry = {
            professions = {},
            lastUpdate = time() - maxAge,
            _simulated = true,
        }

        for _, profName in ipairs({ prof1, prof2 }) do
            local recipes = {}
            local numRecipes = math.random(20, math.min(150, #SAMPLE_RECIPES))
            local used = {}
            for r = 1, numRecipes do
                local idx = math.random(#SAMPLE_RECIPES)
                -- Avoid duplicates within same profession
                while used[idx] do
                    idx = (idx % #SAMPLE_RECIPES) + 1
                end
                used[idx] = true
                local recipeKey = 10000 + (i * 1000) + r  -- synthetic itemID
                recipes[recipeKey] = {
                    name = SAMPLE_RECIPES[idx],
                    source = (math.random() > 0.5) and "Trainer" or "World Drop",
                    category = SAMPLE_CATEGORIES[math.random(#SAMPLE_CATEGORIES)],
                    reagents = SAMPLE_REAGENTS[math.random(#SAMPLE_REAGENTS)],
                }
            end

            local profEntry = { recipes = recipes, skillLevel = math.random(300, 375), maxSkillLevel = 375 }

            -- ~40% chance of having a specialisation (only for profs that have one)
            local specs = SAMPLE_SPECIALISATIONS[profName]
            if specs and math.random() < 0.4 then
                profEntry.specialisation = specs[math.random(#specs)]
            end

            -- ~20% chance of an active cooldown (only for profs that have them)
            local cds = SAMPLE_COOLDOWNS[profName]
            if cds and math.random() < 0.2 then
                local cdName = cds[math.random(#cds)]
                local remaining = math.random(3600, 72 * 3600)  -- 1h to 3d
                profEntry.cooldowns = {
                    [cdName] = { endTime = time() + remaining, duration = remaining },
                }
            end

            entry.professions[profName] = profEntry
        end

        self.db.global[memberKey] = entry
        generated = generated + 1
    end

    GuildCrafts:Printf("Simulated %d guild members injected.", generated)
end

function Data:SimClear()
    local cleared = 0
    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry._simulated then
            self.db.global[memberKey] = nil
            cleared = cleared + 1
        end
    end
    GuildCrafts:Printf("Cleared %d simulated member(s).", cleared)
end

function Data:SimSync()
    -- Generate a fake SYNC_RESPONSE containing 10 simulated members
    -- and feed it through the normal merge path
    local fakeData = {}
    local realm = GetRealmName() or "SimRealm"
    for i = 1, 10 do
        local memberKey = string.format("SyncSim%03d-%s", i, realm)
        local profName = PROF_NAMES[math.random(#PROF_NAMES)]
        local recipes = {}
        for r = 1, math.random(5, 20) do
            local recipeKey = 90000 + (i * 100) + r
            recipes[recipeKey] = {
                name = SAMPLE_RECIPES[math.random(#SAMPLE_RECIPES)],
                source = "Simulated Sync",
                category = SAMPLE_CATEGORIES[math.random(#SAMPLE_CATEGORIES)],
                reagents = SAMPLE_REAGENTS[math.random(#SAMPLE_REAGENTS)],
            }
        end
        local profEntry = { recipes = recipes, skillLevel = math.random(300, 375), maxSkillLevel = 375 }
        local specs = SAMPLE_SPECIALISATIONS[profName]
        if specs and math.random() < 0.4 then
            profEntry.specialisation = specs[math.random(#specs)]
        end
        local cds = SAMPLE_COOLDOWNS[profName]
        if cds and math.random() < 0.2 then
            local cdName = cds[math.random(#cds)]
            local remaining = math.random(3600, 72 * 3600)
            profEntry.cooldowns = {
                [cdName] = { endTime = time() + remaining, duration = remaining },
            }
        end
        fakeData[memberKey] = {
            professions = { [profName] = profEntry },
            lastUpdate = time(),
            _simulated = true,
        }
    end

    local merged = self:MergeIncoming(fakeData)
    GuildCrafts:Printf("Simulated sync: 10 members, merged=%s", tostring(merged))
end

function Data:SimDelta()
    -- Pick a random existing simulated member and add a recipe
    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry._simulated then
            for profName, profData in pairs(entry.professions) do
                local newKey = 99000 + math.random(1, 9999)
                local recipe = {
                    name = SAMPLE_RECIPES[math.random(#SAMPLE_RECIPES)] .. " (NEW)",
                    source = "Simulated Delta",
                    category = SAMPLE_CATEGORIES[math.random(#SAMPLE_CATEGORIES)],
                    reagents = SAMPLE_REAGENTS[math.random(#SAMPLE_REAGENTS)],
                }
                self:MergeDelta(memberKey, profName, newKey, recipe, time())
                GuildCrafts:Printf("Simulated delta: %s → %s → %s", memberKey, profName, recipe.name)
                return
            end
        end
    end
    GuildCrafts:Print("No simulated members found. Run /gc sim <N> first.")
end

function Data:SimCraft()
    -- Simulate an incoming CRAFT_REQUEST (Phase 6 will handle the actual popup)
    if GuildCrafts.CraftRequest and GuildCrafts.CraftRequest.OnIncomingRequest then
        GuildCrafts.CraftRequest:OnIncomingRequest("SimPlayer001", "Lionheart Helm")
    else
        GuildCrafts:Print("Simulated craft request: SimPlayer001 wants you to craft Lionheart Helm")
        GuildCrafts:Print("(Craft popup will be available after Phase 6)")
    end
end

----------------------------------------------------------------------
-- Member Data Accessors (for UI)
----------------------------------------------------------------------

--- Get all members grouped by profession.
--- Returns { [profName] = { { key = memberKey, recipeCount = N, entry = entry }, ... } }
function Data:GetMembersByProfession()
    local result = {}
    for _, profName in ipairs(PROF_NAMES) do
        result[profName] = {}
    end

    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if result[profName] then
                    local count = 0
                    if profData.recipes then
                        for _ in pairs(profData.recipes) do count = count + 1 end
                    end
                    result[profName][#result[profName] + 1] = {
                        key = memberKey,
                        recipeCount = count,
                        entry = entry,
                    }
                end
            end
        end
    end

    return result
end

--- Get the count of members who have a given profession.
function Data:GetProfessionMemberCount(profName)
    local count = 0
    for _, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.professions and entry.professions[profName] then
            count = count + 1
        end
    end
    return count
end

--- Get all profession names (static list).
function Data:GetTrackedProfessions()
    return PROF_NAMES
end

--- Search recipes across all members by name substring.
--- Returns { { recipeName, recipeKey, profName, crafters = { { key, online }, ... } }, ... }
function Data:SearchRecipes(query)
    if not query or query == "" then return {} end
    query = query:lower()

    -- Build a map: recipeName → { recipeKey, profName, crafters }
    local resultMap = {}

    for memberKey, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        if recipeData.name and recipeData.name:lower():find(query, 1, true) then
                            local mapKey = recipeData.name .. "|" .. profName
                            if not resultMap[mapKey] then
                                resultMap[mapKey] = {
                                    recipeName = recipeData.name,
                                    recipeKey = recipeKey,
                                    profName = profName,
                                    source = recipeData.source,
                                    reagents = recipeData.reagents,
                                    crafters = {},
                                }
                            end
                            resultMap[mapKey].crafters[#resultMap[mapKey].crafters + 1] = {
                                key = memberKey,
                                -- online status will be resolved by UI
                            }
                        end
                    end
                end
            end
        end
    end

    -- Convert map to sorted list
    local results = {}
    for _, v in pairs(resultMap) do
        results[#results + 1] = v
    end
    table.sort(results, function(a, b) return a.recipeName < b.recipeName end)

    return results
end
