# Changelog

## 1.1.5 — UI Overhaul — 2026-03-01

### Features

- **Dark sidebar style**: Profession and member list rows now use a dark background (0.07 alpha) that deepens on selection (0.12), a gold accent bar on the left edge of the active row, and a blue hover highlight. Consistent with GuildCraft Classic Era UI conventions.

- **Quality colors**: Recipe names are now tinted by item quality — grey (Poor), white (Common), green (Uncommon), blue (Rare), purple (Epic), orange (Legendary) — using `GetItemInfo` for item-linked recipes. Enchanting spells (negative recipe keys) default to white. Applies to the recipe detail view, collapsible reagent rows, and search results. Favorite star widgets use a WoW raid-target texture instead of an ASCII asterisk for crisp rendering at any size.

- **Collapsible reagent rows**: Recipe rows in the member recipe view and Recipe-centric view now show a `+` expand indicator when reagents are available. Clicking the row toggles a vertical reagent list below it. All rows default to collapsed. Expansion state is preserved within the session. Recipes whose reagent data has not yet synced show a `~` placeholder with a tooltip.

- **Recipe-centric profession view**: Selecting a profession while in Recipes mode shows an aggregated list of all guild recipes for that profession in the detail panel. Each row displays the quality-colored recipe name on the left and up to two crafter names on the right, with a "+N more" indicator in green when there are additional crafters. Hovering shows a tooltip with the full crafter list and online status. Your own character is indicated with a star icon prefix.

- **Members / Recipes view toggle**: A profession header bar appears at the top of the detail panel whenever a profession is selected, showing its icon and name. Below it, a "Members" / "Recipes" toggle switches the detail panel between the existing per-member recipe list and the new aggregated recipe view. The toggle is hidden on the search, favorites, and top-level profession list screens.

### Bug Fixes

- **Welcome text bleedthrough**: The "Select a profession" welcome message no longer overlaps recipe content. It is now only shown at true root idle state (profession list visible, nothing drilled into, no search active).

- **Detail panel not cleared on back navigation**: Navigating back to the profession list now always clears the right panel before showing the welcome message, preventing old member recipe content or empty-state messages from persisting underneath it.

- **Empty member detail blank**: Members recorded by the addon who have not yet synced any recipes (empty `recipes` table) now correctly show a "No recipes synced yet" message instead of a blank panel.

- **Search crafter duplication**: Crafters were being shown twice in search results — once inline on the right side of each row and again in the expanded dropdown. The redundant crafter list in the expanded section has been removed.

- **All recipes showing `~` in Recipe view**: `GetAllRecipesForProfession` was omitting the `reagents` field from recipe map entries, causing every recipe to appear as if its reagent data had not been synced. Fixed.

- **Member names centered / word-wrapped**: Member rows in the left panel now correctly use left-justified, non-wrapping single-line labels.

- **Favorites welcome bleedthrough**: `ShowFavoritesTab` and `PopulateFavMembers` now explicitly hide the welcome message when the Favorites tab is opened.

- **Quality color cache poisoning**: `GetItemInfo` results are no longer cached when the item cache returns nil (i.e. before the client has loaded the item). A `GET_ITEM_INFO_RECEIVED` listener triggers a one-time panel refresh when outstanding items load in, resolving recipes that appeared white on first open.

- **Expand icons on non-TBC fonts**: Unicode arrow characters (`►`/`▼`) are not present in all TBC client fonts and were rendering as rectangles. Replaced with ASCII `+`/`-`.

## 1.1.0 — 2026-02-27

### Features

- **Favorites/Bookmarks**: Star your favorite recipes and crafters! New Favorites tab with Members and Recipes sub-tabs. Per-character favorites stored in `GuildCraftsCharDB`. Star toggle buttons on member rows, recipe rows, and search results.

### Improvements

- **RecipeDB deduplication**: Reagent and category data is now stored once in a shared lookup table (`_recipeDB`) instead of duplicated per crafter. Reduces SavedVariables size and sync payload preparation overhead. Wire format unchanged — fully backward compatible with 1.0.x clients.
- **Auto-prune stale members**: Members who leave the guild are marked absent and automatically pruned after 30 days. Returning members are restored. Absent members show a "(left guild)" indicator in the UI.

### Bug Fixes

- **Star icon rendering**: Fixed star icons appearing as rectangles. Changed from Unicode characters to ASCII asterisk (*) with proper font styling. Increased font size from 14pt to 18pt for better visibility.
- **Favorites text overlap**: Fixed empty state messages overlapping in Favorites tab by adding word wrap and proper width constraints.
- **Frame script cleanup**: Fixed Lua error when navigating between views caused by attempting to clear OnClick script from Frame widgets (should be OnMouseDown).

### Note

- **CurseForge release**: Initial upload was incorrect (contained 1.0.4 code). Re-uploaded as **1.1.0a** with correct features.

## 1.0.4 — 2026-02-26

### Bug Fixes

- **Per-guild database partitioning**: Characters on the same account but in different guilds no longer share or corrupt each other's member data. Each guild's data is now stored in its own partition under `GuildCraftsDB.global["GuildName-Realm"]`. Existing data is automatically migrated on first login after the update.

### Other

- **Luacheck cleanup**: Resolved all 18 luacheck warnings (unused variables, shadowed locals, dead code). Added `.luacheckrc` config for WoW addon development. 0 warnings / 0 errors.

## 1.0.3 — 2026-02-25

### Bug Fixes

- **Partial reagent scan fix**: Re-scans recipes when stored reagent count is less than expected, fixing cases where item cache misses caused incomplete reagent data (e.g. missing Large Prismatic Shards on Enchant Gloves - Spell Strike)

## 1.0.2 — 2026-02-23

### Other

- DR/BDR role change messages moved to debug only (no longer clutter chat)
- Fixed `/gc minimap` toggle ("MinimapButton module not loaded")

## 1.0.1 — 2026-02-23

### Bug Fixes

- **Staleness display**: New entries with `lastUpdate = 0` no longer show as "683 months old"
- **Self-eviction**: Solo DR no longer evicts itself from the addon user list on sync retry
- **One-way HELLO**: HELLO broadcasts now receive a reply, so peers discover each other correctly
- **Re-sync on discovery**: Newly discovered addon users via HELLO now trigger a re-sync after 2 seconds
- **Scroll clipping**: Added bottom padding to all scrollable panels to prevent the last entry from being cut off
- **Square minimap button**: Minimap button now correctly positions on square minimaps (e.g. Titan Panel, SexyMap)
- **Search welcome bleed-through**: Welcome text no longer shows through search results
- **Search reagents**: Search results now display reagent lists for matching recipes
- **Sync timeout (two root causes)**:
  - DR now sends an empty acknowledgement when already converged, so the requester stops waiting
  - DR no longer tries to sync with itself
- **Refresh welcome bleed-through**: Welcome text no longer reappears when the member list refreshes while viewing a member's recipes
- **Reagents in sync**: Reagent and category data is now included in sync payloads sent to other players
- **Backfill timestamp bump**: Re-scanning a profession now bumps the timestamp when reagent/category data is backfilled onto existing recipes, ensuring the updated data propagates via sync
- **Stale synced copies ("already converged")**: Added a data format version so copies synced before reagents were included get re-pulled automatically
- **Craft request popup dismiss**: Accept/Decline buttons now always dismiss the popup, even if downstream logic errors
- **Craft request combat suppression**: Craft request popups are deferred until combat ends instead of appearing mid-fight
- **Craft request sound removed**: Craft request popups no longer play a sound

### Other

- Login reminder to open each profession window once for scanning
- Removed nested `.git` directory from LibDeflate (caused CurseForge upload rejection)

## 1.0.0 — 2026-02-22

- Initial release
