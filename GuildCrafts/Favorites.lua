----------------------------------------------------------------------
-- GuildCrafts — Favorites.lua
-- Per-character favorites for recipes and members.
-- Persisted via SavedVariablesPerCharacter (GuildCraftsCharDB).
----------------------------------------------------------------------
local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)
local GuildCrafts = _G.GuildCrafts

local Favorites = GuildCrafts:NewModule("Favorites")
GuildCrafts.Favorites = Favorites

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function Favorites:OnInitialize()
    -- GuildCraftsCharDB is created by WoW from SavedVariablesPerCharacter.
    -- We just ensure the sub-tables exist.
    GuildCraftsCharDB = GuildCraftsCharDB or {}
    GuildCraftsCharDB.favoriteRecipes = GuildCraftsCharDB.favoriteRecipes or {} -- [recipeKey] = true
    GuildCraftsCharDB.favoriteMembers = GuildCraftsCharDB.favoriteMembers or {} -- [memberKey] = true
end

----------------------------------------------------------------------
-- Recipe Favorites
----------------------------------------------------------------------

--- Toggle a recipe's favorite state. Returns the new state.
function Favorites:ToggleRecipe(recipeKey)
    local db = GuildCraftsCharDB.favoriteRecipes
    if db[recipeKey] then
        db[recipeKey] = nil
        return false
    else
        db[recipeKey] = true
        return true
    end
end

function Favorites:IsRecipeFavorite(recipeKey)
    return GuildCraftsCharDB.favoriteRecipes[recipeKey] == true
end

function Favorites:GetFavoriteRecipeKeys()
    local keys = {}
    for k in pairs(GuildCraftsCharDB.favoriteRecipes) do
        keys[#keys + 1] = k
    end
    return keys
end

----------------------------------------------------------------------
-- Member Favorites
----------------------------------------------------------------------

--- Toggle a member's favorite state. Returns the new state.
function Favorites:ToggleMember(memberKey)
    local db = GuildCraftsCharDB.favoriteMembers
    if db[memberKey] then
        db[memberKey] = nil
        return false
    else
        db[memberKey] = true
        return true
    end
end

function Favorites:IsMemberFavorite(memberKey)
    return GuildCraftsCharDB.favoriteMembers[memberKey] == true
end

function Favorites:GetFavoriteMemberKeys()
    local keys = {}
    for k in pairs(GuildCraftsCharDB.favoriteMembers) do
        keys[#keys + 1] = k
    end
    return keys
end

----------------------------------------------------------------------
-- Query Helpers — build data for the Favorites tab
----------------------------------------------------------------------

--- Get all favorited recipes with crafter info, grouped by profession.
--- Returns: { [profName] = { { recipeKey, recipeName, category, reagents, crafters = { {key, online} } }, ... } }
function Favorites:GetFavoriteRecipesGrouped()
    local gdb = GuildCrafts.Data:GetGuildDB()
    if not gdb then return {} end

    -- Build a map: recipeKey → { recipeName, profName, crafters }
    local recipeMap = {}

    for memberKey, entry in pairs(gdb) do
        if type(entry) == "table" and entry.professions then
            for profName, profData in pairs(entry.professions) do
                if profData.recipes then
                    for recipeKey, recipeData in pairs(profData.recipes) do
                        if self:IsRecipeFavorite(recipeKey) then
                            if not recipeMap[recipeKey] then
                                recipeMap[recipeKey] = {
                                    recipeKey = recipeKey,
                                    recipeName = GuildCrafts.Data:GetLocalizedRecipeName(recipeKey, recipeData.name),
                                    profName = profName,
                                    category = recipeData.category or GuildCrafts.Data:GetRecipeCategory(recipeKey) or "",
                                    reagents = recipeData.reagents or GuildCrafts.Data:GetRecipeReagents(recipeKey),
                                    crafters = {},
                                }
                            end
                            recipeMap[recipeKey].crafters[#recipeMap[recipeKey].crafters + 1] = {
                                key = memberKey,
                                online = GuildCrafts.Data:IsMemberOnline(memberKey),
                            }
                        end
                    end
                end
            end
        end
    end

    -- Group by profession and sort
    local grouped = {}
    for _, info in pairs(recipeMap) do
        if not grouped[info.profName] then
            grouped[info.profName] = {}
        end
        -- Sort crafters: online first, then alpha
        table.sort(info.crafters, function(a, b)
            if a.online ~= b.online then return a.online end
            return a.key < b.key
        end)
        grouped[info.profName][#grouped[info.profName] + 1] = info
    end

    -- Sort recipes within each profession
    for _, recipes in pairs(grouped) do
        table.sort(recipes, function(a, b) return a.recipeName < b.recipeName end)
    end

    return grouped
end

--- Get favorited members with their profession summary.
--- Returns: { { key, entry, online, profSummary = "Alchemy, Enchanting" }, ... }
function Favorites:GetFavoriteMembersInfo()
    local gdb = GuildCrafts.Data:GetGuildDB()
    if not gdb then return {} end

    local result = {}
    for memberKey in pairs(GuildCraftsCharDB.favoriteMembers) do
        local entry = gdb[memberKey]
        if entry and type(entry) == "table" and entry.professions then
            local profNames = {}
            local totalRecipes = 0
            for profName, profData in pairs(entry.professions) do
                profNames[#profNames + 1] = profName
                if profData.recipes then
                    for _ in pairs(profData.recipes) do
                        totalRecipes = totalRecipes + 1
                    end
                end
            end
            table.sort(profNames)
            result[#result + 1] = {
                key = memberKey,
                entry = entry,
                online = GuildCrafts.Data:IsMemberOnline(memberKey),
                profSummary = table.concat(profNames, ", "),
                recipeCount = totalRecipes,
            }
        end
    end

    -- Sort: online first, then alphabetical
    table.sort(result, function(a, b)
        if a.online ~= b.online then return a.online end
        return a.key < b.key
    end)

    return result
end
