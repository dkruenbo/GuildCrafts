----------------------------------------------------------------------
-- GuildCrafts — CraftRequest.lua
-- Craft request/queue management: popup handling, queue persistence,
-- accept/decline/complete logic
----------------------------------------------------------------------
local ADDON_NAME = "GuildCrafts"
local GuildCrafts = _G.GuildCrafts

local CraftRequest = GuildCrafts:NewModule("CraftRequest", "AceTimer-3.0")
GuildCrafts.CraftRequest = CraftRequest

local time = time
local pairs = pairs

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function CraftRequest:OnInitialize()
    -- Pending popup stack (incoming requests not yet accepted/declined)
    self.pendingPopups = {}

    -- Active craft queue (accepted requests)
    self.craftQueue = {}
end

function CraftRequest:OnEnable()
    -- Restore persisted queue from SavedVariables
    self:RestoreQueue()
end

----------------------------------------------------------------------
-- Queue Persistence
----------------------------------------------------------------------

function CraftRequest:RestoreQueue()
    if GuildCrafts.db and GuildCrafts.db.global._craftQueue then
        self.craftQueue = GuildCrafts.db.global._craftQueue
        GuildCrafts:Debug("Restored craft queue:", #self.craftQueue, "items")
    end
end

function CraftRequest:SaveQueue()
    if GuildCrafts.db then
        GuildCrafts.db.global._craftQueue = self.craftQueue
    end
end

----------------------------------------------------------------------
-- Incoming Request (from Comms or simulation)
----------------------------------------------------------------------

function CraftRequest:OnIncomingRequest(requester, itemName)
    GuildCrafts:Printf("|cffffd100Craft Request:|r %s wants you to craft: |cffffd100%s|r",
        requester, itemName)

    -- Play alert sound
    if PlaySound then
        PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    end

    -- Add to pending popups
    local request = {
        requester = requester,
        item      = itemName,
        timestamp = time(),
    }
    self.pendingPopups[#self.pendingPopups + 1] = request

    -- Show popup UI
    if GuildCrafts.UI and GuildCrafts.UI.ShowCraftRequestPopup then
        GuildCrafts.UI:ShowCraftRequestPopup(request)
    end
end

----------------------------------------------------------------------
-- Accept / Decline / Complete
----------------------------------------------------------------------

function CraftRequest:AcceptRequest(request)
    -- Remove from pending popups
    self:RemoveFromPending(request)

    -- Add to craft queue
    request.accepted = true
    request.acceptedAt = time()
    self.craftQueue[#self.craftQueue + 1] = request
    self:SaveQueue()

    -- Send CRAFT_ACCEPT via Comms
    if GuildCrafts.Comms then
        GuildCrafts.Comms:SendCraftAccept(request.requester, request.item)
    end

    GuildCrafts:Printf("|cff00ff00Accepted|r craft request from %s for %s.",
        request.requester, request.item)

    -- Refresh queue panel
    if GuildCrafts.UI and GuildCrafts.UI.RefreshCraftQueue then
        GuildCrafts.UI:RefreshCraftQueue()
    end
end

function CraftRequest:DeclineRequest(request)
    -- Remove from pending popups
    self:RemoveFromPending(request)

    -- Send CRAFT_DECLINE via Comms
    if GuildCrafts.Comms then
        GuildCrafts.Comms:SendCraftDecline(request.requester, request.item)
    end

    GuildCrafts:Printf("|cffff4444Declined|r craft request from %s for %s.",
        request.requester, request.item)
end

function CraftRequest:CompleteRequest(request)
    -- Remove from craft queue
    self:RemoveFromQueue(request)

    -- Send CRAFT_COMPLETE via Comms
    if GuildCrafts.Comms then
        GuildCrafts.Comms:SendCraftComplete(request.requester, request.item)
    end

    GuildCrafts:Printf("|cff00ff00Completed|r craft for %s: %s.",
        request.requester, request.item)

    -- Refresh queue panel
    if GuildCrafts.UI and GuildCrafts.UI.RefreshCraftQueue then
        GuildCrafts.UI:RefreshCraftQueue()
    end
end

function CraftRequest:DismissRequest(request)
    -- Remove from craft queue silently (no message sent)
    self:RemoveFromQueue(request)

    GuildCrafts:Debug("Dismissed craft request from", request.requester, "for", request.item)

    -- Refresh queue panel
    if GuildCrafts.UI and GuildCrafts.UI.RefreshCraftQueue then
        GuildCrafts.UI:RefreshCraftQueue()
    end
end

----------------------------------------------------------------------
-- Internal Helpers
----------------------------------------------------------------------

function CraftRequest:RemoveFromPending(request)
    for i = #self.pendingPopups, 1, -1 do
        if self.pendingPopups[i] == request then
            table.remove(self.pendingPopups, i)
            return
        end
    end
end

function CraftRequest:RemoveFromQueue(request)
    for i = #self.craftQueue, 1, -1 do
        if self.craftQueue[i] == request
        or (self.craftQueue[i].requester == request.requester
            and self.craftQueue[i].item == request.item
            and self.craftQueue[i].timestamp == request.timestamp) then
            table.remove(self.craftQueue, i)
            self:SaveQueue()
            return
        end
    end
end

----------------------------------------------------------------------
-- Accessors
----------------------------------------------------------------------

function CraftRequest:GetQueueCount()
    return #self.craftQueue
end

function CraftRequest:GetQueue()
    return self.craftQueue
end

function CraftRequest:GetPendingCount()
    return #self.pendingPopups
end

----------------------------------------------------------------------
-- Roster Pruning: Remove queue entries for ex-guild members
----------------------------------------------------------------------

function CraftRequest:PruneQueue()
    local changed = false
    for i = #self.craftQueue, 1, -1 do
        local req = self.craftQueue[i]
        local entry = GuildCrafts.Data and GuildCrafts.Data.db and GuildCrafts.Data.db.global[req.requester]
        -- If the requester is no longer in the DB (pruned from guild), remove
        -- We check the guild roster directly for accuracy
        if not self:IsInGuildRoster(req.requester) then
            table.remove(self.craftQueue, i)
            changed = true
        end
    end
    if changed then
        self:SaveQueue()
    end
end

function CraftRequest:IsInGuildRoster(memberKey)
    if not IsInGuild() then return false end
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name = GetGuildRosterInfo(i)
        if name then
            if not name:find("-") then
                name = name .. "-" .. GetRealmName()
            end
            if name == memberKey then
                return true
            end
        end
    end
    return false
end
