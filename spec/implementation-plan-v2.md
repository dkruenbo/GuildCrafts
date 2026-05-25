# GuildCrafts — Implementation Plan v2

> Planned improvements following the v1 release. Each item is self-contained and can be implemented independently. Ordered by estimated value-to-effort ratio.

---

## 1 — SyncPausePolicy

**Priority: High | Effort: Low**

Suspend all outgoing sync traffic during high-activity game states where chat messages are most likely to be dropped, throttled, or disruptive.

### Pause conditions
| Condition | How to detect | Grace after |
|---|---|---|
| Player is in combat | `InCombatLockdown()` returns true | 6s after `PLAYER_REGEN_ENABLED` |
| Player is inside an instance | `IsInInstance()` returns true | 15s after `PLAYER_LEAVING_WORLD` → `PLAYER_ENTERING_WORLD` |
| Zone transition in progress | `PLAYER_ENTERING_WORLD` fires with `isLogin == false` | 12s |

### Implementation
- New module: `SyncPausePolicy.lua`
- Tracks the current pause state and the reason for it
- Exposes a single method: `SyncPausePolicy:ShouldPause()` → boolean
- Every outgoing send site in `Comms.lua` checks this before firing:
  ```lua
  if GuildCrafts.SyncPausePolicy and GuildCrafts.SyncPausePolicy:ShouldPause() then return end
  ```
- Comms registers `PLAYER_REGEN_ENABLED`, `PLAYER_ENTERING_WORLD` events to clear the pause state after grace timers expire
- Grace timers use `AceTimer:ScheduleTimer` to avoid firing while still transitioning

### File changes
- New file: `SyncPausePolicy.lua` (~60 lines)
- `Comms.lua`: add pause check at the top of `SendMessage`, `SendChunked`, `BroadcastHello`, `SendSyncRequest`, `BroadcastNewRecipes`, `BroadcastTimestampTouch`, `BroadcastProfessionRemoval`
- `GuildCrafts.toc`: add `SyncPausePolicy.lua` before `Comms.lua`
- `Core.lua`: instantiate module after AceAddon init

---

## 2 — Partial Scan Protection

**Priority: High | Effort: Low**

Prevent a partial or early-terminated profession scan from silently overwriting a complete existing entry. The WoW API sometimes returns 0 or very few recipes if the profession window hasn't finished loading, or if the client is under load. Merging this destroys good data.

### Detection heuristic
When `MergeIncoming` (or `ScanTradeSkill`/`ScanCraft`) is about to write a profession entry, compare the incoming recipe count against the stored count:

```
if incomingCount > 0 and existingCount > 0
   and incomingCount < (existingCount * 0.5)
then
    → skip merge, emit debug warning
end
```

The 50% threshold avoids false positives when a player genuinely unlearns half their recipes (which is very rare), while catching the common case of a 2-recipe scan replacing a 300-recipe entry.

### Self-scan vs incoming sync

The guard applies to both paths:
- **Local scan** (`ScanTradeSkill`, `ScanCraft`): if `GetNumTradeSkills()` returns a suspiciously low count compared to the stored count, skip the write and schedule a rescan after a 2s delay (when the window is more likely to be fully loaded)
- **Incoming sync** (`MergeIncoming`): check per-profession before merging. If suspicious, keep the existing entry and log which sender triggered the skip

### File changes
- `Data.lua`: add guard inside `MergeIncoming` and inside `ScanTradeSkill`/`ScanCraft` before writing
- No new files required

---

## 3 — Immediate Advertise Broadcast (AD message)

**Priority: High | Effort: Low–Medium**

Currently a new recipe scan only propagates to peers on the next full sync cycle (triggered by DR election or another HELLO). This means peers can be up to `SYNC_DELAY` + election time behind.

### New message type: `DELTA_AD`

When the local player scans a profession and the data changed, immediately broadcast a lightweight advertisement:

```lua
{
    type      = "DELTA_AD",
    sender    = playerKey,
    memberKey = playerKey,
    rev       = newTimestamp,
    profCounts = { ["Alchemy"] = 312, ["Engineering"] = 187 }
}
```

This message is tiny — no recipe data, just a timestamp and counts per profession.

### Receiver behaviour

Any peer who receives a `DELTA_AD` and sees that the advertised `rev` is newer than what they have stored for `memberKey` should:
1. Note the timestamp for display purposes immediately (the sender is clearly active and up to date)
2. If they are the DR: broadcast `DELTA_AD` to the guild so all non-DR nodes also get the hint
3. Queue a whisper-based `SYNC_REQUEST` for just that member after a short jitter (1–5s) to avoid a thundering-herd pull when the whole guild is online

### Distinction from existing `DELTA_UPDATE`

`DELTA_UPDATE` carries actual recipe data — it is the response. `DELTA_AD` is just the announcement that new data exists. Peers who already have a matching or newer timestamp ignore it. This keeps broadcast traffic minimal.

### File changes
- `Comms.lua`: add `MSG_DELTA_AD = "DELTA_AD"`, add `BroadcastLocalAdvertise()` called from `Core.lua` after a scan detects changes, add `HandleDeltaAd()` in the receive dispatcher
- `Core.lua`: call `Comms:BroadcastLocalAdvertise()` from `OnTradeSkillShow` and `OnCraftShow` when `changed == true`

---

## 4 — Chunk RESUME / Recovery

**Priority: Medium | Effort: Medium**

Currently if a chunk is dropped mid-transfer, the requester waits until `SYNC_TIMEOUT` (120s) before retrying the full transfer. Adding sequence-number acknowledgment allows partial recovery in ~4s.

### How it works

**Sender side:**
- Already assigns `chunkIndex` / `chunkTotal` to each chunk
- Add a `sessionId` field (unique per transfer, e.g. `memberKey:timestamp:randomSuffix`)
- Keep chunks in a short-lived outgoing session table keyed by `sessionId`, TTL ~35s

**Receiver side:**
- Track received chunk indices in a `partialReceive[memberKey]` table: `{ sessionId, seen = {[1]=true, [3]=true, ...}, total = N, lastProgressAt = time() }`
- After receiving any chunk, check if all `1..total` are present. If yes, finalize the merge and delete state
- Start a `PROGRESS_TIMEOUT` timer (4s) reset on each received chunk. If it fires and chunks are missing, send a `RESUME` message via whisper listing the missing seq numbers

**New message type: `SYNC_RESUME`:**
```lua
{
    type      = "SYNC_RESUME",
    sessionId = sessionId,
    memberKey = memberKey,
    missing   = { 2, 5, 7 }   -- seq numbers not yet received
}
```

**Sender on `SYNC_RESUME`:** resend only the listed chunks from the session table. If the session has already expired, send nothing — the normal timeout/retry path will handle it.

### Max resume attempts
Cap at 3 resume attempts per transfer. If chunks are still missing after that, fail the request normally and requeue.

### File changes
- `Comms.lua`: add `MSG_SYNC_RESUME`, `sessionId` generation, outgoing session table, `SendChunked` stores chunks, `HandleSyncResume`, `partialReceive` tracking in `HandleSyncResponse`, progress timeout via `AceTimer`
- `Data.lua`: no changes (merge path is unchanged)

---

## 5 — Per-Peer Backoff

**Priority: Medium | Effort: Medium**

Currently a sync timeout evicts the entire DR/BDR and forces a re-election. This is heavy-handed — the DR may be briefly unresponsive due to loading, instance transition, or chat throttle, not because it has crashed.

### Failure tracking

Maintain a per-peer failure table in `Comms`:
```lua
self.peerFailures = {
    ["Name-Realm"] = { count = N, lastFailedAt = timestamp }
}
```

- Increment `count` on: sync timeout, empty SYNC_RESPONSE when non-empty was expected, no SYNC_RESPONSE at all
- Reset `count` on: successful SYNC_RESPONSE from that peer, successful SYNC_PUSH from that peer
- Record `lastFailedAt` on every failure

### Backoff logic

Before dispatching a sync request to a peer, check:
```lua
if peer.count >= 2 and (time() - peer.lastFailedAt) < 45 then
    -- skip this peer this cycle, try BDR or other known nodes
end
```

This means a briefly broken DR is bypassed for 45s. During that window:
- If the local client is the next-best node (BDR), it promotes itself for the request
- If neither DR nor BDR are usable, find the next alphabetically sorted addon user who is not in backoff

### Distinguish from DR eviction

Full DR eviction (removing from `addonUsers`) is kept as a last resort after backoff exhaustion. Backoff is "skip this peer this round", eviction is "this node is dead".

### File changes
- `Comms.lua`: add `peerFailures` table, `MarkPeerFailure(key)`, `MarkPeerSuccess(key)`, `IsPeerBackedOff(key)` helpers; modify `HandleSyncRequest` responder selection and `OnSyncTimeout` retry logic to skip backed-off peers before escalating to eviction

---

## 6 — Tombstone Pruning (Zombie Fix)

**Priority: Medium | Effort: Low**

**The core problem:** When `PruneRoster()` removes a former guild member after the 7-day grace period, it does a hard delete: `gdb[memberKey] = nil`. Any peer who was offline during the grace window still carries a live entry for that member. When they come back online and sync, `MergeIncoming()` sees `localEntry = nil` and unconditionally accepts the stale data — resurrecting the ex-member as a zombie. The zombie then propagates to everyone that peer syncs with.

**The solution:** Replace hard deletes with tombstones so the fact of deletion outlives the data itself.

### How it works

**On pruning:** instead of `gdb[memberKey] = nil`, write:
```lua
gdb[memberKey] = { _tombstone = true, lastUpdate = time() }
```

**In `MergeIncoming()`:** before applying an incoming entry, check for a local tombstone:
```lua
if localEntry and localEntry._tombstone then
    if localEntry.lastUpdate >= incomingEntry.lastUpdate then
        -- Our tombstone is newer — reject the resurrection
        return
    end
    -- Incoming data is newer than our tombstone — accept it
    -- (member rejoined the guild and re-scanned)
end
```

**Tombstone propagation:** `GetVersionVector()` includes tombstone entries with their `lastUpdate` timestamp. When a peer with a tombstone syncs, `StripSyncFields()` returns a lightweight tombstone payload `{ _tombstone = true, lastUpdate = ts }`. The receiver's `MergeIncoming()` writes the tombstone if it is newer than what they hold, replacing any zombie live entry.

**Tombstone expiry:** Clean up tombstones that are older than 30 days in `PruneRoster()`. By that point every online peer will have received the tombstone through at least one sync cycle.

### File changes
- `Data.lua`: modify `PruneRoster()` — replace `gdb[memberKey] = nil` with tombstone write; add tombstone expiry (30 days); modify `MergeIncoming()` — add tombstone check before write and tombstone propagation on receive; modify `StripSyncFields()` — return `{ _tombstone = true, lastUpdate = ts }` for tombstone entries; modify `GetVersionVector()` — include tombstone entries

---

## Release Schedule

Five patches over 4–5 weeks. Each patch is self-contained, testable in-game before the next one starts, and delivers visible value on its own.

---

### Patch 1 — Data Safety (Week 1)
**Items: SyncPausePolicy + Partial Scan Protection**

Pure additions. No protocol changes, no risk to existing sync. Ships as a single small release.

- `SyncPausePolicy.lua` — suspend sync during combat, instances, zone transitions
- Partial scan guard in `Data.lua` — 50% threshold, skip + reschedule

Verification: enter combat, confirm no sync traffic in `/gc comms`. Open a profession window mid-load, confirm existing data is not wiped.

---

### Patch 2 — Faster Propagation (Week 2)
**Item: AD Broadcast**

First protocol change. New `DELTA_AD` message type. Old clients ignore unknown types so it is fully backwards compatible, but isolating it makes rollback clean if something unexpected happens.

- `DELTA_AD` broadcast immediately after a scan detects changes
- Peers queue a targeted pull on receipt

Verification: scan a new recipe, confirm guildmates receive it within seconds rather than waiting for the next full sync cycle.

---

### Patch 3 — Reliable Transfers (Week 3)
**Item: Chunk RESUME**

Most invasive change to the existing sync path. Needs to stand alone so any regression in chunked transfer can be attributed unambiguously.we sh

- `sessionId` on all chunks
- `partialReceive` tracking on the receiver
- `SYNC_RESUME` message with missing seq list
- 3-attempt cap before falling back to normal retry

Verification: simulate chunk loss in a large guild (20+ members), confirm recovery happens in ~4s rather than 120s.

---

### Patch 4 — Smarter Failure Handling (Week 4)
**Item: Per-Peer Backoff**

Depends on Patch 3 being stable. Small change but touches timeout logic which has historically been subtle.

- `peerFailures` table in `Comms`
- `MarkPeerFailure` / `MarkPeerSuccess` / `IsPeerBackedOff` helpers
- 45s backoff before escalating to DR eviction

Verification: take the DR offline mid-sync, confirm it is bypassed cleanly rather than causing a full re-election storm.

---

### Patch 5 — Zombie Fix + UI Polish (Week 5)
**Items: Tombstone Pruning + `[>]` → `[G]` button rename**

Pure `Data.lua` and `UI/MainFrame.lua` changes. No new wire messages, no protocol version bump. Ships last because the tombstone change modifies the prune path and merge path simultaneously — both should be tested against a live guild with users who have been offline for varying lengths of time.

- Replace hard-delete in `PruneRoster()` with tombstone write
- `MergeIncoming()` rejects incoming data that is older than a local tombstone
- Tombstones propagate via version vector and `StripSyncFields()` so all peers converge
- Tombstone expiry after 30 days keeps the database from accumulating stale markers
- Rename `[>]` button to `[G]` in the recipe browser — reduces confusion with expand-row chevrons

Verification: prune a member locally, take a peer offline before the prune runs on their client, have that peer come back online and sync — confirm the ex-member does not reappear. Confirm `[G]` button tooltip still reads correctly and posts to guild chat.

---

## Out of Scope for v2

- **AtlasLoot / TSM pricing integration** — requires significant UI changes and a separate data pipeline
- **Manifest layer** — GuildCrafts' per-member timestamp model is simpler than per-block fingerprinting and sufficient for guild scale
- **Bootstrap sync** — the existing DR → SYNC_REQUEST flow already handles first login correctly
- **Performance scheduler** — GuildCrafts' scan/render workload is light enough that `AceTimer` debouncing is adequate
- **Offline peer replication** — DR accumulates all member data via `SYNC_PUSH` and serves it in `SYNC_RESPONSE`; a new peer receives the full guild picture from the DR without needing separate replica routing
