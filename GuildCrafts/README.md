# GuildCrafts

A World of Warcraft Classic addon that tracks **all learned recipes** across guild members' professions. Open a profession window, and the addon scans and stores every recipe — then syncs it across the entire guild automatically.

Supports multiple Classic versions via multi-TOC:

| Client | Interface | TOC file |
|---|---|---|
| Classic Era | 11507 | `GuildCrafts_Vanilla.toc` |
| TBC Anniversary | 20506 | `GuildCrafts.toc` |
| WotLK Classic | 30403 | `GuildCrafts_Wrath.toc` |
| Cata Classic | 40402 | `GuildCrafts_Cata.toc` |
| MoP Classic | 50504 | `GuildCrafts_Mists.toc` |

## Features

- **Automatic recipe scanning** — hooks into the profession window to capture every recipe you know (supports both legacy `GetTradeSkillInfo` and modern `C_TradeSkillUI` APIs)
- **Guild-wide sync** — OSPF/EIGRP-inspired protocol with Designated Router (DR) election prevents channel flooding
- **Bidirectional sync** — login sync detects and resolves data gaps in both directions
- **Chunked sync with RESUME recovery** — large payloads are split into batches; dropped chunks are automatically re-requested
- **Live search** — find any recipe, profession, or crafter instantly; empty results show an actionable hint including the `!gc` chat command
- **Tooltip integration** — hover over any item in bags, AH, or chat links to see which guild members can craft it
- **Reagent tracking** — see required materials for every recipe at a glance; click any recipe row to expand its reagent list
- **Quality colors** — recipe names are tinted by item rarity using WoW's item quality data
- **Members / Recipes view toggle** — browse per-member recipe lists or an aggregated view showing every recipe the guild can craft
- **Expansion filter** — toggle buttons (Vanilla / TBC / WotLK / Cata / MoP) in the search bar narrow recipes by expansion; only buttons relevant to the current client are shown
- **Specialisation tracking** — detects and displays TBC profession specs (Transmute Master, Weaponsmith, etc.)
- **Cooldown tracking** — shows active profession cooldowns with time remaining
- **Favorites / Bookmarks** — star any recipe or member for quick access
- **Minimap button** — toggle with `/gc minimap`; drag to reposition
- **Whisper a crafter** — `[W]` button opens a whisper to the crafter (or shows a picker for multiple)
- **Post crafters to guild chat** — `[G]` button posts the crafter list to guild chat with a 30-second cooldown
- **`!gc <query>` chat command** — any guild member can type `!gc <recipe>` in guild chat for a crafter list reply; DR responds immediately, BDR after 5 s, others after 12 s
- **Delta broadcasts** — learning a new recipe immediately notifies all online addon users
- **Sync pause policy** — suspends outgoing sync during combat, instances, and zone transitions

## Tracked Professions

**Crafting:** Alchemy · Blacksmithing · Enchanting · Engineering · Inscription · Jewelcrafting · Leatherworking · Tailoring

**Secondary:** Mining (incl. Smelting) · Cooking

**Gathering (skill level only):** Herbalism · Skinning

Inscription requires WotLK+ (expansion level ≥ 2). Jewelcrafting requires TBC+ (expansion level ≥ 1).

## Installation

1. Download or clone this repository
2. Copy the `GuildCrafts/` folder into your WoW `Interface/AddOns/` directory
3. Restart WoW or type `/reload`

The WoW client automatically loads the correct TOC file for your game version.

## Slash Commands

| Command | Description |
|---|---|
| `/gc` | Toggle the main GuildCrafts window |
| `/gc debug` | Toggle debug mode (verbose chat output) |
| `/gc dump` | Print local data summary |
| `/gc comms` | Print addon user list, DR/BDR roles, sync status |
| `/gc mem` | Print addon memory usage |
| `/gc minimap` | Toggle minimap button visibility |
| `/gc reset` | Wipe all saved data and reload |

## How It Works

1. **Open any profession window** — the addon scans all recipes and stores them locally
2. **On login** — broadcasts `HELLO` to discover other addon users, then syncs
3. **Designated Router (DR)** — the lexicographically first addon user handles sync requests. Backup DR (BDR) takes over if the DR is unresponsive or instanced
4. **Delta updates** — new recipes broadcast immediately; lightweight `DELTA_AD` advertisements trigger targeted pulls from peers who are behind
5. **Term-numbered authority** — monotone term counter prevents split-brain; stale messages are silently dropped

## Folder Structure

```
GuildCrafts/
  Core.lua              -- Addon bootstrap, events, slash commands
  Modules/
    Data.lua            -- SavedVariables, scanning, merging, pruning
    Comms.lua           -- Sync protocol, DR/BDR election, messaging
    SyncPausePolicy.lua -- Combat/instance/zone pause logic
    Favorites.lua       -- Bookmark system
    Tooltip.lua         -- Item tooltip injection
    MinimapButton.lua   -- LDB minimap icon
  Data/
    Data_TBC.lua        -- TBC recipe keys (static)
    Data_WOTLK.lua      -- WotLK recipe keys (static)
    Data_CATA.lua       -- Cata recipe keys (static)
    Data_MOP.lua        -- MoP recipe keys (static)
  UI/
    MainFrame.lua       -- All UI panels
  Libs/                 -- Embedded libraries (Ace3, LibDeflate, etc.)
```

## Requirements

- World of Warcraft Classic (any supported version above)
- Must be in a guild

## Libraries Used

- Ace3 (AceAddon, AceComm, AceSerializer, AceDB, AceConsole, AceEvent, AceTimer)
- ChatThrottleLib
- LibDeflate
- LibDBIcon / LibDataBroker

All libraries are embedded — no external dependencies needed.

## Known Limitations

- Recipe scanning requires the profession window to be open
- Enchanting recipes use negative spellID keys (since they don't produce items)
- Each character is tracked independently (no alt-linking)

## Development

Built with AI-assisted development using a spec-driven approach. See [spec/](../spec/) for the design documents.
