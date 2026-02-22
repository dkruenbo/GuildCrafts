# GuildCrafts

A World of Warcraft TBC Anniversary addon that builds a guild-wide recipe book — automatically scanning, storing, and syncing every learned recipe across all guild members.

## Repository Structure

### `GuildCrafts/`

The addon itself. This is the folder you drop into `World of Warcraft/_classic_/Interface/AddOns/`. It contains all Lua source code, the TOC file, embedded libraries, and an addon-specific [README.md](GuildCrafts/README.md) with feature list, slash commands, and installation instructions.

| File | Purpose |
|---|---|
| `Core.lua` | Entry point — addon initialisation, event routing, slash commands |
| `Data.lua` | Recipe scanning, profession detection, data storage, merge logic |
| `Comms.lua` | Network layer — DR/BDR election, sync protocol, delta updates, craft messages |
| `Tooltip.lua` | Item tooltip hook — shows guild crafters on hover |
| `CraftRequest.lua` | Craft request/accept/decline/complete workflow |
| `MinimapButton.lua` | Draggable minimap icon toggle |
| `UI/MainFrame.lua` | Two-panel browse/search interface |
| `Libs/` | Embedded libraries (Ace3, LibDeflate, ChatThrottleLib) |
| `GuildCrafts.toc` | Addon metadata and load order |

### `spec/`

Design documents and planning files. Not part of the addon — these are reference material for development.

| File | Purpose |
|---|---|
| `spec.md` | Full technical specification — data model, sync protocol, UI layout, API usage |
| `tech-stack.md` | Libraries and technology choices with rationale |
| `improvements.md` | Tiered feature roadmap with implementation status |
| `implementation-plan.md` | Original build plan and milestone sequence |
| `GuildCrafts-Guide.txt` | Plain-English user guide explaining every feature |
