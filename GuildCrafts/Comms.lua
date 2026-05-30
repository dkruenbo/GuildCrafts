----------------------------------------------------------------------
-- GuildCrafts — Comms.lua
-- Guild addon channel sync: HELLO, HEARTBEAT, DR/BDR election,
-- SYNC_REQUEST / SYNC_RESPONSE / SYNC_PULL / SYNC_PUSH,
-- DELTA_UPDATE, CRAFT_* messages
----------------------------------------------------------------------
local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)
local GuildCrafts = _G.GuildCrafts

-- Create the Comms module (AceComm mixin for send/receive)
local Comms = GuildCrafts:NewModule("Comms", "AceComm-3.0", "AceSerializer-3.0", "AceTimer-3.0")
GuildCrafts.Comms = Comms

-- Libraries (defensive: pcall in case LibDeflate failed to load)
local _ok, LibDeflate = pcall(LibStub, "LibDeflate")
if not _ok or not LibDeflate then
    LibDeflate = nil
end

-- Local references
local time = time
local pairs = pairs
local ipairs = ipairs
local type = type
local table_sort = table.sort

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local PREFIX = "GuildCrafts"

-- Timing (seconds)
local HELLO_DELAY          = 3       -- delay after login before sending HELLO
local SYNC_DELAY           = 15      -- delay after HELLO before SYNC_REQUEST
local HEARTBEAT_INTERVAL   = 60      -- DR heartbeat broadcast interval
local HEARTBEAT_TIMEOUT    = 180     -- 3 missed heartbeats → DR presumed dead
local SYNC_TIMEOUT         = 120     -- wait for SYNC_RESPONSE before retry
local SYNC_RETRY_TIMEOUT   = 15      -- wait for retry response before open round
local SYNC_CHUNK_SIZE      = 5       -- max members per sync chunk
local SYNC_CHUNK_DELAY     = 1.0     -- seconds between chunks (avoids burst lag)

-- ChatThrottleLib priorities
local PRIO_BULK   = "BULK"
local PRIO_NORMAL = "NORMAL"

-- Message types
local MSG_HELLO              = "HELLO"
local MSG_HEARTBEAT          = "HEARTBEAT"
local MSG_DELTA_UPDATE       = "DELTA_UPDATE"
local MSG_DELTA_AD           = "DELTA_AD"
local MSG_SYNC_REQUEST       = "SYNC_REQUEST"
local MSG_SYNC_RESPONSE      = "SYNC_RESPONSE"
local MSG_SYNC_PULL          = "SYNC_PULL"
local MSG_SYNC_PUSH          = "SYNC_PUSH"
local MSG_SYNC_RESUME        = "SYNC_RESUME"

-- Chunk RESUME
local PROGRESS_TIMEOUT     = 4    -- seconds without chunk progress before sending RESUME
local SESSION_TTL          = 35   -- seconds to keep an outbound session for RESUME requests
local MAX_RESUME_ATTEMPTS  = 3    -- max RESUME requests per transfer before falling back

-- AD: jitter range for targeted sync pull triggered by DELTA_AD receipt
local AD_JITTER_MIN = 1
local AD_JITTER_MAX = 5

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

function Comms:OnInitialize()
    -- Addon user list: { ["Name-Realm"] = { version = N, lastSeen = timestamp } }
    self.addonUsers = {}

    -- DR/BDR
    self.currentDR  = nil    -- "Name-Realm"
    self.currentBDR = nil    -- "Name-Realm"
    self.myRole     = "NONE" -- "DR", "BDR", "OTHER", "NONE"

    -- Heartbeat
    self.heartbeatTimer   = nil
    self.drWatchdogTimer  = nil
    self.lastDRHeartbeat  = 0

    -- Sync state
    self.syncPending          = false
    self.syncRetryCount       = 0
    self.syncTimer            = nil
    self._postSyncHelloDone   = false
    self.lastSyncCompletedAt  = nil  -- set when a full SYNC_RESPONSE is received

    -- Term: incremented each time this client is promoted to DR.
    -- Carried in every outgoing message so stale authority can be detected.
    self.currentTerm = 0

    -- DR request queue (when we are DR)
    self.syncQueue         = {}
    self.syncProcessing    = false

    -- Pending re-sync debounce timer (shared across HandleHello / TouchAddonUser / RecomputeElection)
    self._pendingSyncTimer = nil

    -- BroadcastHello pause-reschedule timer (tracked so we never accumulate duplicates)
    self._helloRescheduleTimer = nil

    -- Per-peer failure tracking for sync backoff.
    -- Incremented on each SYNC_TIMEOUT; cleared on a successful SYNC_RESPONSE.
    -- Prevents premature DR eviction during transient unresponsiveness.
    -- { ["Name-Realm"] = { count = N, lastFailedAt = timestamp } }
    self.peerFailures = {}

    -- Snapshots of DR/BDR captured at the moment each SYNC_REQUEST is sent.
    -- OnSyncTimeout uses these instead of self.currentDR/BDR so that a
    -- mid-flight RecomputeElection (e.g. from CheckDRAlive) does not cause
    -- failure marks or evictions to land on a newly elected, untested peer.
    self._syncTargetedDR          = nil
    self._syncTargetedBDR         = nil
    self._syncLastEffectiveRetry  = 0

    -- Chunk RESUME: outbound sessions keyed by sessionId (sender side)
    -- Each entry: { chunks = {[idx] = chunkPayload}, target = "Name-Realm" }
    self._outboundSessions = {}

    -- Chunk RESUME: partial receive state keyed by sessionId (receiver side)
    -- Each entry: { seen = {[idx]=true}, total = N, resumeAttempts = N, sender, progressTimer }
    self._partialReceive = {}

    -- Registered flag
    self._prefixRegistered = false
end

function Comms:OnEnable()
    -- Register the addon message prefix
    if not self._prefixRegistered then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        self._prefixRegistered = true
    end

    -- Register for AceComm messages
    self:RegisterComm(PREFIX, "OnCommReceived")
end

----------------------------------------------------------------------
-- Login Ready (called from Core.lua after 5s delay)
----------------------------------------------------------------------

function Comms:OnLoginReady()
    if not IsInGuild() then return end

    local playerKey = GuildCrafts.Data:GetPlayerKey()

    -- Add self to user list
    self.addonUsers[playerKey] = {
        version  = GuildCrafts.VERSION,
        lastSeen = time(),
    }

    -- Broadcast HELLO after a short delay
    self:ScheduleTimer("BroadcastHello", HELLO_DELAY)
end

----------------------------------------------------------------------
-- HELLO
----------------------------------------------------------------------

function Comms:BroadcastHello()
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("BroadcastHello delayed (SyncPausePolicy) — rescheduling in 5s")
        -- Cancel any existing reschedule timer before creating a new one so that
        -- a long pause doesn't accumulate N timers that all fire on unpause.
        if self._helloRescheduleTimer then
            self:CancelTimer(self._helloRescheduleTimer)
        end
        self._helloRescheduleTimer = self:ScheduleTimer("BroadcastHello", 5)
        return
    end
    self._helloRescheduleTimer = nil
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_HELLO, {
        sender  = playerKey,
        version = GuildCrafts.VERSION,
    }, "GUILD")

    GuildCrafts:Debug("Sent HELLO as", playerKey)

    -- Schedule SYNC_REQUEST after HELLO has had time to propagate
    self:ScheduleTimer("SendSyncRequest", SYNC_DELAY - HELLO_DELAY)
end

function Comms:HandleHello(payload, sender)
    local memberKey = payload.sender or sender
    if not memberKey then return end

    local isNew = not self.addonUsers[memberKey]

    self.addonUsers[memberKey] = {
        version  = payload.version or 1,
        lastSeen = time(),
    }

    GuildCrafts:Debug("HELLO from", memberKey, "v" .. (payload.version or "?"))
    self:RecomputeElection()

    -- Sync indicator depends on addonUsers count — update it immediately so
    -- the DR (which skips SYNC_REQUEST and never gets a Refresh via sync path)
    -- shows the correct status as soon as a new user is discovered.
    if isNew and GuildCrafts.UI and GuildCrafts.UI.UpdateSyncIndicator then
        GuildCrafts.UI:UpdateSyncIndicator()
    end

    -- Reply with our own HELLO so the sender discovers us too.
    -- Reply if:
    --   (a) sender is new to us and didn't send a plain reply (normal discovery), OR
    --   (b) sender explicitly asked for replies via discover=true (post-sync sweep)
    -- Always use isReply=true in the response to prevent further cascading.
    -- Add random jitter (0.5–4.0 s) to avoid a thundering-herd broadcast storm
    -- when many clients reply to the same HELLO simultaneously.
    local wantReply = (isNew and not payload.isReply) or (payload.discover and not payload.isReply)
    if wantReply then
        local playerKey = GuildCrafts.Data:GetPlayerKey()
        if memberKey ~= playerKey then
            local jitter = 0.5 + math.random() * 3.5  -- 0.5 – 4.0 s
            self:ScheduleTimer(function()
                self:SendMessage(MSG_HELLO, {
                    sender  = playerKey,
                    version = GuildCrafts.VERSION,
                    isReply = true,
                }, "GUILD")
                GuildCrafts:Debug("Sent HELLO reply to", memberKey)
            end, jitter)
        end
    end

    -- Trigger a sync whenever we discover a new addon user.
    -- This handles late logins, reconnects, and the initial race where
    -- the first SYNC_REQUEST fires before any HELLO replies arrive.
    -- Debounced: cancels any pending re-sync timer before scheduling a new one
    -- so multiple discoveries in quick succession collapse into a single sync.
    if isNew and not self.syncPending then
        self.syncRetryCount = 0
        if self._pendingSyncTimer then
            self:CancelTimer(self._pendingSyncTimer)
        end
        self._pendingSyncTimer = self:ScheduleTimer(function()
            self._pendingSyncTimer = nil
            self:SendSyncRequest()
        end, 10)
        GuildCrafts:Debug("Scheduling re-sync after discovering", memberKey)
    end
end

----------------------------------------------------------------------
-- Ensure a node is in addonUsers (called on any inbound message)
----------------------------------------------------------------------

--- Add or refresh the given key in addonUsers.
--- Re-elects only when the key is brand new (avoids spurious churn).
function Comms:TouchAddonUser(key, version)
    if not key then return end
    local isNew = not self.addonUsers[key]
    if isNew then
        self.addonUsers[key] = {
            version  = version or 1,
            lastSeen = time(),
        }
        GuildCrafts:Debug("TouchAddonUser: discovered", key)
        self:RecomputeElection()
        -- If this demoted us from a false-DR election, RecomputeElection
        -- already scheduled a sync. If we're still non-DR and haven't synced,
        -- schedule one now (covers SYNC_REQUEST / SYNC_RESPONSE discovery paths).
        -- Debounced: collapses multiple rapid discoveries into a single sync.
        if self.myRole ~= "DR" and not self.syncPending then
            self.syncRetryCount = 0
            if self._pendingSyncTimer then
                self:CancelTimer(self._pendingSyncTimer)
            end
            self._pendingSyncTimer = self:ScheduleTimer(function()
                self._pendingSyncTimer = nil
                self:SendSyncRequest()
            end, 10)
        end
    else
        self.addonUsers[key].lastSeen = time()
    end
end

----------------------------------------------------------------------
-- DR / BDR Election
----------------------------------------------------------------------

function Comms:RecomputeElection()
    local sorted = {}
    for key, _ in pairs(self.addonUsers) do
        sorted[#sorted + 1] = key
    end
    table_sort(sorted)

    local oldRole = self.myRole
    local playerKey = GuildCrafts.Data:GetPlayerKey()

    self.currentDR  = sorted[1] or nil
    self.currentBDR = sorted[2] or nil

    if playerKey == self.currentDR then
        self.myRole = "DR"
    elseif playerKey == self.currentBDR then
        self.myRole = "BDR"
    elseif self.currentDR then
        self.myRole = "OTHER"
    else
        self.myRole = "NONE"
    end

    -- Log role change
    if self.myRole ~= oldRole then
        if self.myRole == "DR" then
            GuildCrafts:Debug("You are now the Designated Router (DR).")
            self.currentTerm = self.currentTerm + 1
            GuildCrafts:Debug("DR term advanced to", self.currentTerm)
            self:StartHeartbeat()
        elseif self.myRole == "BDR" then
            GuildCrafts:Debug("You are now the Backup Designated Router (BDR).")
            self:StopHeartbeat()
        else
            self:StopHeartbeat()
        end

        GuildCrafts:Debug("Role changed:", oldRole, "→", self.myRole,
            "| DR:", self.currentDR or "none",
            "| BDR:", self.currentBDR or "none")

        -- If we were falsely elected DR (only self was known when SendSyncRequest
        -- fired) and have now been demoted by discovering the real DR, schedule
        -- a fresh sync so we get the guild data we skipped earlier.
        -- Debounced for consistency with other re-sync scheduling points.
        if oldRole == "DR" and self.myRole ~= "DR" and not self.syncPending then
            self.syncRetryCount = 0
            if self._pendingSyncTimer then
                self:CancelTimer(self._pendingSyncTimer)
            end
            self._pendingSyncTimer = self:ScheduleTimer(function()
                self._pendingSyncTimer = nil
                self:SendSyncRequest()
            end, 10)
            GuildCrafts:Debug("Was false-DR, now demoted — scheduling sync with real DR")
        end
    end

    -- Always ensure DR watchdog is running if we're not DR
    if self.myRole ~= "DR" and self.currentDR then
        self:StartDRWatchdog()
    else
        self:StopDRWatchdog()
    end
end

----------------------------------------------------------------------
-- Heartbeat (DR only)
----------------------------------------------------------------------

function Comms:StartHeartbeat()
    self:StopHeartbeat()
    -- Send immediately, then on interval
    self:SendHeartbeat()
    self.heartbeatTimer = self:ScheduleRepeatingTimer("SendHeartbeat", HEARTBEAT_INTERVAL)
end

function Comms:StopHeartbeat()
    if self.heartbeatTimer then
        self:CancelTimer(self.heartbeatTimer)
        self.heartbeatTimer = nil
    end
end

function Comms:SendHeartbeat()
    if self.myRole ~= "DR" then
        self:StopHeartbeat()
        return
    end
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_HEARTBEAT, {
        dr        = playerKey,
        timestamp = time(),
    }, "GUILD")
    GuildCrafts:Debug("Sent HEARTBEAT")
end

function Comms:HandleHeartbeat(payload)
    -- Register the sender in addonUsers BEFORE election logic so that
    -- RecomputeElection() always has complete peer information.
    if payload.dr then
        self.lastDRHeartbeat = time()
        if not self.addonUsers[payload.dr] then
            self.addonUsers[payload.dr] = {
                version  = 1,
                lastSeen = time(),
            }
        else
            self.addonUsers[payload.dr].lastSeen = time()
        end
    end

    -- Drop heartbeats from stale DRs. Term adoption already happened in the
    -- OnReceive dispatcher, so payload.term == currentTerm for the current
    -- authority and < currentTerm for superseded ones.
    if payload.term and payload.term < self.currentTerm then
        GuildCrafts:Debug("Dropping stale HEARTBEAT (term", payload.term, "< current", self.currentTerm, ")")
        return
    end

    -- Always recompute after a valid heartbeat so currentDR/BDR stay accurate
    -- in the sync panel and role change log.
    self:RecomputeElection()
    if GuildCrafts.UI and GuildCrafts.UI.UpdateSyncIndicator then
        GuildCrafts.UI:UpdateSyncIndicator()
    end
end

----------------------------------------------------------------------
-- DR Watchdog (non-DR nodes)
----------------------------------------------------------------------

function Comms:StartDRWatchdog()
    self:StopDRWatchdog()
    self.lastDRHeartbeat = time() -- assume alive now
    self.drWatchdogTimer = self:ScheduleRepeatingTimer("CheckDRAlive", HEARTBEAT_INTERVAL)
end

function Comms:StopDRWatchdog()
    if self.drWatchdogTimer then
        self:CancelTimer(self.drWatchdogTimer)
        self.drWatchdogTimer = nil
    end
end

function Comms:CheckDRAlive()
    if self.myRole == "DR" then
        self:StopDRWatchdog()
        return
    end

    -- GUILD addon messages are not delivered while inside an instance or arena.
    -- Suppress the DR eviction timer so we don't falsely elect ourselves just
    -- because we temporarily can't receive heartbeats.
    local inInstance = IsInInstance and select(1, IsInInstance())
    if inInstance then
        self.lastDRHeartbeat = time()  -- keep the timer fresh
        return
    end

    local elapsed = time() - self.lastDRHeartbeat
    if elapsed > HEARTBEAT_TIMEOUT and self.currentDR then
        GuildCrafts:Debug("DR heartbeat timeout — removing", self.currentDR)
        self.addonUsers[self.currentDR] = nil
        self:RecomputeElection()
    end
end

----------------------------------------------------------------------
-- Guild Roster Update (called from Core.lua)
----------------------------------------------------------------------

function Comms:OnGuildRosterUpdate()
    -- Online-status cache is already rebuilt by Core.lua before this is called.
    -- Addon user expiry is handled solely by the DR heartbeat watchdog (180 s),
    -- which is reliable. Roster-based eviction was removed because
    -- GetGuildRosterInfo isOnline flags are unreliable at login and cause
    -- valid addon users to be prematurely evicted.
end

----------------------------------------------------------------------
-- SYNC_REQUEST
----------------------------------------------------------------------

function Comms:SendSyncRequest()
    if not IsInGuild() then return end
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("SendSyncRequest delayed (SyncPausePolicy) — rescheduling in 10s")
        if self.syncTimer then self:CancelTimer(self.syncTimer) end
        self.syncTimer = self:ScheduleTimer("SendSyncRequest", 10)
        self.syncPending = true  -- prevent duplicate sync chains while deferred
        return
    end

    local playerKey = GuildCrafts.Data:GetPlayerKey()

    -- If we are the DR, nobody will respond to our request (we skip our
    -- own messages in HandleSyncRequest). Mark sync as complete — the DR
    -- already accumulates all data by processing everyone else's requests.
    if self.myRole == "DR" then
        GuildCrafts:Debug("We are DR — skipping SYNC_REQUEST (already authoritative)")
        self.syncPending = false
        self.syncRetryCount = 0
        if self.syncTimer then
            self:CancelTimer(self.syncTimer)
            self.syncTimer = nil
        end
        -- DR never receives a SYNC_RESPONSE, so UI:Refresh() is never triggered
        -- by the sync path. Update the sync indicator directly so the dot
        -- reflects the correct addonUsers count (the re-sync was scheduled from
        -- HandleHello after a new peer was discovered).
        if GuildCrafts.UI and GuildCrafts.UI.UpdateSyncIndicator then
            GuildCrafts.UI:UpdateSyncIndicator()
        end
        return
    end

    local vector = GuildCrafts.Data:GetVersionVector()

    -- If the DR is in backoff (≥2 recent failures within 45 s), promote the
    -- effective retry to 1 so the BDR responds immediately rather than waiting
    -- for a full SYNC_TIMEOUT before escalating.
    local effectiveRetry = self.syncRetryCount
    if effectiveRetry == 0 and self.currentDR and self:IsPeerBackedOff(self.currentDR) then
        effectiveRetry = 1
        GuildCrafts:Debug("DR", self.currentDR, "is in backoff — SYNC_REQUEST retry=1 (targeting BDR)")
    end

    -- Snapshot who we are targeting so OnSyncTimeout can attribute a failure
    -- to the correct peer even if currentDR/BDR change before the timer fires.
    self._syncTargetedDR          = self.currentDR
    self._syncTargetedBDR         = self.currentBDR
    self._syncLastEffectiveRetry  = effectiveRetry

    self:SendMessage(MSG_SYNC_REQUEST, {
        sender = playerKey,
        vector = vector,
        retry  = effectiveRetry,
    }, "GUILD")

    self.syncPending = true
    GuildCrafts:Debug("Sent SYNC_REQUEST (retry=" .. effectiveRetry .. ")")

    -- Use effectiveRetry (not syncRetryCount) for the timeout so that a
    -- DR-backoff-promoted retry=1 gets SYNC_RETRY_TIMEOUT (15 s) rather than
    -- the full 120 s SYNC_TIMEOUT that would otherwise apply at syncRetryCount=0.
    if self.syncTimer then
        self:CancelTimer(self.syncTimer)
    end
    local timeout = (effectiveRetry == 0) and SYNC_TIMEOUT or SYNC_RETRY_TIMEOUT
    self.syncTimer = self:ScheduleTimer("OnSyncTimeout", timeout)
end

function Comms:OnSyncTimeout()
    if not self.syncPending then return end

    -- Clear any pending RESUME state — the full retry will start fresh.
    self._partialReceive = {}

    self.syncRetryCount = self.syncRetryCount + 1

    if self.syncRetryCount == 1 then
        -- Attribute the failure to the peer that was actually targeted.
        -- If the DR was in backoff (effectiveRetry was promoted to 1), the BDR
        -- was the expected responder and should receive the failure mark.
        -- Use the captured snapshot to avoid marking a newly elected peer that
        -- replaced the real non-responder mid-flight.
        local failedPeer = (self._syncLastEffectiveRetry == 1)
            and self._syncTargetedBDR or self._syncTargetedDR
        if failedPeer then self:MarkPeerFailure(failedPeer) end
        GuildCrafts:Debug("SYNC_REQUEST timeout — retrying (BDR should respond)")
        self:SendSyncRequest()
    elseif self.syncRetryCount == 2 then
        -- The retry=1 request targeted the BDR — record its failure.
        -- Use the snapshot captured when that request was sent.
        if self._syncTargetedBDR then self:MarkPeerFailure(self._syncTargetedBDR) end
        local playerKey = GuildCrafts.Data:GetPlayerKey()
        -- Use snapshot peers for eviction so a mid-flight RecomputeElection
        -- does not cause us to evict a newly elected DR that was never tested.
        -- Also skip peers still inside the backoff window.
        local function shouldEvict(key)
            return key and key ~= playerKey and not self:IsPeerBackedOff(key)
        end
        local evicted = false
        if shouldEvict(self._syncTargetedDR)  then self.addonUsers[self._syncTargetedDR]  = nil; evicted = true end
        if shouldEvict(self._syncTargetedBDR) then self.addonUsers[self._syncTargetedBDR] = nil; evicted = true end
        self:RecomputeElection()
        if evicted then
            GuildCrafts:Debug("SYNC_REQUEST retry timeout — evicted unresponsive peers, re-elected. New DR:", self.currentDR or "none")
        else
            GuildCrafts:Debug("SYNC_REQUEST retry timeout — DR/BDR in backoff (not evicted), trying open round")
        end
        self:SendSyncRequest()
    else
        GuildCrafts:Debug("SYNC_REQUEST all retries exhausted. No responder available.")
        self.syncPending = false
        self.syncRetryCount = 0
    end
end

function Comms:HandleSyncRequest(payload, sender)
    local requester = payload.sender or sender
    local retryCount = payload.retry or 0
    local playerKey = GuildCrafts.Data:GetPlayerKey()

    -- Don't respond to our own requests
    if requester == playerKey then return end

    -- Any SYNC_REQUEST proves the sender is online with the addon.
    self:TouchAddonUser(requester)

    -- Decide whether we should respond based on role and retry count
    local shouldRespond = false
    if retryCount == 0 and self.myRole == "DR" then
        shouldRespond = true
    elseif retryCount == 1 and (self.myRole == "DR" or self.myRole == "BDR") then
        shouldRespond = true
    elseif retryCount >= 2 then
        -- DR and BDR both failed to respond — evict and re-elect.
        -- Only the newly elected DR responds, preventing a flood.
        -- Skip eviction for peers still inside the backoff window — they may be
        -- transiently slow. Peers with count < 2 (not yet in backoff) are evicted
        -- as before.
        local function shouldEvict(key)
            return key and key ~= playerKey and not self:IsPeerBackedOff(key)
        end
        if shouldEvict(self.currentDR)  then self.addonUsers[self.currentDR]  = nil end
        if shouldEvict(self.currentBDR) then self.addonUsers[self.currentBDR] = nil end
        self:RecomputeElection()
        if self.myRole == "DR" then
            shouldRespond = true
        end
    end

    if not shouldRespond then return end

    GuildCrafts:Debug("Handling SYNC_REQUEST from", requester, "(role:", self.myRole, ")")

    -- Queue if we're already processing a sync (DR queuing)
    if self.syncProcessing then
        self.syncQueue[#self.syncQueue + 1] = { requester = requester, vector = payload.vector }
        GuildCrafts:Debug("Queued SYNC_REQUEST from", requester, "(queue size:", #self.syncQueue, ")")
        return
    end

    self:ProcessSyncRequest(requester, payload.vector or {})
end

function Comms:ProcessSyncRequest(requester, incomingVector)
    self.syncProcessing = true

    local localVector = GuildCrafts.Data:GetVersionVector()
    local db = GuildCrafts.Data:GetGuildDB()
    if not db then
        self.syncProcessing = false
        return
    end

    -- Compute what we need to send (DR ahead) and what we need to pull (requester ahead)
    local toSend = {}   -- member entries where DR is ahead or requester doesn't have
    local toPull = {}   -- member keys where requester is ahead

    -- Check our entries vs incoming vector
    for memberKey, localTs in pairs(localVector) do
        local incomingTs = incomingVector[memberKey]
        if not incomingTs or localTs > incomingTs then
            -- We have newer data → include in SYNC_RESPONSE (stripped)
            toSend[memberKey] = GuildCrafts.Data:StripSyncFields(db[memberKey])
        end
    end

    -- Check incoming vector for entries we don't have or are behind on
    for memberKey, incomingTs in pairs(incomingVector) do
        local localTs = localVector[memberKey]
        if not localTs or incomingTs > localTs then
            -- Requester has newer data → request via SYNC_PULL
            toPull[#toPull + 1] = memberKey
        elseif localTs == incomingTs then
            -- Timestamps match — check if our local copy is in an old data format
            local localEntry = db[memberKey]
            if localEntry and (localEntry.dataFormat or 0) < GuildCrafts.DATA_FORMAT_VERSION then
                toPull[#toPull + 1] = memberKey
                GuildCrafts:Debug("Format upgrade pull for", memberKey,
                    "(local format", localEntry.dataFormat or 0, "< current", GuildCrafts.DATA_FORMAT_VERSION, ")")
            end
        end
    end

    -- Send SYNC_RESPONSE in chunks to avoid chat throttle issues
    local sendCount = 0
    for _ in pairs(toSend) do sendCount = sendCount + 1 end

    -- Callback fired once all chunks have been sent (or immediately if no chunks).
    -- Clears syncProcessing so the queue can proceed. Defined before SendChunked so
    -- the closure is available regardless of the code path taken below.
    local function onSendComplete()
        self.syncProcessing = false
        self:ProcessNextSyncQueue()
    end

    if sendCount > 0 then
        -- Pass onComplete so syncProcessing is cleared only after the last chunk
        -- fires, not immediately after SendChunked returns. Without this, a queued
        -- SYNC_REQUEST could start while previous chunks are still in-flight.
        self:SendChunked(MSG_SYNC_RESPONSE, toSend, requester, sendCount, onSendComplete)
    else
        -- Always send at least an empty SYNC_RESPONSE so the requester
        -- knows we heard them and can stop waiting (otherwise they time out).
        self:SendMessage(MSG_SYNC_RESPONSE, {
            data       = {},
            chunkIndex = 1,
            chunkTotal = 1,
        }, "WHISPER", requester, PRIO_NORMAL)
    end

    -- Send SYNC_PULL if requester has data we need
    if #toPull > 0 then
        GuildCrafts:Debug("Sending SYNC_PULL to", requester, "(" .. #toPull .. " member keys)")
        self:SendMessage(MSG_SYNC_PULL, {
            memberKeys = toPull,
        }, "WHISPER", requester, PRIO_NORMAL)
    end

    if sendCount == 0 and #toPull == 0 then
        GuildCrafts:Debug("Sync with", requester, "— already converged.")
    end

    -- If there were no chunks to send, mark complete immediately.
    -- Otherwise onSendComplete will fire after the last chunk.
    if sendCount == 0 then
        onSendComplete()
    end
end

function Comms:ProcessNextSyncQueue()
    if #self.syncQueue > 0 then
        local next = table.remove(self.syncQueue, 1)
        GuildCrafts:Debug("Processing queued SYNC_REQUEST from", next.requester)
        self:ProcessSyncRequest(next.requester, next.vector)
    end
end

----------------------------------------------------------------------
-- Per-Peer Backoff
----------------------------------------------------------------------

--- Record a sync failure for a peer (called on SYNC_TIMEOUT).
function Comms:MarkPeerFailure(key)
    if not key then return end
    local pf = self.peerFailures[key] or { count = 0, lastFailedAt = 0 }
    pf.count = pf.count + 1
    pf.lastFailedAt = time()
    self.peerFailures[key] = pf
    GuildCrafts:Debug("Peer failure recorded for", key, "(count:", pf.count, ")")
end

--- Clear the failure record after a successful sync interaction.
function Comms:MarkPeerSuccess(key)
    if not key then return end
    if self.peerFailures[key] then
        GuildCrafts:Debug("Peer success — cleared backoff for", key)
        self.peerFailures[key] = nil
    end
end

--- Returns true if a peer should be bypassed this cycle.
--- Threshold: ≥2 failures with the most recent one within the last 45 s.
--- Also prunes entries whose backoff window has fully decayed to keep the
--- peerFailures table bounded across long sessions.
function Comms:IsPeerBackedOff(key)
    if not key then return false end
    local pf = self.peerFailures[key]
    if not pf then return false end
    if pf.count >= 2 and (time() - pf.lastFailedAt) < 45 then
        return true
    end
    -- Backoff window has expired — remove the entry so the table doesn't
    -- grow indefinitely as guild members come and go over a long session.
    if pf.count >= 2 then
        self.peerFailures[key] = nil
    end
    return false
end

----------------------------------------------------------------------
-- SYNC_RESPONSE (received by requester)
----------------------------------------------------------------------

function Comms:HandleSyncResponse(payload, sender)
    if not payload.data then return end

    -- Term enforcement: discard sync data from a superseded DR.
    if payload.term and payload.term < self.currentTerm then
        GuildCrafts:Debug("Dropping stale SYNC_RESPONSE from", sender,
            "(term", payload.term, "< current", self.currentTerm, ")")
        return
    end
    -- Adopt a higher term seen in a sync response (DR may have replied
    -- before we received its first heartbeat).
    if payload.term and payload.term > self.currentTerm then
        self.currentTerm = payload.term
        GuildCrafts:Debug("Adopted higher term", self.currentTerm, "from SYNC_RESPONSE")
    end

    -- The node that responded is definitely online with the addon.
    self:TouchAddonUser(sender)

    -- Merge this chunk's data immediately (each chunk contains distinct member keys).
    local merged = GuildCrafts.Data:MergeIncoming(payload.data)
    GuildCrafts:Debug("Received SYNC_RESPONSE chunk", (payload.chunkIndex or 1),
        "/", (payload.chunkTotal or 1), "from", sender, "— merged:", tostring(merged))

    -- RESUME path: sender included a sessionId so we can recover dropped chunks.
    local sessionId = payload.sessionId
    if sessionId then
        local pr = self._partialReceive[sessionId]
        if not pr then
            -- Guard: if sync is no longer pending (session already finalized), this
            -- is a late/duplicate chunk arriving after we already completed the
            -- transfer. Drop it to prevent recreating a stale _partialReceive entry
            -- that would arm new progress timers and send spurious RESUME messages.
            if not self.syncPending then return end
            pr = {
                seen           = {},
                total          = payload.chunkTotal or 1,
                resumeAttempts = 0,
                sender         = sender,
                progressTimer  = nil,
            }
            self._partialReceive[sessionId] = pr
        end
        -- Cancel existing progress timer — we just received a chunk.
        if pr.progressTimer then
            self:CancelTimer(pr.progressTimer)
            pr.progressTimer = nil
        end
        pr.seen[payload.chunkIndex or 1] = true

        -- Also reset the main sync timeout to give the RESUME process room to work.
        if self.syncTimer then self:CancelTimer(self.syncTimer) end
        self.syncTimer = self:ScheduleTimer("OnSyncTimeout", SYNC_TIMEOUT)

        -- Count received chunks.
        local receivedCount = 0
        for _ in pairs(pr.seen) do receivedCount = receivedCount + 1 end

        if receivedCount >= pr.total then
            -- All chunks in — finalize.
            local successSender = pr.sender
            self._partialReceive[sessionId] = nil
            self:_FinalizeSyncResponse(successSender)
        else
            -- More chunks expected — arm the progress timeout.
            pr.progressTimer = self:ScheduleTimer(function()
                self:_OnProgressTimeout(sessionId)
            end, PROGRESS_TIMEOUT)
        end
        return
    end

    -- Legacy path (sender pre-dates Patch 3, no sessionId): original behaviour.
    if payload.chunkIndex and payload.chunkTotal and payload.chunkIndex < payload.chunkTotal then
        -- Reset timeout — more chunks coming.
        if self.syncTimer then
            self:CancelTimer(self.syncTimer)
        end
        self.syncTimer = self:ScheduleTimer("OnSyncTimeout", SYNC_TIMEOUT)
        return
    end

    -- Single chunk or last chunk of a legacy multi-chunk transfer — finalize.
    self:_FinalizeSyncResponse(sender)
end

--- Shared finalization for both RESUME and legacy sync completion.
--- successSender: the peer whose response completed this sync (cleared from backoff).
function Comms:_FinalizeSyncResponse(successSender)
    if successSender then self:MarkPeerSuccess(successSender) end
    -- Cancel progress timers on any in-flight partial sessions before clearing
    -- syncPending. This prevents the second session's timer from firing spurious
    -- SYNC_RESUME whispers when both DR and BDR both respond to a retry=1 request.
    for _, pr in pairs(self._partialReceive) do
        if pr.progressTimer then
            self:CancelTimer(pr.progressTimer)
        end
    end
    self._partialReceive = {}
    self.syncPending         = false
    self.syncRetryCount      = 0
    self.lastSyncCompletedAt = time()
    if self.syncTimer then
        self:CancelTimer(self.syncTimer)
        self.syncTimer = nil
    end

    -- Notify UI to refresh if loaded
    if GuildCrafts.UI and GuildCrafts.UI.Refresh then
        GuildCrafts.UI:Refresh()
    end

    -- Broadcast a second HELLO so nodes whose reply was throttled or
    -- arrived too late (before we knew the real DR) get a chance to
    -- add themselves to our addonUsers table and vice-versa.
    -- Use isReply=true so this doesn't trigger yet another round of replies.
    if not self._postSyncHelloDone then
        self._postSyncHelloDone = true
        self:ScheduleTimer("BroadcastPostSyncHello", 5)
    end
end

--- Called when no chunk progress is seen within PROGRESS_TIMEOUT seconds.
--- Sends a SYNC_RESUME whisper listing missing sequence numbers.
function Comms:_OnProgressTimeout(sessionId)
    -- Guard: sync may have been finalized by a concurrent session (e.g., both
    -- DR and BDR responded to a retry=1 request). _FinalizeSyncResponse already
    -- cleared _partialReceive, so there is nothing left to do.
    if not self.syncPending then
        self._partialReceive[sessionId] = nil
        return
    end
    local pr = self._partialReceive[sessionId]
    if not pr then return end

    -- Race: check if all chunks arrived between timer scheduling and firing.
    local receivedCount = 0
    for _ in pairs(pr.seen) do receivedCount = receivedCount + 1 end
    if receivedCount >= pr.total then
        local successSender = pr.sender
        self._partialReceive[sessionId] = nil
        self:_FinalizeSyncResponse(successSender)
        return
    end

    if pr.resumeAttempts >= MAX_RESUME_ATTEMPTS then
        GuildCrafts:Debug("RESUME: max attempts reached for session", sessionId,
            "— falling back to full retry")
        self._partialReceive[sessionId] = nil
        -- Main syncTimer (SYNC_TIMEOUT) will fire and call OnSyncTimeout.
        return
    end

    -- Build the missing seq list.
    local missing = {}
    for i = 1, pr.total do
        if not pr.seen[i] then
            missing[#missing + 1] = i
        end
    end

    pr.resumeAttempts = pr.resumeAttempts + 1
    GuildCrafts:Debug("RESUME: requesting", #missing, "chunk(s) for session", sessionId,
        "(attempt", pr.resumeAttempts, "/", MAX_RESUME_ATTEMPTS, ")")

    self:SendMessage(MSG_SYNC_RESUME, {
        sessionId = sessionId,
        missing   = missing,
    }, "WHISPER", pr.sender, PRIO_NORMAL)

    -- Restart the progress timer for this attempt.
    pr.progressTimer = self:ScheduleTimer(function()
        self:_OnProgressTimeout(sessionId)
    end, PROGRESS_TIMEOUT)
end

--- Received by the sender when the requester reports missing chunks.
function Comms:HandleSyncResume(payload, sender)
    if not payload.sessionId or not payload.missing or #payload.missing == 0 then return end

    local session = self._outboundSessions[payload.sessionId]
    if not session then
        GuildCrafts:Debug("RESUME: session", payload.sessionId, "not found (expired) — requester will retry on timeout")
        return
    end

    -- Always reply to the original requester (session.target), not the message
    -- sender. For legitimate traffic they match, but using session.target ensures
    -- a spoofed SYNC_RESUME can't redirect chunks to an unintended recipient.
    GuildCrafts:Debug("RESUME: resending", #payload.missing, "chunk(s) for session",
        payload.sessionId, "to", session.target)
    for _, seqNum in ipairs(payload.missing) do
        local chunkPayload = session.chunks[seqNum]
        if chunkPayload then
            self:SendMessage(MSG_SYNC_RESPONSE, chunkPayload, "WHISPER", session.target, PRIO_BULK)
        end
    end
end

function Comms:GetLastSyncTime()
    return self.lastSyncCompletedAt
end

function Comms:BroadcastPostSyncHello()
    if not IsInGuild() then return end
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_HELLO, {
        sender   = playerKey,
        version  = GuildCrafts.VERSION,
        discover = true,  -- tells all nodes to reply even if they know us already
    }, "GUILD")
    GuildCrafts:Debug("Sent post-sync HELLO to gather missed addon users")
end

----------------------------------------------------------------------
-- SYNC_PULL (received by requester — DR wants our data)
----------------------------------------------------------------------

function Comms:HandleSyncPull(payload, sender)
    if not payload.memberKeys then return end

    local db = GuildCrafts.Data:GetGuildDB()
    if not db then return end
    local responseData = {}

    for _, memberKey in ipairs(payload.memberKeys) do
        if db[memberKey] then
            responseData[memberKey] = GuildCrafts.Data:StripSyncFields(db[memberKey])
        end
    end

    local count = 0
    for _ in pairs(responseData) do count = count + 1 end

    if count > 0 then
        GuildCrafts:Debug("Responding to SYNC_PULL from", sender, "with", count, "members")
        self:SendChunked(MSG_SYNC_PUSH, responseData, sender, count)
    end
end

----------------------------------------------------------------------
-- SYNC_PUSH (received by DR — requester sent data we requested)
----------------------------------------------------------------------

function Comms:HandleSyncPush(payload, sender)
    if not payload.data then return end

    -- The requester fulfilled a SYNC_PULL — clear any failure record for this peer.
    self:MarkPeerSuccess(sender)

    local merged = GuildCrafts.Data:MergeIncoming(payload.data)
    GuildCrafts:Debug("Received SYNC_PUSH chunk", (payload.chunkIndex or 1),
        "/", (payload.chunkTotal or 1), "from", sender, "— merged:", tostring(merged))

    -- DR rebroadcasts new data as DELTA_UPDATEs so all online nodes converge
    if merged and self.myRole == "DR" then
        for memberKey, entry in pairs(payload.data) do
            if type(entry) == "table" then
                for profName, profData in pairs(entry.professions or {}) do
                    self:SendMessage(MSG_DELTA_UPDATE, {
                        type       = "add",
                        member     = memberKey,
                        profession = profName,
                        recipes    = GuildCrafts.Data:StripRecipeReagents(profData.recipes),
                        lastUpdate = entry.lastUpdate,
                    }, "GUILD", nil, PRIO_NORMAL)
                end
            end
        end
        GuildCrafts:Debug("Rebroadcast DELTA_UPDATEs from SYNC_PUSH data")
    end
end

----------------------------------------------------------------------
-- DELTA_UPDATE
----------------------------------------------------------------------

function Comms:BroadcastNewRecipes(memberKey, profName, recipes)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("BroadcastNewRecipes suppressed (SyncPausePolicy) for", profName)
        return
    end
    local gdb = GuildCrafts.Data:GetGuildDB()
    local entry = gdb and gdb[memberKey]
    self:SendMessage(MSG_DELTA_UPDATE, {
        type       = "add",
        member     = memberKey,
        profession = profName,
        recipes    = GuildCrafts.Data:StripRecipeReagents(recipes),
        lastUpdate = entry and entry.lastUpdate or time(),
    }, "GUILD", nil, PRIO_NORMAL)
    GuildCrafts:Debug("Broadcast DELTA_UPDATE (add) for", memberKey, profName)
end

function Comms:BroadcastProfessionRemoval(memberKey, profName)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("BroadcastProfessionRemoval suppressed (SyncPausePolicy) for", profName)
        return
    end
    local gdb = GuildCrafts.Data:GetGuildDB()
    local entry = gdb and gdb[memberKey]
    self:SendMessage(MSG_DELTA_UPDATE, {
        type       = "remove_profession",
        member     = memberKey,
        profession = profName,
        lastUpdate = entry and entry.lastUpdate or time(),
    }, "GUILD", nil, PRIO_NORMAL)
    GuildCrafts:Debug("Broadcast DELTA_UPDATE (remove) for", memberKey, profName)
end

--- Broadcast a lightweight timestamp-only update. Called when a profession window
--- is opened but no new recipes are found and the data is 25+ days old. This
--- prevents peers (including the DR) from pruning a player who is simply up to
--- date and has nothing new to learn.
function Comms:BroadcastTimestampTouch(memberKey, profName)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("BroadcastTimestampTouch suppressed (SyncPausePolicy) for", profName)
        return
    end
    -- Rate limit: only broadcast once per hour per profession to avoid spamming
    -- the DR when the player opens a profession window repeatedly.
    self._lastTouchBroadcast = self._lastTouchBroadcast or {}
    local last = self._lastTouchBroadcast[profName]
    if last and (time() - last) < 3600 then
        GuildCrafts:Debug("DELTA_UPDATE (touch) rate-limited for", profName)
        return
    end
    self._lastTouchBroadcast[profName] = time()
    local gdb = GuildCrafts.Data:GetGuildDB()
    local entry = gdb and gdb[memberKey]
    self:SendMessage(MSG_DELTA_UPDATE, {
        type       = "touch",
        member     = memberKey,
        profession = profName,
        lastUpdate = entry and entry.lastUpdate or time(),
    }, "GUILD", nil, PRIO_NORMAL)
    GuildCrafts:Debug("Broadcast DELTA_UPDATE (touch) for", memberKey, profName)
end

function Comms:HandleDeltaUpdate(payload, sender)
    if not payload.member then return end
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    -- Don't process our own deltas
    if payload.member == playerKey then return end

    -- Seeing a DELTA_UPDATE proves sender is online with the addon.
    self:TouchAddonUser(sender)

    if payload.type == "add" and payload.profession and payload.recipes then
        -- Merge each recipe
        for recipeKey, recipeData in pairs(payload.recipes) do
            GuildCrafts.Data:MergeDelta(payload.member, payload.profession,
                recipeKey, recipeData, payload.lastUpdate)
        end
        GuildCrafts:Debug("DELTA_UPDATE (add) from", sender, "for", payload.member)

    elseif payload.type == "touch" and payload.lastUpdate then
        -- Lightweight timestamp bump — the sender has no new recipes but is still
        -- active. Update lastUpdate so local pruning logic doesn't evict them.
        local gdb = GuildCrafts.Data:GetGuildDB()
        local entry = gdb and gdb[payload.member]
        if entry and payload.lastUpdate > (entry.lastUpdate or 0) then
            entry.lastUpdate = payload.lastUpdate
        end
        GuildCrafts:Debug("DELTA_UPDATE (touch) from", sender, "for", payload.member)
        -- No recipe data changed; skip UI refresh.
        return

    elseif payload.type == "remove_profession" then
        -- Remove entire profession
        local gdb = GuildCrafts.Data:GetGuildDB()
        local entry = gdb and gdb[payload.member]
        if entry then
            -- We need the profession name... if not provided, do full replacement
            -- using lastUpdate comparison
            if payload.profession then
                GuildCrafts.Data:MergeProfessionRemoval(payload.member,
                    payload.profession, payload.lastUpdate)
            else
                -- Full member replacement via lastUpdate
                if payload.lastUpdate and payload.lastUpdate > (entry.lastUpdate or 0) then
                    -- Request the full member data in next sync
                    GuildCrafts:Debug("DELTA_UPDATE removal without profession name — will resolve on next sync")
                end
            end
        end
        GuildCrafts:Debug("DELTA_UPDATE (remove) from", sender, "for", payload.member)
    end

    -- Notify UI to refresh
    if GuildCrafts.UI and GuildCrafts.UI.Refresh then
        GuildCrafts.UI:Refresh()
    end
end

----------------------------------------------------------------------
-- DELTA_AD  (lightweight "I have new data" advertisement)
----------------------------------------------------------------------

--- Broadcast a tiny advertisement after a local scan produces new recipes.
--- Peers who are behind queue a targeted sync pull with jitter.
--- Carries no recipe data — just a revision timestamp and per-profession counts.
function Comms:BroadcastLocalAdvertise(memberKey, rev, profCounts)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("BroadcastLocalAdvertise suppressed (SyncPausePolicy)")
        return
    end
    if not IsInGuild() then return end
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_DELTA_AD, {
        sender     = playerKey,
        memberKey  = memberKey,
        rev        = rev,
        profCounts = profCounts,
    }, "GUILD", nil, PRIO_NORMAL)
    GuildCrafts:Debug("Broadcast DELTA_AD for", memberKey, "rev", rev)
end

function Comms:HandleDeltaAd(payload, sender)
    if not payload.memberKey or not payload.rev then return end

    -- Register the sender in addonUsers so they appear in the DR election.
    self:TouchAddonUser(sender)

    local playerKey = GuildCrafts.Data:GetPlayerKey()
    -- Ignore advertisements about ourselves.
    if payload.memberKey == playerKey then return end

    -- Check if the advertised revision is actually newer than what we hold.
    local gdb = GuildCrafts.Data:GetGuildDB()
    local localEntry = gdb and gdb[payload.memberKey]
    local localTs = localEntry and localEntry.lastUpdate or 0
    if payload.rev <= localTs then
        GuildCrafts:Debug("DELTA_AD from", sender, "for", payload.memberKey, "— already current")
        return
    end

    GuildCrafts:Debug("DELTA_AD from", sender, "for", payload.memberKey,
        "rev", payload.rev, "— local", localTs)

    -- DR forwards to guild so non-DR nodes that missed the original also get
    -- the hint. The 'forwarded' flag prevents re-forwarding loops.
    if self.myRole == "DR" and not payload.forwarded then
        self:SendMessage(MSG_DELTA_AD, {
            sender     = payload.sender or sender,
            memberKey  = payload.memberKey,
            rev        = payload.rev,
            profCounts = payload.profCounts,
            forwarded  = true,
        }, "GUILD", nil, PRIO_NORMAL)
        GuildCrafts:Debug("DR forwarded DELTA_AD for", payload.memberKey)
        -- DR accumulates data through SYNC_PUSH; scheduling a sync pull via
        -- SendSyncRequest would immediately no-op and could cancel a legitimate
        -- pending timer from HELLO discovery. Return now.
        return
    end

    -- Non-DR nodes queue a sync pull with jitter to avoid a thundering-herd burst.
    if not self.syncPending then
        local jitter = AD_JITTER_MIN + math.random() * (AD_JITTER_MAX - AD_JITTER_MIN)
        if self._pendingSyncTimer then
            self:CancelTimer(self._pendingSyncTimer)
        end
        self._pendingSyncTimer = self:ScheduleTimer(function()
            self._pendingSyncTimer = nil
            self:SendSyncRequest()
        end, jitter)
        GuildCrafts:Debug("DELTA_AD: queued sync pull in",
            string.format("%.1fs", jitter))
    end
end

----------------------------------------------------------------------
-- Message Send / Receive Infrastructure
----------------------------------------------------------------------

--- Send a member data table in chunks of SYNC_CHUNK_SIZE.
--- Each chunk is sent after a SYNC_CHUNK_DELAY to avoid burst lag.
--- onComplete is an optional callback fired after the last chunk is sent.
function Comms:SendChunked(msgType, memberData, target, totalCount, onComplete)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("SendChunked suppressed (SyncPausePolicy):", msgType)
        -- We must still call onComplete so syncProcessing is cleared and the
        -- DR's queue doesn't deadlock permanently. Affected requesters will not
        -- receive their SYNC_RESPONSE and will retry via SYNC_TIMEOUT (120 s).
        if onComplete then onComplete() end
        return
    end
    local keys = {}
    for k in pairs(memberData) do
        keys[#keys + 1] = k
    end
    table_sort(keys)

    local totalChunks = math.ceil(totalCount / SYNC_CHUNK_SIZE)

    -- Generate a unique session ID so the receiver can request missing chunks.
    local sessionId = string.format("%s:%d:%04d", target, time(), math.random(1000, 9999))
    self._outboundSessions[sessionId] = { chunks = {}, target = target }

    local function sendChunk(chunkIndex, startIdx)
        if startIdx > #keys then return end

        local chunk = {}
        for j = startIdx, math.min(startIdx + SYNC_CHUNK_SIZE - 1, #keys) do
            chunk[keys[j]] = memberData[keys[j]]
        end

        local chunkPayload = {
            data       = chunk,
            chunkIndex = chunkIndex,
            chunkTotal = totalChunks,
            sessionId  = sessionId,
        }
        -- Keep a copy for potential RESUME re-sends.
        self._outboundSessions[sessionId].chunks[chunkIndex] = chunkPayload

        self:SendMessage(msgType, chunkPayload, "WHISPER", target, PRIO_BULK)

        GuildCrafts:Debug("Sent chunk", chunkIndex, "/", totalChunks, "to", target)

        local nextStart = startIdx + SYNC_CHUNK_SIZE
        if nextStart <= #keys then
            self:ScheduleTimer(function()
                sendChunk(chunkIndex + 1, nextStart)
            end, SYNC_CHUNK_DELAY)
        else
            -- Last chunk sent — expire session after TTL and notify caller.
            self:ScheduleTimer(function()
                self._outboundSessions[sessionId] = nil
                GuildCrafts:Debug("RESUME: outbound session expired:", sessionId)
            end, SESSION_TTL)
            if onComplete then
                onComplete()
            end
        end
    end

    sendChunk(1, 1)
    GuildCrafts:Debug("SendChunked started:", msgType, "→", target, totalChunks, "chunk(s)")
end

--- Serialize, optionally compress, and send a message.
function Comms:SendMessage(msgType, payload, distribution, target, priority)
    if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then
        GuildCrafts:Debug("SendMessage suppressed (SyncPausePolicy):", msgType)
        return
    end
    local envelope = {
        t    = msgType,           -- type
        v    = GuildCrafts.VERSION,
        term = self.currentTerm,  -- DR authority term
        p    = payload,
    }

    local serialized = self:Serialize(envelope)
    if not serialized then
        GuildCrafts:Debug("Failed to serialize message:", msgType)
        return
    end

    -- Compress large messages (> 200 bytes)
    local toSend
    local compressed = false
    if LibDeflate and #serialized > 200 then
        local deflated = LibDeflate:CompressDeflate(serialized)
        if deflated then
            local encoded = LibDeflate:EncodeForWoWAddonChannel(deflated)
            if encoded and #encoded < #serialized then
                toSend = "Z" .. encoded  -- "Z" prefix = compressed
                compressed = true
            end
        end
    end

    if not compressed then
        toSend = "U" .. serialized  -- "U" prefix = uncompressed
    end

    -- Send via AceComm (handles chunking automatically)
    if distribution == "WHISPER" and target then
        -- Extract character name without realm for whisper target
        local whisperTarget = target:match("^(.+)-") or target
        self:SendCommMessage(PREFIX, toSend, distribution, whisperTarget, priority or PRIO_NORMAL)
    elseif distribution == "GUILD" then
        self:SendCommMessage(PREFIX, toSend, distribution, nil, priority or PRIO_NORMAL)
    end
end

--- Receive callback from AceComm.
function Comms:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= PREFIX then return end
    if not message or #message < 2 then return end

    -- Wrap in pcall to prevent malformed messages from crashing
    local ok, err = pcall(function()
        self:ProcessIncoming(message, distribution, sender)
    end)

    if not ok then
        GuildCrafts:Debug("Error processing message from", sender, ":", err)
    end
end

function Comms:ProcessIncoming(message, _distribution, sender)
    -- Decompress if needed
    local flag = message:sub(1, 1)
    local data = message:sub(2)
    local serialized

    if flag == "Z" then
        -- Compressed
        if not LibDeflate then
            GuildCrafts:Debug("Received compressed message but LibDeflate not loaded")
            return
        end
        local decoded = LibDeflate:DecodeForWoWAddonChannel(data)
        if not decoded then
            GuildCrafts:Debug("Failed to decode compressed message from", sender)
            return
        end
        serialized = LibDeflate:DecompressDeflate(decoded)
        if not serialized then
            GuildCrafts:Debug("Failed to decompress message from", sender)
            return
        end
    elseif flag == "U" then
        -- Uncompressed
        serialized = data
    else
        GuildCrafts:Debug("Unknown message flag from", sender, ":", flag)
        return
    end

    -- Deserialize
    local success, envelope = self:Deserialize(serialized)
    if not success or type(envelope) ~= "table" then
        GuildCrafts:Debug("Failed to deserialize message from", sender)
        return
    end

    -- Normalize sender to "Name-Realm" format
    if sender and not sender:find("-") then
        sender = sender .. "-" .. GetRealmName()
    end

    -- Update lastSeen for known addon users
    if self.addonUsers[sender] then
        self.addonUsers[sender].lastSeen = time()
    end

    -- Route to handler
    local msgType = envelope.t
    local payload = envelope.p or {}
    local msgVersion = envelope.v or 1
    -- Inject envelope-level term so handlers can enforce authority without
    -- each sender needing to embed it redundantly in the payload.
    payload.term = envelope.term

    -- Early term propagation: adopt a higher term from ANY incoming message.
    -- This corrects a node that missed term increments while inside an instance
    -- (where GUILD addon messages are not delivered). A stale DR will step down
    -- as soon as it receives any message from the updated network.
    if type(envelope.term) == "number" and envelope.term > self.currentTerm then
        GuildCrafts:Debug("Higher term", envelope.term, "adopted from", msgType, "by", sender)
        self.currentTerm = envelope.term
        if self.myRole == "DR" then
            GuildCrafts:Debug("Stepping down — higher-term authority arrived via", msgType)
            self:StopHeartbeat()
            -- Do NOT set myRole or call RecomputeElection here: the sender is not
            -- yet registered in addonUsers. The specific message handler (e.g.
            -- HandleHeartbeat) will register the sender and run RecomputeElection
            -- with the complete peer list, correctly computing the new role.
        end
    end

    -- Version compatibility check
    if msgVersion > GuildCrafts.VERSION then
        -- One-time warning per sender about incompatible version
        if not self._versionWarned then self._versionWarned = {} end
        if not self._versionWarned[sender] then
            self._versionWarned[sender] = true
            GuildCrafts:Printf("|cffff8800%s is running a newer GuildCrafts version. Please update.|r",
                sender)
        end
        -- Still attempt to process — forward compatible where possible
    end

    if msgType == MSG_HELLO then
        self:HandleHello(payload, sender)
    elseif msgType == MSG_HEARTBEAT then
        self:HandleHeartbeat(payload)
    elseif msgType == MSG_SYNC_REQUEST then
        self:HandleSyncRequest(payload, sender)
    elseif msgType == MSG_SYNC_RESPONSE then
        self:HandleSyncResponse(payload, sender)
    elseif msgType == MSG_SYNC_PULL then
        self:HandleSyncPull(payload, sender)
    elseif msgType == MSG_SYNC_PUSH then
        self:HandleSyncPush(payload, sender)
    elseif msgType == MSG_DELTA_UPDATE then
        self:HandleDeltaUpdate(payload, sender)
    elseif msgType == MSG_DELTA_AD then
        self:HandleDeltaAd(payload, sender)
    elseif msgType == MSG_SYNC_RESUME then
        self:HandleSyncResume(payload, sender)
    else
        GuildCrafts:Debug("Unknown message type:", msgType, "from", sender)
    end
end

----------------------------------------------------------------------
-- Debug: Dump Status
----------------------------------------------------------------------

function Comms:DumpStatus()
    GuildCrafts:Printf("--- Comms Status ---")
    GuildCrafts:Printf("My role: %s", self.myRole)
    GuildCrafts:Printf("DR: %s", self.currentDR or "none")
    GuildCrafts:Printf("BDR: %s", self.currentBDR or "none")
    GuildCrafts:Printf("Sync pending: %s (retries: %d)", tostring(self.syncPending), self.syncRetryCount)
    GuildCrafts:Printf("Sync queue: %d", #self.syncQueue)

    local count = 0
    for key, info in pairs(self.addonUsers) do
        count = count + 1
        GuildCrafts:Printf("  [%d] %s (v%d, seen %ds ago)",
            count, key, info.version or 0, time() - (info.lastSeen or 0))
    end
    GuildCrafts:Printf("Total addon users: %d", count)
end

----------------------------------------------------------------------
-- Accessor for other modules
----------------------------------------------------------------------

--- Get count of addon users who are currently online according to the guild
--- roster cache. This filters out zombie entries (users who logged off but
--- haven't yet timed out of addonUsers via the heartbeat watchdog).
function Comms:GetActiveAddonUserCount()
    local count = 0
    local onlineCache = GuildCrafts.Data and GuildCrafts.Data._onlineCache
    for key, _ in pairs(self.addonUsers) do
        -- Always count ourselves (we're online by definition)
        -- and count anyone the roster cache confirms as online.
        if key == GuildCrafts.Data:GetPlayerKey()
           or (onlineCache and onlineCache[key]) then
            count = count + 1
        end
    end
    return count
end

--- Returns true if the given member key is a currently known active addon user.
function Comms:IsActiveAddonUser(key)
    return self.addonUsers[key] ~= nil
end

--- Get sync status for UI indicator.
--- Returns "synced", "syncing", or "disconnected"
function Comms:GetSyncStatus()
    if self.syncPending then
        return "syncing"
    end
    if self:GetActiveAddonUserCount() <= 1 then
        return "disconnected"
    end
    return "synced"
end
