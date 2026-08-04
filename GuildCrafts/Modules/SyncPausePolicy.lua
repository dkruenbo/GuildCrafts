----------------------------------------------------------------------
-- GuildCrafts — SyncPausePolicy.lua
-- Suspends all outgoing sync traffic during high-activity game states
-- where addon channel messages are likely to be dropped or throttled.
--
-- Pause conditions:
--   • In combat (InCombatLockdown) — cleared 6s after PLAYER_REGEN_ENABLED
--   • Inside an instance (IsInInstance) — cleared 15s after zone-in
--   • Zone transition in progress — cleared 12s after PLAYER_ENTERING_WORLD
--
-- Public API:
--   GuildCrafts.SyncPausePolicy:ShouldPause() → boolean
----------------------------------------------------------------------
local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)
local GuildCrafts = _G.GuildCrafts

local SyncPausePolicy = GuildCrafts:NewModule("SyncPausePolicy", "AceEvent-3.0", "AceTimer-3.0")
GuildCrafts.SyncPausePolicy = SyncPausePolicy

-- Grace period durations (seconds)
local GRACE_COMBAT     =  6   -- after PLAYER_REGEN_ENABLED
local GRACE_INSTANCE   = 15   -- after entering/leaving an instance
local GRACE_TRANSITION = 12   -- after any non-login PLAYER_ENTERING_WORLD

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

function SyncPausePolicy:OnInitialize()
    -- Each flag is set to true while the corresponding condition is active
    -- (including its grace period).  ShouldPause returns true if any is set.
    self._inCombat     = false
    self._inInstance   = false
    self._inTransition = false

    -- Active grace timers (cancelled if condition re-triggers before expiry)
    self._combatTimer     = nil
    self._instanceTimer   = nil
    self._transitionTimer = nil
end

function SyncPausePolicy:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_ENABLED",  "OnCombatEnd")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneEnter")

    -- Capture the initial state at login (combat is theoretically possible
    -- on PvP servers via world PvP, though unlikely on login).
    if InCombatLockdown() then
        self._inCombat = true
    end
    local inInstance = IsInInstance and select(1, IsInInstance())
    if inInstance then
        self._inInstance = true
    end
end

----------------------------------------------------------------------
-- Event Handlers
----------------------------------------------------------------------

function SyncPausePolicy:OnCombatStart()
    -- Cancel any pending grace-off timer so we don't clear the flag too early
    if self._combatTimer then
        self:CancelTimer(self._combatTimer)
        self._combatTimer = nil
    end
    self._inCombat = true
    GuildCrafts:Debug("SyncPausePolicy: combat started — sync paused")
end

function SyncPausePolicy:OnCombatEnd()
    if self._combatTimer then
        self:CancelTimer(self._combatTimer)
    end
    self._combatTimer = self:ScheduleTimer(function()
        self._inCombat    = false
        self._combatTimer = nil
        GuildCrafts:Debug("SyncPausePolicy: combat grace expired — sync resumed")
    end, GRACE_COMBAT)
    GuildCrafts:Debug("SyncPausePolicy: combat ended — grace timer started")
end

function SyncPausePolicy:OnZoneEnter(_, isLogin)
    -- Zone transition: always apply the short grace period
    if self._transitionTimer then
        self:CancelTimer(self._transitionTimer)
    end
    if not isLogin then
        self._inTransition = true
        self._transitionTimer = self:ScheduleTimer(function()
            self._inTransition   = false
            self._transitionTimer = nil
            GuildCrafts:Debug("SyncPausePolicy: zone-transition grace expired — sync resumed")
        end, GRACE_TRANSITION)
        GuildCrafts:Debug("SyncPausePolicy: zone transition detected — sync paused")
    end

    -- Instance check: apply the longer grace period when entering or leaving
    local inInstance = IsInInstance and select(1, IsInInstance())
    if self._instanceTimer then
        self:CancelTimer(self._instanceTimer)
    end
    if inInstance then
        self._inInstance = true
        -- No grace timer while still inside — stays paused until next zone-in
        GuildCrafts:Debug("SyncPausePolicy: inside instance — sync paused")
    else
        -- Just left an instance (or logged in outside one).
        -- Apply grace period before allowing sync traffic.
        self._instanceTimer = self:ScheduleTimer(function()
            self._inInstance   = false
            self._instanceTimer = nil
            GuildCrafts:Debug("SyncPausePolicy: instance grace expired — sync resumed")
        end, GRACE_INSTANCE)
    end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Returns true if outgoing sync messages should be suppressed right now.
function SyncPausePolicy:ShouldPause()
    return self._inCombat or self._inInstance or self._inTransition
end
