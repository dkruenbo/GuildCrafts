# GuildCrafts Protocol — RFC 0001

**Status:** Informational  
**Applies to:** GuildCrafts v1.0.0+

---

## Table of Contents

1. [Purpose](#1-purpose)
2. [Module Map](#2-module-map)
3. [Initialization Order](#3-initialization-order)
4. [Inter-Module Communication](#4-inter-module-communication)
5. [Library Dependencies](#5-library-dependencies)
6. [SavedVariables Overview](#6-savedvariables-overview)
7. [Key Game Events](#7-key-game-events)
8. [Data Flow: Recipe Scan](#8-data-flow-recipe-scan)
9. [Data Flow: Peer Sync](#9-data-flow-peer-sync)

---

## 1. Purpose

This document provides a high-level map of GuildCrafts' internal structure:
what modules exist, how they are loaded, and how they communicate. It is the
entry point for contributors before diving into protocol (RFC-0002), data
schema (RFC-0003), or UI (RFC-0004) specifics.

---

## 2. Module Map

```
GuildCrafts (AceAddon-3.0 root)
│
├── Core.lua            — Addon bootstrap, lifecycle events, slash commands,
│                         guild chat responder (!gc), post-crafters formatter
│
├── Data.lua            — SavedVariables management, profession/recipe scanning,
│                         merging, pruning, online-status cache, locale helpers
│
├── Data_TBC.lua        — Static lookup table: TBC_ITEM_IDS maps every TBC
│                         recipe spell/item ID to 1 (expansion filter support)
│
├── SyncPausePolicy.lua — Combat/instance/zone-transition pause guards;
│                         public ShouldPause() API consumed by Comms
│
├── Comms.lua           — All guild channel sync: HELLO/HEARTBEAT, DR/BDR
│                         election, SYNC_REQUEST/RESPONSE/PULL/PUSH,
│                         DELTA_UPDATE, DELTA_AD, SYNC_RESUME
│
├── Favorites.lua       — Per-character favorites list (SavedVariablesPerCharacter)
│
├── Tooltip.lua         — GameTooltip/ItemRefTooltip hook: shows guild crafters
│                         when hovering an item
│
├── MinimapButton.lua   — LibDBIcon minimap button; opens/closes the main window
│
└── UI/
    └── MainFrame.lua   — Entire UI: member list, recipe browser, search panel,
                          favorites panel, sync indicator, resize/drag
```

All modules are AceAddon-3.0 modules created with
`GuildCrafts:NewModule(name, ...)`. The addon root object is stored globally
as `_G.GuildCrafts` so each file can access it with a local alias.

---

## 3. Initialization Order

WoW loads `.toc` entries in declaration order. AceAddon then fires lifecycle
hooks in a deterministic sequence:

```
1.  Libs loaded            (embeds.xml → AceAddon, AceComm, AceDB, etc.)
2.  Core.lua loaded        → GuildCrafts root object created, _G.GuildCrafts set
3.  Data.lua loaded        → Data module registered
4.  Data_TBC.lua loaded    → GuildCrafts.TBC_ITEM_IDS populated
5.  SyncPausePolicy.lua    → SyncPausePolicy module registered
6.  Comms.lua loaded       → Comms module registered
7.  Favorites.lua loaded   → Favorites module registered
8.  Tooltip.lua loaded     → Tooltip module registered
9.  MinimapButton.lua      → MinimapButton module registered
10. UI/MainFrame.lua       → UI namespace populated

--- ADDON_LOADED fires ---

11. GuildCrafts:OnInitialize()
    ├── Data:OnInitialize()       — AceDB setup, RecipeDB migration
    └── GuildCrafts:RegisterChatCommand("/gc")

12. GuildCrafts:OnEnable()
    ├── Data:OnEnable()
    ├── SyncPausePolicy:OnEnable() — registers combat/zone events, captures
    │                                initial state
    ├── Comms:OnEnable()           — registers AceComm prefix
    ├── Tooltip:OnEnable()         — hooks tooltip system
    └── MinimapButton:OnEnable()   — creates minimap button

--- PLAYER_LOGIN fires ---

13. GuildCrafts:OnPlayerEnteringWorld(isLogin=true)
    └── ScheduleTimer("OnLoginReady", 5s)

--- 5 seconds later ---

14. GuildCrafts:OnLoginReady()
    ├── Data:DetectProfessions()
    │   └── Data:DetectSpecialisations()
    └── Comms:OnLoginReady()
        └── ScheduleTimer("BroadcastHello", 3s)
```

---

## 4. Inter-Module Communication

Modules communicate through direct method calls on the shared `GuildCrafts`
global. There is no event bus or message broker — modules call each other by
name.

| Caller | Calls | Purpose |
|--------|-------|---------|
| `Core` | `Data:DetectProfessions()` | Login-time profession scan |
| `Core` | `Data:ScanTradeSkill()` | TRADE\_SKILL\_SHOW event |
| `Core` | `Data:ScanCraft()` | CRAFT\_SHOW event (Enchanting) |
| `Core` | `Data:RebuildOnlineCache()` | GUILD\_ROSTER\_UPDATE |
| `Core` | `Data:PruneRoster()` | GUILD\_ROSTER\_UPDATE (out of combat) |
| `Core` | `Comms:OnLoginReady()` | 5s post-login init |
| `Core` | `Comms:OnGuildRosterUpdate()` | GUILD\_ROSTER\_UPDATE |
| `Core` | `UI:UpdateSyncIndicator()` | GUILD\_ROSTER\_UPDATE |
| `Data` | `Comms:BroadcastNewRecipes()` | After scan finds new recipes |
| `Data` | `Comms:BroadcastProfessionRemoval()` | Dropped profession detected |
| `Data` | `Comms:BroadcastLocalAdvertise()` | After scan (DELTA\_AD) |
| `Data` | `Comms:BroadcastTimestampTouch()` | Scan with no new recipes, data 25+ days old |
| `Comms` | `Data:MergeIncoming()` | SYNC\_RESPONSE received |
| `Comms` | `Data:MergeDelta()` | DELTA\_UPDATE received |
| `Comms` | `Data:GetVersionVector()` | Build SYNC\_REQUEST payload |
| `Comms` | `Data:GetGuildDB()` | Read/write guild database |
| `Comms` | `SyncPausePolicy:ShouldPause()` | Before any outbound message |
| `Comms` | `UI:Refresh()` | After sync completes |
| `Comms` | `UI:UpdateSyncIndicator()` | After HELLO / HEARTBEAT |
| `Tooltip` | `Data:GetGuildDB()` | Look up crafters for hovered item |
| `Tooltip` | `Data:IsMemberOnline()` | Online status in tooltip |
| `UI` | `Data:GetGuildDB()` | Render member/recipe lists |
| `UI` | `Comms:GetSyncStatus()` | Sync indicator dot |
| `UI` | `Comms:GetActiveAddonUserCount()` | Sync indicator tooltip |
| `UI` | `Favorites:*` | Favorites read/write |

---

## 5. Library Dependencies

| Library | Version | Purpose |
|---------|---------|---------|
| LibStub | — | Library registry |
| AceAddon-3.0 | — | Addon/module lifecycle |
| AceComm-3.0 | — | Addon message channel send/receive |
| AceSerializer-3.0 | — | Table → string serialization |
| AceDB-3.0 | — | SavedVariables with defaults and profiles |
| AceConsole-3.0 | — | `/gc` slash command registration |
| AceEvent-3.0 | — | WoW event registration (mixin) |
| AceTimer-3.0 | — | Scheduled timers (mixin) |
| AceGUI-3.0 | — | (Available, not actively used post-1.0) |
| AceHook-3.0 | — | (Available, not actively used post-1.0) |
| LibDeflate | — | Optional compression for large sync payloads |
| LibDataBroker-1.1 | — | Minimap button data object |
| LibDBIcon-1.0 | — | Minimap button rendering and position |
| ChatThrottleLib | — | Rate-limiting for addon channel sends (used by AceComm internally) |

LibDeflate is loaded defensively with `pcall`; the addon functions correctly
without it (messages are sent uncompressed).

---

## 6. SavedVariables Overview

```
GuildCraftsDB (global SavedVariable — AceDB-3.0)
│
├── global
│   ├── minimap          — { hide, minimapPos } — LibDBIcon state
│   ├── _recipeDB        — shared recipe lookup { [recipeKey] = { name, category, reagents } }
│   └── ["GuildName-Realm"]   ← guild partition (one per guild)
│       ├── ["CharName-Realm"]  ← member entry (live)
│       │     ├── professions   { [profName] = { recipes, skillLevel, maxSkillLevel, specialisation } }
│       │     ├── lastUpdate    Unix timestamp of most recent scan
│       │     └── dataFormat    integer, DATA_FORMAT_VERSION at time of last sync
│       ├── ["CharName-Realm"]  ← tombstone entry
│       │     └── _tombstone = true
│       └── ...
│
└── profile (per-character profile)
    ├── showOnlineOnly      — boolean
    ├── expansionFilter     — { ORIG = bool, TBC = bool }
    └── showTooltipCrafters — boolean

GuildCraftsCharDB (per-character SavedVariable)
└── favorites   — { [recipeKey] = true, ... }
```

The `_recipeDB` key is intentionally stored at `db.global` (not inside the
guild partition) so that reagent data accumulated from one guild transfers to
a second guild the player joins without re-scanning.

---

## 7. Key Game Events

| Event | Handler | Action |
|-------|---------|--------|
| `PLAYER_ENTERING_WORLD` | `Core:OnPlayerEnteringWorld` | Schedules `OnLoginReady` on first login; re-announces on zone change |
| `PLAYER_LOGIN` | (implicit via PLAYER\_ENTERING\_WORLD isLogin) | — |
| `TRADE_SKILL_SHOW` | `Core:OnTradeSkillShow` | Triggers `Data:ScanTradeSkill()` |
| `CRAFT_SHOW` | `Core:OnCraftShow` | Triggers `Data:ScanCraft()` (Enchanting) |
| `GUILD_ROSTER_UPDATE` | `Core:OnGuildRosterUpdate` | Rebuilds online cache, prunes roster, updates sync indicator |
| `GET_ITEM_INFO_RECEIVED` | `Core:OnItemInfoReceived` | Debounced `UI:Refresh()` for quality-color re-render |
| `CHAT_MSG_GUILD` | `Core:OnGuildChatMessage` | Responds to `!gc <recipe>` queries |
| `PLAYER_REGEN_DISABLED` | `SyncPausePolicy:OnCombatStart` | Sets `_inCombat` flag |
| `PLAYER_REGEN_ENABLED` | `SyncPausePolicy:OnCombatEnd` | Starts 6s grace timer |
| `PLAYER_ENTERING_WORLD` | `SyncPausePolicy:OnZoneEnter` | Sets `_inTransition` / `_inInstance` flags |

---

## 8. Data Flow: Recipe Scan

```
Player opens profession window
        │
        ▼
TRADE_SKILL_SHOW / CRAFT_SHOW
        │
        ▼
Data:ScanTradeSkill() / ScanCraft()
        ├── Reads GetNumTradeSkills / GetTradeSkillInfo for each recipe
        ├── Compares against stored entry in guild DB
        ├── If new recipes found:
        │       ├── Writes to db.global[guildKey][playerKey].professions
        │       ├── Comms:BroadcastNewRecipes()   → DELTA_UPDATE (GUILD)
        │       └── Comms:BroadcastLocalAdvertise() → DELTA_AD (GUILD)
        └── If no new recipes but data is 25+ days old:
                └── Comms:BroadcastTimestampTouch() → DELTA_UPDATE "touch" (GUILD)
```

---

## 9. Data Flow: Peer Sync

```
Login → Comms:OnLoginReady()
        │
        ├── BroadcastHello (t+3s)      ─── HELLO → GUILD ──────────────────────►
        │                               ◄── HELLO replies from peers ────────────
        │                               (addonUsers populated, election runs)
        │
        └── SendSyncRequest (t+15s)    ─── SYNC_REQUEST → GUILD ───────────────►
                                                │
                                     (DR receives, computes diff)
                                                │
                                        ◄── SYNC_RESPONSE chunks (WHISPER) ─────
                                        ◄── SYNC_PULL (WHISPER) [if DR wants data]
                                                │
                              Data:MergeIncoming() called per chunk
                                                │
                              ─── SYNC_PUSH chunks → DR (WHISPER) ─────────────►
                                                │
                              UI:Refresh() called after last chunk
```

After sync, a second HELLO (with `discover=true`) is sent to collect any
peers whose initial reply was throttled or arrived after the first election.
