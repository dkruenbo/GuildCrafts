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

### 1.3.0 — Ghost Member Auto-Prune

> **Problem:** Members who uninstall GuildCrafts but remain in the guild are never pruned. The existing `PruneStaleMembers` only removes members who have *left the guild* (roster absence + 30-day grace via `_absentSince`). A still-in-guild member who stops running the addon accumulates an ever-staler entry indefinitely. Additionally, the 30-day grace period for ex-guild members is too long — someone who left the guild is immediately irrelevant and their data should be gone within a week.

> **Solution:** Two threshold changes + one new sweep. `Data.lua` only, no protocol changes, no VERSION bump.

#### Threshold changes

> `STALE_THRESHOLD` is currently a single constant (`30 * 24 * 3600`) shared between three distinct uses:
> 1. The ex-guild member grace period in `PruneStaleMembers` (`_absentSince` check)
> 2. The staleness tag display threshold in `GetStalenessTag`
> 3. The stale member count in `CountStaleMembers`
>
> These need to be split into separate named constants so each can be tuned independently:
> ```lua
> local STALE_DISPLAY_THRESHOLD  = 30 * 24 * 3600  -- show [30d ago] tag (keep as-is)
> local EX_GUILD_GRACE_PERIOD    =  7 * 24 * 3600  -- prune ex-members after 7 days
> local INACTIVE_MEMBER_THRESHOLD = 45 * 24 * 3600  -- prune inactive in-guild members after 45 days
> ```
> Update references:
> - `PruneStaleMembers` `_absentSince` check → use `EX_GUILD_GRACE_PERIOD`
> - `GetStalenessTag` → use `STALE_DISPLAY_THRESHOLD` (no change in behaviour)
> - `CountStaleMembers` → use `STALE_DISPLAY_THRESHOLD` (no change in behaviour)
> - New inactive sweep → use `INACTIVE_MEMBER_THRESHOLD`

#### New inactive member sweep

> Add a second sweep in `PruneStaleMembers` after the existing ex-guild sweep:
> ```lua
> -- Prune still-in-guild members who haven't scanned in 45 days
> for memberKey, entry in pairs(db) do
>     if type(memberKey) == "string"
>     and type(entry) == "table"
>     and entry.lastUpdate and entry.lastUpdate > 0
>     and (now - entry.lastUpdate) > INACTIVE_MEMBER_THRESHOLD
>     and rosterKeys[memberKey] then   -- IS still in guild but data is stale
>         db[memberKey] = nil
>         pruned = pruned + 1
>     end
> end
> ```
> Log: `"Auto-pruned N inactive guild member(s) (45d+ no scan)."` at debug level.
>
> **Sync-back:** A lagging peer may re-sync the old data. Acceptable — the entry re-appears stale-tagged and is pruned again on the next cycle. If the member wants back in, they open their profession window and data re-syncs with a fresh `lastUpdate`.

> **Files:** `Data.lua` only — constants block and `PruneStaleMembers()`.

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
