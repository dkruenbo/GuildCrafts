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

---

## Planned

---

### 1.2.4b — Correctness & Safety Patch

#### Enchanting recipe key collision fix

> **What:** The fallback key generation in `Data:GetCraftRecipeKey()` for enchants that yield neither an itemID nor a spellID produces a negative integer derived from a simple `(hash * 31 + byte) % 1000000` hash of the localised craft name. This creates a real (if small) collision risk: two different enchant names could hash to the same key, causing one recipe to silently overwrite the other in the DB, with no error surfaced.

> **Why:** The stable spellID-based negative key (`-spellID`) is already used for the vast majority of enchants and is collision-free. The name-hash fallback should only ever fire if both `GetCraftItemLink` and `GetCraftRecipeLink` return nil — which in practice should not happen for any known TBC enchant. But if it does, the current hash is not safe enough given that the key is stored persistently and synced to other clients.

> **How:**
> 1. Open `Data.lua` and find `Data:GetCraftRecipeKey()` (around line 1143).
> 2. The last-resort block currently does:
>    ```lua
>    local hash = 0
>    for c = 1, #craftName do
>        hash = (hash * 31 + craftName:byte(c)) % 1000000
>    end
>    return -(hash + 1000000)
>    ```
> 3. Replace with a namespaced key in a dedicated negative range, separated from both positive itemIDs and real spellID-based negative keys. Real spellIDs for TBC enchants are in the range 13–28000, so placing the fallback below −2,000,000 avoids overlap with real keys:
>    ```lua
>    local namespacedInput = "enc:" .. craftName
>    local hash = 0
>    for c = 1, #namespacedInput do
>        hash = (hash * 31 + namespacedInput:byte(c)) % 1000000
>    end
>    return -(hash + 2000000)
>    ```
> 4. Add a comment: `-- Fallback: namespaced hash in a dedicated negative range. Collision risk is reduced but not eliminated. Only fires if both item and spell links are nil (should not happen for known TBC enchants).`
> 5. No DB migration needed — this fallback path fires only for unknown recipes that have no valid link at all. If any old entry was stored under the old hash range (−1,000,000 to −2,000,000), it will simply become an orphan (not found by the new key) and be silently ignored. That is acceptable since these entries had no real identity to begin with.

> **Files:** `GuildCrafts/Data.lua` — only `GetCraftRecipeKey()`.
> **Risk:** Very low. The change only affects the fallback path, which should be dead code for all known TBC enchants.

---

### 1.2.5 — Responsiveness & Trust

#### Tooltip index incremental rebuild (#6)

> **What:** `Tooltip:RebuildIndex()` iterates the entire guild DB every time it runs — scanning all members, all professions, all recipes — and rebuilds the `indexByID` and `indexByName` tables from scratch. `indexDirty` is set to `true` whenever data changes (via `InvalidateIndex()`). This means the first tooltip hover after any sync or delta update triggers a full rebuild, which can cause a visible frame hitch in large guilds.

> **Why:** With 50+ members and hundreds of recipes per profession, the full rebuild iterates thousands of table entries in a single frame. WoW's Lua runs on the main thread with no background execution, so a large rebuild blocks frame rendering for a perceptible moment.

> **How (deferred rebuild — recommended for maintenance mode):**
>
> A naive incremental approach (scanning `indexByID` and `indexByName` to remove a member's entries on every sync) moves the work from hover-time to sync-time but does not eliminate it — it just shifts the spike to a less user-visible moment. For a truly incremental index, a reverse-ref map (`memberToRecipeKeys`, `memberToRecipeNames`) would be needed to avoid full scans on removal. That adds coupling and is out of scope for maintenance mode.
>
> The simpler, lower-risk approach:
> 1. Keep `indexDirty` as-is. Keep `InvalidateIndex()` as-is.
> 2. **Remove the `RebuildIndex()` call from `OnTooltipSetItem`.** Do not rebuild on hover.
> 3. Instead, schedule a deferred rebuild via a short timer when the index is marked dirty:
>    ```lua
>    function Tooltip:InvalidateIndex()
>        indexDirty = true
>        if not self._rebuildTimer then
>            self._rebuildTimer = C_Timer.After(2, function()
>                self._rebuildTimer = nil
>                if indexDirty then self:RebuildIndex() end
>            end)
>        end
>    end
>    ```
>    This means the rebuild happens 2 seconds after the last data change — well after the sync burst completes — and never during a hover event.
> 4. `OnTooltipSetItem` uses whatever index is currently built. If the index is still mid-rebuild (i.e. a hover fires within 2 seconds of a data change), it uses the previous index. This is acceptable — a briefly stale tooltip is far better than a hover hitch.
> 5. On `OnInitialize`, call `RebuildIndex()` directly (no timer needed — no user interaction yet).

> **Files:** `GuildCrafts/Tooltip.lua` only — `InvalidateIndex()` and `OnTooltipSetItem`. No changes to `Data.lua`.
> **Risk:** Low. The change is fully contained in Tooltip.lua. Test: hover immediately after login sync (uses existing index, no hitch), hover 3 seconds after a delta update (uses freshly rebuilt index).

---

#### Richer sync status in tooltip (#12)

> **What:** The sync dot in the title bar shows three states: green (synced), yellow (syncing), red (no addon users / disconnected). Hovering shows `Status`, `DR`, and `Addon users`. This tells you the current sync state but nothing about *data freshness* — you cannot tell if the data was last synced 10 minutes ago or 3 days ago, or whether any members have stale entries.

> **Why:** Users with the debug panel open can see election activity but there is no easy way to judge whether the data they're looking at is trustworthy. Adding "last synced" and a stale-member count to the hover tooltip costs little (all the data exists) and meaningfully increases trust in the addon.

> **How:**
> 1. **Track sync completion time in Comms.** In `Comms.lua`, add a field `self.lastSyncCompletedAt = nil`. Set it to `time()` only when a real sync transaction completes — i.e. in `HandleSyncResponse` when the final chunk is received (`payload.chunkIndex == payload.chunkTotal`) and `self.syncPending` is cleared. **Do not set it when the DR skips sync because it is already current** — that would show "Last synced: 10s ago" without any data actually having been exchanged, which is misleading.
>    The DR never receives a `SYNC_RESPONSE` (it is the one sending them), so `lastSyncCompletedAt` will remain `nil` for a DR node that has not synced with anyone. That is correct and honest — the DR's tooltip can show "not yet" for last synced, which accurately reflects that it has not gone through a sync transaction this session.
>    ```lua
>    function Comms:GetLastSyncTime()
>        return self.lastSyncCompletedAt
>    end
>    ```
> 3. **Count stale members in Data.** Add a method `Data:CountStaleMembers(thresholdDays)`:
>    ```lua
>    function Data:CountStaleMembers(thresholdDays)
>        local threshold = thresholdDays * 86400
>        local now = time()
>        local count = 0
>        local db = self:GetGuildDB()
>        if not db then return 0 end
>        for _, entry in pairs(db) do
>            if type(entry) == "table" and entry.lastUpdate then
>                if (now - entry.lastUpdate) > threshold then
>                    count = count + 1
>                end
>            end
>        end
>        return count
>    end
>    ```
> 4. **Update the sync dot tooltip** in `UI/MainFrame.lua` in the `syncDot:SetScript("OnEnter", ...)` block. After the existing three `AddDoubleLine` calls, add:
>    ```lua
>    local lastSync = GuildCrafts.Comms and GuildCrafts.Comms:GetLastSyncTime()
>    if lastSync then
>        local age = time() - lastSync
>        local ageStr = GuildCrafts.Data:FormatAge(age)  -- reuse existing formatter
>        GameTooltip:AddDoubleLine("Last synced:", ageStr .. " ago", 0.7,0.7,0.7, 1,1,1)
>    else
>        GameTooltip:AddDoubleLine("Last synced:", "not yet this session", 0.7,0.7,0.7, 0.6,0.6,0.6)
>    end
>    local stale = GuildCrafts.Data and GuildCrafts.Data:CountStaleMembers(30) or 0
>    if stale > 0 then
>        GameTooltip:AddDoubleLine("Stale members (30d+):", tostring(stale), 0.7,0.7,0.7, 1,0.5,0.2)
>    end
>    ```
> 5. Verify that `Data:FormatAge()` exists and is accessible — it is used in the member detail panel already. If the function is local, promote it to a method or duplicate the logic inline.

> **Files:** `GuildCrafts/Comms.lua` (add `lastSyncCompletedAt`, `GetLastSyncTime()`), `GuildCrafts/Data.lua` (add `CountStaleMembers()`), `GuildCrafts/UI/MainFrame.lua` (extend sync dot tooltip).
> **Risk:** Low — all changes are additive. Nothing existing is modified except the tooltip content.

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
