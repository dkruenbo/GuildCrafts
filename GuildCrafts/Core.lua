----------------------------------------------------------------------
-- GuildCrafts — Core.lua
-- Addon initialization, event handling, slash commands
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"

-- Create the main AceAddon object.
-- Mixins give us built-in event handling, console (slash commands), and timers.
local GuildCrafts = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceTimer-3.0"
)

-- Make it globally accessible for other files
_G.GuildCrafts = GuildCrafts

-- Addon version — keep in sync with .toc and CurseForge
GuildCrafts.DISPLAY_VERSION = "1.3.3"

-- Protocol version — integer used in sync envelope for compatibility checks.
-- Bump when the wire format changes in a backward-incompatible way.
GuildCrafts.VERSION = 2
GuildCrafts.ADDON_PREFIX = "GuildCrafts"

-- Data format version — bump when sync payload structure changes
-- (e.g. adding reagents to sync). Forces re-pull of stale copies.
GuildCrafts.DATA_FORMAT_VERSION = 2

-- Debug mode toggle
GuildCrafts.debugMode = false

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function GuildCrafts:OnInitialize()
    -- Called when the addon is loaded (before PLAYER_LOGIN).
    -- Set up database, register slash commands.
    self:RegisterChatCommand("gc", "SlashHandler")
end

function GuildCrafts:OnEnable()
    -- Called after all addons have loaded (PLAYER_LOGIN equivalent).
    -- Register game events.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    -- Enchanting in Classic TBC uses CRAFT_SHOW, not TRADE_SKILL_SHOW
    self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
    -- Fired when the client loads an item into memory (e.g. after GetItemInfo)
    -- Used to retry quality-color lookups that returned nil on first render
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", "OnItemInfoReceived")
    self:RegisterEvent("CHAT_MSG_GUILD", "OnGuildChatMessage")
end

function GuildCrafts:OnDisable()
    -- Called if the addon is disabled (rarely used).
end

--- Fired when the WoW client loads an item into its local cache.
--- Quality colors use GetItemInfo and may return nil on first render if the item
--- is not yet cached — this event is our signal to re-render with real colors.
function GuildCrafts:OnItemInfoReceived()
    -- Debounce: cancel any pending refresh and reschedule 0.5s later.
    -- This collapses a burst of item loads into a single refresh.
    if self._itemInfoRefreshTimer then
        self:CancelTimer(self._itemInfoRefreshTimer)
        self._itemInfoRefreshTimer = nil
    end
    self._itemInfoRefreshTimer = self:ScheduleTimer(function()
        self._itemInfoRefreshTimer = nil
        GuildCrafts.UI:Refresh()
    end, 0.5)
end

----------------------------------------------------------------------
-- Event Handlers
----------------------------------------------------------------------

function GuildCrafts:OnPlayerEnteringWorld(_event, isLogin, isReload)
    -- One-time stale-data warning for the local player's own entry
    if not self._staleWarnShown then
        C_Timer.After(3, function()
            if self._staleWarnShown then return end
            self._staleWarnShown = true
            local playerKey = GuildCrafts.Data:GetPlayerKey()
            local db = GuildCrafts.Data:GetGuildDB()
            local entry = db and db[playerKey]
            if entry and entry.lastUpdate and entry.lastUpdate > 0 then
                local age = time() - entry.lastUpdate
                if age > 30 * 86400 then
                    local days = math.floor(age / 86400)
                    GuildCrafts:Print("|cffff9900Your profession data is " .. days ..
                        " days old and will be pruned soon. Open your profession windows to resync.|r")
                end
            end
        end)
    end

    if not IsInGuild() then
        self:Debug("Not in a guild — sync disabled.")
        return
    end

    -- Request a guild roster update so we have fresh online/offline data
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end

    if isLogin or isReload then
        self:Debug("Login/reload detected. Will init comms after delay.")
        -- Delay to let guild channel initialize
        self:ScheduleTimer("OnLoginReady", 5)
    else
        -- Zone transition: crossing an instance/arena boundary or taking a portal.
        -- Re-announce so other nodes don't falsely time us out, and so we
        -- discover any traffic (heartbeats, hellos) we missed while instanced.
        if self.Comms and IsInGuild() then
            self.Comms:ScheduleTimer("BroadcastHello", 2)
        end
    end
end

function GuildCrafts:OnLoginReady()
    -- Called ~5s after login/reload to give the guild channel time to init.
    -- Phase 1 will add: profession detection, recipe scan comparison
    -- Phase 2 will add: HELLO broadcast, SYNC_REQUEST

    -- Detect professions on login (Phase 1)
    if self.Data then
        self.Data:DetectProfessions()
    end

    -- Init comms (Phase 2)
    if self.Comms then
        self.Comms:OnLoginReady()
    end

    -- Warn about unscanned professions (excluding Herbalism/Skinning — no recipes)
    local SCAN_EXEMPT = { Herbalism = true, Skinning = true }
    if self.Data and self.Data._currentProfs then
        local unscanned = {}
        local entry = self.Data:GetMemberEntry(self.Data:GetPlayerKey(), false)
        for profName in pairs(self.Data._currentProfs) do
            if not SCAN_EXEMPT[profName] then
                local profData = entry and entry.professions and entry.professions[profName]
                local hasRecipes = profData and profData.recipes and next(profData.recipes)
                if not hasRecipes then
                    unscanned[#unscanned + 1] = profName
                end
            end
        end
        if #unscanned > 0 then
            table.sort(unscanned)
            self:Print("|cffff9900Open these profession windows to sync your recipes: " ..
                table.concat(unscanned, ", ") .. ".|r")
        end
    end
end

function GuildCrafts:OnTradeSkillShow()
    -- Profession window was opened — scan recipes
    if self.Data then
        self.Data:ScanTradeSkill()
    end
end

function GuildCrafts:OnCraftShow()
    -- Enchanting window was opened (Classic TBC uses separate Craft API)
    if self.Data then
        self.Data:ScanCraft()
    end
end

function GuildCrafts:OnGuildRosterUpdate()
    -- Rebuild online cache first so all downstream handlers see fresh data
    if self.Data then
        self.Data:RebuildOnlineCache()
        self.Data:PruneRoster()
    end
    if self.Comms then
        self.Comms:OnGuildRosterUpdate()
    end
    -- GetActiveAddonUserCount() cross-checks addonUsers with _onlineCache, so
    -- the sync indicator must be refreshed whenever the cache is rebuilt.
    if self.UI and self.UI.UpdateSyncIndicator then
        self.UI:UpdateSyncIndicator()
    end
end

----------------------------------------------------------------------
-- Guild Chat — Post Crafters & !gc responder
----------------------------------------------------------------------

-- Per-recipe post cooldown (recipeKey → last post time)
GuildCrafts._chatPostCooldowns = {}
local CHAT_POST_COOLDOWN = 30  -- seconds

--- Sort and format a crafter list into a single chat-friendly string.
--- Online crafters appear first; list is capped to stay within 255-byte
--- guild chat limit.  Builds incrementally and stops when adding another
--- name would exceed the budget.
--- @param extraReserve number|nil  Additional bytes to reserve for a suffix
---                                 appended by the caller after this string.
function GuildCrafts:FormatCraftersLine(crafters, prefix, maxNames, extraReserve)
    local myKey = self.Data:GetPlayerKey()
    local sorted = {}
    for _, c in ipairs(crafters) do sorted[#sorted + 1] = c end
    table.sort(sorted, function(a, b)
        if a.key == myKey then return true end
        if b.key == myKey then return false end
        local aOn = self.Data:IsMemberOnline(a.key)
        local bOn = self.Data:IsMemberOnline(b.key)
        if aOn ~= bOn then return aOn end
        return a.key < b.key
    end)

    -- Reserve space for the prefix (e.g. "[GuildCrafts] Recipe (Prof): ")
    -- plus a generous overflow suffix like ", +99 more",
    -- plus any caller-supplied suffix (e.g. " — /gc to browse").
    local prefixLen = prefix and #prefix or 0
    local budget    = 255 - prefixLen - 15 - (extraReserve or 0)
    local cap       = maxNames or #sorted   -- 0 = no cap beyond budget
    local parts     = {}
    local totalLen  = 0
    local shown     = 0

    for i = 1, #sorted do
        if shown >= cap then break end
        local c    = sorted[i]
        local name = c.key:match("^(.+)-") or c.key
        local isOn = self.Data:IsMemberOnline(c.key)
        if isOn then name = name .. " (online)" end

        local addition = (shown > 0 and 2 or 0) + #name  -- ", " separator
        if totalLen + addition > budget then break end
        parts[#parts + 1] = name
        totalLen = totalLen + addition
        shown = shown + 1
    end

    local line = table.concat(parts, ", ")
    local overflow = #sorted - shown
    if overflow > 0 then line = line .. ", +" .. overflow .. " more" end
    return line
end

--- Post the crafter list for a recipe to guild chat.
--- Respects a per-recipe 30-second cooldown to prevent accidental spam.
function GuildCrafts:PostCraftersToGuildChat(recipeName, recipeKey, crafters)
    if not IsInGuild() then
        self:Print("You are not in a guild.")
        return
    end
    local now = time()
    local lastPost = self._chatPostCooldowns[recipeKey] or 0
    local remaining = CHAT_POST_COOLDOWN - (now - lastPost)
    if remaining > 0 then
        self:Printf("Please wait %d seconds before posting %s again.", math.ceil(remaining), recipeName)
        return
    end
    if not crafters or #crafters == 0 then
        self:Printf("No guild crafters found for %s.", recipeName)
        return
    end
    self._chatPostCooldowns[recipeKey] = now
    local BROWSE_SUFFIX = " \226\128\148 /gc to browse"  -- em dash: 3 bytes
    local prefix = "[GuildCrafts] " .. recipeName .. ": "
    local line = self:FormatCraftersLine(crafters, prefix, nil, #BROWSE_SUFFIX)
    SendChatMessage(prefix .. line .. BROWSE_SUFFIX, "GUILD")
end

-- Epoch of the last [GuildCrafts] message seen in guild chat.
-- Uses GetTime() (sub-second float) so that a DR response posted in the
-- same wall-clock second still suppresses BDR/OTHER fallback timers.
GuildCrafts._gcLastGuildCraftsMsg = 0

--- CHAT_MSG_GUILD handler for !gc <query> commands.
--- DR responds immediately; BDR falls back after 5 s; anyone else after 12 s.
--- DR inside an instance uses 8–12 s so a newly elected outside DR/BDR can
--- respond first — prevents double-posting when the DR is in a BG/dungeon.
--- The guild-chat echo acts as the cross-client deduplication signal.
function GuildCrafts:OnGuildChatMessage(_event, msg)
    -- Track any [GuildCrafts] response so fallback timers can detect it.
    if msg:sub(1, 13) == "[GuildCrafts]" then
        self._gcLastGuildCraftsMsg = GetTime()
        return
    end

    -- Not an addon user yet — nothing to respond with.
    if not self.Comms or self.Comms.myRole == "NONE" then return end

    local query = msg:match("^!gc%s+(.+)$")
    if not query then return end

    -- Extract a numeric recipe key from a hyperlink before stripping markup.
    -- |Hitem:12345:...|h  →  recipeKey = 12345  (positive itemID)
    -- |Henchant:9876|h    →  recipeKey = -9876   (negative spellID, matches DB convention)
    local linkRecipeKey = nil
    local itemID = query:match("|Hitem:(%d+)")
    if itemID then
        linkRecipeKey = tonumber(itemID)
    else
        local spellID = query:match("|Henchant:(%d+)")
        if spellID then linkRecipeKey = -tonumber(spellID) end
    end

    -- Strip item/spell hyperlink markup so shift-clicking an item works.
    -- "|cff...|Hitem:...|h[Name]|h|r"  →  "Name"
    -- "|cff...|Henchant:...|h[Enchanting: Name]|h|r"  →  "Name"
    query = query:gsub("|c%x%x%x%x%x%x%x%x", "")
                 :gsub("|r", "")
                 :gsub("|H[^|]+|h(%[?[^%]|]*%]?)|h", function(s)
                     return s:match("^%[(.-)%]$") or s
                 end)
                 :trim()
    -- Enchant spell links embed a "Profession: " prefix in the display text
    -- (e.g. "Enchanting: Enchant Bracer - Spellpower"). Strip it so the query
    -- matches the bare recipe name stored in the DB.
    query = query:gsub("^[^:]+:%s+", "")
    if query == "" and not linkRecipeKey then return end

    if not self._gcQueryCooldowns then self._gcQueryCooldowns = {} end
    local cooldownKey = query:lower()
    local now = time()
    if (now - (self._gcQueryCooldowns[cooldownKey] or 0)) < CHAT_POST_COOLDOWN then return end
    -- Cooldown is stamped only on a successful response (see below),
    -- so a no-match query can be retried immediately with a corrected spelling.

    -- Staggered delay: DR=0 s, BDR=5 s, anyone else=12–20 s.
    -- If DR is inside an instance it may have been silently replaced by the BDR
    -- (heartbeats don't cross instance boundaries). Treat an in-instance DR as
    -- OTHER so the outside DR/BDR responds first. When the DR leaves the
    -- instance it broadcasts HELLO, roles re-converge, and it reclaims DR.
    local myRole = self.Comms.myRole
    local inInstance = IsInInstance and select(1, IsInInstance())
    local effectiveRole = (myRole == "DR" and inInstance) and "OTHER" or myRole
    local delay = 0
    if effectiveRole == "BDR" then
        delay = 5
    elseif effectiveRole == "OTHER" then
        -- Add per-client jitter so many OTHER nodes don't all fire at the same
        -- time. The first to post emits [GuildCrafts] in guild chat, causing
        -- all others to cancel when their timer fires.
        delay = 12 + math.random(0, 8)
    end

    local capturedQuery      = query
    local capturedCooldown   = cooldownKey
    local capturedScheduled  = GetTime()  -- sub-second precision for dedup
    local capturedRecipeKey  = linkRecipeKey

    self:ScheduleTimer(function()
        -- If any [GuildCrafts] message arrived after we scheduled, someone
        -- already replied — skip to avoid double-posting.
        if self._gcLastGuildCraftsMsg > capturedScheduled then return end

        -- If we're an OTHER node responding at 12 s, DR and BDR both failed to
        -- answer !gc. We do NOT evict or re-elect here: a non-response only means
        -- those nodes don't have 1.1.7+ installed, not that they're dead. The
        -- heartbeat watchdog handles true DR failures independently.

        if not self.Data then return end

        -- Prefer exact key-based lookup (locale-independent) when the query
        -- came from a shift-clicked hyperlink.  Fall back to text search for
        -- plain typed queries or if the key isn't in the DB.
        local results
        if capturedRecipeKey then
            results = self.Data:SearchRecipesByKey(capturedRecipeKey)
        end
        if not results or #results == 0 then
            results = self.Data:SearchRecipes(capturedQuery)
        end
        if not results or #results == 0 then
            results = self.Data:SearchRecipes(capturedQuery, true)
        end
        if not results or #results == 0 then
            -- No match — do NOT set the cooldown so the user can retry immediately.
            SendChatMessage("[GuildCrafts] No guild crafter found for \"" .. capturedQuery .. "\" \226\128\148 /gc to browse all recipes", "GUILD")
            return
        end
        -- Successful response — stamp the cooldown now to prevent spam.
        self._gcQueryCooldowns[capturedCooldown] = time()

        -- Stagger multi-line responses 0.5 s apart to avoid "sending too quickly"
        local msgQueue = {}
        local posted = 0
        for _, result in ipairs(results) do
            if posted >= 3 then break end
            local prefix = "[GuildCrafts] " .. result.recipeName .. " (" .. result.profName .. "): "
            local line = self:FormatCraftersLine(result.crafters, prefix, 2)
            msgQueue[#msgQueue + 1] = prefix .. line
            posted = posted + 1
        end
        if #results > 3 then
            msgQueue[#msgQueue + 1] = "[GuildCrafts] +" .. (#results - 3) .. " more result(s) \226\128\148 /gc to browse"
        end
        for i, chatMsg in ipairs(msgQueue) do
            if i == 1 then
                SendChatMessage(chatMsg, "GUILD")
            else
                self:ScheduleTimer(function()
                    SendChatMessage(chatMsg, "GUILD")
                end, (i - 1) * 0.5)
            end
        end
    end, delay)
end

----------------------------------------------------------------------
-- Slash Command Handler
----------------------------------------------------------------------

function GuildCrafts:SlashHandler(input)
    input = (input or ""):trim():lower()

    if input == "" then
        -- Toggle main window
        if self.UI then
            self.UI:Toggle()
        else
            self:Print("UI module not loaded.")
        end
    elseif input == "debug" then
        self.debugMode = not self.debugMode
        self:Print("Debug mode: " .. (self.debugMode and "ON" or "OFF"))
    elseif input == "dump" then
        if self.Data then
            self.Data:DumpSummary()
        else
            self:Print("Data module not loaded.")
        end
    elseif input == "comms" then
        if self.Comms then
            self.Comms:DumpStatus()
        else
            self:Print("Comms module not loaded.")
        end
    elseif input == "mem" then
        UpdateAddOnMemoryUsage()
        local mem = GetAddOnMemoryUsage(ADDON_NAME)
        self:Printf("Memory: %.1f KB (%.2f MB)", mem, mem / 1024)
    elseif input == "reset" then
        self:Print("Wiping all SavedVariables and reloading...")
        GuildCraftsDB = nil
        ReloadUI()
    elseif input == "minimap" then
        if self.MinimapButton then
            self.MinimapButton:Toggle()
        else
            self:Print("MinimapButton module not loaded.")
        end
    else
        self:Print("Commands: /gc, /gc debug, /gc dump, /gc comms, /gc mem, /gc minimap, /gc reset")
    end
end

----------------------------------------------------------------------
-- Utility: Debug print
----------------------------------------------------------------------

function GuildCrafts:Debug(...)
    if self.debugMode then
        self:Print("|cff888888[debug]|r", ...)
    end
end

function GuildCrafts:Printf(fmt, ...)
    self:Print(string.format(fmt, ...))
end
