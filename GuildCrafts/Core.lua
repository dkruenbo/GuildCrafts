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

-- Addon version (parsed from .toc at runtime, fallback to hardcoded)
GuildCrafts.VERSION = 1
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
    local clientInterface = select(4, GetBuildInfo()) or "unknown"
    self:Print("v" .. self.VERSION .. " loaded (client Interface: " .. clientInterface .. "). Type /gc to open.")
end

function GuildCrafts:OnEnable()
    -- Called after all addons have loaded (PLAYER_LOGIN equivalent).
    -- Register game events.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    -- Enchanting in Classic TBC uses CRAFT_SHOW, not TRADE_SKILL_SHOW
    self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
end

function GuildCrafts:OnDisable()
    -- Called if the addon is disabled (rarely used).
end

----------------------------------------------------------------------
-- Event Handlers
----------------------------------------------------------------------

function GuildCrafts:OnPlayerEnteringWorld(event, isLogin, isReload)
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

    -- Remind the player to open profession windows so recipes get scanned
    self:Print("Open each profession window once so GuildCrafts can scan your recipes.")
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
    elseif input:sub(1, 3) == "sim" then
        local simArg = input:sub(5):trim()
        if self.Data then
            self.Data:HandleSimCommand(simArg)
        else
            self:Print("Data module not loaded.")
        end
    elseif input == "minimap" then
        if self.MinimapButton then
            self.MinimapButton:Toggle()
        else
            self:Print("MinimapButton module not loaded.")
        end
    else
        self:Print("Commands: /gc, /gc debug, /gc dump, /gc comms, /gc mem, /gc sim <N>, /gc minimap, /gc reset")
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
