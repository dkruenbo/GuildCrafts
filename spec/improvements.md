# GuildCrafts — Ranked Improvements & Suggestions

## Tier 1 — High Impact

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 1 | ~~Tooltip Integration~~ | ~~When hovering over any item in WoW (bags, AH, chat links), show "Craftable by: PlayerA, PlayerB" in the tooltip automatically.~~ | **DONE** — Implemented in Tooltip.lua |
| 2 | ~~Reagent / Material Tracking~~ | ~~Show what materials each recipe requires. Scan `GetTradeSkillReagentInfo()` during profession scan.~~ | **DONE** — Reagents scanned during profession window open and displayed in recipe detail view |
| 3 | ~~Specialisation Tracking~~ | ~~Detect and display profession specialisations (Potions/Elixir/Transmute Master, Weaponsmith/Armorsmith, Gnomish/Goblin Engineering, Mooncloth/Shadoweave/Spellfire Tailoring, Dragonscale/Elemental/Tribal Leatherworking).~~ | **DONE** — Detected via IsSpellKnown on login, shown in member list and recipe header |
| 4 | ~~Cooldown Tracking~~ | ~~Track shared cooldowns (Primal Mooncloth, Transmutes, Spellcloth, etc.) and show time remaining per player.~~ | **DONE** — Scanned when profession window opens, displayed in recipe detail view with time remaining |

## Tier 2 — Strong Quality of Life

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 5 | Skill Level Display | Show each member's current profession skill (e.g. "Alchemy 375/375"). | Helps identify who can learn a recipe they don't have yet vs. who is capped. |
| 6 | Favorites / Bookmarks | Let users star recipes for quick access in a dedicated "Favorites" tab. | Avoids repeated searches for the same commonly-needed items (flasks, enchants). |
| 7 | Recipe Categorization | Group recipes by sub-type (Potions, Elixirs, Flasks for Alchemy; Weapons, Armor for Blacksmithing, etc.). | Flat lists get unwieldy with 100+ recipes. Categories make browsing practical. |
| 8 | Minimap Button | Small icon on the minimap to toggle the window. Uses LibDBIcon. | Not everyone remembers `/gc`. A visible button increases discoverability. |

## Tier 3 — Communication & UX

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 9 | In-Game Craft Request Chat | Small embedded chat box between requester and crafter to discuss mats, tips, meeting location. | Keeps the conversation in context instead of switching to whisper windows. |
| 10 | Profession Icons | Use WoW's built-in profession icons next to each profession name in the left panel. | Visual polish. Makes the list easier to scan at a glance. |
| 11 | Data Expiry / Staleness Indicator | Flag member data that hasn't been updated in 30+ days. Optional auto-hide for inactive players. | Keeps the recipe book relevant. Prevents clutter from long-offline alts. |

## Tier 4 — Scale & Infrastructure

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 12 | Chunked Sync | Break large sync responses into smaller batches instead of one big payload. | Prevents chat throttle issues in large guilds (200+ members with dozens of recipes each). |
| 13 | Export to CSV / Text | Dump the full guild recipe database to a text file for guild websites or spreadsheets. | Useful for guild management outside the game. |
| 14 | Locale Support | Handle multi-locale guilds where recipe names differ by client language. Use spellID-based keys (already partially implemented) with localized display names. | Relevant for EU servers where players may run different language clients. |

## Tier 5 — Server-Wide Craft Marketplace

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 15 | Craft Marketplace | A "Market" tab where any player on the server can list up to 5 recipes they're selling as a crafting service. Other addon users can browse listings and whisper sellers directly. | Turns GuildCrafts from a guild tool into a server-wide crafting service board. Fills a gap WoW doesn't have natively. |

### Implementation Plan

**Architecture:**
- Completely separate from guild sync. The guild recipe book stays as-is. The marketplace is an opt-in layer on top.
- New module: `Market.lua` — handles listings, channel communication, and caching.
- New UI tab: "Market" added to the main window alongside the existing guild view.

**Communication:**
- On login, the addon auto-joins a server-wide custom chat channel (e.g. `GCMarket`).
- Uses the same AceComm + serialize + compress infrastructure already built for guild sync.
- All market messages use the custom channel instead of GUILD.

**Listing Flow:**
1. Player opens their recipe list in the guild view and clicks "List for Sale" on up to 5 recipes.
2. Listings are stored locally in SavedVariables and broadcast to the custom channel on a periodic heartbeat (every 5 minutes).
3. When another addon user joins the channel, they receive active listings from whoever is online.

**Data Model per Listing:**
```
{
    seller    = "PlayerName-Realm",
    item      = "Flask of Supreme Power",
    profName  = "Alchemy",
    spec      = "Potions Master",    -- optional, if spec tracking is implemented
    tip       = "Free for guildies", -- optional seller note (max 80 chars)
    listedAt  = timestamp,
}
```

**Browsing & Contact:**
- Market tab shows all active listings, searchable and sortable by item name, profession, or seller.
- Each listing has a "Whisper" button that opens a whisper to the seller.
- If both parties have the addon, "Request Craft" works the same way as the guild version.
- Only shows listings from sellers who are currently online. When a seller logs off, their listings are removed from the market view immediately (no cached/stale entries).

**Constraints to Handle:**
- **Throttling**: Custom channels have stricter rate limits than guild chat. Heartbeat interval should be conservative (5 min). Use compression aggressively.
- **Channel slot**: WoW allows max 10 custom channels per player. Market uses 1 slot. If all 10 are taken, warn the user.
- **Spam prevention**: Max 5 listings per player enforced client-side. Listings auto-expire after 24 hours without a heartbeat refresh.
- **No DR/BDR needed**: Unlike guild sync, the marketplace doesn't need a coordinator. Every user broadcasts their own listings and caches what they receive. Simple gossip protocol.
- **Privacy**: Listing is fully opt-in. No recipes are shared on the market channel unless the player explicitly marks them for sale.

**Milestone Sequence:**
1. Implement custom channel join/leave and basic send/receive on the market channel.
2. Add "List for Sale" toggle to recipe rows in the UI (max 5).
3. Build the Market tab with listing display, search, and "Whisper" button.
4. Add heartbeat broadcast and cache expiry logic.
5. Polish: seller notes, spec display, sort/filter options.
