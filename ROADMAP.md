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

---

## Upcoming

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

### Specialisation description tooltip on member rows

> **What it is:** When a member row displays a specialisation tag such as `[Armorsmith]` or `[Transmutation Master]`, hovering anywhere on that row shows a `GameTooltip` with a plain-English explanation of what the specialisation unlocks. Currently the tag is rendered inline and colour-coded but provides no further context — a player who doesn't know what "Dragonscale Leatherworking" entails has no way to find out in-context.

**Why now:** The specialisation label is already detected at login via `DetectSpecialisations()` in `Data.lua` and stored in `profData.specialisation`. The `SPECIALISATION_SPELLS` table has the canonical label per spellID; it just lacks a `description` string. No protocol changes, no new data collection — this is a two-file change with high UX value per line written.

**Implementation:**

1. **Add descriptions to `SPECIALISATION_SPELLS`** — Extend each entry in the table in `Data.lua` with a `description` string:
   ```lua
   [28672] = { prof = "Alchemy", spec = "Transmutation Master",
               description = "Chance to create additional items when performing transmutations." },
   [9788]  = { prof = "Blacksmithing", spec = "Armorsmith",
               description = "Unlocks the ability to craft high-end plate armour sets." },
   -- etc. for all entries
   ```

2. **Add accessor** — Add `Data:GetSpecialisationDescription(spec)` that iterates `SPECIALISATION_SPELLS` values and returns the `description` for a matching `spec` label (`nil` if not found).

3. **Wire tooltip onto member rows** — In the member profession view in `MainFrame.lua`, where rows with a specialisation tag are rendered, add `OnEnter` / `OnLeave` scripts. The tooltip title reuses the existing light-blue colour (`|cffaaddff` → RGB `0.67, 0.87, 1`) to match the inline tag:
   ```lua
   row:SetScript("OnEnter", function(self)
       if profData and profData.specialisation then
           local desc = GuildCrafts.Data:GetSpecialisationDescription(profData.specialisation)
           if desc then
               GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
               GameTooltip:AddLine(profData.specialisation, 0.67, 0.87, 1)
               GameTooltip:AddLine(desc, 1, 1, 1, true)
               GameTooltip:Show()
           end
       end
   end)
   row:SetScript("OnLeave", function() GameTooltip:Hide() end)
   ```

4. **Scope** — Only add the tooltip on rows that actually have a `specialisation` set. Rows for members without a spec, or rows in the Favorites or Search views where spec context is absent, get no `OnEnter` script and remain unchanged.

**Files:** `Data.lua` (~25 lines — description strings + accessor), `UI/MainFrame.lua` (~15 lines — `OnEnter`/`OnLeave` on member rows).

---

> **Exit criterion:** After 1.2.1, GuildCrafts is considered feature-complete for its core browsing and coordination use case. 1.2.2 below adds one further user-facing feature before the project is considered stable.

---

## 1.2.2 — Expansion Filter

**Theme:** Let players narrow the recipe browser to Original Classic or The Burning Crusade recipes. Guilds actively progressing through TBC content frequently want to see only TBC-era profession recipes; players focused on original-content crafting (Arcanite transmutes, Classic raid gear sets, etc.) want the reverse. The filter is purely a display layer — it requires one new data file and a small UI control, with zero changes to the sync protocol, merge logic, or database schema.

---

### [#49] Recipe expansion filter (Classic / TBC)

> **What it is:** A pair of toggle buttons in the main window header — `[Classic]` and `[TBC]` — that limit the displayed recipe list to Original Classic recipes, TBC recipes, or both. Each recipe's expansion is resolved at render time using a per-profession spell-ID threshold: any recipe whose spell ID is greater than or equal to the profession's threshold is TBC; lower is Classic. No new file is needed.

**Why now:** As guilds move deeper into TBC, profession windows fill with a mix of original and expansion recipes. Finding a specific TBC crafted item becomes slower as the lists grow. The feature is additive and non-breaking — old clients show all recipes exactly as today, and the new client defaults both toggles to on, so first-run behaviour is identical to the current state.

**Implementation:**

1. **Inline threshold table in `Data.lua`** — Add a single 7-entry table alongside the existing profession constants:
   ```lua
   GuildCrafts.TBC_THRESHOLD = {
       ["Alchemy"]        = 28543,  -- Elixir of Camouflage
       ["Blacksmithing"]  = 29545,  -- Fel Iron Plate Gloves
       ["Cooking"]        = 28267,  -- Crunchy Spider Surprise
       ["Enchanting"]     = 27899,  -- Enchant Bracer - Brawn
       ["Engineering"]    = 30303,  -- Elemental Blasting Powder
       ["Leatherworking"] = 32454,  -- Knothide Leather
       ["Tailoring"]      = 26745,  -- Bolt of Netherweave
       -- Jewelcrafting: TBC-only profession, no threshold (all recipes are TBC)
   }
   ```
   Each value is the spell ID of the first TBC recipe learned by the profession. Thresholds were verified against WoWHead's Classic TBC spell database. No new file, no `.toc` change.

2. **Tag resolution helper** — Add a small helper (also in `Data.lua`):
   ```lua
   function GuildCrafts:GetExpansionTag(profName, spellID)
       if profName == "Jewelcrafting" then return "TBC" end
       local threshold = GuildCrafts.TBC_THRESHOLD[profName]
       if not threshold then return nil end  -- unknown prof: always show
       return spellID >= threshold and "TBC" or "ORIG"
   end
   ```

3. **Persist filter state** — Add to the `AceDB` `global` defaults in `Data.lua`:
   ```lua
   expansionFilter = { ORIG = true, TBC = true },
   ```
   Both on by default (show all). Stored in `global` scope, not per-character — expansion preference is a guild-browsing setting, not alt-specific.

4. **UI control** — In `MainFrame.lua`, add two small toggle buttons in the header bar alongside the existing search box and view toggle:
   - `[Classic]` — toggles `expansionFilter.ORIG`
   - `[TBC]` — toggles `expansionFilter.TBC`

   Style them with the existing active/inactive visual pattern (highlighted border or background when active). If the user toggles both off, re-enable both automatically — an empty filter set would hide all recipes and is not a useful state.

5. **Filter at render time** — In every recipe-list rendering loop (`ShowRecipesView`, `ShowSearchResults`, `ShowMemberRecipes`), insert a single check before adding each recipe row:
   ```lua
   local tag = GuildCrafts:GetExpansionTag(profName, math.abs(recipeKey))
   if tag then
       local f = GuildCrafts.db.global.expansionFilter
       if not f[tag] then goto continue end
   end
   -- nil tag (unknown prof): always show
   ```
   `math.abs` normalises negative enchantment spell IDs. This is the entirety of the runtime cost — one table lookup per recipe row render.

6. **Optional tooltip label** — Show a dim secondary line in the recipe detail tooltip: `|cff888888Classic|r` or `|cff888888TBC|r`. Skip this if it adds visual noise; the filter buttons already communicate the active state clearly.

**Backward compat:** No wire-format changes. The filter is entirely client-side. Old clients show all recipes unfiltered, which is identical to their current behaviour. New clients default both toggles on, so the out-of-box experience is also unchanged. No new file is added; the threshold table is negligible in size.

**Files:** `Data.lua` (~20 lines — threshold table + tag helper + AceDB default), `UI/MainFrame.lua` (~30 lines — toggle buttons + filter checks in three render loops).

---

> **Exit criterion:** After 1.2.2, GuildCrafts is considered stable. Future work requires either confirmed user demand or an available contributor willing to own it end-to-end.

---

## 1.2.3 — Craft Request Rework

**Theme:** Replace the disruptive popup-based craft request system with a whisper button that delegates conversation to WoW's own chat. The popup system was opt-out, had no rate limiting, and was used for trolling. This release removes the entire addon-protocol request flow and replaces it with a single `[W]` button per recipe row that pre-fills a whisper — keeping the "ask a crafter" workflow intact while eliminating every abuse vector.

---

### [#50] Replace craft request popup with whisper button

> **What it is:** Remove the `CRAFT_REQUEST / CRAFT_ACCEPT / CRAFT_DECLINE / CRAFT_COMPLETE` addon message protocol, the incoming popup, and the craft queue panel. Add a `[W]` button to every recipe row in the Recipes view and Search Results view. Clicking `[W]` pre-fills the WoW chat input with a whisper to the chosen crafter — including a live item link — without sending it, so the player can review and edit before pressing Enter.

**Why now:** The popup fires on the recipient's screen regardless of what they are doing, is stackable by anyone in the guild, and cannot be rate-limited without significant protocol complexity. Delegating to WoW's native whisper means the recipient can use `/ignore`, Blizzard handles spam, and the addon protocol shrinks rather than grows.

**Implementation:**

1. **Remove addon request protocol** — Delete `MSG_CRAFT_REQUEST`, `MSG_CRAFT_ACCEPT`, `MSG_CRAFT_DECLINE`, `MSG_CRAFT_COMPLETE` from `Comms.lua` along with their send and handle functions (`SendCraftRequest`, `SendCraftAccept`, `SendCraftDecline`, `SendCraftComplete`, `HandleCraftRequest`, `HandleCraftAccept`, `HandleCraftDecline`, `HandleCraftComplete`). The `PREFIX` registration and all other message types are unaffected.

2. **Remove `CraftRequest.lua`** — The entire module (`pendingPopups`, `craftQueue`, persistence, popup display, accept/decline/complete logic) is deleted. Remove it from `GuildCrafts.toc` and remove the `GuildCrafts:NewModule("CraftRequest")` call from `Core.lua`.

3. **Remove popup UI and queue panel** — Delete `UI:ShowCraftRequestPopup()`, `UI:RemovePopup()`, `UI:RefreshCraftQueue()`, and the craft queue section from `MainFrame.lua`. Remove `_activePopups` state.

4. **Add `[W]` button factory** — Add `UI:CreateWhisperButton(parent, crafters, recipeName, recipeKey)` in `MainFrame.lua`, styled identically to the existing `CreatePostButton` (same size, same backdrop, same hover highlight). The label is `|cff666666[W]|r`, brightening to `|cffdddddd[W]|r` on hover. Tooltip on hover reads: *"Whisper a crafter"*.

5. **Single crafter path** — If `#crafters == 1` and `crafters[1].key ~= myKey`, clicking `[W]` calls `OpenWhisper(crafters[1], recipeName, recipeKey)` directly, no picker shown.

6. **Self-only path** — If the only crafter is the player themselves, `[W]` does not render.

7. **Multi-crafter picker** — If `#crafters > 1` (excluding self), clicking `[W]` opens a small dropdown frame anchored `BOTTOMRIGHT` of the button. One row per crafter (self excluded), sorted online-first then alphabetical. Each row is a clickable button showing:
   ```
   ● Thrall        (green dot = online, |cff00ff00 ; grey |cff888888 = offline)
   ```
   Clicking a row calls `OpenWhisper(crafter, recipeName, recipeKey)` and closes the picker. Clicking anywhere outside the picker (detected via `OnUpdate` world-click check or a full-screen invisible intercept frame) closes it without action.

8. **`OpenWhisper(crafter, recipeName, recipeKey)` helper** — Constructs the pre-filled message and opens chat:
   ```lua
   local function OpenWhisper(crafter, recipeName, recipeKey)
       local name = crafter.key:match("^(.+)-") or crafter.key
       local link
       if recipeKey > 0 then
           link = select(2, GetItemInfo(recipeKey))  -- item link or nil if uncached
       else
           link = GetSpellLink(-recipeKey)           -- spell link for enchants
       end
       local display = link or recipeName            -- fallback to plain name
       ChatFrame_OpenChat("/w " .. name .. " Can you craft " .. display .. " for me?")
   end
   ```
   `ChatFrame_OpenChat` pre-populates the chat editbox and focuses it without sending. The player edits freely and presses Enter (or Escape to cancel).

9. **Placement** — `[W]` sits immediately to the left of `[>]` on every recipe row in `ShowSearchResults` and the Recipes-centric view (`ShowRecipesView`). The crafter text label anchors its right edge to `[W]`'s left edge, the same way it currently anchors to `[>]`. No layout changes elsewhere.

**Backward compat:** Old clients (v1.2.2 and below) that send `CRAFT_REQUEST` messages to a v1.2.3 client will have them silently ignored — the prefix is still registered, but the handler is gone. No error, no response. Old clients receive no `CRAFT_ACCEPT` or `CRAFT_DECLINE` back, so their pending popup simply times out. Not ideal but acceptable for a transition period; the changelog should advise guilds to update together.

**Files:** `Comms.lua` (~−80 lines), `CraftRequest.lua` (deleted), `Core.lua` (~5 lines — remove module load), `UI/MainFrame.lua` (~+80 lines for `[W]` button + picker, ~−120 lines removing popup/queue panel), `GuildCrafts.toc` (remove `CraftRequest.lua`).

---

> **Exit criterion:** After 1.2.3, GuildCrafts is considered stable. Future work requires either confirmed user demand or an available contributor willing to own it end-to-end.

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
| — | Cooldown panel: dedicated UI panel showing who has what on cooldown and when it expires | Basic cooldown tracking (Mooncloth, Shadowcloth, Spellcloth, Transmutes) is already implemented and visible in the existing UI. This item is a separate, focused panel — a dedicated view listing all guild cooldowns with expiry countdowns. Requires DR to broadcast cooldown state in real time; design needed before implementation. |
