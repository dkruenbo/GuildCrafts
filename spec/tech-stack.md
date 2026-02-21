# GuildCrafts — Tech Stack

## Platform
- **Game**: World of Warcraft — The Burning Crusade Anniversary (Classic TBC client, API version 2.5.x)
- **Language**: Lua 5.1 (WoW embedded runtime)
- **UI Markup**: XML (for frame templates) + Lua (for dynamic UI creation)

## Addon Structure
```
GuildCrafts/
├── GuildCrafts.toc              -- Addon metadata & file load order
├── Core.lua                     -- Initialization, event handling, slash commands
├── Comms.lua                    -- Guild addon channel sync (all messages over GUILD prefix)
├── Data.lua                     -- SavedVariables read/write, data merging
├── CraftRequest.lua             -- Craft request/queue logic
├── UI/
│   ├── MainFrame.xml            -- Main window frame template (title bar, two-panel split)
│   ├── MainFrame.lua            -- Main window behavior, panel switching, resize
│   ├── LeftPanel.lua            -- Navigation: profession list, member list, breadcrumbs
│   ├── DetailPanel.lua          -- Right panel: recipe list, search results, empty states
│   ├── SearchBar.lua            -- Live search input, scope dropdown, debounce logic
│   ├── CraftRequestPopup.xml    -- Craft request popup template (Accept / Decline)
│   ├── CraftRequestPopup.lua    -- Popup stacking, sound, dismiss behavior
│   ├── CraftQueuePanel.xml      -- Collapsible craft queue template (docked to bottom)
│   └── CraftQueuePanel.lua      -- Queue list, complete/dismiss, persistence
├── Libs/                        -- Embedded libraries
│   ├── AceAddon-3.0/
│   ├── AceComm-3.0/             -- Addon messaging over guild channel
│   ├── AceSerializer-3.0/       -- Data serialization for comms
│   ├── AceDB-3.0/               -- SavedVariables management
│   ├── AceGUI-3.0/              -- Widget toolkit for UI
│   ├── ChatThrottleLib/         -- Throttle outgoing addon messages
│   └── LibDeflate/              -- Compression for large payloads
└── README.md
```

## Key Libraries
| Library | Purpose |
|---|---|
| **AceAddon-3.0** | Addon lifecycle (OnInitialize, OnEnable) |
| **AceComm-3.0** | Send/receive addon messages over hidden `GUILD` addon channel |
| **AceSerializer-3.0** | Serialize Lua tables for transmission |
| **AceDB-3.0** | Structured SavedVariables with defaults & profiles |
| **AceGUI-3.0** | UI widgets (frames, scroll lists, buttons, labels) |
| **ChatThrottleLib** | Prevent disconnects from message flooding |
| **LibDeflate** | Compress serialized payloads before transmission |

## WoW API Surface (key functions used)
- `GetNumTradeSkills()`, `GetTradeSkillInfo(index)` — scan the player's open profession window for recipes. Returns `skillName, skillType, ...` — filter out `skillType == "header"` rows.
- `ExpandTradeSkillSubClass(index)` — expand collapsed skill headers before scanning (iterate backwards to avoid index shifting).
- `GetTradeSkillItemLink(index)` — get the item link for a recipe's crafted item (returns nil for most Enchanting recipes).
- `GetTradeSkillRecipeLink(index)` — get the spell link for a recipe (used as fallback for Enchanting; extract spellID).
- `TRADE_SKILL_SHOW` event — fires when the profession window opens; triggers a re-scan for new recipes.
- `GetNumSkillLines()`, `GetSkillLineInfo()` — enumerate the player's known professions on login to detect profession changes (does **not** require the profession window to be open).
- `C_ChatInfo.RegisterAddonMessagePrefix()`, `C_ChatInfo.SendAddonMessage()` — addon-to-addon comms.
- `GetGuildRosterInfo()`, `GetNumGuildMembers()` — guild member enumeration.
- `SendChatMessage()` — whisper fallback for craft requests to non-addon users.
- `CreateFrame()`, XML templates — UI construction.

## Data Persistence
- **SavedVariables** declared in `.toc`: `GuildCraftsDB` (account-wide merged guild data).
- Uses AceDB-3.0 for defaults, per-character profiles, and global (cross-character) storage.

## Communication Protocol (Gossip + OSPF-Style DR/BDR)
- **Prefix**: `"GuildCrafts"` (registered via `RegisterAddonMessagePrefix`).
- **Broadcast channel**: `GUILD` distribution type for broadcasts (`HELLO`, `HEARTBEAT`, `DELTA_UPDATE`, `SYNC_REQUEST`, `CRAFT_*` messages).
- **Unicast channel**: `WHISPER` distribution type for `SYNC_RESPONSE` — sent directly from DR to requester to avoid flooding all online members with large payloads. **Note:** `SendAddonMessage(prefix, data, "WHISPER", target)` is invisible addon-to-addon communication — it does NOT produce a visible whisper in the chat window. It only fires the hidden `CHAT_MSG_ADDON` event that addons listen for. This is fundamentally different from `SendChatMessage()` which produces visible chat.
- **Serialization**: AceSerializer-3.0 → compressed with LibDeflate for large payloads.
- Messages are throttled via ChatThrottleLib to avoid disconnects. `SYNC_RESPONSE` uses `BULK` priority; `DELTA_UPDATE` uses `NORMAL` priority.
- **Designated Router (DR)**: Only the DR responds to `SYNC_REQUEST` messages, preventing channel flooding. A BDR stands by for failover.

### DR / BDR Election
- Election is **deterministic** — the online addon user with the lexicographically lowest `CharacterName-Realm` is DR; second-lowest is BDR.
- No election negotiation messages needed; every node computes the same result from the same online user list.
- Re-election triggers: `HELLO` from a new addon user, DR heartbeat timeout, `GUILD_ROSTER_UPDATE` (someone goes offline).

### Addon User List Maintenance
Each node maintains a local list of online addon users (needed for DR/BDR election and craft request routing):
- **Addition**: When a `HELLO` message is received, the sender is added to the list. The DR/BDR election is recomputed.
- **Removal**: On `GUILD_ROSTER_UPDATE`, any addon user whose `isOnline` flag is false is removed from the list and the election is recomputed. Additionally, if the DR's `HEARTBEAT` is missed for a configurable number of intervals, the DR is considered offline.
- The list is ephemeral (not persisted) — rebuilt from scratch each session via incoming `HELLO` messages.

### Message Types
| Message | Direction | Payload | When |
|---|---|---|---|
| `HELLO` | Broadcast → GUILD | Sender name, addon version | On login / reload — announces addon presence (triggers election recomputation) |
| `HEARTBEAT` | Broadcast → GUILD (DR only) | DR name, timestamp | Periodic (e.g. every 60s) — proves DR is alive |
| `DELTA_UPDATE` | Broadcast → GUILD | Type (`add` or `remove_profession`), member, profession, recipe data (if add), new `lastUpdate` | Player learns a recipe or drops a profession |
| `SYNC_REQUEST` | Broadcast → GUILD | Version vector (`{ [member] = lastUpdate, ... }`), requester name, retry flag (false/true) | Player logs in or `/reload`s (retry=true on second attempt if DR failed) |
| `SYNC_RESPONSE` | Addon WHISPER → requester (DR only, invisible) | Chunked recipe entries the requester is missing (one chunk per profession) | DR has newer data than requester |
| `SYNC_PULL` | Addon WHISPER → requester (DR only, invisible) | List of member keys where requester has newer `lastUpdate` | DR detects requester has data the DR is missing |
| `SYNC_PUSH` | Addon WHISPER → DR (requester, invisible) | Recipe entries for the requested member keys | Requester responds to `SYNC_PULL` — DR merges & broadcasts `DELTA_UPDATE`s |
| `CRAFT_REQUEST` | Addon WHISPER → target crafter (invisible) | Item name, requester name | Player clicks "Request Craft" (online crafters only). If target is not in addon user list, falls back to visible `SendChatMessage()` whisper. |
| `CRAFT_ACCEPT` | Addon WHISPER → requester (invisible) | Item name, crafter name | Crafter accepts request |
| `CRAFT_DECLINE` | Addon WHISPER → requester (invisible) | Item name, crafter name | Crafter declines request |
| `CRAFT_COMPLETE` | Addon WHISPER → requester (invisible) | Item name, crafter name | Crafter marks request done |

### Sync Flow (with DR — bidirectional)
```
Player4 logs in
  │
  ├─► Broadcasts HELLO over GUILD (triggers election recomputation on all nodes)
  ├─► Broadcasts SYNC_REQUEST { versionVector } over GUILD
  │
  │   DR (e.g. Player2) receives SYNC_REQUEST, compares version vectors:
  │
  │   Case A — DR is ahead (DR has data Player4 is missing):
  ├─◄   DR WHISPERs SYNC_RESPONSE to Player4
  │     (chunked by profession, BULK priority)
  │
  │   Case B — Player4 is ahead (Player4 has data DR is missing):
  ├─◄   DR WHISPERs SYNC_PULL to Player4 (list of member keys needed)
  ├─►   Player4 WHISPERs SYNC_PUSH back to DR (the requested entries)
  ├─◄   DR merges, then broadcasts DELTA_UPDATEs over GUILD
  │     (so all other online nodes also get the new data)
  │
  │   Case C — Both directions:
  │     DR sends both SYNC_RESPONSE and SYNC_PULL simultaneously.
  │
  │   BDR (e.g. Player3) monitors:
  │     - BDR cannot see WHISPER-based responses, so it relies on
  │       the requester's retry: if Player4 broadcasts a second
  │       SYNC_REQUEST with retry=true, BDR takes over as acting DR.
  │     - If DR's HEARTBEAT has also stopped, BDR promotes permanently.
  │
  └─► Player4 merges response progressively (union, append-only)

Delta flow (no DR gating):
  Player1 learns recipe
  │
  └─► Broadcasts DELTA_UPDATE over GUILD → ALL online nodes merge immediately
```

### Deduplication
- Since only the DR responds to `SYNC_REQUEST`, duplicate responses are eliminated by design.
- `SYNC_RESPONSE` is sent via WHISPER directly to the requester, so no other addon user receives or processes it.
- In the fallback case (DR + BDR both silent, open response round), the receiver deduplicates by `(member, profession, recipeKey)` — if a recipe already exists locally, it is skipped. `recipeKey` is `itemID` for most professions or `spellID` for Enchanting.
- Craft request/response messages include target player names — only the intended recipient acts on them.

### Guild Roster Pruning
- On `GUILD_ROSTER_UPDATE` and at login, the addon fetches the current guild roster.
- Any member key in `GuildCraftsDB` not present in the roster is **deleted** from local storage.
- Pruned members are never included in `SYNC_RESPONSE` payloads, so the deletion propagates to other nodes as they sync.
- This ensures data for `/gquit` or `/gkick`ed players is removed across all addon users.

## Build & Development
- No build step required — pure Lua/XML loaded by the WoW client.
- Place the `GuildCrafts/` folder in `Interface/AddOns/`.
- `/reload` in-game to reload the addon during development.
- Use `/dump` and BugSack/BugGrabber for debugging.