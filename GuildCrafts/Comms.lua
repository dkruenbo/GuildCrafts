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
local MSG_SYNC_REQUEST       = "SYNC_REQUEST"
local MSG_SYNC_RESPONSE      = "SYNC_RESPONSE"
local MSG_SYNC_PULL          = "SYNC_PULL"
local MSG_SYNC_PUSH          = "SYNC_PUSH"

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

    self:SendMessage(MSG_SYNC_REQUEST, {
        sender = playerKey,
        vector = vector,
        retry  = self.syncRetryCount,
    }, "GUILD")

    self.syncPending = true
    GuildCrafts:Debug("Sent SYNC_REQUEST (retry=" .. self.syncRetryCount .. ")")

    -- Set timeout for response
    if self.syncTimer then
        self:CancelTimer(self.syncTimer)
    end
    local timeout = (self.syncRetryCount == 0) and SYNC_TIMEOUT or SYNC_RETRY_TIMEOUT
    self.syncTimer = self:ScheduleTimer("OnSyncTimeout", timeout)
end

function Comms:OnSyncTimeout()
    if not self.syncPending then return end

    self.syncRetryCount = self.syncRetryCount + 1

    if self.syncRetryCount == 1 then
        GuildCrafts:Debug("SYNC_REQUEST timeout — retrying (BDR should respond)")
        self:SendSyncRequest()
    elseif self.syncRetryCount == 2 then
        -- Neither DR nor BDR responded — evict both and re-elect so the
        -- new DR (sorted[1] of remaining nodes) handles the request.
        -- Never evict ourselves — we know we're online.
        local playerKey = GuildCrafts.Data:GetPlayerKey()
        if self.currentDR  and self.currentDR  ~= playerKey then self.addonUsers[self.currentDR]  = nil end
        if self.currentBDR and self.currentBDR ~= playerKey then self.addonUsers[self.currentBDR] = nil end
        self:RecomputeElection()
        GuildCrafts:Debug("SYNC_REQUEST retry timeout — evicted DR/BDR, re-elected. New DR:", self.currentDR or "none")
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
        -- DR and BDR both failed to respond — evict them and re-elect.
        -- Only the newly elected DR responds, preventing a flood.
        -- Never evict ourselves — we know we're online.
        if self.currentDR  and self.currentDR  ~= playerKey then self.addonUsers[self.currentDR]  = nil end
        if self.currentBDR and self.currentBDR ~= playerKey then self.addonUsers[self.currentBDR] = nil end
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

    local merged = GuildCrafts.Data:MergeIncoming(payload.data)
    GuildCrafts:Debug("Received SYNC_RESPONSE chunk", (payload.chunkIndex or 1),
        "/", (payload.chunkTotal or 1), "from", sender, "— merged:", tostring(merged))

    -- If more chunks expected, reset the sync timeout but stay pending
    if payload.chunkIndex and payload.chunkTotal and payload.chunkIndex < payload.chunkTotal then
        -- Reset timeout — more chunks coming
        if self.syncTimer then
            self:CancelTimer(self.syncTimer)
        end
        self.syncTimer = self:ScheduleTimer("OnSyncTimeout", SYNC_TIMEOUT)
        return
    end

    -- All chunks received (or single un-chunked response) — sync complete
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
-- Message Send / Receive Infrastructure
----------------------------------------------------------------------

--- Send a member data table in chunks of SYNC_CHUNK_SIZE.
--- Each chunk is sent after a SYNC_CHUNK_DELAY to avoid burst lag.
--- onComplete is an optional callback fired after the last chunk is sent.
function Comms:SendChunked(msgType, memberData, target, totalCount, onComplete)
    local keys = {}
    for k in pairs(memberData) do
        keys[#keys + 1] = k
    end
    table_sort(keys)

    local totalChunks = math.ceil(totalCount / SYNC_CHUNK_SIZE)

    local function sendChunk(chunkIndex, startIdx)
        if startIdx > #keys then return end

        local chunk = {}
        for j = startIdx, math.min(startIdx + SYNC_CHUNK_SIZE - 1, #keys) do
            chunk[keys[j]] = memberData[keys[j]]
        end

        self:SendMessage(msgType, {
            data       = chunk,
            chunkIndex = chunkIndex,
            chunkTotal = totalChunks,
        }, "WHISPER", target, PRIO_BULK)

        GuildCrafts:Debug("Sent chunk", chunkIndex, "/", totalChunks, "to", target)

        local nextStart = startIdx + SYNC_CHUNK_SIZE
        if nextStart <= #keys then
            self:ScheduleTimer(function()
                sendChunk(chunkIndex + 1, nextStart)
            end, SYNC_CHUNK_DELAY)
        elseif onComplete then
            -- Last chunk sent — notify caller
            onComplete()
        end
    end

    sendChunk(1, 1)
    GuildCrafts:Debug("SendChunked started:", msgType, "→", target, totalChunks, "chunk(s)")
end

--- Serialize, optionally compress, and send a message.
function Comms:SendMessage(msgType, payload, distribution, target, priority)
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
