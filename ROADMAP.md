# Roadmap

Issue tracker: https://github.com/dkruenbo/GuildCrafts/issues

## 1.0.x — Patch Fixes

| Issue | Title | Status |
|-------|-------|--------|
| [#27](https://github.com/dkruenbo/GuildCrafts/issues/27) | Per-guild database partitioning | Fixed in 1.0.4 |
| [#30](https://github.com/dkruenbo/GuildCrafts/pull/30) | Luacheck cleanup — 0 warnings / 0 errors | Fixed in 1.0.4 |
| [#23](https://github.com/dkruenbo/GuildCrafts/issues/23) | Lazy tooltip index rebuild (dirty flag) | Done (already implemented) |
| [#24](https://github.com/dkruenbo/GuildCrafts/issues/24) | Wrong recipe for Enchant Gloves - Spell Strike | Fixed in 1.0.3 |

## 1.1.0 — Data & Sync Optimisation

| Issue | Title | Status |
|-------|-------|--------|
| [#18](https://github.com/dkruenbo/GuildCrafts/issues/18) | Deduplicate reagent data with shared RecipeDB lookup | Done in 1.1.0 |
| [#20](https://github.com/dkruenbo/GuildCrafts/issues/20) | Auto-prune stale member entries | Done in 1.1.0 |
| [#5](https://github.com/dkruenbo/GuildCrafts/issues/5) | Favorites / Bookmarks | Done in 1.1.0 |

## 1.1.5 — Complete UI Overhaul 

**Theme:** Modern dark UI inspired by GuildCraft Classic Era addon. Adds professional icons, quality colors, dual navigation modes, and collapsible content for information-dense browsing.

| Issue | Title | Status |
|-------|-------|--------|
| [#37](https://github.com/dkruenbo/GuildCrafts/issues/37) | Dark mode profession sidebar buttons with WoW icons | Done in 1.1.5 |
| [#38](https://github.com/dkruenbo/GuildCrafts/issues/38) | Quality-colored recipe/reagent names + raid target star for favorites | Done in 1.1.5 |
| [#39](https://github.com/dkruenbo/GuildCrafts/issues/39) | Collapsible reagent lists (click recipe to expand/collapse) | Done in 1.1.5 |
| [#44](https://github.com/dkruenbo/GuildCrafts/issues/44) | Recipe-centric view with inline crafter preview | Done in 1.1.5 |
| [#45](https://github.com/dkruenbo/GuildCrafts/issues/45) | Members/Recipes view toggle for professions | Done in 1.1.5 |

## 1.2.0 — Protocol Correctness & Incremental Sync

**Theme:** Close formal safety gaps (split-brain protection, documented guarantees) and improve replication efficiency for large guilds.

| Issue | Title | Status |
|-------|-------|--------|
| [#47](https://github.com/dkruenbo/GuildCrafts/issues/47) | Term-based authority enforcement (split-brain protection) | Not started |
| [#48](https://github.com/dkruenbo/GuildCrafts/issues/48) | Document safety guarantees and convergence properties | Not started |
| [#19](https://github.com/dkruenbo/GuildCrafts/issues/19) | Incremental sync: send only changed professions | Not started |

**Note:** Issues [#21](https://github.com/dkruenbo/GuildCrafts/issues/21) (login storm coalescing) and [#22](https://github.com/dkruenbo/GuildCrafts/issues/22) (heartbeat hash piggybacking) removed from roadmap as premature optimizations. Retained as issues for potential future relevance if real-world performance issues emerge.

## 2.0.0 — User Features & Extensibility

| Issue | Title | Status |
|-------|-------|--------|
| [#6](https://github.com/dkruenbo/GuildCrafts/issues/6) | In-Game Craft Request Chat | Not started |
| [#7](https://github.com/dkruenbo/GuildCrafts/issues/7) | Export to CSV / Text | Not started |
| [#8](https://github.com/dkruenbo/GuildCrafts/issues/8) | Locale Support | Not started |
| [#9](https://github.com/dkruenbo/GuildCrafts/issues/9) | Code Modularisation | Not started |
| [#10](https://github.com/dkruenbo/GuildCrafts/issues/10) | Craft Marketplace | **Moved to separate addon: MarketCrafts** |
