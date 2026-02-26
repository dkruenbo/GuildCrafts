----------------------------------------------------------------------
-- GuildCrafts — Comms.lua
-- Guild addon channel sync: HELLO, HEARTBEAT, DR/BDR election,
-- SYNC_REQUEST / SYNC_RESPONSE / SYNC_PULL / SYNC_PUSH,
-- DELTA_UPDATE, CRAFT_* messages
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"
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
local table_concat = table.concat

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local PREFIX = "GuildCrafts"

-- Timing (seconds)
local HELLO_DELAY          = 3       -- delay after login before sending HELLO
local SYNC_DELAY           = 5       -- delay after HELLO before SYNC_REQUEST
local HEARTBEAT_INTERVAL   = 60      -- DR heartbeat broadcast interval
local HEARTBEAT_TIMEOUT    = 180     -- 3 missed heartbeats → DR presumed dead
local SYNC_TIMEOUT         = 30      -- wait for SYNC_RESPONSE before retry
local SYNC_RETRY_TIMEOUT   = 15      -- wait for retry response before open round
local SYNC_CHUNK_SIZE      = 10      -- max members per sync chunk

-- ChatThrottleLib priorities
local PRIO_BULK   = "BULK"
local PRIO_NORMAL = "NORMAL"
local PRIO_ALERT  = "ALERT"

-- Message types
local MSG_HELLO              = "HELLO"
local MSG_HEARTBEAT          = "HEARTBEAT"
local MSG_DELTA_UPDATE       = "DELTA_UPDATE"
local MSG_SYNC_REQUEST       = "SYNC_REQUEST"
local MSG_SYNC_RESPONSE      = "SYNC_RESPONSE"
local MSG_SYNC_PULL          = "SYNC_PULL"
local MSG_SYNC_PUSH          = "SYNC_PUSH"
local MSG_CRAFT_REQUEST      = "CRAFT_REQUEST"
local MSG_CRAFT_ACCEPT       = "CRAFT_ACCEPT"
local MSG_CRAFT_DECLINE      = "CRAFT_DECLINE"
local MSG_CRAFT_COMPLETE     = "CRAFT_COMPLETE"

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
    self.syncPending       = false
    self.syncRetryCount    = 0
    self.syncTimer         = nil

    -- DR request queue (when we are DR)
    self.syncQueue         = {}
    self.syncProcessing    = false

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

    -- Reply with our own HELLO so the sender discovers us too.
    -- Only reply to genuinely new users (not replies) to prevent infinite loops.
    if isNew and not payload.isReply then
        local playerKey = GuildCrafts.Data:GetPlayerKey()
        if memberKey ~= playerKey then
            self:SendMessage(MSG_HELLO, {
                sender  = playerKey,
                version = GuildCrafts.VERSION,
                isReply = true,
            }, "GUILD")
            GuildCrafts:Debug("Sent HELLO reply to", memberKey)
        end
    end

    -- Trigger a sync whenever we discover a new addon user.
    -- This handles late logins, reconnects, and the initial race where
    -- the first SYNC_REQUEST fires before any HELLO replies arrive.
    if isNew and not self.syncPending then
        self.syncRetryCount = 0
        self:ScheduleTimer("SendSyncRequest", 2)
        GuildCrafts:Debug("Scheduling re-sync after discovering", memberKey)
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
    if payload.dr then
        self.lastDRHeartbeat = time()
        -- Ensure DR is in our user list
        if not self.addonUsers[payload.dr] then
            self.addonUsers[payload.dr] = {
                version  = 1,
                lastSeen = time(),
            }
            self:RecomputeElection()
        else
            self.addonUsers[payload.dr].lastSeen = time()
        end
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
    if not IsInGuild() then return end

    -- Build set of online guild members
    local onlineMembers = {}
    local numMembers = GetNumGuildMembers()

    -- Safety: if roster hasn't fully loaded yet, skip the offline check.
    -- On login the first GUILD_ROSTER_UPDATE can fire with 0 members.
    if numMembers < 2 then
        GuildCrafts:Debug("OnGuildRosterUpdate skipped — roster not ready yet (", numMembers, "members)")
        return
    end

    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name and isOnline then
            if not name:find("-") then
                name = name .. "-" .. GetRealmName()
            end
            onlineMembers[name] = true
        end
    end

    -- Remove addon users who went offline
    local changed = false
    for key, _ in pairs(self.addonUsers) do
        if not onlineMembers[key] then
            GuildCrafts:Debug("Addon user offline:", key)
            self.addonUsers[key] = nil
            changed = true
        end
    end

    if changed then
        self:RecomputeElection()
    end
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
        local playerKey = GuildCrafts.Data:GetPlayerKey()
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

    if sendCount > 0 then
        self:SendChunked(MSG_SYNC_RESPONSE, toSend, requester, sendCount)
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

    -- Mark processing complete and check queue
    self.syncProcessing = false
    self:ProcessNextSyncQueue()
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
    self.syncPending = false
    self.syncRetryCount = 0
    if self.syncTimer then
        self:CancelTimer(self.syncTimer)
        self.syncTimer = nil
    end

    -- Notify UI to refresh if loaded
    if GuildCrafts.UI and GuildCrafts.UI.Refresh then
        GuildCrafts.UI:Refresh()
    end
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

function Comms:HandleDeltaUpdate(payload, sender)
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    -- Don't process our own deltas
    if payload.member == playerKey then return end

    if payload.type == "add" and payload.profession and payload.recipes then
        -- Merge each recipe
        for recipeKey, recipeData in pairs(payload.recipes) do
            GuildCrafts.Data:MergeDelta(payload.member, payload.profession,
                recipeKey, recipeData, payload.lastUpdate)
        end
        GuildCrafts:Debug("DELTA_UPDATE (add) from", sender, "for", payload.member)

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
-- CRAFT_* Messages
----------------------------------------------------------------------

function Comms:SendCraftRequest(targetKey, itemName)
    local playerKey = GuildCrafts.Data:GetPlayerKey()

    -- Check if target has the addon
    if self.addonUsers[targetKey] then
        self:SendMessage(MSG_CRAFT_REQUEST, {
            requester = playerKey,
            item      = itemName,
        }, "WHISPER", targetKey, PRIO_NORMAL)
        GuildCrafts:Printf("Request sent to %s for %s.", targetKey, itemName)
    else
        -- Fallback: visible whisper
        local targetName = targetKey:match("^(.+)-")
        if targetName then
            SendChatMessage(
                string.format("[GuildCrafts] %s is requesting you craft: %s. Whisper them to arrange!",
                    playerKey:match("^(.+)-") or playerKey, itemName),
                "WHISPER", nil, targetName
            )
            GuildCrafts:Printf("Whisper sent to %s for %s (no addon detected).", targetKey, itemName)
        end
    end
end

function Comms:SendCraftAccept(requesterKey, itemName)
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_CRAFT_ACCEPT, {
        crafter = playerKey,
        item    = itemName,
    }, "WHISPER", requesterKey, PRIO_NORMAL)
end

function Comms:SendCraftDecline(requesterKey, itemName)
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_CRAFT_DECLINE, {
        crafter = playerKey,
        item    = itemName,
    }, "WHISPER", requesterKey, PRIO_NORMAL)
end

function Comms:SendCraftComplete(requesterKey, itemName)
    local playerKey = GuildCrafts.Data:GetPlayerKey()
    self:SendMessage(MSG_CRAFT_COMPLETE, {
        crafter = playerKey,
        item    = itemName,
    }, "WHISPER", requesterKey, PRIO_NORMAL)
end

function Comms:HandleCraftRequest(payload, sender)
    GuildCrafts:Debug("CRAFT_REQUEST from", payload.requester, "for", payload.item)
    if GuildCrafts.CraftRequest and GuildCrafts.CraftRequest.OnIncomingRequest then
        GuildCrafts.CraftRequest:OnIncomingRequest(payload.requester, payload.item)
    end
end

function Comms:HandleCraftAccept(payload, sender)
    GuildCrafts:Printf("|cff00ff00%s|r accepted your request for |cffffd100%s|r.",
        payload.crafter or sender, payload.item or "unknown item")
    PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
end

function Comms:HandleCraftDecline(payload, sender)
    GuildCrafts:Printf("|cffff4444%s|r declined your request for |cffffd100%s|r.",
        payload.crafter or sender, payload.item or "unknown item")
end

function Comms:HandleCraftComplete(payload, sender)
    GuildCrafts:Printf("|cff00ff00%s|r has completed crafting |cffffd100%s|r!",
        payload.crafter or sender, payload.item or "unknown item")
    PlaySound(SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_CLOSE or 5274)
end

----------------------------------------------------------------------
-- Message Send / Receive Infrastructure
----------------------------------------------------------------------

--- Send a member data table in chunks of SYNC_CHUNK_SIZE.
--- Each chunk is a separate message with chunkIndex/chunkTotal metadata.
function Comms:SendChunked(msgType, memberData, target, totalCount)
    -- Collect keys into a list for deterministic ordering
    local keys = {}
    for k in pairs(memberData) do
        keys[#keys + 1] = k
    end
    table_sort(keys)

    local totalChunks = math.ceil(totalCount / SYNC_CHUNK_SIZE)
    local chunkIndex = 0

    for i = 1, #keys, SYNC_CHUNK_SIZE do
        chunkIndex = chunkIndex + 1
        local chunk = {}
        for j = i, math.min(i + SYNC_CHUNK_SIZE - 1, #keys) do
            chunk[keys[j]] = memberData[keys[j]]
        end
        self:SendMessage(msgType, {
            data       = chunk,
            chunkIndex = chunkIndex,
            chunkTotal = totalChunks,
        }, "WHISPER", target, PRIO_BULK)
    end

    GuildCrafts:Debug("Sent", msgType, "to", target, "in", totalChunks, "chunk(s),", totalCount, "members")
end

--- Serialize, optionally compress, and send a message.
function Comms:SendMessage(msgType, payload, distribution, target, priority)
    local envelope = {
        t = msgType,      -- type
        v = GuildCrafts.VERSION,
        p = payload,
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

function Comms:ProcessIncoming(message, distribution, sender)
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
    elseif msgType == MSG_CRAFT_REQUEST then
        self:HandleCraftRequest(payload, sender)
    elseif msgType == MSG_CRAFT_ACCEPT then
        self:HandleCraftAccept(payload, sender)
    elseif msgType == MSG_CRAFT_DECLINE then
        self:HandleCraftDecline(payload, sender)
    elseif msgType == MSG_CRAFT_COMPLETE then
        self:HandleCraftComplete(payload, sender)
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

--- Check if a player is a known addon user.
function Comms:IsAddonUser(memberKey)
    return self.addonUsers[memberKey] ~= nil
end

--- Get list of online addon users.
function Comms:GetAddonUsers()
    return self.addonUsers
end

--- Get sync status for UI indicator.
--- Returns "synced", "syncing", or "disconnected"
function Comms:GetSyncStatus()
    if self.syncPending then
        return "syncing"
    end
    local count = 0
    for _ in pairs(self.addonUsers) do count = count + 1 end
    if count <= 1 then
        return "disconnected"
    end
    return "synced"
end
