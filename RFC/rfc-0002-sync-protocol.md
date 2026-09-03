# GuildCrafts Protocol — RFC 0002

**Status:** Informational  
**Applies to:** GuildCrafts v1.4.0 through v2.0.1
**Channel:** `GUILD` addon message channel (WoW Classic Era through MoP Classic)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Roles & Election](#2-roles--election)
   - 2.1 [Role Definitions](#21-role-definitions)
   - 2.2 [Election Algorithm](#22-election-algorithm)
   - 2.3 [Terms & Stale-Message Rejection](#23-terms--stale-message-rejection)
3. [Wire Format](#3-wire-format)
   - 3.1 [Channel & Transport](#31-channel--transport)
   - 3.2 [Envelope](#32-envelope)
   - 3.3 [Framing & Compression](#33-framing--compression)
   - 3.4 [Versioning & Compatibility](#34-versioning--compatibility)
4. [Message Reference](#4-message-reference)
   - 4.1 [HELLO](#41-hello)
   - 4.2 [HEARTBEAT](#42-heartbeat)
   - 4.3 [SYNC\_REQUEST](#43-sync_request)
   - 4.4 [SYNC\_RESPONSE](#44-sync_response)
   - 4.5 [SYNC\_PULL](#45-sync_pull)
   - 4.6 [SYNC\_PUSH](#46-sync_push)
   - 4.7 [DELTA\_UPDATE](#47-delta_update)
   - 4.8 [DELTA\_AD](#48-delta_ad)
   - 4.9 [SYNC\_RESUME](#49-sync_resume)
5. [Sync Protocol](#5-sync-protocol)
   - 5.1 [Login Sequence](#51-login-sequence)
   - 5.2 [Version Vector](#52-version-vector)
   - 5.3 [DR Response Logic](#53-dr-response-logic)
   - 5.4 [Retry & Escalation](#54-retry--escalation)
   - 5.5 [Per-Peer Backoff](#55-per-peer-backoff)
6. [Chunked Transfer Protocol](#6-chunked-transfer-protocol)
   - 6.1 [Chunking](#61-chunking)
   - 6.2 [RESUME Recovery](#62-resume-recovery)
7. [Delta Propagation](#7-delta-propagation)
   - 7.1 [DELTA\_UPDATE](#71-delta_update)
   - 7.2 [DELTA\_AD](#72-delta_ad)
8. [Tombstones & Pruning](#8-tombstones--pruning)
9. [Pause Policy](#9-pause-policy)
10. [Failure Recovery](#10-failure-recovery)
11. [Constants Reference](#11-constants-reference)

---

## 1. Overview

GuildCrafts synchronises guild members' profession recipe databases across all
addon users in the guild. There is no server component — peers communicate
exclusively through WoW's addon message channel.

The protocol uses a **Designated Router / Backup Designated Router** (DR/BDR)
model in which one node acts as the authoritative sync responder. All other
nodes request data from the DR (or BDR on failover). Delta broadcasts allow
newly scanned recipes to propagate without a full sync cycle.

The protocol is **eventually consistent**: all nodes converge to the same
guild database given sufficient time and message delivery. No locking or
two-phase commit is used.

---

## 2. Roles & Election

### 2.1 Role Definitions

| Role   | Description |
|--------|-------------|
| `NONE` | Initial state. No peers have been discovered yet. |
| `OTHER` | A known addon user; not DR or BDR. Requests data from the DR. |
| `BDR`  | Backup Designated Router. Responds to retry=1 sync requests and promotes to DR if the DR is lost. |
| `DR`   | Designated Router. Responds to all retry=0 sync requests, broadcasts heartbeats, and forwards DELTA\_ADs. |

### 2.2 Election Algorithm

Election is **fully decentralised** and requires no coordination messages.
Every node independently sorts the set of known addon users alphabetically by
`Name-Realm` key and assigns:

```
DR  = sorted[1]
BDR = sorted[2]
```

A node sets its own role by comparing its player key against `DR` and `BDR`.
Election runs whenever `addonUsers` changes (peer added, peer removed).

**Convergence prerequisite:** all nodes must have the same `addonUsers` set.
The HELLO handshake and post-sync HELLO sweep are the primary mechanisms for
achieving this. Nodes that miss HELLOs are discovered through SYNC\_REQUEST
visibility (any inbound message registers the sender as a known user).

### 2.3 Terms & Stale-Message Rejection

Each node maintains a monotone integer `currentTerm`, initially 0. Every time
a node is **promoted to DR** it increments `currentTerm`. The current term is
embedded in every outgoing message envelope.

**Adoption:** any node that receives a message carrying a term higher than
its own immediately adopts that term. If the receiving node is currently
acting as DR it steps down (stops heartbeats) and waits for the specific
message handler to re-register the sender and re-run election with complete
information.

**Rejection:** messages carrying a term lower than `currentTerm` are silently
dropped. This prevents a previously evicted DR — one that was inside an
instance while the network re-elected — from re-asserting authority after
rejoining.

---

## 3. Wire Format

### 3.1 Channel & Transport

| Distribution | Used for |
|---|---|
| `GUILD` | HELLO, HEARTBEAT, SYNC\_REQUEST, DELTA\_UPDATE, DELTA\_AD |
| `WHISPER` | SYNC\_RESPONSE, SYNC\_PULL, SYNC\_PUSH, SYNC\_RESUME |

All messages use AceComm-3.0's `SendCommMessage` with prefix `"GuildCrafts"`.
ChatThrottleLib is used internally by AceComm. Bulk-priority (`BULK`) is used
for SYNC\_RESPONSE and SYNC\_PUSH chunks; normal-priority (`NORMAL`) for
everything else.

### 3.2 Envelope

Every message is wrapped in an envelope table before serialisation:

```lua
{
    t    = "MSG_TYPE",    -- string message type identifier
    v    = <integer>,     -- sender's GuildCrafts.VERSION
    term = <integer>,     -- sender's current DR authority term
    p    = { ... },       -- message-specific payload (see §4)
}
```

### 3.3 Framing & Compression

The serialised envelope is prefixed with a single ASCII byte before
transmission:

| Prefix | Meaning |
|--------|---------|
| `U`    | Uncompressed — payload is raw AceSerializer output. |
| `Z`    | Compressed — payload is LibDeflate `CompressDeflate` output, then `EncodeForWoWAddonChannel`. |

Compression is applied when the serialised string exceeds **200 bytes** and
produces a shorter result. Receivers detect the prefix, decode, decompress
(if `Z`), and deserialise before routing.

Unknown prefix bytes are silently discarded.

### 3.4 Versioning & Compatibility

Two independent version integers exist:

| Field | Meaning |
|---|---|
| `GuildCrafts.VERSION` | Wire protocol version. Carried in every envelope. Nodes running a newer version show a one-time upgrade notice; the message is still processed. |
| `GuildCrafts.DATA_FORMAT_VERSION` | Data schema version. Stored per-entry in the guild DB. During sync, an entry whose `dataFormat` is lower than the local `DATA_FORMAT_VERSION` is added to the pull list even when timestamps match, so the DR can supply the up-to-date schema. |

---

## 4. Message Reference

All field descriptions refer to the `p` (payload) table inside the envelope.

### 4.1 HELLO

**Direction:** GUILD broadcast  
**Sent by:** any node

Announces the sender's presence. Triggers peer discovery and election.

| Field | Type | Description |
|---|---|---|
| `sender` | string | `Name-Realm` of the sender. |
| `version` | integer | Sender's `GuildCrafts.VERSION`. |
| `isReply` | boolean? | If true, this is a reply HELLO and should not trigger further cascading replies. |
| `discover` | boolean? | If true, all nodes reply even if they already know the sender (post-sync sweep). |

**Behaviour on receipt:**
1. Register the sender in `addonUsers`.
2. Run election.
3. If the sender is new and `isReply` is not set: send a jittered HELLO reply (0.5–4.0 s) to enable bidirectional discovery.
4. If the sender is new and a sync is not already pending: schedule a debounced re-sync (10 s).

### 4.2 HEARTBEAT

**Direction:** GUILD broadcast  
**Sent by:** DR only, every 60 s

Proves the DR is alive. Non-DR nodes reset their watchdog timer on receipt.

| Field | Type | Description |
|---|---|---|
| `dr` | string | `Name-Realm` of the current DR. |
| `timestamp` | integer | Unix timestamp of transmission. |

**Behaviour on receipt:**
- Update `lastDRHeartbeat` timestamp.
- If `payload.term < currentTerm`: drop the message.
- Re-run election; update sync indicator.

**DR watchdog:** non-DR nodes check heartbeat freshness every 60 s. If no
heartbeat has been received in 180 s (`HEARTBEAT_TIMEOUT`) and the player is
not inside an instance, the DR entry is removed from `addonUsers` and
election re-runs. The node that wins the new election becomes the DR and
immediately begins broadcasting heartbeats.

### 4.3 SYNC\_REQUEST

**Direction:** GUILD broadcast  
**Sent by:** non-DR nodes

Requests a state sync. Carries the requester's version vector so the
responder can compute exactly what data to send.

| Field | Type | Description |
|---|---|---|
| `sender` | string | `Name-Realm` of the requester. |
| `vector` | table | Version vector: `{ ["Name-Realm"] = lastUpdate, ... }` |
| `retry` | integer | 0 = first attempt (DR should respond); 1 = retry (DR or BDR should respond); ≥2 = open round (any newly elected DR responds). |

### 4.4 SYNC\_RESPONSE

**Direction:** WHISPER to requester  
**Sent by:** DR (or BDR on retry=1)

Carries member entries that the responder has and the requester lacks or
has stale copies of. Delivered in chunks (see §6).

| Field | Type | Description |
|---|---|---|
| `data` | table | `{ ["Name-Realm"] = memberEntry, ... }` Subset of the guild DB. May be empty (`{}`). |
| `chunkIndex` | integer | 1-based index of this chunk. |
| `chunkTotal` | integer | Total number of chunks in this transfer. |
| `sessionId` | string? | Unique transfer ID for RESUME recovery (absent in pre-Patch-3 senders). |

An empty SYNC\_RESPONSE (data = `{}`, chunkIndex = 1, chunkTotal = 1) is
always sent when the responder has nothing new, to prevent the requester from
timing out unnecessarily.

### 4.5 SYNC\_PULL

**Direction:** WHISPER to requester  
**Sent by:** DR (or BDR)

Sent alongside SYNC\_RESPONSE when the responder's version vector reveals
that the requester holds newer data for one or more members.

| Field | Type | Description |
|---|---|---|
| `memberKeys` | array | `["Name-Realm", ...]` — member keys whose data the responder wants. |

### 4.6 SYNC\_PUSH

**Direction:** WHISPER to DR  
**Sent by:** requester (fulfilling a SYNC\_PULL)

Contains the member entries requested via SYNC\_PULL. Delivered in chunks.

| Field | Type | Description |
|---|---|---|
| `data` | table | `{ ["Name-Realm"] = memberEntry, ... }` |
| `chunkIndex` | integer | 1-based index of this chunk. |
| `chunkTotal` | integer | Total number of chunks in this transfer. |

### 4.7 DELTA\_UPDATE

**Direction:** GUILD broadcast  
**Sent by:** any node, immediately after a local profession scan

Announces recipe changes without waiting for the next sync cycle. Three
sub-types:

| `type` value | Meaning |
|---|---|
| `"add"` | New or updated recipes for a profession. |
| `"remove_profession"` | An entire profession was dropped by the member. |
| `"touch"` | Timestamp-only heartbeat for a profession with no new recipes (prevents pruning). Rate-limited to once per hour per profession. |

Common fields:

| Field | Type | Description |
|---|---|---|
| `type` | string | Sub-type (see above). |
| `member` | string | `Name-Realm` of the guild member whose data changed. |
| `profession` | string | Canonical profession name (English). |
| `lastUpdate` | integer | Unix timestamp of the scan. |

Additional fields for `"add"`:

| Field | Type | Description |
|---|---|---|
| `recipes` | table | `{ [recipeKey] = recipeData, ... }` Reagent data is stripped for size. |

### 4.8 DELTA\_AD

**Direction:** GUILD broadcast  
**Sent by:** any node (forwarded by DR)

Lightweight advertisement — no recipe data. Sent immediately after a local
scan produces new recipes. Peers that are behind on the advertised member
schedule a jittered SYNC\_REQUEST (1–5 s) to pull the full data.

| Field | Type | Description |
|---|---|---|
| `sender` | string | Originating node. |
| `memberKey` | string | `Name-Realm` of the member with new data. |
| `rev` | integer | Unix timestamp of the new revision (used to compare against local copy). |
| `profCounts` | table? | Per-profession recipe counts (informational). |
| `forwarded` | boolean? | Set to true when the DR re-broadcasts the ad to reach nodes that missed the original. Prevents re-forwarding loops. |

**DR forwarding:** when the DR receives a DELTA\_AD it re-broadcasts it with
`forwarded = true` so nodes that were offline or missed the original broadcast
receive the hint.

### 4.9 SYNC\_RESUME

**Direction:** WHISPER to sender of the in-progress SYNC\_RESPONSE  
**Sent by:** requester

Requests retransmission of specific missing chunks from an in-progress
chunked transfer.

| Field | Type | Description |
|---|---|---|
| `sessionId` | string | The session ID from the SYNC\_RESPONSE chunks. |
| `missing` | array | `[seqNum, ...]` — 1-based indices of chunks not yet received. |

---

## 5. Sync Protocol

### 5.1 Login Sequence

```
t=0s   Player logs in / UI loads
t=3s   BroadcastHello (HELLO → GUILD)
t=15s  SendSyncRequest (SYNC_REQUEST retry=0 → GUILD)
       ├── DR responds with SYNC_RESPONSE (whisper, chunked)
       ├── DR sends SYNC_PULL if requester has newer data (whisper)
       └── Requester responds to SYNC_PULL with SYNC_PUSH (whisper, chunked)
t+5s   Post-sync HELLO sweep (discover=true → GUILD)
```

The 12-second gap between HELLO and SYNC\_REQUEST (15 − 3) allows HELLO
replies from other online nodes to arrive and populate `addonUsers` before
election runs. This reduces false-DR promotions at login.

### 5.2 Version Vector

The version vector is a flat table mapping each known member key to that
member's most recent `lastUpdate` Unix timestamp:

```lua
{ ["Alice-Realm"] = 1700000000, ["Bob-Realm"] = 1700001234, ... }
```

During `ProcessSyncRequest` the DR compares its local vector against the
incoming vector:

- **Local ahead** (local `ts > incoming ts`, or key absent from incoming):
  entry is included in SYNC\_RESPONSE.
- **Requester ahead** (incoming `ts > local ts`, or key absent locally):
  member key is added to SYNC\_PULL list.
- **Equal timestamp but lower `dataFormat`**: member key is added to
  SYNC\_PULL list to trigger a schema-upgrade push.
- **Equal and current**: entry is skipped.

### 5.3 DR Response Logic

A node responds to a SYNC\_REQUEST only when its role and the request's
`retry` value match:

| `retry` | Responder |
|---------|-----------|
| 0 | DR only |
| 1 | DR **or** BDR |
| ≥2 | Any newly elected DR (after evicting non-responding peers) |

The DR queues concurrent SYNC\_REQUESTs and processes them one at a time to
prevent interleaved chunk streams. The `syncProcessing` flag is cleared only
after the final chunk of a response has been sent (via `onComplete` callback).

### 5.4 Retry & Escalation

```
SYNC_REQUEST (retry=0)
    ├── DR responds → done
    └── Timeout after 120s (SYNC_TIMEOUT)
            → Mark DR failure, syncRetryCount = 1
            → SYNC_REQUEST (retry=1)
                ├── DR or BDR responds → done
                └── Timeout after 15s (SYNC_RETRY_TIMEOUT)
                        → Mark BDR failure, syncRetryCount = 2
                        → Evict non-backed-off DR and BDR from addonUsers
                        → Re-run election
                        → SYNC_REQUEST (retry=2)
                            ├── New DR responds → done
                            └── Timeout after 15s
                                    → All retries exhausted; syncPending = false
```

Target snapshots (`_syncTargetedDR`, `_syncTargetedBDR`) are captured at the
moment each SYNC\_REQUEST is sent. Failure marks are applied to these
snapshots, not to the live `currentDR`/`currentBDR`, to avoid penalising a
peer that was elected mid-flight and never had a chance to respond.

### 5.5 Per-Peer Backoff

Each node tracks per-peer failure counts:

- **Increment:** on each SYNC\_TIMEOUT attributable to that peer.
- **Decrement / clear:** on a successful SYNC\_RESPONSE or SYNC\_PUSH from
  that peer.
- **Backed-off condition:** `count ≥ 2` **and** the most recent failure was
  within the last 45 seconds.

A backed-off DR at retry=0 causes the effective retry to be promoted to 1
immediately, so the BDR is targeted directly without waiting for a full
120-second timeout.

Backed-off peers are skipped during eviction at retry=2. The table is pruned
automatically when a backoff window expires to avoid unbounded growth over a
long session.

---

## 6. Chunked Transfer Protocol

### 6.1 Chunking

Member data tables exceeding `SYNC_CHUNK_SIZE` (5) members are split into
chunks and sent at a rate of one chunk per second (`SYNC_CHUNK_DELAY`). This
prevents burst lag from large guilds and stays within ChatThrottleLib limits.

Each chunk payload includes `chunkIndex`, `chunkTotal`, and a `sessionId`
that uniquely identifies the transfer:

```
sessionId = "<target>:<unix_time>:<4-digit-random>"
```

The sender retains a copy of every chunk for `SESSION_TTL` (35 s) to allow
RESUME retransmission.

### 6.2 RESUME Recovery

If the receiver stops seeing new chunks for `PROGRESS_TIMEOUT` (4 s) and the
transfer is not yet complete, it sends a SYNC\_RESUME whisper listing the
missing sequence numbers. The sender re-transmits only the identified chunks.

Up to `MAX_RESUME_ATTEMPTS` (3) RESUME requests are made before the receiver
abandons recovery and waits for the main `SYNC_TIMEOUT` to fire a full retry.

The main sync timeout (`SYNC_TIMEOUT`) is reset whenever a chunk arrives or a
RESUME is sent, giving the recovery process adequate time to complete.

If the sender's session has expired (the `SESSION_TTL` elapsed), the sender
logs a debug message and takes no action. The receiver's `SYNC_TIMEOUT` will
eventually fire and initiate a full retry.

**Security note:** on receipt of SYNC\_RESUME, the sender always transmits to
`session.target` (captured when the session was created), not to the `sender`
field of the RESUME message. This prevents a spoofed SYNC\_RESUME from
redirecting chunk retransmission to an unintended recipient.

---

## 7. Delta Propagation

### 7.1 DELTA\_UPDATE

Sent immediately after a local scan detects changes. Does not replace the
full sync mechanism — it is an optimisation to avoid waiting for the next
SYNC\_REQUEST cycle.

Sub-type `"touch"` is rate-limited to once per hour per profession to prevent
flooding the DR when a player opens profession windows repeatedly. Tombstone
entries are explicitly guarded: a `"touch"` update will never advance a
tombstone's `lastUpdate`, which would block the resurrection of a member who
genuinely rejoined the guild.

### 7.2 DELTA\_AD

Sent in addition to (not instead of) DELTA\_UPDATE. The advertisement carries
no recipe data; peers that are behind queue a SYNC\_REQUEST with jitter to
retrieve the full update. This staggers requests across the guild, avoiding a
thundering-herd burst when a popular member scans a large profession.

The DR always forwards received DELTA\_ADs (with `forwarded = true`) to reach
nodes that were not in range of the original broadcast.

---

## 8. Tombstones & Pruning

When a guild member is pruned (ex-guild after 7-day grace period, or
still-in-guild but inactive for 45 days), the entry is replaced with a
lightweight tombstone rather than deleted:

```lua
{ _tombstone = true }
```

Tombstones propagate through the normal sync mechanism. Any peer that still
holds a live entry for the ex-member will overwrite it with the tombstone on
their next sync, as long as the local version vector shows the tombstone is
newer.

**Resurrection guard:** `MergeIncoming` will not overwrite a local tombstone
with incoming live data unless the live data's `lastUpdate` is strictly greater
than the tombstone's `lastUpdate`. If a member genuinely rejoins and re-scans,
their new timestamp satisfies this condition.

**Expiry:** tombstones are excluded from the 45-day inactivity check and
expire after 30 days, at which point they are hard-deleted.

---

## 9. Pause Policy

Bulk sync traffic — SYNC\_REQUEST, SYNC\_RESPONSE, SYNC\_PULL, SYNC\_PUSH,
DELTA\_UPDATE, and DELTA\_AD — is suppressed while
`SyncPausePolicy:ShouldPause()` returns true.

Signaling messages required for role-election consistency bypass the pause
policy and always transmit:

- `HEARTBEAT` — the DR's 60-second keepalive
- `HELLO` — login and reply discovery
- `GC_ACK` — addon-channel dedup signal for the `!gc` responder

These are single tiny packets (≤ ~50 bytes) and were never the source of the
chat-throttle pressure the pause was designed to prevent. Suppressing them
caused split-brain elections in players who were regularly in combat or
transitioning zones (both nodes' `addonUsers` sets never converged, so both
computed `myRole = "DR"` and answered `!gc` in parallel).

Pause conditions and grace periods:

| Condition | Trigger | Grace period after clearing |
|---|---|---|
| In combat | `PLAYER_REGEN_DISABLED` | 6 s after `PLAYER_REGEN_ENABLED` |
| In instance | `IsInInstance() == true` at zone enter | 15 s |
| Zone transition | `PLAYER_ENTERING_WORLD` (non-login) | 12 s |

Grace periods prevent a burst of queued messages from flooding the channel
immediately after leaving combat or an instance. Conditions and timers are
tracked independently; `ShouldPause()` returns true if any flag is set.

Callers that are suppressed by the pause policy reschedule themselves (e.g.
`SendSyncRequest` in 10 s). The DR's `SendChunked` calls `onComplete`
immediately when suppressed so the sync queue does not deadlock; affected
requesters will time out and retry normally.

The DR heartbeat watchdog explicitly suppresses eviction while the player is
inside an instance, since GUILD addon messages are not delivered across
instance boundaries.

---

## 10. Failure Recovery

| Scenario | Recovery mechanism |
|---|---|
| DR goes offline or becomes unreachable | DR watchdog detects heartbeat gap > 180 s; removes DR from `addonUsers`; re-election promotes BDR to DR. |
| DR temporarily unresponsive (loading screen, throttle) | Per-peer backoff: after 2 failures within 45 s, BDR is targeted directly without evicting the DR. DR recovers automatically when it responds. |
| BDR unresponsive | Retry=1 timeout attributes failure to BDR; retry=2 evicts both and re-elects. |
| False DR election at login (self is only known user) | SYNC\_REQUEST is skipped (DR skips self-requests). When the real DR is discovered via HELLO reply or incoming message, the false-DR detects demotion and schedules a 10-second debounced sync. |
| Chunks dropped in transit | RESUME recovery requests only the missing sequence numbers. After `MAX_RESUME_ATTEMPTS` exhaustion, the main sync timeout initiates a full retry. |
| Node was inside an instance during re-election | Early term adoption: the first message the node receives from the new network carries the higher term, causing immediate step-down. The node re-syncs on the next SYNC\_REQUEST cycle. |
| Stale DR sends old data after eviction | Term enforcement drops any message with `term < currentTerm`. |

---

## 11. Constants Reference

| Constant | Value | Description |
|---|---|---|
| `PREFIX` | `"GuildCrafts"` | AceComm addon message prefix. |
| `HELLO_DELAY` | 3 s | Delay after login before sending the initial HELLO. |
| `SYNC_DELAY` | 15 s | Delay after login before sending the initial SYNC\_REQUEST. |
| `HEARTBEAT_INTERVAL` | 60 s | How often the DR broadcasts HEARTBEAT. |
| `HEARTBEAT_TIMEOUT` | 180 s | Inactivity threshold before the DR is presumed dead (3 missed heartbeats). |
| `SYNC_TIMEOUT` | 120 s | How long to wait for a SYNC\_RESPONSE before the first retry. |
| `SYNC_RETRY_TIMEOUT` | 15 s | How long to wait on subsequent retries. |
| `SYNC_CHUNK_SIZE` | 5 | Maximum member entries per chunk. |
| `SYNC_CHUNK_DELAY` | 1.0 s | Interval between successive chunks. |
| `PROGRESS_TIMEOUT` | 4 s | Chunk-gap threshold before sending SYNC\_RESUME. |
| `SESSION_TTL` | 35 s | How long the sender keeps an outbound chunk cache. |
| `MAX_RESUME_ATTEMPTS` | 3 | RESUME requests before falling back to full retry. |
| `AD_JITTER_MIN` | 1 s | Minimum jitter for DELTA\_AD-triggered sync pull. |
| `AD_JITTER_MAX` | 5 s | Maximum jitter for DELTA\_AD-triggered sync pull. |
| `GRACE_COMBAT` | 6 s | Post-combat pause grace period. |
| `GRACE_INSTANCE` | 15 s | Post-instance pause grace period. |
| `GRACE_TRANSITION` | 12 s | Post-zone-transition pause grace period. |
