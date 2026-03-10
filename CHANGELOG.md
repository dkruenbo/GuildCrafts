# Changelog

## 1.1.8 — Recipe Hover Tooltips — 2026-03-10

### New Features

- **Hover a recipe name to see its tooltip** — hovering the recipe name in Search results, Recipes view, member detail, or Favorites shows the native WoW item or spell tooltip. Enchanting recipes (spell-based) show the spell tooltip; all other professions show the item tooltip

### Fixes

- Tooltip hit zone is scoped to the recipe name only — hovering the crafter list, expand icon, or post button no longer triggers the item tooltip
- Fixed potential tooltip flicker when moving the cursor between the recipe name and the rest of the row

---

## 1.1.7a — Guild Chat Fixes — 2026-03-08

### Fixes

- Fixed responses occasionally posting twice in quick succession
- Fixed guild chat messages being cut off mid-name
- Fixed typo searches matching too many unrelated recipes
- Fixed multiple addon users all responding at the same time when the primary responder was offline
- Crafter list in `!gc` replies is now limited to 2 names + "+X more" to keep messages short

---

## 1.1.7 — Guild Chat Integration — 2026-03-08

### New Features

- **`!gc <recipe>` in guild chat** — type `!gc shadowcloth` and the addon posts matching crafters right in guild chat. No addon needed to ask, anyone can use it
- **Post crafters button** — every recipe row now has a small `[>]` button to share that recipe's crafters to guild chat with one click

### Improvements

- Fuzzy search so typos still find the right recipe (e.g. "shadwcloth" → Shadowcloth)
- Shift-clicking an item into `!gc` works correctly
- 30-second cooldown per recipe/query to prevent accidental spam

---

## 1.1.6 — Multi-Language Support — 2026-03-07

### New Features

- **Mixed-language guilds now work** — French, German, English and other client languages all see recipes in their own language, regardless of what language the crafter scanned them in
- Recipe search, tooltips, and favorites all show correctly localised names

---

## 1.1.5b — Stability Fixes — 2026-03-03

### Fixes

- Fixed guild members appearing twice in the member list
- Fixed recipes being lost when two entries for the same character existed
- Fixed the addon user count showing too low on login or too high over time
- Reduced chat noise when many addon users log in at the same time

---

## 1.1.5a — 2026-03-03

### Fixes

- Fixed hunter pet abilities (Claw, Dash, Dive, etc.) showing up as Enchanting recipes for hunters

---

## 1.1.5 — UI Overhaul — 2026-03-01

### New Features

- **Recipe quality colors** — recipe names are colored by rarity (grey/white/green/blue/purple/orange) so rare recipes stand out
- **Collapsible reagent rows** — click any recipe to expand its material list; collapsed by default for a clean view
- **"Recipes" view** — new toggle to switch between a per-member recipe list and an aggregated "who can craft this?" view per profession
- **Polished sidebar** — dark rows with a gold accent bar on the selected profession and a blue hover highlight

### Fixes

- Fixed the "Select a profession" message overlapping recipe content in various situations
- Fixed crafters showing twice in search results
- Fixed recipes always showing `~` (missing reagents) in the Recipe view
- Fixed quality colors not loading until the window was reopened
- Fixed expand/collapse icons showing as rectangles on some clients

---

## 1.1.0 — Favorites — 2026-02-27

### New Features

- **Favorites** — star recipes and crafters for quick access. New Favorites tab with Members and Recipes sub-tabs

### Improvements

- Members who leave the guild are automatically removed after 30 days
- Reduced SavedVariables size by deduplicating shared recipe data

### Fixes

- Fixed star icons showing as rectangles
- Fixed empty state messages overlapping in the Favorites tab

---

## 1.0.4 — 2026-02-26

### Fixes

- Fixed characters in multiple guilds on the same account sharing (and corrupting) each other's data

---

## 1.0.3 — 2026-02-25

### Fixes

- Fixed missing reagents on some recipes when the game hadn't fully loaded the item data yet (e.g. Enchant Gloves - Spell Strike)

---

## 1.0.2 — 2026-02-23

### Fixes

- Removed noisy role-change messages from chat (debug only now)
- Fixed `/gc minimap` toggle not working

---

## 1.0.1 — 2026-02-23

### Fixes

- Fixed new members showing as "683 months old"
- Fixed peers not discovering each other correctly on login
- Fixed scroll panels cutting off the last entry
- Fixed minimap button position on square minimap addons (Titan Panel, SexyMap)
- Fixed reagents missing from synced recipe data
- Fixed craft request popups appearing during combat
- Fixed sync getting stuck when already up to date
- Various search and navigation display fixes

---

## 1.0.0 — 2026-02-22

- Initial release
