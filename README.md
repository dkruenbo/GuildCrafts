# GuildCrafts

A World of Warcraft Classic addon that builds a guild-wide recipe book — automatically scanning, storing, and syncing every learned recipe across all guild members.

Supports Classic Era, TBC Anniversary, WotLK Classic, Cata Classic, and MoP Classic via multi-TOC.

## Repository Structure

### `GuildCrafts/`

The addon itself. This is the folder you drop into `World of Warcraft/_classic_/Interface/AddOns/`. It contains all Lua source code, TOC files for each game version, embedded libraries, and an addon-specific [README.md](GuildCrafts/README.md) with feature list, slash commands, and installation instructions.

| File | Purpose |
|---|---|
| `Core.lua` | Entry point — addon initialisation, event routing, slash commands |
| `Modules/Data.lua` | Recipe scanning, profession detection, expansion classification, data storage, merge logic |
| `Modules/Comms.lua` | Network layer — DR/BDR election, sync protocol, delta updates, craft messages |
| `Modules/SyncPausePolicy.lua` | Pause gate — suppresses outgoing sync during combat, instances, and zone transitions |
| `Modules/Tooltip.lua` | Item tooltip hook — shows guild crafters on hover |
| `Modules/MinimapButton.lua` | Draggable minimap icon toggle |
| `Modules/Favorites.lua` | Bookmark/star system |
| `Data/Data_TBC.lua` | Pre-generated TBC recipe lookup table |
| `Data/Data_WOTLK.lua` | Pre-generated WotLK recipe lookup table |
| `Data/Data_CATA.lua` | Pre-generated Cata recipe lookup table |
| `Data/Data_MOP.lua` | Pre-generated MoP recipe lookup table |
| `UI/MainFrame.lua` | Two-panel browse/search interface |
| `Libs/` | Embedded libraries (Ace3, LibDeflate, ChatThrottleLib) |
| `GuildCrafts*.toc` | Addon metadata and load order (one per game version) |

Member identities use a canonical `Name-Realm` key. Connected-realm display
punctuation is normalized consistently across roster data, addon messages,
saved data, and election state; existing entries are merged on first access.

### `spec/`

Design documents and planning files. Not part of the addon — these are reference material for development.

| File | Purpose |
|---|---|
| `spec.md` | Full technical specification — data model, sync protocol, UI layout, API usage |
| `tech-stack.md` | Libraries and technology choices with rationale |
| `improvements.md` | Tiered feature roadmap with implementation status |
| `implementation-plan.md` | Original build plan and milestone sequence |
| `implementation-plan-v2.md` | Patch-based plan for sync reliability and multi-expansion |
| `migration-classic-era.md` | Classic Era (1.15.x) compatibility notes |
| `migration-wotlk.md` | WotLK Classic (3.4.x) compatibility notes |
| `migration-mop.md` | MoP Classic (5.5.x) compatibility notes |
