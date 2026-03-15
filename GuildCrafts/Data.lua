----------------------------------------------------------------------
-- GuildCrafts — Data.lua
-- SavedVariables management, recipe scanning, data merging,
-- guild roster pruning, and simulation mode
----------------------------------------------------------------------
local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)
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

-- TBC crafting professions we track (canonical English keys)
local TRACKED_PROFESSIONS = {
    ["Alchemy"] = true,
    ["Blacksmithing"] = true,
    ["Cooking"] = true,
    ["Enchanting"] = true,
    ["Engineering"] = true,
    ["Jewelcrafting"] = true,
    ["Leatherworking"] = true,
    ["Tailoring"] = true,
}

-- TBC_ITEM_IDS is populated by Data_TBC.lua on the GuildCrafts addon table.
-- It maps every TBC Classic recipe spell ID to 1.

----------------------------------------------------------------------
-- Locale-to-canonical profession name mapping
-- GetSpellInfo(id) returns the *localised* profession name, which must
-- match what GetSkillLineInfo / GetTradeSkillLine returns on that client.
-- Using rank-1 profession spell IDs lets us normalise any locale to the
-- stable English key used in the DB, TRACKED_PROFESSIONS, etc.
----------------------------------------------------------------------
local PROFESSION_SPELL_IDS = {
    ["Alchemy"]        = 2259,
    ["Blacksmithing"]  = 2018,
    ["Cooking"]        = 2550,
    ["Enchanting"]     = 7411,
    ["Engineering"]    = 4036,
    ["Jewelcrafting"]  = 25229,
    ["Leatherworking"] = 2108,
    ["Tailoring"]      = 3908,
}

-- Populated lazily on first use (GetSpellInfo is not reliable at file-load time)
local _localeToCanonical = nil
local function BuildLocaleMap()
    _localeToCanonical = {}
    for canonical, spellID in pairs(PROFESSION_SPELL_IDS) do
        local localizedName = GetSpellInfo(spellID)
        if localizedName then
            _localeToCanonical[localizedName] = canonical
        end
    end
end

--- Return the canonical (English) profession name for a possibly-localised input.
--- Falls back to the input unchanged if the name is already canonical or unknown.
function Data:GetCanonicalProfName(name)
    if not _localeToCanonical then BuildLocaleMap() end
    return _localeToCanonical[name] or name
end

--- Return the localized recipe name for the viewing client's language.
--- recipeKey > 0: itemID  → GetItemInfo for the crafted item's name
--- recipeKey < 0: spellID → GetSpellInfo for the enchant/spell name
--- Falls back to `fallback` (or "Unknown") when not yet cached.
function Data:GetLocalizedRecipeName(recipeKey, fallback)
    if recipeKey and recipeKey > 0 then
        local name = GetItemInfo(recipeKey)
        if name then return name end
    elseif recipeKey and recipeKey < 0 then
        local name = GetSpellInfo(-recipeKey)
        if name then return name end
    end
    return fallback or "Unknown"
end

--- Return the localized name for a reagent entry {name, count, itemID}.
--- Uses GetItemInfo when itemID is available so non-English clients see
--- their own locale's item names even for recipes scanned in another language.
function Data:GetLocalizedReagentName(reagent)
    if reagent.itemID then
        local name = GetItemInfo(reagent.itemID)
        if name then return name end
    end
    return reagent.name or ""
end

-- TBC profession specialisations keyed by spellID
-- Each entry maps to { prof, spec, desc }
local SPECIALISATION_SPELLS = {
    -- Alchemy
    [28675] = { prof = "Alchemy",         spec = "Potion Master",              desc = "Chance to create extra potions when crafting." },
    [28677] = { prof = "Alchemy",         spec = "Elixir Master",              desc = "Chance to create extra elixirs when crafting." },
    [28672] = { prof = "Alchemy",         spec = "Transmutation Master",       desc = "Chance to create extra materials when transmuting." },
    -- Blacksmithing
    [9788]  = { prof = "Blacksmithing",   spec = "Armorsmith",                 desc = "Unlocks high-end plate armour recipes." },
    [9787]  = { prof = "Blacksmithing",   spec = "Weaponsmith",                desc = "Unlocks high-end weapon recipes." },
    [17039] = { prof = "Blacksmithing",   spec = "Master Swordsmith",          desc = "Unlocks iconic TBC sword recipes." },
    [17040] = { prof = "Blacksmithing",   spec = "Master Hammersmith",         desc = "Unlocks iconic TBC hammer recipes." },
    [17041] = { prof = "Blacksmithing",   spec = "Master Axesmith",            desc = "Unlocks iconic TBC axe recipes." },
    -- Engineering
    [20219] = { prof = "Engineering",     spec = "Gnomish Engineer",           desc = "Unlocks Gnomish gadgets and backfiring devices." },
    [20222] = { prof = "Engineering",     spec = "Goblin Engineer",            desc = "Unlocks explosive Goblin devices and launchers." },
    -- Leatherworking
    [10656] = { prof = "Leatherworking",  spec = "Dragonscale Leatherworking", desc = "Unlocks dragonscale armour sets for hunters and shamans." },
    [10658] = { prof = "Leatherworking",  spec = "Elemental Leatherworking",   desc = "Unlocks elemental leather gear for rogues and druids." },
    [10660] = { prof = "Leatherworking",  spec = "Tribal Leatherworking",      desc = "Unlocks tribal leather gear with nature resistance." },
    -- Tailoring
    [26798] = { prof = "Tailoring",       spec = "Mooncloth Tailoring",        desc = "Unlocks Primal Mooncloth gear; craft Primal Mooncloth on cooldown." },
    [26801] = { prof = "Tailoring",       spec = "Shadoweave Tailoring",       desc = "Unlocks Frozen Shadoweave gear; craft Shadowcloth on cooldown." },
    [26797] = { prof = "Tailoring",       spec = "Spellfire Tailoring",        desc = "Unlocks Spellfire gear; craft Spellcloth on cooldown." },
}

--- Return the description string for the given specialisation label, or nil if not found.
function Data:GetSpecialisationDescription(spec)
    for _, info in pairs(SPECIALISATION_SPELLS) do
        if info.spec == spec then return info.desc end
    end
    return nil
end

--- Returns "TBC", "ORIG", or nil (show regardless) for a recipe.
--- recipeKey: positive = createdItemId, negative = -spellId (enchanting).
--- Looks up directly in TBC_ITEM_IDS — no scan required.
function Data:GetExpansionTag(_profName, recipeKey)
    local ids = GuildCrafts.TBC_ITEM_IDS
    if not ids then return nil end
    return ids[recipeKey] and "TBC" or "ORIG"
end

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
    profile = {
        showOnlineOnly     = false,
        expansionFilter    = { ORIG = true, TBC = true },
        showTooltipCrafters = true,
    },
}

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Data:OnInitialize()
    -- Set up AceDB
    GuildCrafts.db = LibStub("AceDB-3.0"):New("GuildCraftsDB", DB_DEFAULTS, true)
    self.db = GuildCrafts.db

    -- Migrate legacy per-crafter reagents/categories into shared RecipeDB
    self:MigrateToRecipeDB()
end

function Data:OnEnable()
end

----------------------------------------------------------------------
-- RecipeDB — shared recipe lookup (reagents + category stored once)
----------------------------------------------------------------------

--- Return (and lazily create) the shared recipe lookup table.
--- Keyed by recipeKey (positive itemID or negative spellID).
function Data:GetRecipeDB()
    if not self.db.global._recipeDB then
        self.db.global._recipeDB = {}
    end
    return self.db.global._recipeDB
end

--- Store or update reagent/category data for a recipe in the shared DB.
--- Only overwrites reagents when the new list is longer (more complete).
function Data:SetRecipeInfo(recipeKey, name, category, reagents)
    local rdb = self:GetRecipeDB()
    if not rdb[recipeKey] then
        rdb[recipeKey] = {}
    end
    local entry = rdb[recipeKey]
    if name then entry.name = name end
    if category then entry.category = category end
    if reagents then
        if not entry.reagents or #reagents > #entry.reagents then
            entry.reagents = reagents
        end
    end
end

--- Look up reagents for a recipe from the shared DB.
function Data:GetRecipeReagents(recipeKey)
    local rdb = self:GetRecipeDB()
    local entry = rdb[recipeKey]
    return entry and entry.reagents or nil
end

--- Look up category for a recipe from the shared DB.
function Data:GetRecipeCategory(recipeKey)
    local rdb = self:GetRecipeDB()
    local entry = rdb[recipeKey]
    return entry and entry.category or nil
end

--- Extract reagents/categories from all per-crafter entries into RecipeDB.
--- Strips the duplicated fields from per-crafter storage.
function Data:MigrateToRecipeDB()
    local migrated = 0
    for _, entry in pairs(self.db.global) do
        if type(entry) == "table" and entry.professions then
            for _, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        if recipeData.reagents or recipeData.category then
                            self:SetRecipeInfo(recipeKey, recipeData.name, recipeData.category, recipeData.reagents)
                            recipeData.reagents = nil
                            recipeData.category = nil
                            migrated = migrated + 1
                        end
                    end
                end
            end
        end
    end
    if migrated > 0 then
        GuildCrafts:Debug("RecipeDB migration: extracted", migrated, "recipe entries")
    end
end

--- Extract reagents/categories from a single incoming entry into RecipeDB.
--- Strips the fields from the entry in-place.
function Data:ExtractToRecipeDB(entry)
    if type(entry) ~= "table" or not entry.professions then return end
    for _, profData in pairs(entry.professions) do
        if profData.recipes then
            for recipeKey, recipeData in pairs(profData.recipes) do
                if recipeData.reagents or recipeData.category then
                    self:SetRecipeInfo(recipeKey, recipeData.name, recipeData.category, recipeData.reagents)
                    recipeData.reagents = nil
                    recipeData.category = nil
                end
            end
        end
    end
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

----------------------------------------------------------------------
-- Per-guild database partitioning
-- Each guild's member data lives under db.global["GuildName-Realm"].
-- UI preferences (_minimapAngle, _minimapHide) remain at db.global.
----------------------------------------------------------------------

--- Return the partition key for the current character's guild, or nil.
function Data:GetGuildKey()
    if self._guildKey then return self._guildKey end
    local guildName = GetGuildInfo("player")
    if not guildName or guildName == "" then return nil end
    self._guildKey = guildName .. "-" .. GetRealmName()
    return self._guildKey
end

--- Return the guild-scoped sub-table for the current guild, or nil
--- if the player is not in a guild (yet).  Lazily creates the partition
--- and runs a one-time migration of legacy flat data.
function Data:GetGuildDB()
    local guildKey = self:GetGuildKey()
    if not guildKey then return nil end

    -- Lazy migration on first access
    if not self._guildMigrated then
        self:MigrateToGuildPartition()
        self._guildMigrated = true
    end

    if not self.db.global[guildKey] then
        self.db.global[guildKey] = {}
    end

    -- One-time cleanup: merge/rename keys stored without realm suffix.
    -- Requires realm name, which is only guaranteed available after login.
    if not self._realmlessMerged then
        self:MergeRealmlessKeys(self.db.global[guildKey])
        self._realmlessMerged = true
    end

    return self.db.global[guildKey]
end

--- One-time cleanup: find member keys stored without a realm suffix
--- (e.g. "Betadrul") and merge them into the canonical "Name-Realm" entry.
--- If the canonical entry is newer, the realmless entry is simply deleted.
--- If the canonical entry is absent, the realmless entry is renamed.
function Data:MergeRealmlessKeys(gdb)
    if not gdb then return end
    local realm = GetRealmName()
    if not realm or realm == "" then return end

    local renamed  = 0
    local merged   = 0

    -- Collect realmless keys first to avoid mutating the table mid-iteration.
    local realmless = {}
    for key, entry in pairs(gdb) do
        if type(entry) == "table" and entry.lastUpdate and not key:find("-") then
            realmless[#realmless + 1] = key
        end
    end

    for _, key in ipairs(realmless) do
        local entry      = gdb[key]
        local canonical  = key .. "-" .. realm
        local existing   = gdb[canonical]

        if not existing then
            -- No canonical entry — rename in-place
            gdb[canonical] = entry
            gdb[key]       = nil
            renamed = renamed + 1
            GuildCrafts:Debug("Renamed realmless key", key, "→", canonical)
        else
            -- Both exist — keep the one with the more recent lastUpdate,
            -- merging any professions the winner is missing from the loser.
            local keepExisting = (existing.lastUpdate or 0) >= (entry.lastUpdate or 0)
            local winner = keepExisting and existing or entry
            local loser  = keepExisting and entry    or existing

            -- Back-fill professions/recipes present in loser but absent in winner.
            -- If the profession exists in winner but is empty (e.g. DetectProfessions
            -- created it with a newer timestamp but no recipes scanned yet), merge
            -- individual recipes from the loser so no data is lost.
            for profName, loserProf in pairs(loser.professions or {}) do
                if not winner.professions then winner.professions = {} end
                if not winner.professions[profName] then
                    -- Profession entirely missing from winner — copy whole block
                    winner.professions[profName] = loserProf
                else
                    -- Profession exists in winner — merge individual recipes
                    local winnerProf = winner.professions[profName]
                    if not winnerProf.recipes then winnerProf.recipes = {} end
                    for recipeKey, recipeData in pairs(loserProf.recipes or {}) do
                        if not winnerProf.recipes[recipeKey] then
                            winnerProf.recipes[recipeKey] = recipeData
                        end
                    end
                end
            end

            gdb[canonical] = winner
            gdb[key]       = nil
            merged = merged + 1
            GuildCrafts:Debug("Merged realmless key", key, "into", canonical)
        end
    end

    if renamed > 0 then
        GuildCrafts:Printf("Cleaned up %d member key(s): added missing realm suffix.", renamed)
    end
    if merged > 0 then
        GuildCrafts:Printf("Cleaned up %d duplicate member key(s): merged realmless into realm entry.", merged)
    end
end

--- One-time migration: move flat member entries from db.global into
--- the current guild's partition.  Safe to call multiple times.
function Data:MigrateToGuildPartition()
    local guildKey = self:GetGuildKey()
    if not guildKey then return end

    if not self.db.global[guildKey] then
        self.db.global[guildKey] = {}
    end
    local gdb = self.db.global[guildKey]

    local migrated = 0
    for key, entry in pairs(self.db.global) do
        -- A legacy member entry is a table with a lastUpdate field
        -- sitting directly on db.global (not a guild partition table).
        if type(entry) == "table" and entry.lastUpdate then
            gdb[key] = entry
            self.db.global[key] = nil
            migrated = migrated + 1
        end
    end

    -- Clean up legacy _craftQueue (removed in 1.2.3)
    if self.db.global._craftQueue then
        self.db.global._craftQueue = nil
    end
    if gdb._craftQueue then
        gdb._craftQueue = nil
    end

    if migrated > 0 then
        GuildCrafts:Printf("Migrated %d member(s) to per-guild database.", migrated)
    end
end

--- Get or create a member entry in the DB (guild-scoped).
function Data:GetMemberEntry(memberKey, create)
    local gdb = self:GetGuildDB()
    if not gdb then return nil end
    local entry = gdb[memberKey]
    if not entry and create then
        entry = {
            professions = {},
            lastUpdate = 0,
        }
        gdb[memberKey] = entry
    end
    return entry
end

----------------------------------------------------------------------
-- Profession Detection (login-time, no window needed)
----------------------------------------------------------------------

function Data:DetectProfessions()
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, true)
    if not entry then return end
    local currentProfs = {}

    -- GetSkillLineInfo enumerates all skills including professions.
    -- Canonicalize the localized name so non-English clients store the same
    -- stable English key that TRACKED_PROFESSIONS and the rest of the addon use.
    local skillLevels = {}  -- profName -> { rank, max }
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank, _, _, skillMaxRank, _, _, _, _, _, _ = GetSkillLineInfo(i)
        if not isHeader then
            local canonical = self:GetCanonicalProfName(skillName)
            if TRACKED_PROFESSIONS[canonical] then
                currentProfs[canonical] = true
                skillLevels[canonical] = { rank = skillRank, max = skillMaxRank }
            end
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
    local hasCD = (next(cooldowns) ~= nil)

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
        if craftType ~= "header" and craftType ~= "ability" and craftName then
            local cdRemaining = GetCraftCooldown(i)
            if cdRemaining and cdRemaining > 0 then
                cooldowns[craftName] = {
                    endTime = now + cdRemaining,
                    duration = cdRemaining,
                }
            end
        end
    end

    local hasCD = (next(cooldowns) ~= nil)

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
    if not entry then return end
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
    local backfillChanged = false

    for i = 1, numSkills do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType == "header" then
            currentCategory = skillName
        elseif skillName then
            local recipeKey = self:GetRecipeKey(i)
            if recipeKey then
                -- Store/update reagents + category in shared RecipeDB
                local scannedReagents = self:ScanTradeSkillReagents(i)
                local existingReagents = self:GetRecipeReagents(recipeKey)
                local expectedCount = GetTradeSkillNumReagents(i)
                if scannedReagents and (not existingReagents
                        or (expectedCount and expectedCount > 0 and #existingReagents < expectedCount)) then
                    self:SetRecipeInfo(recipeKey, skillName, currentCategory, scannedReagents)
                    if recipes[recipeKey] then backfillChanged = true end
                elseif currentCategory then
                    self:SetRecipeInfo(recipeKey, skillName, currentCategory, nil)
                end

                if not recipes[recipeKey] then
                    local recipeData = {
                        name = skillName,
                        source = "",
                    }
                    recipes[recipeKey] = recipeData
                    newRecipes[recipeKey] = recipeData
                    newCount = newCount + 1
                end
            end
        end
    end

    if backfillChanged and newCount == 0 then
        entry.lastUpdate = time()
        GuildCrafts:Printf("Scanned %s: backfilled reagent/category data.", profName)
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
    -- or we can use GetTradeSkillLine() if available (TBC).
    -- Always canonicalize so non-English clients return the same stable English key.
    if GetTradeSkillLine then
        local lineName = GetTradeSkillLine()
        return lineName and self:GetCanonicalProfName(lineName) or nil
    end

    -- Fallback: check first header
    for i = 1, GetNumTradeSkills() do
        local skillName, skillType = GetTradeSkillInfo(i)
        if skillType == "header" then
            return self:GetCanonicalProfName(skillName)
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

    -- Guard: CRAFT_SHOW fires for both Enchanting and Beast Training (hunter pet)
    -- windows in Classic TBC. Only scan when the player actually has Enchanting.
    -- Compare against the canonical name so non-English clients are handled.
    local hasEnchanting = false
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader = GetSkillLineInfo(i)
        if not isHeader and self:GetCanonicalProfName(skillName) == "Enchanting" then
            hasEnchanting = true
            break
        end
    end
    if not hasEnchanting then
        GuildCrafts:Debug("CRAFT_SHOW fired but player has no Enchanting skill — skipping scan (likely Beast Training).")
        return
    end

    local profName = "Enchanting"
    local playerKey = self:GetPlayerKey()
    local entry = self:GetMemberEntry(playerKey, true)
    if not entry then return end
    if not entry.professions[profName] then
        entry.professions[profName] = { recipes = {} }
    end

    -- Refresh Enchanting skill level while the window is open
    for i = 1, GetNumSkillLines() do
        local skillName, isHeader, _, skillRank, _, _, skillMaxRank = GetSkillLineInfo(i)
        if not isHeader and self:GetCanonicalProfName(skillName) == profName then
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
    local backfillChanged = false

    for i = 1, numCrafts do
        local craftName, _, craftType = GetCraftInfo(i)
        if craftType == "header" then
            currentCategory = craftName
        elseif craftName and craftType ~= "ability" then
            -- Skip "ability" type entries (hunter pet abilities) as a secondary
            -- guard in case an Enchanter+Hunter opens the Beast Training window.
            local recipeKey = self:GetCraftRecipeKey(i)
            if recipeKey then
                -- Store/update reagents + category in shared RecipeDB
                local scannedReagents = self:ScanCraftReagents(i)
                local existingReagents = self:GetRecipeReagents(recipeKey)
                local expectedCount = GetCraftNumReagents(i)
                if scannedReagents and (not existingReagents
                        or (expectedCount and expectedCount > 0 and #existingReagents < expectedCount)) then
                    self:SetRecipeInfo(recipeKey, craftName, currentCategory, scannedReagents)
                    if recipes[recipeKey] then backfillChanged = true end
                elseif currentCategory then
                    self:SetRecipeInfo(recipeKey, craftName, currentCategory, nil)
                end

                if not recipes[recipeKey] then
                    local recipeData = {
                        name = craftName,
                        source = "",
                    }
                    recipes[recipeKey] = recipeData
                    newRecipes[recipeKey] = recipeData
                    newCount = newCount + 1
                end
            end
        end
    end

    if backfillChanged and newCount == 0 then
        entry.lastUpdate = time()
        GuildCrafts:Printf("Scanned %s: backfilled reagent/category data.", profName)
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
        dataFormat = GuildCrafts.DATA_FORMAT_VERSION,
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
                category = recipeData.category or self:GetRecipeCategory(recipeKey),
                reagents = recipeData.reagents or self:GetRecipeReagents(recipeKey),
            }
        end
        copy.professions[profName] = profCopy
    end

    return copy
end

--- Prepare a recipes table for delta payloads.
--- Re-inflates reagents/category from RecipeDB for wire compatibility.
function Data:StripRecipeReagents(recipes)
    if type(recipes) ~= "table" then return recipes end

    local copy = {}
    for recipeKey, recipeData in pairs(recipes) do
        copy[recipeKey] = {
            name = recipeData.name,
            source = recipeData.source,
            category = recipeData.category or self:GetRecipeCategory(recipeKey),
            reagents = recipeData.reagents or self:GetRecipeReagents(recipeKey),
        }
    end
    return copy
end

----------------------------------------------------------------------
-- Version Vector
----------------------------------------------------------------------

function Data:GetVersionVector()
    local gdb = self:GetGuildDB()
    if not gdb then return {} end
    local vector = {}
    for memberKey, entry in pairs(gdb) do
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
    local gdb = self:GetGuildDB()
    if not gdb then return false end
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
                local localEntry = gdb[memberKey]
                local dominated = not localEntry
                    or incomingEntry.lastUpdate > localEntry.lastUpdate
                    or (incomingEntry.lastUpdate == localEntry.lastUpdate
                        and (incomingEntry.dataFormat or 0) > (localEntry.dataFormat or 0))
                if dominated then
                    gdb[memberKey] = incomingEntry
                    self:ExtractToRecipeDB(incomingEntry)
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
    if not entry then return end
    if not entry.professions[profName] then
        entry.professions[profName] = { recipes = {} }
    end
    entry.professions[profName].recipes[recipeKey] = recipeData
    -- Extract reagents/category to shared RecipeDB
    if recipeData.reagents or recipeData.category then
        self:SetRecipeInfo(recipeKey, recipeData.name, recipeData.category, recipeData.reagents)
        recipeData.reagents = nil
        recipeData.category = nil
    end
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
    local gdb = self:GetGuildDB()
    if not gdb then return end
    local entry = gdb[memberKey]
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

    -- Prune entries not in the roster (with 30-day grace period)
    local pruned = 0
    local marked = 0
    local restored = 0
    local now = time()
    local gdb = self:GetGuildDB()
    if not gdb then return end
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.lastUpdate and not rosterKeys[memberKey] then
            -- Don't prune simulated entries (they won't be in the roster)
            if not entry._simulated then
                if not entry._absentSince then
                    -- First time absent — mark with timestamp
                    entry._absentSince = now
                    marked = marked + 1
                elseif now - entry._absentSince > STALE_THRESHOLD then
                    -- Grace period expired — prune
                    gdb[memberKey] = nil
                    pruned = pruned + 1
                end
            end
        elseif type(entry) == "table" and entry._absentSince and rosterKeys[memberKey] then
            -- Back in guild — clear absent flag
            entry._absentSince = nil
            restored = restored + 1
        end
    end

    if marked > 0 then
        GuildCrafts:Debug("Marked", marked, "absent member(s) for future pruning.")
    end
    if restored > 0 then
        GuildCrafts:Debug("Restored", restored, "member(s) — back in guild.")
    end
    if pruned > 0 then
        GuildCrafts:Debug("Pruned", pruned, "ex-guild member(s) after 30-day grace period.")
    end
end

----------------------------------------------------------------------
-- Debug: Dump Summary
----------------------------------------------------------------------

function Data:DumpSummary()
    local playerKey = self:GetPlayerKey()
    GuildCrafts:Printf("Local player: %s", playerKey)
    GuildCrafts:Printf("Guild key: %s", self:GetGuildKey() or "(none)")

    local gdb = self:GetGuildDB()
    if not gdb then
        GuildCrafts:Print("No guild database available.")
        return
    end

    local totalMembers = 0
    local totalRecipes = 0
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.professions then
            totalMembers = totalMembers + 1
            local memberRecipes = 0
            for _, profData in pairs(entry.professions) do
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
    local gdb = self:GetGuildDB()
    if not gdb then
        GuildCrafts:Print("Cannot simulate — not in a guild.")
        return
    end
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

        gdb[memberKey] = entry
        self:ExtractToRecipeDB(entry)
        generated = generated + 1
    end

    GuildCrafts:Printf("Simulated %d guild members injected.", generated)
end

function Data:SimClear()
    local gdb = self:GetGuildDB()
    if not gdb then return end
    local cleared = 0
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry._simulated then
            gdb[memberKey] = nil
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
    local gdb = self:GetGuildDB()
    if not gdb then return end
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry._simulated then
            local profName = next(entry.professions)
            if profName then
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
    GuildCrafts:Print("Craft request simulation removed in 1.2.3 — use [W] whisper button instead.")
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

    local gdb = self:GetGuildDB()
    if not gdb then return result end

    for memberKey, entry in pairs(gdb) do
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

    -- Deduplicate by character name (the part before the "-" realm suffix).
    -- Legacy entries may have been stored without a realm suffix (e.g. "Betadrul")
    -- while current entries are always stored with one ("Betadrul-Firemaw").
    -- Keep the entry with the most-recent lastUpdate; fall back to recipeCount.
    for pName, list in pairs(result) do
        local seen    = {}   -- displayName -> index in deduped
        local deduped = {}
        for _, info in ipairs(list) do
            local displayName = info.key:match("^(.+)-") or info.key
            local idx = seen[displayName]
            if not idx then
                deduped[#deduped + 1] = info
                seen[displayName] = #deduped
            else
                local existing = deduped[idx]
                local existTs  = existing.entry and existing.entry.lastUpdate or 0
                local newTs    = info.entry    and info.entry.lastUpdate    or 0
                if newTs > existTs
                        or (newTs == existTs and info.recipeCount > existing.recipeCount) then
                    deduped[idx] = info
                end
            end
        end
        result[pName] = deduped
    end

    return result
end

--- Get the count of members who have a given profession.
--- Deduplicates by character name so legacy no-realm-suffix entries
--- do not inflate the count.
function Data:GetProfessionMemberCount(profName, onlineOnly)
    local gdb = self:GetGuildDB()
    if not gdb then return 0 end
    local seen = {}
    local count = 0
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.professions and entry.professions[profName] then
            if not onlineOnly or self:IsMemberOnline(memberKey) then
                local displayName = memberKey:match("^(.+)-") or memberKey
                if not seen[displayName] then
                    seen[displayName] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Get all profession names (static list).
function Data:GetTrackedProfessions()
    return PROF_NAMES
end

--- Return all guild recipes for a given profession, aggregated across all members.
--- Returns: { { key, name, crafters = { {key}, ... } }, ... } sorted alphabetically by name.
function Data:GetAllRecipesForProfession(profName)
    local gdb = self:GetGuildDB()
    if not gdb then return {} end
    local recipeMap = {}
    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.professions and entry.professions[profName] then
            local profData = entry.professions[profName]
            if profData.recipes then
                for recipeKey, recipeData in pairs(profData.recipes) do
                    -- Resolve the recipe name in the *viewing* client's locale via
                    -- GetItemInfo/GetSpellInfo so a recipe scanned in French still
                    -- shows in English (or German, etc.) for other guild members.
                    local name = self:GetLocalizedRecipeName(recipeKey, recipeData.name)
                    if not recipeMap[recipeKey] then
                        recipeMap[recipeKey] = {
                            key      = recipeKey,
                            name     = name,
                            crafters = {},
                            reagents = recipeData.reagents or self:GetRecipeReagents(recipeKey),
                        }
                    else
                        -- Update name if we now have a better (locally resolved) one
                        if name ~= "Unknown" then
                            recipeMap[recipeKey].name = name
                        end
                    end
                    recipeMap[recipeKey].crafters[#recipeMap[recipeKey].crafters + 1] = { key = memberKey }
                end
            end
        end
    end
    -- Deduplicate crafters per recipe by display name so a member who appears
    -- under two different DB keys (e.g. legacy no-realm-suffix entry + current entry)
    -- is only listed once per recipe.
    for _, recipe in pairs(recipeMap) do
        local seenCrafters   = {}
        local uniqueCrafters = {}
        for _, c in ipairs(recipe.crafters) do
            local displayName = c.key:match("^(.+)-") or c.key
            if not seenCrafters[displayName] then
                seenCrafters[displayName] = true
                uniqueCrafters[#uniqueCrafters + 1] = c
            end
        end
        recipe.crafters = uniqueCrafters
    end
    local results = {}
    for _, recipe in pairs(recipeMap) do
        results[#results + 1] = recipe
    end
    table.sort(results, function(a, b) return (a.name or "") < (b.name or "") end)
    return results
end

--- Search recipes across all members by name substring.
--- Returns { { recipeName, recipeKey, profName, crafters = { { key, online }, ... } }, ... }
--- Strip vowels for fuzzy matching — handles the most common typo class.
--- "agylity" → "glty", "agility" → "glty"
local function StripVowels(s)
    return s:lower():gsub("[aeiouAEIOU]", "")
end

function Data:SearchRecipes(query, fuzzy)
    if not query or query == "" then return {} end
    query = query:lower()
    -- Require at least 4 characters for fuzzy (vowel-stripped) matching to avoid
    -- false positives on very short consonant patterns like "st" matching dozens.
    local fuzzyQuery = (fuzzy and #query >= 4) and StripVowels(query) or nil

    -- Build a map: recipeName → { recipeKey, profName, crafters }
    local resultMap = {}

    local gdb = self:GetGuildDB()
    if not gdb then return {} end

    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        -- Always try to resolve the name in the viewing client's locale.
                        -- Fall back to the stored (possibly foreign-locale) name so that
                        -- uncached items still appear in results.
                        local localName = self:GetLocalizedRecipeName(recipeKey, recipeData.name)
                        local storedName = recipeData.name or ""
                        -- Match against both the locally-resolved name and the stored name
                        -- so a French player's "Transmutation: Mercure brut" is still
                        -- findable by an English player typing "Mercury".
                        local matchName  = localName ~= "Unknown" and localName or storedName
                        local matched = matchName:lower():find(query, 1, true)
                            or (storedName ~= matchName and storedName:lower():find(query, 1, true))
                            or (fuzzyQuery and StripVowels(matchName):find(fuzzyQuery, 1, true))
                        if matched then
                            -- Use recipeKey+profName as the map key (locale-independent)
                            -- so the same recipe scanned in two different languages is
                            -- deduplicated into a single result entry.
                            local mapKey = tostring(recipeKey) .. "|" .. profName
                            if not resultMap[mapKey] then
                                resultMap[mapKey] = {
                                    recipeName = localName,
                                    recipeKey = recipeKey,
                                    profName = profName,
                                    source = recipeData.source,
                                    reagents = recipeData.reagents or self:GetRecipeReagents(recipeKey),
                                    crafters = {},
                                }
                            else
                                -- Keep the better (locally resolved) name if available
                                if localName ~= "Unknown" then
                                    resultMap[mapKey].recipeName = localName
                                end
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

    -- Deduplicate crafters by display name (same fix as GetAllRecipesForProfession;
    -- prevents double-listing when a legacy no-realm key and a current key coexist)
    for _, v in pairs(resultMap) do
        local seenCrafters   = {}
        local uniqueCrafters = {}
        for _, c in ipairs(v.crafters) do
            local displayName = c.key:match("^(.+)-") or c.key
            if not seenCrafters[displayName] then
                seenCrafters[displayName] = true
                uniqueCrafters[#uniqueCrafters + 1] = c
            end
        end
        v.crafters = uniqueCrafters
    end

    -- Convert map to sorted list
    local results = {}
    for _, v in pairs(resultMap) do
        results[#results + 1] = v
    end
    table.sort(results, function(a, b) return a.recipeName < b.recipeName end)

    return results
end
