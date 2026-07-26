# GuildCrafts Protocol — RFC 0004

**Status:** Informational  
**Applies to:** GuildCrafts v1.0.0+

---

## Table of Contents

1. [Overview](#1-overview)
2. [Frame Hierarchy](#2-frame-hierarchy)
3. [Layout & Dimensions](#3-layout--dimensions)
4. [View Modes](#4-view-modes)
5. [Left Panel](#5-left-panel)
   - 5.1 [Profession List (default)](#51-profession-list-default)
   - 5.2 [Member List](#52-member-list)
   - 5.3 [Row Pooling](#53-row-pooling)
6. [Detail Panel](#6-detail-panel)
   - 6.1 [Welcome / Empty States](#61-welcome--empty-states)
   - 6.2 [Member Recipe View](#62-member-recipe-view)
   - 6.3 [Search Results](#63-search-results)
   - 6.4 [Favorites Tab](#64-favorites-tab)
   - 6.5 [Recipes View](#65-recipes-view)
7. [Bottom Bar](#7-bottom-bar)
8. [Sync Indicator](#8-sync-indicator)
9. [Tooltip Integration](#9-tooltip-integration)
10. [Minimap Button](#10-minimap-button)
11. [Shift-Click to Link](#11-shift-click-to-link)
12. [Quality Colors](#12-quality-colors)
13. [Key Public Methods](#13-key-public-methods)

---

## 1. Overview

The entire GuildCrafts UI lives in a single file: `UI/MainFrame.lua`. There
are no AceGUI containers or frame XML files — every frame is created
programmatically. The `UI` namespace is attached to `GuildCrafts.UI` and
shares the global `GuildCrafts` object for access to `Data` and `Comms`.

---

## 2. Frame Hierarchy

```
GuildCraftsMainFrame  (UIParent child, "Frame")
├── TitleBar          (Button — drag handle)
│   ├── TitleText     (FontString)
│   ├── SyncIndicator (FontString — coloured dot)
│   └── CloseButton   (Button "×")
│
├── LeftPanel         (Frame — profession/member list)
│   ├── ScrollFrame + ScrollChild
│   │   └── [rows]  (pooled Button + FontString pairs)
│   └── Separators   (pooled FontString labels)
│
├── Divider           (Texture — vertical line)
│
├── DetailPanel       (Frame — main content area)
│   ├── ScrollFrame + ScrollChild
│   │   └── [content rows]  (recipe rows, search results, etc.)
│   └── PostButton / WhisperButton / StarButton (context-dependent)
│
├── BottomBar         (Frame)
│   ├── SearchBox     (EditBox — /gc search shortcut)
│   ├── ViewToggle    (Button — list ↔ recipes view)
│   ├── FavoritesTab  (Button — ★)
│   ├── OnlineFilter  (Button — filter online-only)
│   ├── MinimapToggle (Button)
│   ├── TooltipToggle (Button)
│   └── ExpansionButtons (ORIG / TBC filter)
│
└── ResizeGrip        (Button — bottom-right corner drag)
```

---

## 3. Layout & Dimensions

| Constant | Value | Description |
|----------|-------|-------------|
| `DEFAULT_WIDTH` | 820 | Initial frame width in pixels. |
| `DEFAULT_HEIGHT` | 540 | Initial frame height in pixels. |
| `MIN_WIDTH` | 560 | Minimum resizable width. |
| `MIN_HEIGHT` | 380 | Minimum resizable height. |
| `LEFT_PANEL_WIDTH` | 240 | Fixed width of the left column. |

The frame is movable (drag the title bar), resizable (drag the bottom-right
grip), and clamped to screen. The detail panel fills the remaining space to
the right of the divider. `UI:OnResize()` is called after each resize drag
to reflow the layout.

---

## 4. View Modes

The UI has three top-level modes managed by `UI:SetViewMode(mode)`:

| Mode | Description |
|------|-------------|
| `"list"` | Default. Left panel shows profession list; detail panel shows member list for the selected profession, or recipe detail for the selected member. |
| `"recipes"` | Left panel shows profession list; detail panel shows all guild crafters for a recipe keyed by recipeKey. Switched via the view-toggle button. |
| `"search"` | Left panel is hidden; detail panel shows full-width search results. Active when text is entered in the search box. |

The current mode is stored in `UI._viewMode`. The favorites tab is a
sub-mode overlaid on top of any main mode; `UI._favoritesOpen` tracks its
visibility.

---

## 5. Left Panel

### 5.1 Profession List (default)

Populated by `UI:PopulateProfessionList()`. Each tracked profession appears
as a clickable row. Clicking a profession row calls
`UI:NavigateToMembers(profName)`, which switches the detail panel to the
member list for that profession.

Professions with at least one guild crafter appear with a count badge. A
separator is drawn between "crafting" and "gathering" professions.

### 5.2 Member List

After `NavigateToMembers`, the left panel is repopulated with guild members
who know at least one recipe in the selected profession. Each row shows:
- Coloured online indicator dot (green = online + addon; yellow = online; grey = offline)
- Character name (realm stripped for readability)
- Recipe count badge

Clicking a member row calls `UI:ShowMemberRecipes(memberKey, profName)`.

A **Back** row appears at the top to return to the profession list via
`UI:NavigateBack()`.

### 5.3 Row Pooling

To avoid allocating and destroying frames on every navigation, left-panel
rows and separators use two pools:

```lua
UI._leftRowPool       = {}  -- recycled Button frames
UI._leftSeparatorPool = {}  -- recycled FontString frames
```

`UI:ClearLeftRows()` returns all active rows to their pool and hides them.
`UI:CreateLeftRow()` pops from the pool (or creates a new frame if empty).
This pattern prevents frame-count growth on guilds with many members or
frequent navigation.

---

## 6. Detail Panel

### 6.1 Welcome / Empty States

`UI:UpdateDetailWelcome()` — shown when no profession is selected. Displays
a brief usage hint.

`UI:ShowDetailEmpty()` — shown when the selected member has no recipes for
the current profession.

`UI:ShowGatheringMemberDetail()` — shown for gathering professions (Mining,
Herbalism, Skinning) which have no scannable recipes.

### 6.2 Member Recipe View

`UI:ShowMemberRecipes(memberKey, profName)` renders the recipe list for a
single member × profession combination. Each recipe row shows:
- Recipe name (via `Data:GetLocalizedRecipeName`, with quality colour coding)
- Expansion tag (TBC / ORIG) when the expansion filter is active
- Cooldown indicator when applicable
- Star button to toggle the recipe as a favorite
- `nameHit` invisible button covering the name for shift-click-to-link

A **Post** button at the bottom posts the crafter list to guild chat.
A **Whisper** button opens a target picker for whispering a specific crafter.

### 6.3 Search Results

`UI:OnSearch(text)` fires as the player types in the search box (EditBox
`OnEditFocusGained` / `OnTextChanged`). Two search strategies run:
- `FilterProfessionList`: hides profession rows that have no match.
- `FilterMemberList`: within a profession, hides member rows with no match.

`UI:ShowSearchResults(results)` renders full-width search results when the
search term is long enough (≥2 characters). Each result row shows profession,
member name, and recipe name.

Search exits when the EditBox loses focus or is cleared.

### 6.4 Favorites Tab

`UI:ShowFavoritesTab()` switches the detail panel to the favorites view.
Two sub-sections are rendered: **Favorite members** and **Favorite recipes**.

- Favorite members: `UI:PopulateFavMembers()` — lists members the player has
  starred, with online dot and recipe count.
- Favorite recipes: `UI:PopulateFavRecipes()` — lists starred recipes with
  crafter names grouped by profession. Click a recipe to open
  `UI:ShowFavRecipesDetail(grouped, filterProf)`.

### 6.5 Recipes View

`UI:ShowRecipesView(profName)` renders a list of all known recipes for a
profession, grouped by category (from `RecipeDB`). For each recipe, the
known crafters are listed inline.

A `nameHit` button on each recipe row supports shift-click-to-link.

---

## 7. Bottom Bar

The bottom bar spans the full width below both panels. It holds:

| Control | Action |
|---------|--------|
| SearchBox | Triggers search on text change |
| ViewToggle (⊞ / ☰) | Switches between `"list"` and `"recipes"` modes |
| FavoritesTab (★) | Opens/closes the favorites panel |
| OnlineFilter | Toggles `showOnlineOnly` — filters member list to online members |
| MinimapToggle | Shows/hides the minimap button |
| TooltipToggle | Toggles `showTooltipCrafters` |
| ORIG / TBC buttons | Toggles the expansion filter for `"ORIG"` and `"TBC"` recipe tags |

Toggle button visuals are updated by `UI:_UpdateViewToggleVisuals()`,
`UI:_UpdateOnlineBtnVisuals()`, etc. — each reads the current preference from
`GuildCrafts.db.profile` or `Comms` state and applies the appropriate colour.

---

## 8. Sync Indicator

`UI:UpdateSyncIndicator()` updates a coloured dot in the title bar based on
`Comms:GetSyncStatus()`:

| Status | Colour | Meaning |
|--------|--------|---------|
| `"synced"` | Green | Sync complete and ≥2 addon users online. |
| `"syncing"` | Yellow | SYNC\_REQUEST in flight. |
| `"disconnected"` | Red | Only the local player is known (no peers). |

The indicator is also updated on HELLO receipt, HEARTBEAT receipt, and
GUILD\_ROSTER\_UPDATE to keep it current without polling.

An `OnEnter` tooltip on the dot shows the active addon user count and the
most recent sync time (formatted as a human-readable age by `FormatAge`).

---

## 9. Tooltip Integration

`GuildCrafts/Tooltip.lua` hooks the game tooltip to show guild crafters when
the player hovers over an item. The hook strategy depends on the client
version:

| Client | Strategy |
|--------|----------|
| TBC 2.5.6+ / Classic Era 1.15.9+ | `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, handler)` |
| TBC 2.5.5 and earlier | `SecureHookScript(GameTooltip, "OnTooltipSetItem", handler)` and `SecureHookScript(ItemRefTooltip, …)` |

The detection is a runtime `if TooltipDataProcessor then` guard in
`Tooltip:OnEnable()`. Both paths call the same `OnTooltipSetItem` handler
which uses `tooltip:GetItem()` to extract the item name/link and looks up
crafters in the guild DB.

The crafter list is added as tooltip lines only when `showTooltipCrafters` is
enabled (profile preference). Online crafters are listed first.

`Tooltip:InvalidateIndex()` is called by `Data:MergeIncoming` and
`Data:MergeDelta` to clear any cached crafter index so stale data is not shown.

---

## 10. Minimap Button

`MinimapButton.lua` registers a LibDataBroker-1.1 launcher object and
passes it to LibDBIcon-1.0. This makes the button compatible with minimap
managers (Leatrix Plus, SexyMap, etc.).

- Left-click: `UI:Toggle()` — shows or hides the main frame.
- Button position and visibility are stored at `db.global.minimap` (shared
  across all profiles and characters).
- `MinimapButton:Toggle(silent)` — programmatically shows/hides the button
  and updates `db.global.minimap.hide`.

---

## 11. Shift-Click to Link

`UI:LinkRecipeToChat(recipeKey)` inserts a recipe's item or spell link into
the active chat input box via `ChatEdit_InsertLink`.

- **Items** (`recipeKey > 0`): `select(2, GetItemInfo(recipeKey))` returns
  the item link.
- **Enchants** (`recipeKey < 0`): `C_Spell.GetSpellLink(-recipeKey)` with
  fallback to `GetSpellLink(-recipeKey)` for older clients.

An invisible `nameHit` button overlays each recipe name in the following views:
- Member recipe detail (`ShowMemberRecipes`)
- Search results (`ShowSearchResults`)
- Favorites recipe detail (`ShowFavRecipesDetail`)
- Recipes view (`ShowRecipesView`)

Each `nameHit` has an `OnMouseDown` handler:

```lua
nameHit:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and IsShiftKeyDown() then
        UI:LinkRecipeToChat(capturedKey)
    end
end)
```

The captured key variable is a local closure per row; its name varies by view
(`capturedKey`, `capturedRecipeKey`, `capturedNameKey`) but the behaviour is
identical across all four sites.

---

## 12. Quality Colors

Recipe names are coloured by item quality using the standard Blizzard colour
codes. A local cache (`_qualityCache`) maps `recipeKey → quality integer` to
avoid repeated `GetItemInfo` calls per render.

```lua
QUALITY_COLORS = {
    [0] = "|cff9d9d9d",  -- Poor (grey)
    [1] = "|cffffffff",  -- Common (white)
    [2] = "|cff1eff00",  -- Uncommon (green)
    [3] = "|cff0070dd",  -- Rare (blue)
    [4] = "|cffa335ee",  -- Epic (purple)
    [5] = "|cffff8000",  -- Legendary (orange)
}
```

`UI:GetRecipeQualityColor(recipeKey)` returns the colour code string, or the
Common colour as a fallback. The quality cache is invalidated (cleared)
indirectly by `UI:Refresh()` which rebuilds the frame from scratch.

`GET_ITEM_INFO_RECEIVED` triggers a debounced `UI:Refresh()` (0.5 s) so
quality colours update once item data arrives from the server cache.

---

## 13. Key Public Methods

| Method | Description |
|--------|-------------|
| `UI:Toggle()` | Show or hide the main frame. Creates it on first call. |
| `UI:Refresh()` | Re-render the current view from the DB (called after sync, item info, etc.). |
| `UI:UpdateSyncIndicator()` | Update the title-bar dot without a full re-render. |
| `UI:NavigateToMembers(profName)` | Switch left panel to the member list for a profession. |
| `UI:NavigateBack()` | Return to the profession list. |
| `UI:ShowMemberRecipes(memberKey, profName)` | Render recipe detail for a member. |
| `UI:ShowSearchResults(results)` | Render full-width search results. |
| `UI:ShowFavoritesTab()` | Open the favorites panel. |
| `UI:ShowRecipesView(profName)` | Render the per-recipe crafter view. |
| `UI:LinkRecipeToChat(recipeKey)` | Insert a recipe link into the chat input box. |
| `UI:SetViewMode(mode)` | Switch between `"list"`, `"recipes"`, and `"search"` modes. |
