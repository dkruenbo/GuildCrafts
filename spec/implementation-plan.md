# GuildCrafts — Implementation Plan

> **Historical document.** This was the phased implementation plan written before development began. The addon is now complete and in maintenance mode. All phases were executed, though some details changed along the way — notably Phase 6 (Craft Request System) was built and later removed in favour of the `[W]` whisper button workflow.

## Guiding Principles
- **Vertical slices**: Each phase delivers a testable, working addon. Don't build all of comms before all of UI — build thin end-to-end features and thicken them.
- **Hardest risk first**: The communication protocol is the riskiest part (throttling, DR election, bidirectional sync). Get it working with simple test data before polishing the UI.
- **Test in-game constantly**: No external test harness exists for WoW addons. Every phase ends with an in-game verification step. Use `/reload`, `/dump`, and BugSack/BugGrabber.

---

## Phase 0 — Project Skeleton
**Goal**: A loadable addon that does nothing but prove the toolchain works.

| # | Task | File(s) | Details |
|---|---|---|---|
| 0.1 | Create `.toc` file | `GuildCrafts.toc` | Set `Interface`, `Title`, `Notes`, `Author`, `SavedVariables: GuildCraftsDB`, and file load order. Include Ace3 libs and LibDeflate via `Libs/` embeds. |
| 0.2 | Embed libraries | `Libs/` | Download and embed AceAddon-3.0, AceComm-3.0, AceSerializer-3.0, AceDB-3.0, AceGUI-3.0, ChatThrottleLib, LibDeflate. Add `embeds.xml` for Ace libs. |
| 0.3 | Create `Core.lua` skeleton | `Core.lua` | Initialize AceAddon. Register `/gc` slash command (prints "GuildCrafts loaded" for now). Register events: `PLAYER_LOGIN`, `GUILD_ROSTER_UPDATE`. |
| 0.4 | Create empty module files | `Comms.lua`, `Data.lua`, `CraftRequest.lua` | Empty AceAddon modules so the `.toc` load order doesn't error. |

**Verification**: Install addon, `/reload`, type `/gc` → see chat message. No errors in BugSack.

---

## Phase 1 — Local Data: Scanning & Storage
**Goal**: The addon scans the local player's professions and stores recipes in SavedVariables. No communication yet.

| # | Task | File(s) | Details |
|---|---|---|---|
| 1.1 | Initialize AceDB | `Data.lua` | Set up `GuildCraftsDB` with AceDB-3.0. Define defaults for the global (account-wide) profile. Structure: `db.global[memberKey].professions[profName].recipes[recipeKey]`. |
| 1.2 | Profession detection on login | `Core.lua` | On `PLAYER_LOGIN`, call `GetNumSkillLines()` / `GetSkillLineInfo()` to enumerate known professions. Store profession names in a local table. Compare against stored data — if a profession is missing from the API but present in DB, **purge** it (profession change detection). |
| 1.3 | Recipe scanning on `TRADE_SKILL_SHOW` | `Core.lua` | Register `TRADE_SKILL_SHOW` event. On fire: expand all headers (iterate backwards with `ExpandTradeSkillSubClass`), then iterate `GetNumTradeSkills()`. For each non-header row, extract `itemID` from `GetTradeSkillItemLink()`. If nil (Enchanting), extract `spellID` from `GetTradeSkillRecipeLink()`. Store `{ name, source }` keyed by `itemID` or `spellID`. Detect new recipes by comparing against existing DB entries. |
| 1.4 | `lastUpdate` timestamp | `Data.lua` | When any recipe is added or a profession is purged, update `db.global[memberKey].lastUpdate = time()`. |
| 1.5 | Debug dump command | `Core.lua` | Add `/gc dump` subcommand that prints a summary: number of professions, recipe counts per profession, `lastUpdate` value. |

**Verification**: Login, open each profession window, `/gc dump` → see correct recipe counts. Log out, log in, `/gc dump` → data persists. Drop a profession, log back in → old profession purged.

---

## Phase 2 — Communication Foundation
**Goal**: Addon users can see each other on the guild channel. DR/BDR election works. No data sync yet.

| # | Task | File(s) | Details |
|---|---|---|---|
| 2.1 | Register addon prefix | `Comms.lua` | `C_ChatInfo.RegisterAddonMessagePrefix("GuildCrafts")`. Set up AceComm-3.0 with `RegisterComm`. |
| 2.2 | Message envelope | `Comms.lua` | Define a standard message format: `{ type = "HELLO", version = N, payload = ... }`. Serialize with AceSerializer, compress large messages with LibDeflate. Decompress and deserialize on receive. Small messages (HELLO, HEARTBEAT) skip compression. |
| 2.3 | `HELLO` broadcast on login | `Comms.lua` | On `PLAYER_LOGIN` (after a short delay to let the guild channel initialize — ~3 seconds via `C_Timer.After`), broadcast `HELLO` with sender name and addon version over GUILD. |
| 2.4 | Addon user list | `Comms.lua` | Maintain a local table `addonUsers = { ["Name-Realm"] = { version = N, lastSeen = time() } }`. Populate on incoming `HELLO`. Remove entries on `GUILD_ROSTER_UPDATE` when `isOnline` is false. |
| 2.5 | DR/BDR election | `Comms.lua` | After any change to `addonUsers`, sort keys lexicographically. First = DR, second = BDR. Store `self.myRole` ("DR", "BDR", or "OTHER"). Log role to chat on change: `[GuildCrafts] You are now the DR.` |
| 2.6 | `HEARTBEAT` (DR only) | `Comms.lua` | If `self.myRole == "DR"`, start a repeating timer (`C_Timer.NewTicker`, 60s). Broadcast `HEARTBEAT` with DR name and timestamp. Other nodes reset a "DR alive" watchdog timer on receipt. If watchdog expires (e.g. 3 missed heartbeats = 180s), remove DR from `addonUsers` and re-elect. |
| 2.7 | Debug: `/gc comms` | `Comms.lua` | Print addon user list, current DR, BDR, own role. |

**Verification**: Log in on two characters in the same guild. Both should show each other in `/gc comms`. The lexicographically lower name should report itself as DR. Log off the DR → BDR promotes within ~180s (or faster via `GUILD_ROSTER_UPDATE`).

---

## Phase 3 — Data Sync Protocol
**Goal**: Recipe data propagates between addon users via the DR. Bidirectional sync works.

| # | Task | File(s) | Details |
|---|---|---|---|
| 3.1 | Version vector generation | `Data.lua` | Add `Data:GetVersionVector()` → returns `{ ["Name-Realm"] = lastUpdate, ... }` for all entries in `GuildCraftsDB`. |
| 3.2 | `SYNC_REQUEST` on login | `Comms.lua` | After the initial HELLO delay, broadcast `SYNC_REQUEST` with the version vector and `retry = false`. |
| 3.3 | DR handles `SYNC_REQUEST` | `Comms.lua` | DR receives `SYNC_REQUEST`, compares incoming vector against own DB. Compute three sets: (a) members where DR is ahead, (b) members where requester is ahead, (c) members only DR knows about. |
| 3.4 | `SYNC_RESPONSE` — DR sends missing data | `Comms.lua` | For members in sets (a) and (c), serialize their full entries, compress, and send via AceComm WHISPER to the requester. Chunk by profession. Use `BULK` priority in ChatThrottleLib. |
| 3.5 | `SYNC_PULL` — DR requests data it's missing | `Comms.lua` | For members in set (b), send a `SYNC_PULL` listing those member keys via WHISPER to the requester. |
| 3.6 | `SYNC_PUSH` — requester responds to pull | `Comms.lua` | On receiving `SYNC_PULL`, serialize the requested members' data and WHISPER it back to the DR. |
| 3.7 | DR merges push and rebroadcasts | `Comms.lua`, `Data.lua` | DR merges `SYNC_PUSH` data into its own DB (full replacement at member level if incoming `lastUpdate` is newer). Then broadcasts `DELTA_UPDATE` messages over GUILD for each merged member so all online nodes converge. |
| 3.8 | Requester merges `SYNC_RESPONSE` | `Data.lua` | On receiving `SYNC_RESPONSE` chunks, merge into local DB. Full replacement at member level. |
| 3.9 | Retry logic and BDR fallback | `Comms.lua` | If no `SYNC_RESPONSE` or `SYNC_PULL` arrives within 30 seconds, rebroadcast `SYNC_REQUEST` with `retry = true`. BDR responds to retry requests the same way DR would. If retry also fails, broadcast a third request with `retry = "open"` — any peer may respond. |
| 3.10 | DR request queuing | `Comms.lua` | If the DR receives multiple `SYNC_REQUEST`s before the current response finishes, queue them. Process one at a time. |
| 3.11 | `DELTA_UPDATE` — live recipe broadcast | `Comms.lua`, `Core.lua` | When the recipe scanner (Phase 1) detects a new recipe, call `Comms:BroadcastDelta(memberKey, profession, recipeKey, recipeData)`. Broadcast over GUILD at `NORMAL` priority. All nodes merge on receipt. |
| 3.12 | `DELTA_UPDATE` — profession removal | `Comms.lua`, `Core.lua` | When profession change detection (Phase 1) purges a profession, broadcast `DELTA_UPDATE` with `type = "remove_profession"`. All nodes purge that profession for the member and accept the new `lastUpdate`. |
| 3.13 | Guild roster pruning | `Data.lua` | On `GUILD_ROSTER_UPDATE` and on login, iterate guild roster via `GetGuildRosterInfo()`. Delete any `GuildCraftsDB` key not in the roster. |

**Verification**: Set up 3 characters (A, B, C). A learns a recipe → B and C see it via delta. A logs off. D logs in → DR sends A's recipe to D. B has data DR is missing → DR pulls from B and rebroadcasts. Remove a character from guild → data pruned on next roster update.

---

## Phase 4 — Main Window UI
**Goal**: The `/gc` command opens a functional browse window. No craft requests yet.

| # | Task | File(s) | Details |
|---|---|---|---|
| 4.1 | Main frame template | `UI/MainFrame.xml`, `UI/MainFrame.lua` | Create a `Frame` with `UIParent` as parent. ~700×500, draggable (`SetMovable`, `RegisterForDrag`), resizable (`SetResizable`, resize grip), ESC-to-close (`UISpecialFrames`). Title bar with addon name, sync indicator placeholder, close button. |
| 4.2 | Two-panel layout | `UI/MainFrame.lua` | Divide content area into left panel (~200px) and right panel (remaining). Use `SetPoint` anchoring. Both panels get scroll frames. |
| 4.3 | Sync status indicator | `UI/MainFrame.lua` | Title bar dot: green texture by default. Hook into `Comms` module to switch to yellow during active sync, red if no addon users online. Tooltip on hover: last sync time, DR name, addon user count. |
| 4.4 | Left panel — Profession list | `UI/LeftPanel.lua` | Default view. Iterate the 7 TBC professions. For each, count members in `GuildCraftsDB` that have it. Show rows: profession name + `(count)`. Clicking a row switches to member list for that profession. |
| 4.5 | Left panel — Member list | `UI/LeftPanel.lua` | Show members with the selected profession. Each row: name, online indicator (● / ○ via `GetGuildRosterInfo` `isOnline`), recipe count. Sort online-first, then alphabetical. "◀ Professions" breadcrumb at top to go back. Click a member → update detail panel. |
| 4.6 | Left panel — All members view | `UI/LeftPanel.lua` | Accessible via breadcrumb or member search scope. Lists all members with synced data. Same format as 4.5. |
| 4.7 | Right panel — Welcome state | `UI/DetailPanel.lua` | When no member is selected, show centered text: "Select a profession to browse, or use the search bar to find a specific recipe." |
| 4.8 | Right panel — Recipe list | `UI/DetailPanel.lua` | When a member + profession is selected, iterate their recipes from DB. Each row: recipe name (colored by quality if available), source as subdued text below. Scrollable. |
| 4.9 | Right panel — Empty state | `UI/DetailPanel.lua` | If the selected member has no recipes for the profession, show: "No recipes synced yet..." message. |
| 4.10 | Online/offline refresh | `UI/MainFrame.lua` | Register `GUILD_ROSTER_UPDATE` to refresh online indicators without rebuilding the entire list. |
| 4.11 | `/gc` opens the window | `Core.lua` | Update slash command handler to toggle the main frame visibility. |

**Verification**: `/gc` opens the window. Browse professions → members → recipes. Online/offline dots update. Window is draggable, resizable, closes with ESC. Data from synced DB displays correctly.

---

## Phase 5 — Search
**Goal**: Live search across recipes, professions, and members.

| # | Task | File(s) | Details |
|---|---|---|---|
| 5.1 | Search bar widget | `UI/SearchBar.lua` | EditBox spanning the top of the content area. Scope dropdown to the right (`UIDropDownMenu`): All, Item, Profession, Member. Default = All. |
| 5.2 | Debounced input handler | `UI/SearchBar.lua` | On each keystroke, cancel previous timer and set a new 0.2s `C_Timer.After`. When it fires, trigger the search. Clearing the box restores the default browse view. |
| 5.3 | Search — Item scope | `UI/DetailPanel.lua` | Iterate all recipes across all members in DB. Match against recipe `name` (case-insensitive substring). Group results by recipe: show recipe name, then list all crafters underneath with online/offline indicators. |
| 5.4 | Search — Profession scope | `UI/LeftPanel.lua` | Filter the profession list to show only professions matching the search text. |
| 5.5 | Search — Member scope | `UI/LeftPanel.lua` | Filter the member list (all members view) to show only members matching the search text. |
| 5.6 | Search — All scope | `UI/SearchBar.lua` | Combine Item + Member results. If the text matches a profession name, also highlight that profession in the left panel. Use Item search results layout in the detail panel. |

**Verification**: Type "Lionheart" → see the recipe with all crafters. Type "Gandorf" → see that member. Clear search → back to default. Scope dropdown changes behavior correctly.

---

## Phase 6 — Craft Request System
**Goal**: Players can request crafts from online guild members and manage a craft queue.

| # | Task | File(s) | Details |
|---|---|---|---|
| 6.1 | "Request Craft" button | `UI/DetailPanel.lua` | Next to each online crafter in the recipe list / search results, show a button. Hidden for offline players. |
| 6.2 | Send `CRAFT_REQUEST` | `CraftRequest.lua`, `Comms.lua` | On button click: check `addonUsers` list. If target is an addon user → send `CRAFT_REQUEST` via addon WHISPER. If not → `SendChatMessage()` visible whisper fallback. Print confirmation to requester's chat frame. |
| 6.3 | Craft request popup | `UI/CraftRequestPopup.xml`, `UI/CraftRequestPopup.lua` | On receiving `CRAFT_REQUEST`: create a popup frame (centered, non-blocking). Show requester name, item name, Accept/Decline buttons. Play `PlaySound()`. Stack multiple popups vertically. |
| 6.4 | Accept / Decline handlers | `CraftRequest.lua` | Accept: send `CRAFT_ACCEPT` via addon WHISPER, add to craft queue, dismiss popup. Decline: send `CRAFT_DECLINE` via addon WHISPER, dismiss popup. |
| 6.5 | Craft queue panel | `UI/CraftQueuePanel.xml`, `UI/CraftQueuePanel.lua` | Collapsible panel docked to bottom of main frame. List of accepted requests. Each row: item name, requester name, [✓] complete, [✕] dismiss. |
| 6.6 | Complete / dismiss handlers | `CraftRequest.lua` | [✓]: send `CRAFT_COMPLETE` via addon WHISPER, remove from queue. [✕]: remove from queue (no message sent). |
| 6.7 | Queue persistence | `CraftRequest.lua`, `Data.lua` | Store pending queue items in SavedVariables (`GuildCraftsDB.craftQueue`). Restore on login. Clear items for requesters who are no longer in the guild (roster pruning). |
| 6.8 | Requester notifications | `CraftRequest.lua` | On receiving `CRAFT_ACCEPT`, `CRAFT_DECLINE`, `CRAFT_COMPLETE`: print colored chat frame message. Play sound for accept/complete. |

**Verification**: Character A requests a craft from Character B. B sees the popup, accepts → item appears in B's craft queue. B marks complete → A gets a notification. Test with a character that doesn't have the addon → visible whisper sent. Test queue persistence (log out/in).

---

## Phase 7 — Polish & Edge Cases
**Goal**: Harden the addon for real-world use in a 500-member guild.

| # | Task | File(s) | Details |
|---|---|---|---|
| 7.1 | Version compatibility | `Comms.lua` | Check `version` field in incoming messages. If major version mismatch, print a one-time warning: `[GuildCrafts] <PlayerName> is running an incompatible version. Please update.` Ignore their data. |
| 7.2 | Login timing robustness | `Core.lua` | Ensure HELLO and SYNC_REQUEST are sent after the guild channel is ready. Use `PLAYER_ENTERING_WORLD` + `IsInGuild()` check + `C_Timer.After(5)` delay as a safe baseline. Test with slow-loading UIs. |
| 7.3 | Large payload testing | `Comms.lua` | Simulate a full DB (200 members × 150 recipes) and verify SYNC_RESPONSE transmits without errors or disconnects. Measure time. Tune chunk sizes if needed. |
| 7.4 | Rapid login stress test | `Comms.lua` | Simulate 5+ SYNC_REQUESTs arriving at the DR within seconds. Verify queuing works, no requests are dropped, and BDR doesn't false-trigger. |
| 7.5 | Memory profiling | All | Use `/gc mem` command with `UpdateAddOnMemoryUsage()` and `GetAddOnMemoryUsage()`. Target: < 5 MB idle, < 15 MB during active sync of large dataset. |
| 7.6 | UI scroll performance | `UI/LeftPanel.lua`, `UI/DetailPanel.lua` | If a member has 150+ recipes, ensure the scroll list doesn't lag. Consider virtual scrolling (reuse row frames, update content on scroll) if performance is poor with naive `CreateFrame` per row. |
| 7.7 | Frame positioning persistence | `UI/MainFrame.lua` | Save window position and size in SavedVariables (per-character via AceDB profile). Restore on open. |
| 7.8 | Edge case: only one addon user online | `Comms.lua` | If you are the only addon user, you are DR with no BDR. SYNC_REQUEST from yourself should be a no-op. Heartbeat still broadcasts (in case others come online). |
| 7.9 | Edge case: guild transfer / server merge | `Data.lua` | If `CharacterName-Realm` format changes, old data becomes orphaned. Roster pruning handles this naturally — orphaned keys get pruned. Verify this works. |
| 7.10 | Error handling | All | Wrap all incoming message handlers in `pcall`. Log errors via `BugGrabber` if available, else print to chat. Never let a malformed message crash the addon. |

**Verification**: Extended play session with multiple characters. Monitor for errors, memory leaks, and UI lag. Final stress test with simulated large dataset.

---

## Phase 8 — Release Preparation
**Goal**: Ship-ready addon.

| # | Task | File(s) | Details |
|---|---|---|---|
| 8.1 | README | `README.md` | Installation instructions, feature summary, slash commands, known limitations. |
| 8.2 | Clean debug output | All | Remove or gate all debug print statements behind a `/gc debug` toggle (default off). |
| 8.3 | `.toc` metadata | `GuildCrafts.toc` | Final `Version`, `X-Website`, `X-Category` fields. |
| 8.4 | Testing checklist | — | Manual run-through of all verification steps from Phases 0–7. Document results. |

---

## Dependency Graph

```
Phase 0 ─► Phase 1 ─► Phase 3 ─────────────────────────────────►┐
               │                                                  │
               ▼                                                  ▼
          Phase 2 ─► Phase 3                                 Phase 7
                                                                  │
          Phase 4 ─► Phase 5 ─► Phase 6 ────────────────────────►│
                                                                  ▼
                                                             Phase 8
```

- **Phase 0** must come first (skeleton).
- **Phase 1** (scanning) and **Phase 2** (comms) can be developed in parallel after Phase 0.
- **Phase 3** (sync) requires both Phase 1 and Phase 2.
- **Phase 4** (UI) can start after Phase 1 (needs data to display) but doesn't need comms.
- **Phase 5** (search) requires Phase 4.
- **Phase 6** (craft requests) requires Phase 5 (needs UI) and Phase 2 (needs comms).
- **Phase 7** (polish) after all functional phases.
- **Phase 8** (release) is last.

---

## Testing Strategy

WoW addons run inside the game client — there's no external test runner. All testing relies on in-game verification, debug tooling, and simulated data.

### Debug Commands

These commands are gated behind a `/gc debug` toggle (off by default, so end users never see debug output).

| Command | Purpose |
|---|---|
| `/gc` | Toggle the main window |
| `/gc debug` | Toggle debug mode (enables verbose chat output for all events) |
| `/gc dump` | Print local data summary: professions, recipe counts, `lastUpdate` per member |
| `/gc comms` | Print addon user list, current DR, BDR, own role, heartbeat status |
| `/gc mem` | Print addon memory usage (`GetAddOnMemoryUsage`) |
| `/gc sim <N>` | Inject N simulated guild members with random professions and recipes (debug mode only) |
| `/gc sim clear` | Remove all simulated data |
| `/gc sim sync` | Simulate a full SYNC_RESPONSE arriving (tests merge + UI refresh without needing a second client) |
| `/gc sim delta` | Simulate an incoming DELTA_UPDATE (tests live merge) |
| `/gc sim craft` | Simulate an incoming CRAFT_REQUEST popup |
| `/gc reset` | Wipe all SavedVariables and reload |

### Simulated Data System (`/gc sim`)

Since you can't always test with guildies online, the addon includes a built-in simulation mode that generates fake guild member data.

**`/gc sim 100`** generates 100 dummy guild members:
- Random character names (`SimPlayer001-Realm` through `SimPlayer100-Realm`)
- Each gets 2 random professions from the TBC list
- Each profession gets 20–150 random recipes with realistic names (pulled from a hardcoded sample table of ~50 TBC recipe names, cycled with suffix variations)
- Each member gets a randomized `lastUpdate` timestamp (spread across the last 7 days)
- Simulated members are flagged with `_simulated = true` so they can be bulk-removed and are never sent over the wire

**What this lets you test without a second client:**
- UI performance with large datasets (scroll lag, search speed)
- Left panel navigation with many members per profession
- Item search results with dozens of crafters per recipe
- SavedVariables file size and login/logout lag
- Memory footprint
- Online/offline indicators (simulated members randomly assigned online/offline status)

**`/gc sim sync`** simulates the full sync flow:
- Generates a fake SYNC_RESPONSE payload as if the DR had sent it
- Feeds it through the normal `Data:MergeIncoming()` path
- Tests the merge logic, UI refresh, and progressive loading without needing network

**`/gc sim delta`** simulates an incoming delta:
- Picks a random simulated member and adds a new recipe
- Feeds it through the normal `DELTA_UPDATE` handler
- Verifies the recipe appears in the UI immediately

**`/gc sim craft`** simulates a craft request:
- Generates a fake `CRAFT_REQUEST` as if another player sent it
- Triggers the popup, sound, and Accept/Decline flow
- Tests the full craft UI without needing a second character

### Multi-Boxing (for protocol testing)

Comms-layer features (DR election, sync, bidirectional pull/push) require multiple WoW clients:
- Run **2–3 clients** on separate WoW accounts with characters in the same guild
- Alternatively, use two characters on the same account by logging out/in (slower, but works for verifying data persistence and sync-on-login)

**Minimum multi-box tests:**
1. Two clients online → verify both appear in `/gc comms`, correct DR/BDR assignment
2. DR learns a recipe → verify DELTA_UPDATE reaches the other client
3. Log out client A, modify its SavedVariables manually, log back in → verify bidirectional sync (DR pulls missing data)
4. Kill the DR client → verify BDR promotion via heartbeat timeout
5. Both clients online, send a craft request A→B → verify popup, accept/complete flow

### Lua Linting (offline, pre-flight)

Use **luacheck** to catch errors before launching the game:

```bash
# Install
brew install luacheck

# Run from addon root
luacheck *.lua UI/*.lua --config .luacheckrc
```

A `.luacheckrc` file is included with the project to define WoW API globals so luacheck doesn't flag them as undefined:

```lua
-- .luacheckrc
std = "lua51"
max_line_length = false
globals = {
    "GuildCrafts", "GuildCraftsDB",
}
read_globals = {
    -- WoW API
    "CreateFrame", "UIParent", "C_ChatInfo", "C_Timer",
    "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink",
    "GetTradeSkillRecipeLink", "ExpandTradeSkillSubClass",
    "GetNumSkillLines", "GetSkillLineInfo",
    "GetGuildRosterInfo", "GetNumGuildMembers", "GuildRoster",
    "SendChatMessage", "PlaySound", "IsInGuild",
    "GetAddOnMemoryUsage", "UpdateAddOnMemoryUsage",
    "UISpecialFrames", "UIDropDownMenu_Initialize",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetSelectedID",
    -- Ace3
    "LibStub",
}
```

### Error Handling During Development

- **BugSack + BugGrabber**: Install these companion addons. BugGrabber silently captures Lua errors; BugSack provides a UI to browse them. Far better than watching for errors in the chat frame.
- **`/dump`**: Built-in WoW command to inspect any Lua expression. E.g. `/dump GuildCraftsDB["Gandorf-Firemaw"]` to inspect a member's stored data.
- All incoming message handlers are wrapped in `pcall` — a malformed message from another addon user should never crash the local client.

### Per-Phase Test Checklist

Each phase in the implementation plan ends with a **Verification** section. The checklist below covers cross-cutting tests to run after each phase:

- [ ] `/reload` — addon loads without errors
- [ ] BugSack — no captured Lua errors
- [ ] `/gc mem` — memory usage within expected range
- [ ] `/gc dump` — data state matches expectations
- [ ] `/gc sim 200` then `/gc` — UI handles scale (if Phase 4+)
- [ ] `/gc sim clear` — simulated data fully removed

---

## Estimated Effort

| Phase | Description | Estimate |
|---|---|---|
| 0 | Project skeleton | ~1 hour |
| 1 | Local data scanning & storage | ~4 hours |
| 2 | Communication foundation | ~6 hours |
| 3 | Data sync protocol | ~12 hours |
| 4 | Main window UI | ~8 hours |
| 5 | Search | ~4 hours |
| 6 | Craft request system | ~6 hours |
| 7 | Polish & edge cases | ~8 hours |
| 8 | Release preparation | ~2 hours |
| **Total** | | **~51 hours** |

These are development-time estimates assuming familiarity with the WoW addon API and Lua. Testing and debugging time is included within each phase.
