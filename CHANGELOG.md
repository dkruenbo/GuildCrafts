        # Changelog

    ## 1.3.1 — 2026-03-22

    ### Fixes

    - **`!gc` enchant link lookup** — shift-clicking an enchant spell link into guild chat (e.g. `!gc [Enchanting: Enchant Bracer - Spellpower]`) now correctly strips the leading `Profession: ` prefix before searching. Previously the prefix caused a false "No guild crafter found" even when crafters existed

    ### Improvements

    - **Locale-independent link lookup** — when a `!gc` query contains a shift-clicked hyperlink, the numeric item/spell ID is extracted and used for an exact key-based DB lookup before falling back to text search. A German DR can now answer an English player's shift-clicked link (and vice-versa) regardless of client language

    ---

    ## 1.3.0 — 2026-03-22

    ### Improvements

    - **Ghost member auto-prune** — members who are still in the guild but haven't scanned their professions in 45 days are now automatically removed from the guild database. Previously only ex-guild members were pruned; a still-in-guild member who uninstalled GuildCrafts would accumulate an ever-staler entry indefinitely
    - **Ex-guild grace period reduced: 30d → 7d** — someone who leaves the guild is immediately irrelevant; their entry is now gone within a week instead of a month
    - **Login stale-data warning** — if your own profession data is more than 30 days old, a one-time amber message appears in chat on login reminding you to open your profession windows to resync. Fires once per session only
    - **Smarter login prompt** — the blanket "open profession windows" message is replaced with a targeted warning that lists only the specific professions you have but haven't scanned yet. Herbalism and Skinning are excluded (no recipes to scan). No message is shown if all professions are already synced
    - **Legacy entry cleanup** — entries from early addon versions that were never assigned a scan timestamp (`lastUpdate` nil or 0) are now pruned on the next roster cycle. Active members who open a profession window get a fresh entry immediately
    - **Silent load** — the startup chat message ("v1.x loaded…") has been removed. The addon only speaks when there is something actionable to say

    ---

    ## 1.2.5 — 2026-03-20

    ### Improvements

    - **Deferred tooltip index rebuild** — the reverse-lookup index used by item tooltips is no longer rebuilt synchronously during a hover event. `InvalidateIndex()` now schedules a 2-second deferred rebuild via `C_Timer.After`; hover events always use the most recently built index. This eliminates frame hitches on first hover after a sync burst in large guilds
    - **Richer sync status tooltip** — hovering the sync dot in the title bar now shows two additional lines: _Last synced_ (time since the last completed `SYNC_RESPONSE` transaction this session, or "not yet this session" for a DR that has not synced with anyone) and _Stale members (30d+)_ (count of member entries older than 30 days, shown in amber only when non-zero)

    ---

    ## 1.2.4b — 2026-03-19

    ### Fixes

    - **Fixed Enchanting fallback key collision risk** — the last-resort recipe key for enchants that yield neither an itemID nor a spellID was derived from a plain `craftName` hash in the range −1,000,000 to −2,000,000. This shared the same modulo space across all enchant names and could silently overwrite one recipe with another. Fix: the input is now namespaced (`"enc:" .. craftName`) and the hash is placed in a dedicated range below −2,000,000, separated from real spellID-based keys. Collision risk is reduced; the fallback path should never fire for any known TBC enchant

    ---

    ## 1.2.4a — 2026-03-18

    ### Fixes

    - **Fixed role change log showing wrong transition** — when a node stepped down from DR after receiving a higher-term heartbeat, the debug log showed `OTHER → BDR` instead of `DR → BDR`. Root cause: `myRole` was reset to `OTHER` in the generic message handler before `RecomputeElection()` ran, so `oldRole` was always `OTHER`
    - **Fixed sync panel showing stale DR** — `RecomputeElection()` was called in the generic message handler before `HandleHeartbeat` had registered the sender in `addonUsers`, so the election ran with an incomplete peer list and `currentDR` came out wrong. Fix: removed the premature role reset and election call from the generic handler; `HandleHeartbeat` now always calls `RecomputeElection()` and updates the sync indicator after registering the sender

    ---

    ## 1.2.4 — Secondary Professions — 2026-03-17

    ### New Features

    - **Mining (Smelting), Herbalism, and Skinning now tracked** — gathering professions appear in the profession browser alongside crafting professions. Skill levels are tracked and synced; member counts show in the left panel the same way as any other profession
    - **Smelting recipes tracked under Mining** — the Smelting tradeskill window fires `TRADE_SKILL_SHOW` exactly like any crafting profession, so Smelting recipes are scanned and stored under the Mining entry. 
    - **Secondary profession divider in left panel** — a thin separator divides the crafting professions (Alchemy, Blacksmithing, Enchanting, Engineering, Jewelcrafting, Leatherworking, Tailoring) from the secondary group (Mining, Herbalism, Skinning, Cooking) in the left navigation panel
    - **Cooking moved to secondary group** — Cooking now appears below the divider with the other secondary professions
    - **Gathering profession detail panel** — clicking a Herbalism or Skinning member shows their name, skill level, and last-scanned timestamp at the top, with a clear `Herbalism is a gathering profession. No recipes to display.` note below instead of the generic empty-state message

    ### Fixes

    - **Fixed DR term oscillation** — two online addon users could endlessly leapfrog each other's DR authority terms (1472 → 1473 → 1474...) spamming the debug window. Root cause: `RecomputeElection()` was called before the heartbeat sender was registered in the peer list, so the stepping-down node re-elected itself immediately. Fix: register the peer first, then compute election once with complete information 

    ---

    ## 1.2.3a — 2026-03-16

    ### Fixes

    - **Fixed `!gc` double-response when DR is inside an instance** — when the Designated Router enters a battleground or dungeon, heartbeats stop crossing the instance boundary. After 3 minutes the BDR is promoted to DR outside, but the original DR is still alive and also responding to `!gc` queries — causing two replies in guild chat. The fix: a DR inside an instance now treats itself as a regular node for `!gc` purposes (12–20 s delay with jitter). The outside DR/BDR responds first; the in-instance DR sees the `[GuildCrafts]` echo in guild chat and cancels its pending reply. When the DR leaves the instance it broadcasts HELLO, roles re-converge within seconds, and it reclaims the DR role normally

    ---

    ## 1.2.3 — Whisper & UI Polish — 2026-03-16

    ### New Features

    - **`[W]` whisper button** — each recipe row now has a `[W]` button to the left of `[>]`. Clicking it opens the chat edit box pre-filled with `/w CharName Can you craft X for me?`. If there is only one non-self crafter the whisper opens directly; if there are multiple, a small dropdown picker appears (online crafters shown in green, offline in grey). The button is hidden when you are the only known crafter

    - **Bottom bar with `[Online]` and `[Tooltip]` toggles** — the cryptic `O` dot has been replaced by proper labelled buttons in a thin bar at the bottom of the window. `[Online]` filters the crafter list to online members; `[Tooltip]` controls whether guild crafters are injected into hover tooltips. Both buttons glow yellow when active and dim when inactive, matching the existing `[Vanilla]` / `[TBC]` style

    - **Tooltip crafters toggle** — the new `[Tooltip]` button lets you disable the tooltip crafter injection entirely. Useful in large guilds where popular items (flasks, enchants) generate very long tooltips. Off means no crafter section is shown at all; the setting persists across sessions

    - **Three-state online indicator** — the `O` dot next to each member name is now colour-coded with three states: **green** = online and GuildCrafts is active; **yellow** = online but GuildCrafts not detected (addon may be uninstalled); **grey** = offline. Hovering the dot shows a tooltip explaining the state

    ### Fixes

    - **Cooking now appears in the profession list** — Cooking was tracked and synced correctly but was missing from the profession browser due to a hardcoded list that omitted it
    - **Cooking now has a profession icon** — the bread/food icon is shown next to Cooking in the profession list, matching all other professions
    - **Sync dot now updates correctly for the DR** — the Designated Router never receives a `SYNC_RESPONSE`, so the sync indicator was stuck on red even when other addon users were online. The dot now updates immediately when new peers are discovered via HELLO or heartbeat
    - **Sync dot now updates on roster change** — the online indicator cross-checks `addonUsers` against the guild roster cache; it now re-evaluates whenever the roster rebuilds
    - **Bottom bar buttons no longer overlap the resize grip** — the bar's right edge is offset far enough from the corner that it no longer touches the resize dragger
    - **Fixed instances causing false DR eviction** — GUILD addon messages are not delivered inside instances and arenas. The DR heartbeat watchdog now pauses eviction while the player is in an instance, preventing a false re-election every 3 minutes when the DR zones in

    ### Removed

    - **Craft request protocol** — the peer-to-peer craft request / accept / decline / complete flow (popup, comms commands, queue) has been removed. The `[W]` whisper button is the replacement workflow

    ---

    ## 1.2.2 — Expansion Filter — 2026-03-13

    ### New Features

    - **Expansion filter buttons** — two toggle buttons `[Vanilla]` and `[TBC]` in the search bar let you narrow the recipe display to Original Classic recipes, TBC recipes, or both. Filter state persists across reloads per character. Both are active by default so first-run behaviour is unchanged
    - **Accurate TBC classification** — recipes are classified via a pre-generated lookup table (`TBC_ITEM_IDS`) covering all TBC crafting professions. Lookup is a direct hash — no per-frame scan, zero runtime cost
    - **Enchanting fully covered** — enchanting recipe keys are `-spellID` as returned by `GetCraftRecipeLink`; the lookup table is keyed accordingly so all TBC enchants classify correctly

    ---

    ## 1.2.1 — Data Clarity & Search UX — 2026-03-13

    ### New Features

    - **Online-only crafter filter** — a new `[Online]` toggle button in the profession header bar filters the crafter display in Recipes view and Search Results to show only online crafters. Toggle state persists across reloads. When active, recipes with no online crafter show `—`
    - **"Scanned: N ago" timestamp in member detail** — the member recipe panel now shows a small grey label (`Scanned: 2h ago`, `Scanned: 3d ago`, etc.) below the member name so you can immediately judge how fresh the data is
    - **Specialisation description tooltip** — hovering a member row that shows a specialisation tag (e.g. `[Transmutation Master]`, `[Dragonscale Leatherworking]`) now pops a GameTooltip with a plain-English explanation of what the spec unlocks
    - **Better empty search state** — searching for a term with no results now shows a clear "Nobody in the guild knows X" message instead of a silent blank

    ---

    ## 1.2.0 — Protocol Correctness — 2026-03-12

    ### New Features

    - **Cooking now tracked** — raid food, utility food, and all Cooking recipes are now included in the guild database, search, and tooltip injection (closes #60)

    ### Improvements

    - **Term-based DR authority** — the Designated Router now carries a monotone term counter in every message. If a DR is replaced by a new election, any late-arriving messages from the old DR are silently discarded, preventing stale data from overwriting newer guild recipes
    - **Immediate step-down** — if a node is currently acting as DR and receives a heartbeat from a higher-term authority, it steps down instantly and triggers a fresh election rather than waiting for the next heartbeat cycle

    ### Fixes

    - Fixed a race where the old DR kept responding to sync requests after being superseded, because `myRole` was not updated until the next heartbeat timeout

    ---

    ## 1.1.8a — 2026-03-10

    ### New Features

    - **Hover crafter names to see the full list** — hovering the crafter text (right side of a recipe row) in Search results and Recipes view shows a tooltip with all crafters and their online status
    - **Hover a reagent to see its tooltip** — expanding a recipe and hovering any reagent line shows the native WoW item tooltip

    ### Fixes

    - Tooltip hit zone is now scoped to the recipe name only — hovering the crafter list, expand icon, or post button no longer triggers the item tooltip
    - Fixed potential tooltip flicker when moving the cursor between the recipe name and the rest of the row

    ---

    ## 1.1.8 — Recipe Hover Tooltips — 2026-03-10

    ### New Features

    - **Hover a recipe name to see its tooltip** — hovering the recipe name in Search results, Recipes view, member detail, or Favorites shows the native WoW item or spell tooltip. Enchanting recipes (spell-based) show the spell tooltip; all other professions show the item tooltip

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
