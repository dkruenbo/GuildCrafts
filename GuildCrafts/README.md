# GuildCrafts

A World of Warcraft TBC Anniversary addon that tracks **all learned recipes** across guild members' professions. Open a profession window, and the addon scans and stores every recipe — then syncs it across the entire guild automatically.

## Features

- **Automatic recipe scanning** — hooks into the profession window to capture every recipe you know
- **Guild-wide sync** — OSPF/EIGRP-inspired protocol with Designated Router (DR) election prevents channel flooding
- **Bidirectional sync** — login sync detects and resolves data gaps in both directions
- **Live search** — find any recipe, profession, or crafter instantly
- **Craft requests** — request crafts from online guild members directly through the UI
- **Craft queue** — crafters can manage incoming requests with accept/decline/complete workflow
- **Tooltip integration** — hover over any item in bags, AH, or chat links to see which guild members can craft it
- **Reagent tracking** — see required materials for every recipe at a glance; click any recipe row to expand or collapse its reagent list
- **Quality colors** — recipe names are tinted by item rarity (grey/white/green/blue/purple/orange) using WoW's item quality data; Enchanting spells default to white
- **Dark professional sidebar** — profession and member rows use a polished dark style with a gold accent bar on the selected row and a blue hover highlight
- **Members / Recipes view toggle** — when browsing a profession, switch between the existing per-member recipe list and an aggregated view showing every recipe the guild can craft, with an inline crafter preview and hover tooltip
- **Recipe-centric view** — aggregated view shows all guild recipes for a profession sorted alphabetically; each row shows up to two crafter names with a `+N more` indicator and full crafter list on hover
- **Specialisation tracking** — detects and displays TBC profession specs (Transmute Master, Weaponsmith, Mooncloth Tailoring, etc.)
- **Cooldown tracking** — shows active profession cooldowns (Transmutes, Primal Mooncloth, Spellcloth, Shadowcloth) with time remaining
- **Skill level display** — see each member's current profession skill level (e.g. "375/375") in the member list and recipe detail view
- **Recipe categorization** — recipes are grouped by sub-type (Potions, Elixirs, Flasks, Weapons, Armor, etc.) with visual category headers
- **Favorites / Bookmarks** — star any recipe or member; dedicated Favorites tab with profession filter and quick access to your most-used crafters
- **Minimap button** — small icon on the minimap to toggle the window; drag to reposition, hide with `/gc minimap`
- **Profession icons** — WoW's built-in profession icons displayed next to each profession name in the browse panel
- **Chunked sync** — large sync payloads are split into batches of 10 members, preventing chat throttle issues in large guilds
- **Data staleness indicator** — member data older than 30 days is flagged with a red age tag (e.g. "30d ago", "2mo ago")
- **Profession change detection** — dropping a profession automatically purges stale data
- **Guild roster pruning** — ex-guild members are cleaned up automatically
- **Post crafters to guild chat** — every recipe row in the Recipe-centric and Search Results views has a `[>]` button that posts the crafter list for that recipe to guild chat, so members without the addon can see who to ask; a 30-second per-recipe cooldown prevents accidental spam
- **`!gc <query>` chat command** — any guild member can type `!gc <recipe name>` (or shift-click an item) in guild chat to get a crafter list reply without opening the addon; partial and fuzzy (vowel-tolerant) matching supported; DR responds immediately, BDR after 5 s, any other addon user after 12 s if no response appeared yet

## Tracked Professions

Alchemy · Blacksmithing · Enchanting · Engineering · Jewelcrafting · Leatherworking · Tailoring

## Installation

1. Download or clone this repository
2. Copy the `GuildCrafts/` folder into your WoW `Interface/AddOns/` directory
3. Restart WoW or type `/reload`

## Slash Commands

| Command | Description |
|---|---|
| `/gc` | Toggle the main GuildCrafts window |
| `/gc debug` | Toggle debug mode (verbose chat output) |
| `/gc dump` | Print local data summary |
| `/gc comms` | Print addon user list, DR/BDR roles, sync status |
| `/gc mem` | Print addon memory usage |
| `/gc sim <N>` | Inject N simulated guild members (debug mode only) |
| `/gc sim clear` | Remove all simulated data |
| `/gc sim sync` | Simulate a full sync response |
| `/gc sim delta` | Simulate an incoming recipe update |
| `/gc sim craft` | Simulate an incoming craft request |
| `/gc minimap` | Toggle minimap button visibility |
| `/gc reset` | Wipe all saved data and reload |

## How It Works

1. **Open any profession window** — the addon scans all recipes and stores them locally
2. **On login** — the addon broadcasts a `HELLO` to discover other addon users, then performs a sync. A second `discover` HELLO is sent ~15 s after sync completes so nodes whose first reply was throttled are still found
3. **Designated Router (DR)** — the addon user with the lexicographically lowest character name handles sync requests, preventing channel flooding in large guilds
4. **Delta updates** — learning a new recipe immediately broadcasts it to all online addon users
5. **Browse & search** — use the two-panel UI to browse by profession → member → recipes, or search globally
6. **Sync dot** — the top-right indicator shows green (synced), yellow (syncing), or red (alone). Hover to see the DR name and count of online addon users confirmed by the guild roster

## Requirements

- World of Warcraft: The Burning Crusade Anniversary (Classic TBC, Interface 20505)
- Must be in a guild

## Libraries Used

- Ace3 (AceAddon, AceComm, AceSerializer, AceDB, AceConsole, AceEvent, AceTimer)
- ChatThrottleLib
- LibDeflate

All libraries are embedded — no external dependencies needed.

## Known Limitations

- Recipe scanning requires the profession window to be open; cached data is used until then
- Enchanting recipes use spellID keys (since they don't produce items)
- Each character is tracked independently (no alt-linking)

## Development

Built with AI-assisted development using a spec-driven approach. See [spec/](../spec/) for the design documents.
