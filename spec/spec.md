# GuildCrafts — Specification

## Overview
World of Warcraft addon for tracking **all learned recipes** across guild members' professions. Every recipe a guild member knows is stored and synced — the built-in search and filter system makes it easy to find exactly what you need.

**This addon is strictly for internal guild use.** Only current guild members' data is stored and displayed. When a player leaves the guild (or is removed), their data is purged from all nodes.

## Slash Command
- `/gc` — Opens the main GuildCrafts window.

---

## Recipe Scanning
The addon detects the local player's learned recipes through two mechanisms:

1. **When the profession window is opened** — the addon hooks `TRADE_SKILL_SHOW` to scan the active profession. All skill headers are expanded before iterating so that collapsed categories are not missed. Header rows (where `skillType == "header"`) are filtered out; only actual recipes are stored. This catches recipes learned mid-session (e.g. from a recipe item used while playing). Any newly detected recipes trigger a `DELTA_UPDATE` broadcast.
2. **On login (profession-level detection only)** — the addon uses `GetSkillLineInfo()` to enumerate which professions the character knows and their skill levels, **but does not scan individual recipes** (the trade skill API requires the profession window to be open). Previously cached recipe data from SavedVariables is used until the player opens each profession window.

All learned recipes are stored and synced — no exclusion list is needed.

> **Enchanting note:** Most enchanting recipes do not produce an item and therefore `GetTradeSkillItemLink()` returns nil. The addon uses `GetTradeSkillRecipeLink()` instead, extracting the **spellID** from the returned spell link. Recipes are keyed by `itemID` when available, or `spellID` as a fallback for enchanting (and any other recipes that lack an item).

### Profession Change Detection
If a player drops a profession (e.g. unlearns Blacksmithing and picks up Tailoring), the addon detects the missing profession on the next login via `GetSkillLineInfo()`. The old profession's data is **purged** from the local database and a `DELTA_UPDATE` (removal) is broadcast so all nodes drop the stale records.

---

## Alt Handling
Each character is tracked as a **separate entry** keyed by `CharacterName-Realm`. If a player has multiple characters in the same guild, each appears independently in the member list. No alt-linking is performed.

---

## Tracked Professions
All crafting professions in TBC:
- Alchemy
- Blacksmithing
- Enchanting (tracked the same as other professions — recipe name and source)
- Engineering
- Jewelcrafting
- Leatherworking
- Tailoring

---

## Data Sharing — Gossip Sync with Designated Router
Recipe data propagates through the guild using an **incremental gossip protocol** inspired by EIGRP and OSPF. Every node (player with the addon) holds the **full merged state** of all known guild recipes, but to prevent channel flooding, a **Designated Router (DR)** and **Backup Designated Router (BDR)** are elected among online addon users — similar to OSPF multicast behavior.

### DR / BDR Election
- All online addon users participate in an automatic election on the hidden guild addon channel.
- **Election criteria** (deterministic, no negotiation needed): the addon user whose character name is **lexicographically lowest** among currently online addon users becomes the **DR**. The second-lowest becomes the **BDR**.
- Election runs on login, on logout detection (via `GUILD_ROSTER_UPDATE` / periodic heartbeat), and when the current DR goes silent.
- Every addon user tracks who the current DR and BDR are locally — no central state.

### Why DR/BDR matters
When a player logs in and broadcasts a `SYNC_REQUEST`, without a DR **every** online peer would respond with potentially large `SYNC_RESPONSE` payloads, flooding the channel. With DR/BDR:
- **Only the DR responds** to `SYNC_REQUEST` messages.
- The DR sends its `SYNC_RESPONSE` via **addon WHISPER** (targeted to the requester, completely invisible — no chat text appears) rather than broadcasting over GUILD. This avoids forcing every online addon user to download data they already have.
- If the requester does not receive a response within a timeout (e.g. 5 seconds), it broadcasts a **second `SYNC_REQUEST`** with a retry flag. The **BDR** recognizes the retry and takes over as acting DR, sending the response. (The BDR cannot directly observe the DR's WHISPER-based responses, so the requester's retry is the failure signal.)
- If neither DR nor BDR responds, the requester falls back to a third `SYNC_REQUEST` round which any peer may answer (graceful degradation).

### Sync Rules

1. **Recipe learned (incremental update)** 
   When a player learns a new recipe, a lightweight **delta update** is broadcast to all online guild addon users immediately. Every node merges the delta — this is **not** routed through the DR (all nodes receive deltas directly, like OSPF flooding LSAs).

2. **Login (full sync convergence via DR — bidirectional)** 
   When a player logs in (or `/reload`s), they broadcast a `SYNC_REQUEST` containing a compact **version vector** (map of `CharacterName-Realm → lastUpdate timestamp` for every member they know about). **Only the DR** compares the incoming vector against its own state:
   - **DR is ahead** → DR sends a `SYNC_RESPONSE` (via addon WHISPER) with the entries the requester is missing.
   - **Requester is ahead** → DR sends a `SYNC_PULL` (via addon WHISPER) listing the member keys where the requester has a newer timestamp. The requester responds with a `SYNC_PUSH` (via addon WHISPER back to DR) containing those entries. The DR merges them and broadcasts `DELTA_UPDATE`s to all online nodes so the entire guild converges.
   - **Both directions** → Both `SYNC_RESPONSE` and `SYNC_PULL` are sent. This handles the common case where two nodes each have data the other is missing.
   
   The BDR monitors for retry `SYNC_REQUEST`s and steps in if the DR failed to respond.

3. **Propagation through intermediaries** 
   Because every node stores the full merged state, updates survive the originator going offline:
   - *Player 1* learns a recipe → broadcasts delta → all online nodes merge it.
   - *Player 1* logs out.
   - *Player 4* logs in → DR sends the missing recipe to Player 4.
   - If Player 4 had data the DR was missing (e.g. Player 4 synced with Player 1 before going offline, but the DR was offline at that time), the DR pulls it from Player 4 and broadcasts it to all online nodes.

4. **Conflict resolution** 
   Within a profession, recipes are append-only (a learned recipe is never unlearned). If two nodes disagree on recipe sets for the same member and profession, the **union** of both sets wins.
   
   However, at the **member level**, sync uses **full replacement**: if the incoming data for a member has a newer `lastUpdate` than the local copy, the receiver replaces that member's entire entry (all professions and recipes) with the incoming version. This ensures that profession removals propagate correctly — if Player A drops Blacksmithing, their newer `lastUpdate` causes all syncing nodes to replace their stale copy (which included Blacksmithing) with the new one (which does not).

5. **Throttling** 
   Full sync responses are sent via WHISPER and are chunked by profession into separate messages, throttled via ChatThrottleLib at `BULK` priority to avoid disconnects. This means the requester receives data progressively (profession by profession) and can display partial results before the full sync completes. Delta updates are small (single recipe) and sent at `NORMAL` priority for faster delivery.

6. **Guild roster pruning** 
   On login and periodically while online, the addon checks the current guild roster via `GetGuildRosterInfo()`. Any `CharacterName-Realm` key in the local database that does **not** appear in the current guild roster is **deleted**. This ensures:
   - Players who `/gquit` or are `/gkick`ed are removed from all nodes automatically.
   - Data only persists for active guild members.
   - Pruning propagates naturally: when Player 4 logs in and syncs, the DR will not send data for ex-members (already pruned), and Player 4 prunes any stale entries locally as well.

7. **Heartbeat** 
   The DR periodically broadcasts a lightweight `HEARTBEAT` message so all nodes know it is still active. If the heartbeat is missed for a configurable number of intervals, the BDR is promoted to DR and a new BDR is elected.

8. **DR request queuing** 
   When multiple players log in simultaneously (e.g. raid time), the DR may receive several `SYNC_REQUEST`s in quick succession. The DR queues these and processes them **sequentially** — each `SYNC_RESPONSE` must finish transmitting (or be substantially through the ChatThrottleLib queue) before the next one begins. This prevents the DR's outbound bandwidth from being split across too many concurrent responses, which would slow all of them. Requesters should use a generous timeout (e.g. 30 seconds for the first response chunk) to account for queuing delays.

### Data Storage
- All guild recipe data is stored locally in **SavedVariables** (`GuildCraftsDB`), persisted across sessions.
- Each entry is keyed by `CharacterName-Realm` with a per-member `lastUpdate` timestamp for version vector comparison.

---

## User Interface

### Main Window
Opened via `/gc`. A standalone, draggable, resizable frame (~700×500 default) with an ESC-to-close binding. The layout uses a **two-panel split**: a narrow left panel for navigation and a wide right panel for detail.

```
┌─────────────────────────────────────────────────────────────────┐
│  GuildCrafts                                    [Sync ●] [✕]   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ 🔍 Search...                        [▾ All ▾]            │  │
│  └───────────────────────────────────────────────────────────┘  │
│ ┌──────────────────┐ ┌──────────────────────────────────────┐   │
│ │ ◀ Members        │ │                                      │   │
│ │                  │ │  (Detail Panel)                       │   │
│ │  Alchemy     (3) │ │                                      │   │
│ │  Blacksmith  (5) │ │  Lionheart Helm                      │   │
│ │  Enchanting  (2) │ │    Source: World Drop                 │   │
│ │  Engineer    (1) │ │    Crafters: Gandorf ● Thrallin ○    │   │
│ │  Jewelcraft  (4) │ │    [Request Craft ▾]                 │   │
│ │  Leatherwork (2) │ │                                      │   │
│ │  Tailoring   (3) │ │  Felsteel Longblade                  │   │
│ │                  │ │    Source: Trainer                    │   │
│ │                  │ │    Crafters: Gandorf ● Smithy ●      │   │
│ │                  │ │    [Request Craft ▾]                  │   │
│ │                  │ │                                      │   │
│ │                  │ │                                      │   │
│ └──────────────────┘ └──────────────────────────────────────┘   │
│  Craft Queue (2 pending)                                        │
└─────────────────────────────────────────────────────────────────┘
```

### Layout Components

#### Title Bar
- Addon name ("GuildCrafts"), a sync status indicator, and a close button.
- **Sync indicator**: Green dot (●) = up-to-date, yellow spinning icon = sync in progress, red dot = no DR available / not connected. Hovering shows a tooltip with last sync time, DR identity, and number of known addon users.

#### Search Bar
A single text input spanning the top of the content area with a **scope dropdown** to its right:
- **All** (default) — searches across item names, profession names, and member names simultaneously.
- **Item** — searches recipe/item names only. Results show a flat list of matching recipes with all crafters listed under each.
- **Profession** — filters the left panel to show only the selected profession.
- **Member** — searches member names. Results show matching members in the left panel.

Search is **live** (filters as you type, with a short debounce). Clearing the search box returns to the default browse view.

#### Left Panel — Navigation
The left panel supports three views, toggled by breadcrumb-style navigation at the top:

1. **Profession List** (default landing view)
   - Lists the 7 TBC crafting professions.
   - Each row shows the profession name and a count of guild members who have it (e.g. `Blacksmithing (5)`).
   - Clicking a profession drills into the Member List for that profession.

2. **Member List** (after selecting a profession, or via search)
   - Lists guild members who have the selected profession.
   - Each row shows: character name, online/offline indicator (● green = online, ○ grey = offline), and recipe count.
   - Sorted: online members first (alphabetical), then offline (alphabetical).
   - Clicking a member drills into their recipe list in the detail panel.
   - A **"◀ Professions"** breadcrumb at the top returns to the profession list.

3. **All Members** (accessible via "Members" breadcrumb or Member search scope)
   - Lists all guild members with synced data, regardless of profession.
   - Same online/offline indicators and sorting.

#### Right Panel — Detail
Content changes based on navigation context:

1. **Welcome state** (nothing selected)
   - Brief instructions: "Select a profession to browse, or use the search bar to find a specific recipe."

2. **Recipe List** (member selected)
   - Shows all recipes the selected member knows for the selected profession.
   - Each recipe row displays:
     - Recipe/item name (colored by rarity if item quality data is available, white otherwise).
     - Source (e.g. "World Drop", "Trainer", "Moroes — Karazhan") — shown as subdued secondary text.
   - Scrollable list.

3. **Item Search Results** (search scope = Item or All, with text entered)
   - Flat list of matching recipes grouped by item name.
   - Under each recipe name, shows **all guild members** who can craft it:
     - `Gandorf ●` (online, clickable → Request Craft)
     - `Thrallin ○` (offline, greyed out, no action)
   - This is the most useful view for "who can craft X?"

4. **Empty state** (member has no synced recipes for a profession)
   - "No recipes synced yet. This member's data will appear after they open their profession window with the addon installed."

#### Online / Offline Indicators
- **● Green dot** — player is currently online (present in guild roster with `isOnline = true`).
- **○ Grey dot** — player is offline. Still shown in browse and search results so users can see who *could* craft something, but the "Request Craft" button is hidden.
- Online status is refreshed periodically via `GUILD_ROSTER_UPDATE`.

### Craft Request (from the UI)

When viewing a recipe with online crafters, a **"Request Craft"** button appears next to each online crafter's name. If multiple crafters are available, each has its own button.

Clicking the button:
1. The addon checks its local addon user list to determine whether the crafter has the addon.
2. **If the crafter has the addon**: An invisible addon WHISPER (`CRAFT_REQUEST`) is sent. A confirmation line appears in the requester's chat frame: `[GuildCrafts] Request sent to <CrafterName> for <ItemName>.`
3. **If the crafter does NOT have the addon**: A formatted visible whisper is sent via `SendChatMessage()` (e.g. `"[GuildCrafts] <PlayerName> is requesting you craft: Lionheart Helm. Whisper them to arrange!"`). A confirmation line appears in the requester's chat frame.

### Craft Request Popup (crafter side)
When a craft request arrives, a small popup frame appears in the center of the screen (non-intrusive, does not block gameplay):

```
┌──────────────────────────────────────┐
│  Craft Request                  [✕]  │
│                                      │
│  Gandorf wants you to craft:         │
│  Lionheart Helm                      │
│                                      │
│         [Accept]   [Decline]         │
└──────────────────────────────────────┘
```

- A subtle sound plays when the popup appears (using `PlaySound()`).
- If multiple requests arrive, they stack vertically.
- Declining dismisses the popup and sends `CRAFT_DECLINE` to the requester.
- Accepting sends `CRAFT_ACCEPT` and adds the item to the Craft Queue.

### Craft Queue Panel
A collapsible panel docked to the **bottom edge** of the main GuildCrafts window. Toggled by the "Craft Queue (N pending)" bar at the bottom.

```
┌──────────────────────────────────────────────────────┐
│  Craft Queue                                    [▴]  │
│ ┌──────────────────────────────────────────────────┐ │
│ │  Lionheart Helm — for Gandorf        [✓] [✕]    │ │
│ │  Felsteel Longblade — for Thrallin   [✓] [✕]    │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

- **[✓]** marks the request as complete → sends `CRAFT_COMPLETE` to the requester.
- **[✕]** dismisses/cancels the request.
- The queue persists in SavedVariables across sessions (in case the crafter logs out before completing).
- When the queue is empty, the bar shows "Craft Queue (empty)" and the panel auto-collapses.

### Notifications (requester side)
When the requester receives a response to their craft request, a notification is displayed as a **chat frame message** (colored addon output):

- `[GuildCrafts] <CrafterName> accepted your request for <ItemName>.`
- `[GuildCrafts] <CrafterName> declined your request for <ItemName>.`
- `[GuildCrafts] <CrafterName> has completed crafting <ItemName>!`

A subtle sound plays for accept and complete notifications.

### Tooltip Integration
_Not included in v1. May be added in a future version (hover over items in bags/chat to see guild crafters)._

---

## Data Model

### Stored Data (SavedVariables)
```
GuildCraftsDB = {
  ["CharacterName-Realm"] = {
    professions = {
      ["Blacksmithing"] = {
        recipes = {
          [itemID] = {                    -- itemID for professions that produce items
            name = "Lionheart Helm",
            source = "World Drop",       -- optional metadata
          },
          ...
        },
      },
      ["Enchanting"] = {
        recipes = {
          [spellID] = {                  -- spellID for enchants (no item produced)
            name = "Enchant Weapon - Mongoose",
            source = "Moroes - Karazhan",
          },
          ...
        },
      },
      ...
    },
    lastUpdate = timestamp,   -- latest change time for this member's data
  },
  ...
}
```

This is a **single merged table** containing data for every guild member the player has ever synced with. It is the same structure on every node — the full guild-wide state.

### Version Vector (used during login sync)
```
versionVector = {
  ["Player1-Realm"] = 1708300000,  -- lastUpdate timestamps
  ["Player2-Realm"] = 1708295000,
  ...
}
```
Sent in `SYNC_REQUEST` so peers can determine which deltas to send back.

---

## Recipe Scope
The addon tracks **all** learned recipes for each profession — both trainer-taught and those from special sources (world drops, reputation vendors, dungeon/raid bosses, quest rewards, etc.). This eliminates the need to maintain a static exclusion list and gives a complete picture of each guild member's crafting capabilities. The search and filter system makes it easy to find any specific recipe across the guild.

---

## Versioning & Compatibility
- Addon communication includes a version identifier so newer clients can handle older data formats gracefully.
- Incompatible versions will notify the user to update.

---

## Future Considerations (out of scope for v1)
- Tooltip integration (hover over items to see who can craft them).
- Minimap button.
- Integration with auction house pricing.