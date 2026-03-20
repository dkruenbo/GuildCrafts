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

### 1.1.6 — Multi-Locale Support

| Issue | Title | Status |
|-------|-------|--------|
| [#8](https://github.com/dkruenbo/GuildCrafts/issues/8) | Locale Support — multi-language guild sync and display | Done in 1.1.6 |

### 1.1.7a — Guild Chat Integration

| Issue | Title | Status |
|-------|-------|--------|
| — | `!gc <query>` guild chat command — DR/BDR/OTHER staggered response | Done in 1.1.7a |
| — | `[>]` post-to-guild-chat button on recipe rows | Done in 1.1.7a |
| — | Dedup via `GetTime()` float echo check (sub-second precision) | Done in 1.1.7a |
| — | OTHER-tier jitter (`math.random(0,8)`) to prevent response storms | Done in 1.1.7a |

### 1.2.0 — Protocol Correctness + Cooking

| Issue | Title | Status |
|-------|-------|--------|
| [#47](https://github.com/dkruenbo/GuildCrafts/issues/47) | Term-based authority enforcement (split-brain protection) | Done in 1.2.0 |
| [#48](https://github.com/dkruenbo/GuildCrafts/issues/48) | Document safety guarantees and convergence properties | Done in 1.2.0 |
| [#60](https://github.com/dkruenbo/GuildCrafts/issues/60) | Add Cooking profession support | Done in 1.2.0 |

### 1.2.1 — Data Clarity & Search UX

| Issue | Title | Status |
|-------|-------|--------|
| — | Online-only member filter (toggle next to favourites star) | Done in 1.2.1 |
| — | Better empty search state with actionable `!gc` hint | Done in 1.2.1 |
| — | "Scanned: N ago" timestamp in member detail panel | Done in 1.2.1 |
| — | Specialisation description tooltip in member detail panel | Done in 1.2.1 |

### 1.2.2 — Expansion Filter

| Issue | Title | Status |
|-------|-------|--------|
| [#49](https://github.com/dkruenbo/GuildCrafts/issues/49) | Recipe expansion filter (Classic / TBC) | Done in 1.2.2 |

### 1.2.3 — Whisper & UI Polish

| Issue | Title | Status |
|-------|-------|--------|
| [#50](https://github.com/dkruenbo/GuildCrafts/issues/50) | Replace craft request popup with `[W]` whisper button | Done in 1.2.3 |
| — | Bottom bar with `[Online]` and `[Tooltip]` toggle buttons | Done in 1.2.3 |
| — | Tooltip crafters toggle (`showTooltipCrafters`) | Done in 1.2.3 |

### 1.2.4b — Correctness & Safety Patch

| Issue | Title | Status |
|-------|-------|--------|
| — | Enchanting fallback key collision fix (namespaced hash, dedicated range) | Done in 1.2.4b |

### 1.2.5 — Responsiveness & Trust

| Issue | Title | Status |
|-------|-------|--------|
| — | Deferred tooltip index rebuild (no rebuild on hover) | Done in 1.2.5 |
| — | Richer sync dot tooltip (last synced time + stale member count) | Done in 1.2.5 |

---

## Planned

---

### 1.3.0 — Ghost Member Data & Tombstone Protocol

> **Problem:** Members who uninstall GuildCrafts but remain in the guild are never pruned. The existing `PruneStaleMembers` only removes members who have *left the guild* (roster absence + 30-day grace via `_absentSince`). A still-in-guild member who stops running the addon accumulates an ever-staler entry with no cleanup path. Making the prune *stick* requires tombstones — any local deletion without them gets synced back in by the first peer who still has the data.

> **Why this is 1.3.0 and not a patch:** A correct tombstone implementation requires touching the sync protocol (new `TOMBSTONE` message type), `MergeIncoming` (tombstone wins over entries with older timestamps), `StripSyncFields` / SYNC_RESPONSE payload (tombstones must be carried in sync), persistent DB storage (tombstones must survive relogs), and a protocol version bump. This is meaningful surface area — more than any 1.2.x change.

#### Tombstone design

> A tombstone is a lightweight record stored in the guild DB under a reserved key, separate from member entries:
> ```lua
> db["__tombstones"] = {
>     ["PlayerName-Realm"] = { deletedAt = timestamp, deletedBy = "OfficerName-Realm" },
>     ...
> }
> ```
> **Reserved key guard — critical:** `db["__tombstones"]` must be explicitly skipped in every `pairs(db)` loop in `Data.lua`. Functions that currently iterate all DB keys without a guard include `CountStaleMembers`, `MergeIncoming`, `GetVersionVector`, `PruneStaleMembers`, and several others. Without the guard, each of these will treat the tombstone table as a member entry and behave incorrectly (e.g. `GetVersionVector` would include `__tombstones.lastUpdate` in the vector; `PruneStaleMembers` would try to evict it from the roster). The safest pattern is a shared helper:
> ```lua
> local function IsMemberKey(key)
>     return type(key) == "string" and key ~= "__tombstones"
> end
> ```
> Apply this check at the top of every `for key, entry in pairs(db)` loop before any other logic. This is the highest-risk part of the implementation — easy to add the tombstone table, easy to forget to guard one loop.
>
> **Merge precedence** — `MergeIncoming` must follow this exact decision tree for each incoming member entry:
> ```
> 1. Does a tombstone exist for this member key?
>    YES → Is incoming lastUpdate > tombstone.deletedAt?
>          YES → Member re-scanned after the prune (resurrection). Clear tombstone, accept data.
>          NO  → Tombstone wins. Drop incoming data.
>    NO  → Run standard merge: newest lastUpdate wins.
> ```
> This order is critical. Reversing the checks would allow a stale sync from a lagging peer to silently resurrect a pruned member.
>
> **Sync:** Tombstones are included in SYNC_RESPONSE and DELTA_UPDATE payloads. A peer coming back online after being absent during a prune will receive the tombstone during their initial sync and correctly discard their stale copy.
>
> **Expiry:** Tombstones expire after 90 days. This prevents unbounded growth. Edge case: a peer who was offline for 91+ days logs in with the original member data, but the tombstone is gone. This is acceptable — the existing `PruneStaleMembers` already evicts guild-roster-absent members after 30 days, giving a 60-day safety margin before a tombstone would expire. A peer carrying 91-day-old data for a member who has long since left the roster would also have that entry removed by their own prune on login. The overlap is safe.

#### Officer prune (`/gc prune`)

> Any officer can run `/gc prune [days]` (default: 90). The client does not need to be the DR. Flow:
> 1. Officer runs `/gc prune [days]` — their client lists candidates locally (still-in-guild members with `lastUpdate` older than threshold) and asks for confirmation.
> 2. On confirm, a `PRUNE_REQUEST` message is sent via whisper to the current DR (same pattern as `SYNC_REQUEST`). The payload contains the list of member keys to tombstone and the requesting officer's player key.
> 3. The DR validates that the requester holds a privileged rank — see **Rank validation** below. If validation fails, the DR whispers back a rejection. If it passes, the DR creates the tombstone entries and broadcasts a `PRUNE_BROADCAST` to the guild channel.
> 4. All peers apply the tombstones on receipt.
>
> If the officer *is* the DR, the request is handled locally without a whisper round-trip.
>
> **DR unavailability:** If `self.currentDR` is nil at the time the officer confirms, show an error immediately: *"GuildCrafts: No DR is currently elected. Try again in a moment."* Do not send the request — there is no one to receive it. Re-run `/gc prune` once a DR is elected (the sync dot turning green is the signal).
>
> **Rank validation — implementation detail:** `GetGuildRosterInfo` returns a rank *index* (0 = Guild Master), not a named role. Guild rank names vary per guild so checking by name is fragile. Two options:
> - **Convention (simpler):** Treat rank index ≤ 2 as authorised (GM + first two officer ranks). Works for most guilds with a traditional rank structure.
> - **Configurable (robust):** Add a `/gc set-prune-rank <index>` command for the GM to set the minimum authorised rank index, stored in `db.global.pruneRankThreshold`. Defaults to 2.
> The configurable approach is recommended for 1.3.0 to avoid assumptions about guild structure.

#### Member self-removal (`/gc remove-my-data`)

> Any member can request removal of their own data. The request is sent to the current DR as a `REMOVE_REQUEST` message. The DR validates the sender (only the member themselves can remove their own entry — enforce via sender check on the message), creates the tombstone, and broadcasts it. This is the correct self-service path that doesn't require officer involvement.

#### Protocol version bump

> `VERSION` in `Core.lua` bumped from `2` to `3`. Nodes on VERSION 2 will not understand `PRUNE_BROADCAST` or `REMOVE_REQUEST` — they will ignore unknown message types (existing behaviour) and simply re-sync the pruned data back in.
>
> **v2 peer isolation:** VERSION 3 nodes must not send tombstone data to VERSION 2 peers. Tombstone payloads in SYNC_RESPONSE should be stripped when the requester's VERSION is < 3 (the requester's version is known from their `HELLO` message and stored in `addonUsers`). Sending tombstone tables to a v2 client wastes bandwidth and risks confusing their merge logic if they happen to handle unknown keys unexpectedly.
>
> **Update reminder:** When a VERSION 3 node receives any message from a VERSION 2 peer, print once per session (not per message):
> ```
> GuildCrafts: [PlayerName] is running an older version (v2). Pruning and advanced sync features are disabled for this peer. Ask them to update to 1.3.0.
> ```
> Use a `_warnedLegacyPeers` set to suppress repeat warnings for the same sender.

> **Files:** `Comms.lua` (new `PRUNE_BROADCAST`, `REMOVE_REQUEST` handlers, DR-gated broadcast), `Data.lua` (`MergeIncoming` tombstone logic, `PruneInactiveGuildMembers`, tombstone expiry), `Core.lua` (`/gc prune`, `/gc remove-my-data` slash handlers, VERSION bump), `UI/MainFrame.lua` (prune candidate list UI, confirmation dialog).

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
| — | Old guild partition cleanup | Detect and offer to clean up `db.global` partitions from guilds the user is no longer in. Detection heuristic ("contains a hyphen") is weak — needs a more explicit partition identity model (e.g. a `_guildPartition = true` metadata flag written at partition creation time) before auto-detection is safe enough to act on. Non-destructive `/gc cleanup` command with confirmation is the right shape. Non-urgent — slow-moving problem, only affects guild-hoppers. |
| — | Quick-action buttons in search results (Request / Post) | Convenience shortcut. Low complexity, good candidate for a 1.2.x patch after 1.2.0 ships. |
| — | Cooldown panel: dedicated UI panel showing who has what on cooldown and when it expires | Basic cooldown tracking (Mooncloth, Shadowcloth, Spellcloth, Transmutes) is already implemented and visible in the existing UI. This item is a separate, focused panel — a dedicated view listing all guild cooldowns with expiry countdowns. Requires DR to broadcast cooldown state in real time; design needed before implementation. |
