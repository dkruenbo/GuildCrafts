# GuildCrafts — Roadmap

Issue tracker: https://github.com/dkruenbo/GuildCrafts/issues

This document describes planned releases with implementation notes for each item.

---

## Released

### 1.0.x — Patch Fixes

| Issue | Title | Status |
|-------|-------|--------|
| [#27](https://github.com/dkruenbo/GuildCrafts/issues/27) | Per-guild database partitioning | Fixed in 1.0.4 |
| [#30](https://github.com/dkruenbo/GuildCrafts/pull/30) | Luacheck cleanup — 0 warnings / 0 errors | Fixed in 1.0.4 |
| [#23](https://github.com/dkruenbo/GuildCrafts/issues/23) | Lazy tooltip index rebuild (dirty flag) | Done (already implemented) |
| [#24](https://github.com/dkruenbo/GuildCrafts/issues/24) | Wrong recipe for Enchant Gloves - Spell Strike | Fixed in 1.0.3 |

### 1.1.0 — Data & Sync Optimisation

| Issue | Title | Status |
|-------|-------|--------|
| [#18](https://github.com/dkruenbo/GuildCrafts/issues/18) | Deduplicate reagent data with shared RecipeDB lookup | Done in 1.1.0 |
| [#20](https://github.com/dkruenbo/GuildCrafts/issues/20) | Auto-prune stale member entries | Done in 1.1.0 |
| [#5](https://github.com/dkruenbo/GuildCrafts/issues/5) | Favorites / Bookmarks | Done in 1.1.0 |

### 1.1.5 — Complete UI Overhaul

| Issue | Title | Status |
|-------|-------|--------|
| [#37](https://github.com/dkruenbo/GuildCrafts/issues/37) | Dark mode profession sidebar buttons with WoW icons | Done in 1.1.5 |
| [#38](https://github.com/dkruenbo/GuildCrafts/issues/38) | Quality-colored recipe/reagent names + raid target star for favorites | Done in 1.1.5 |
| [#39](https://github.com/dkruenbo/GuildCrafts/issues/39) | Collapsible reagent lists (click recipe to expand/collapse) | Done in 1.1.5 |
| [#44](https://github.com/dkruenbo/GuildCrafts/issues/44) | Recipe-centric view with inline crafter preview | Done in 1.1.5 |
| [#45](https://github.com/dkruenbo/GuildCrafts/issues/45) | Members/Recipes view toggle for professions | Done in 1.1.5 |

### 1.1.7a — Guild Chat Integration

| Issue | Title | Status |
|-------|-------|--------|
| — | `!gc <query>` guild chat command — DR/BDR/OTHER staggered response | Done in 1.1.7a |
| — | `[>]` post-to-guild-chat button on recipe rows | Done in 1.1.7a |
| — | Dedup via `GetTime()` float echo check (sub-second precision) | Done in 1.1.7a |
| — | OTHER-tier jitter (`math.random(0,8)`) to prevent response storms | Done in 1.1.7a |

---

## Upcoming

---

## 1.2.0 — Protocol Correctness

**Theme:** Close formal safety gaps in the sync protocol. Two tightly scoped items — one code change, one documentation pass. No wire-format changes, no merge-logic changes, clean to validate.

**Note:** UX improvements are intentionally held out of this release. See 1.2.1 below.

---

### [#47] Term-based authority enforcement (split-brain protection)

> **What it is:** Add a monotonically incrementing `term` counter to the DR election so stale-leader commands are rejected after a DR handover. Without this, a delayed HEARTBEAT from an old DR could be accepted by nodes that have already elected a new one.

**Why now:** The current LWW (last-write-wins) version vector protects *data* integrity but not *authority* integrity. The protocol is empirically stable in a small guild on a reliable network, but the design is formally unsound. This is a clean ~50 line change with high correctness value.

**Implementation:**

1. **State** — Add `self.currentTerm = 0` to `Comms:OnInitialize()`. Keep it **runtime-only** (do not persist to `SavedVariables`). The term resets to `0` on every login and the first DR promotion bumps it to `1`. This is sufficient to reject a delayed stale-leader message within the same session. Persistence would only add value for reload/rehydration edge cases that have no reported user impact — don't solve a problem you don't have.

2. **DR promotion** — In `RecomputeElection()`, when role changes to `"DR"`, increment `self.currentTerm` before starting the heartbeat:
   ```lua
   if self.myRole == "DR" then
       self.currentTerm = self.currentTerm + 1
       self:StartHeartbeat()
   end
   ```

3. **HEARTBEAT payload** — Add `term = self.currentTerm` to `SendHeartbeat()`.

4. **SYNC_RESPONSE payload** — Add `term = self.currentTerm` to the envelope in `ProcessSyncRequest()`.

5. **Inbound checks** — In `HandleHeartbeat()` and `HandleSyncResponse()`, gate on term:
   ```lua
   if msg.term < self.currentTerm then return end  -- reject stale
   if msg.term > self.currentTerm then
       self.currentTerm = msg.term
       -- step down if we thought we were DR
       if self.myRole == "DR" then
           self.myRole = "OTHER"
           self:StopHeartbeat()
       end
   end
   ```

6. **Migration** — Existing installs with no stored term default to `0`. First real DR promotion bumps it to `1`, which is higher than any stale-DR `0` message. No special migration code needed.

7. **Backward compat** — Old clients (v1.1.x) send no `term` field. Treat missing term as `0`, which will always be ≤ `currentTerm` after first election. Harmless.

**Files:** `Comms.lua` (~50 lines), `Core.lua` (version bump).

---

### [#48] Document safety guarantees and convergence properties

> **What it is:** Add a `## Safety Guarantees` section to README.md formally stating what can and cannot happen in the sync protocol — what is prevented, what is eventually consistent, and what the known limitations are.

**Why now:** Pure documentation, no code changes. Write it immediately after #47 lands while the design decisions are fresh.

**Implementation:**

Write a section covering three categories:

- **Safety (what cannot happen):** At most one valid DR per term (once #47 lands). No conflicting per-recipe data for the same `(member, profession, recipeKey)` triple — the version vector's LWW merge is idempotent. No data loss for a successfully ACK'd sync (the requester only marks `syncPending = false` on final chunk receipt).

- **Liveness (what may temporarily happen):** Stale data visible during a network partition (eventual consistency model — all nodes converge when connectivity is restored). Delayed convergence after DR failure — up to `3 × HEARTBEAT_INTERVAL = 180s`. Duplicate HEARTBEAT/SYNC messages are safe — all handlers are idempotent.

- **Convergence (what must eventually happen):** All connected nodes converge to a consistent state via the version vector comparison in `ProcessSyncRequest`. DR/BDR election completes within one roster update. A failed DR is detected and replaced within 180s.

- **Limitations subsection:** No Byzantine fault tolerance (a malicious client can inject false data). Clock-based LWW means data from a client with a misconfigured system clock may incorrectly win or lose merge conflicts. No quorum — DR acts as single source of truth.

**Files:** `README.md` only.

---

## 1.2.1 — Data Clarity & Search UX

**Theme:** Surface existing data more clearly. All three items use data and infrastructure already in the codebase — this is purely a UI and messaging pass. Separating it from 1.2.0 means any regression can be cleanly attributed to either the protocol changes or the UI changes, not both.

---

### Online-only crafter filter toggle

> **What it is:** A toggle button in the Recipes view and Search Results view that hides crafters who are currently offline from the crafter list. Currently online crafters are already sorted to the top; this makes "show only online" a first-class UI action rather than requiring the user to scroll past offline names.

**Why now:** The online/offline status infrastructure already exists — `Data._onlineCache` is populated from `GetGuildRosterInfo` on every `GUILD_ROSTER_UPDATE`. This is purely a UI filter layer on top of existing data. Estimated ~40 lines in `MainFrame.lua`.

**Implementation:**

1. **State** — Add a boolean `GuildCrafts.UI.showOnlineOnly = false` (default off, or persist to `AceDB`).

2. **Toggle button** — In `MainFrame.lua`, add a small toggle button in the recipes/search header bar (next to the existing search box or view toggle). Style it like the existing sidebar buttons. On click, flip `showOnlineOnly` and call `UI:Refresh()`.

3. **Filter at render time** — In the crafter-list rendering loop (both `ShowRecipesView` and `ShowSearchResults`), wrap the crafter display in:
   ```lua
   if self.showOnlineOnly then
       local isOnline = GuildCrafts.Data._onlineCache
           and GuildCrafts.Data._onlineCache[crafterKey]
       if not isOnline then goto continue end
   end
   ```

4. **Visual state** — When the toggle is active, give it a highlighted border or different text color so it's clear the filter is on. Use the same highlight pattern as the existing active-tab buttons.

5. **Persistence** — Store `showOnlineOnly` in `AceDB` profile so it survives reloads. Key: `db.profile.showOnlineOnly`.

**Files:** `UI/MainFrame.lua` (~40 lines), `Data.lua` (no changes — `_onlineCache` already exists).

---

### Better no-result states: missing-scan CTA and search suggestions

> **What it is:** Replace the current empty/sparse states (missing profession data shown as `~`, search returning nothing silently) with actionable messages that tell the user why data is missing and what to do about it.

**Why now:** Two common pain points from tester feedback: (1) seeing `~` for a guild member's professions with no explanation, (2) searching for a recipe and getting no results with no guidance on whether that means nobody can craft it or the data just hasn't been collected yet.

**Implementation:**

1. **Missing profession data (`~` → actionable message):**
   In `MainFrame.lua`, wherever member profession data is rendered as `~` or empty, replace with a dim italic label:
   ```
   "Data not yet scanned — ask them to open their profession window"
   ```
   The condition is: member exists in the guild DB but `entry.professions[profName]` is `nil` or `entry.lastUpdate` is `0`.

2. **Empty search results:**
   In `ShowSearchResults()`, when `results` is empty, render a hint frame instead of a blank scroll area:
   ```
   "No crafters found for '[query]'.
    Try: a shorter search term, checking Browse by Profession,
    or asking in guild chat with !gc [query]."
   ```

3. **`!gc` no-match consistency:**
   The `!gc` handler in `Core.lua` already posts "No crafters found for X" to guild chat. Mirror the same message in the UI search panel so the two surfaces are consistent.

4. **Last-scan timestamp context:**
   Show a dim timestamp next to missing data: "Last updated: never" or "Last updated: 14 days ago". This tells the user whether the data was collected long ago or never at all. Data source: `entry.lastUpdate` in the guild DB.

**Files:** `UI/MainFrame.lua` (~30 lines), `Core.lua` (no changes needed for !gc).

---

### Show "last scanned N ago" timestamp in member detail view

> **What it is:** Display a human-readable "Updated 2 hours ago" / "Updated 3 days ago" label on member detail panels so users can judge how fresh the data is.

**Why now:** `entry.lastUpdate` is already stored per member. The data is there; it just isn't surfaced anywhere in the UI. This is a pure display addition.

**Implementation:**

1. **Helper function** — Add a local `FormatAge(timestamp)` in `MainFrame.lua`:
   ```lua
   local function FormatAge(ts)
       if not ts or ts == 0 then return "never" end
       local delta = time() - ts
       if delta < 120 then return "just now"
       elseif delta < 3600 then return math.floor(delta / 60) .. "m ago"
       elseif delta < 86400 then return math.floor(delta / 3600) .. "h ago"
       else return math.floor(delta / 86400) .. "d ago" end
   end
   ```

2. **Render location** — In the member detail panel (the view that shows a single member's professions and recipes), add a dim label below the member name:
   ```
   Scanned: 2h ago
   ```
   Use `|cff808080` (medium grey) to make it clearly secondary information.

3. **Refresh on UI update** — `FormatAge` is called at render time, so it's always current whenever the panel redraws (which happens on `UI:Refresh()` calls triggered by sync events).

**Files:** `UI/MainFrame.lua` (~20 lines).

---

> **Exit criterion:** After 1.2.1, GuildCrafts is considered feature-complete for its core use case. Everything below this line is optional and only justified by confirmed user demand or available contributors.

---

## Future Candidates

Items in this section are not a committed release. They are candidates — each one only worth building if there is real user demand, a clear scope boundary, or a contributor ready to own it.

---

### [#7] Export to CSV / Text

> **What it is:** A `/gc export` command that dumps the full guild recipe database to a format that can be copied out of the game for spreadsheets or guild websites.

**Implementation notes:**
- WoW addons cannot write arbitrary files. The standard workaround is to write the export into a `SavedVariables` entry as a plain string, then instruct the user to open `WTF/Account/.../SavedVariables/GuildCrafts.lua` and copy the value. Alternatively — and more user-friendly — open a full-screen scrollable text frame the user can Ctrl+A / Ctrl+C from directly in-game.
- The in-game copy frame approach is strongly preferred (no file system navigation required). Use `AceGUIContainer-Frame` fullscreen with a `MultiLineEditBox` set to read-only.
- CSV columns: `Member, Profession, Recipe, SkillLevel, Specialisation, Category, LastScanned`.
- For large guilds (50+ members, 500+ recipes per member), build the CSV string incrementally using `table.concat` on a parts list to avoid string concatenation performance degradation.
- Consider coroutine-based generation if the dataset causes frame drops (unlikely for typical guild sizes, but guard it).

**Files:** `Core.lua` (new `/gc export` slash handler), `UI/MainFrame.lua` (export frame), `Data.lua` (new `ExportCSV()` method).

---

### [#8] Locale Support

> **What it is:** Make all user-visible strings in the UI and chat messages locale-aware so the addon works correctly for non-English clients.

**Implementation notes:**
- The profession name normalisation layer (`Data:GetCanonicalProfName()` via `PROFESSION_SPELL_IDS`) already handles localized profession names from `GetSpellInfo`. This is the hardest part of locale support and it's already done.
- Remaining work: extract all hardcoded English strings in `UI/MainFrame.lua` and `Core.lua` into a `Locale.lua` file using AceLocale-3.0 or a simple `L = {}` table pattern. AceLocale-3.0 is the conventional WoW addon approach.
- Recipe names are already localized via `Data:GetLocalizedRecipeName()` using `GetItemInfo` / `GetSpellInfo`.
- The main effort is the UI label strings (~80–100 strings in `MainFrame.lua`).

**Files:** New `GuildCrafts/Locale.lua` (and per-locale files e.g. `Locale-deDE.lua`), `UI/MainFrame.lua` (replace string literals with `L["key"]`), `Core.lua` (same), `GuildCrafts.toc` (new file entries).

---

### [#6] In-Game Craft Request Chat

> **What it is:** A small embedded chat panel between requester and crafter that appears when a craft request is accepted. Keeps negotiation (mats, tip, meeting point) in-context instead of switching to the whisper window.

> **Honest assessment:** This is the weakest large feature in the roadmap. The underlying CRAFT_REQUEST protocol is already built, so the *protocol* cost is zero — but the UI wiring, edge-case handling (disconnect mid-craft, panel state on reload, both sides closing at different times), and a new `MSG_CRAFT_CHAT` message type add meaningful ongoing maintenance surface for a feature whose practical advantage over just using the built-in whisper window is marginal. Before implementing, validate with actual users that the whisper workflow is a real pain point, not a theoretical one. **If you want to end the project cleanly, skip this feature entirely.** It belongs on the roadmap only if contributors are available and user demand is confirmed.

**Implementation notes:**
- On `HandleCraftAccept`, open a slim chat panel frame (similar to `AceGUIContainer-Frame`) anchored to the main GuildCrafts window.
- Messages are sent via addon whisper (the existing `SendMessage(..., "WHISPER", ...)` path with a new `MSG_CRAFT_CHAT` type), so they are invisible in normal chat.
- The panel auto-closes when `MSG_CRAFT_COMPLETE` or `MSG_CRAFT_DECLINE` is received, or when the user clicks "Done".
- Do **not** persist chat history to `SavedVariables` — session-only.

**Files:** `UI/MainFrame.lua` (new chat panel), `Comms.lua` (new `MSG_CRAFT_CHAT` type and handler), `CraftRequest.lua` (wire up open/close).

---

### [#9] Code Modularisation

> **What it is:** Split `Data.lua` (1,884 lines) and `UI/MainFrame.lua` (2,371 lines) into focused sub-modules.

> **Honest assessment:** This is an internal housekeeping task with zero user-visible impact. It is only worth doing if (a) you are actively onboarding a new contributor who needs navigable files, or (b) a specific file is causing repeated PR conflicts. Otherwise it is a productivity cost dressed up as progress. The current file sizes are large but not dysfunctional for a single maintainer. **Do not let this block or delay any user-facing work.**

**Implementation notes:**
- This is a pure refactor with zero user-visible changes. Do it in one PR to avoid a long-lived split-state.
- Suggested split for `Data.lua`:
  - `Data/Scan.lua` — `ScanTradeSkills`, `ScanCraft`, `ScanCurrentProfession`
  - `Data/Merge.lua` — `MergeIncoming`, `MergeDelta`, `MergeProfessionRemoval`
  - `Data/Search.lua` — `SearchRecipes`, `StripVowels`, `BuildSearchIndex`
  - `Data/Roster.lua` — `RebuildOnlineCache`, `PruneStaleMembers`, `GetPlayerKey`
  - `Data/DB.lua` — `OnInitialize`, `GetGuildDB`, `GetVersionVector`, `StripSyncFields`
- Suggested split for `UI/MainFrame.lua`:
  - `UI/RecipesView.lua` — profession sidebar, recipes list, post button
  - `UI/SearchView.lua` — search bar, results list
  - `UI/MemberView.lua` — member detail panel
  - `UI/CraftRequestView.lua` — craft request popup (overlaps with #6)
  - `UI/MainFrame.lua` — frame creation, tab navigation, `Refresh()`
- All sub-modules share the same `GuildCrafts` global and use the same `local _, _ns = ...` bootstrap pattern.
- Update `embeds.xml` and `GuildCrafts.toc` to load new files in dependency order.

**Files:** Many — treat as a full refactor milestone.

---

## Backlog (no milestone assigned)

| Issue | Title | Notes |
|-------|-------|-------|
| [#21](https://github.com/dkruenbo/GuildCrafts/issues/21) | Coalesce login sync storms on DR | Premature optimisation — no reported user pain. Revisit if DR lag is observed during raid-start login surges. |
| [#22](https://github.com/dkruenbo/GuildCrafts/issues/22) | Piggyback version vector hash on HEARTBEAT | Premature optimisation — SYNC_REQUESTs at login are legitimate, not redundant. Revisit if telemetry shows unnecessary round-trips. |
| [#19](https://github.com/dkruenbo/GuildCrafts/issues/19) | Incremental sync: send only changed professions | Premature optimisation. `DELTA_UPDATE` already handles the real-time case; the full-member SYNC_RESPONSE only fires for members who were offline, and LibDeflate already compresses those payloads well. The implementation touches version vector format, merge semantics, `StripSyncFields`, and requires capability negotiation in `HELLO` — meaningful surface area for a problem with no reported user pain. Revisit only if a 50+ member guild reports slow post-login sync or chat throttle hits. Benchmark first. |
| — | Search result ranking by skill level / online status | Useful QoL but requires ranking model design. |
| — | Quick-action buttons in search results (Request / Post) | Convenience shortcut. Low complexity, good candidate for a 1.2.x patch after 1.2.0 ships. |
| — | Cooldown panel: show who has what on cooldown and when it expires | Requires active DR participation to broadcast cooldown state. Design needed before implementation. |
