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
- **Reagent tracking** — see required materials for every recipe at a glance in the recipe detail view
- **Specialisation tracking** — detects and displays TBC profession specs (Transmute Master, Weaponsmith, Mooncloth Tailoring, etc.)
- **Cooldown tracking** — shows active profession cooldowns (Transmutes, Primal Mooncloth, Spellcloth, Shadowcloth) with time remaining
- **Profession change detection** — dropping a profession automatically purges stale data
- **Guild roster pruning** — ex-guild members are cleaned up automatically

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
| `/gc reset` | Wipe all saved data and reload |

## How It Works

1. **Open any profession window** — the addon scans all recipes and stores them locally
2. **On login** — the addon broadcasts a `HELLO` to discover other addon users, then performs a sync
3. **Designated Router (DR)** — the addon user with the lexicographically lowest character name handles sync requests, preventing channel flooding in large guilds
4. **Delta updates** — learning a new recipe immediately broadcasts it to all online addon users
5. **Browse & search** — use the two-panel UI to browse by profession → member → recipes, or search globally

## Requirements

- World of Warcraft: The Burning Crusade Anniversary (Classic TBC, Interface 20504)
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
