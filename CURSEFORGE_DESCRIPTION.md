# GuildCrafts

**A shared recipe book for your entire guild.**

Stop whispering every guildie asking "Can you craft Flask of Supreme Power?" — open one window and instantly see every recipe your guild knows.

## Features

*   **Browse by profession or recipe** — switch between a per-member recipe list and an aggregated "who can craft this?" view with one click
*   **Search anything** — type an item name, see every guild member who can craft it
*   **Quality colors** — recipe names are tinted by item rarity (grey/white/green/blue/purple/orange) so rare recipes pop out at a glance
*   **Collapsible reagent rows** — click any recipe to expand or collapse its material list; everything stays collapsed by default for a clean view
*   **Dark professional sidebar** — polished dark rows with a gold accent bar on the selected profession and a blue hover highlight
*   **Craft requests** — click a button to ask an online crafter, they get an Accept/Decline popup
*   **Guild chat lookup** — type `!gc <query>` in guild chat and the addon instantly replies with matching crafters, no window needed
*   **Favorites/Bookmarks** — star your favorite recipes and crafters for quick access
*   **Specialisations** — Transmutation Master, Goblin Engineer, Mooncloth Tailoring, etc.
*   **Cooldown tracking** — see when transmutes and specialty cloth are off cooldown guild-wide
*   **Tooltip integration** — hover any item in bags, AH, or chat to see who can craft it
*   **Profession icons** — each profession shows its WoW icon for quick scanning
*   **Minimap button** — one-click access, draggable, hideable
*   **Fully automatic sync** — recipes sync in the background with zero configuration
*   **Auto-cleanup** — members who leave the guild are automatically removed after 30 days

## How It Works

1.  Install the addon
2.  Open each profession window once (so it can scan your recipes)
3.  That's it — your recipes are shared with every guildie running the addon

The more guild members who install it, the more complete the recipe book becomes.

## Under the Hood

*   Smart sync protocol — one coordinator handles all data exchange (no chat spam)
*   Automatic failover — if the coordinator goes offline, a backup takes over seamlessly
*   Live updates — new recipes broadcast instantly, no re-sync needed
*   Lightweight — data is compressed and sent in small batches
*   Efficient storage — recipe data is deduplicated to minimize SavedVariables size

## Commands

*   `/gc` — toggle the main window
*   `/gc minimap` — show/hide the minimap button
*   `/gc reset` — wipe saved data and start fresh
*   `!gc <query>` — (guild chat) search for a recipe and the addon posts matching crafters for the whole guild to see

> **Troubleshooting:** If you experience missing or incorrect recipe data, type `/gc reset` to clear your local database and re-scan on next profession window open.

## TBC Anniversary Edition

Built for WoW TBC Anniversary (Interface 20505). Covers all 7 TBC crafting professions.
