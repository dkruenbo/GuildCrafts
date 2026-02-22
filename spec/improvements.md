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
| 5 | ~~Skill Level Display~~ | ~~Show each member's current profession skill (e.g. "Alchemy 375/375").~~ | **DONE** — Skill level captured during DetectProfessions, displayed in member list and recipe detail header |
| 6 | Favorites / Bookmarks | Let users star recipes for quick access in a dedicated "Favorites" tab. | Avoids repeated searches for the same commonly-needed items (flasks, enchants). |
| 7 | ~~Recipe Categorization~~ | ~~Group recipes by sub-type (Potions, Elixirs, Flasks for Alchemy; Weapons, Armor for Blacksmithing, etc.).~~ | **DONE** — Category captured from profession window headers during scan, displayed as grouped headers in recipe detail view |
| 8 | ~~Minimap Button~~ | ~~Small icon on the minimap to toggle the window. Uses LibDBIcon.~~ | **DONE** — Self-contained MinimapButton.lua module with draggable icon, saved position, /gc minimap toggle |

## Tier 3 — Communication & UX

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 9 | In-Game Craft Request Chat | Small embedded chat box between requester and crafter to discuss mats, tips, meeting location. | Keeps the conversation in context instead of switching to whisper windows. |
| 10 | ~~Profession Icons~~ | ~~Use WoW's built-in profession icons next to each profession name in the left panel.~~ | **DONE** — Icon textures rendered next to profession names in the left panel via CreateLeftRow icon parameter |
| 11 | ~~Data Expiry / Staleness Indicator~~ | ~~Flag member data that hasn't been updated in 30+ days. Optional auto-hide for inactive players.~~ | **DONE** — Red [30d ago] / [2mo ago] tag shown in member list and recipe detail header for entries older than 30 days |

## Tier 4 — Scale & Infrastructure

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 12 | ~~Chunked Sync~~ | ~~Break large sync responses into smaller batches instead of one big payload.~~ | **DONE** — SYNC_RESPONSE and SYNC_PUSH payloads are split into chunks of 10 members each with chunkIndex/chunkTotal metadata; receivers merge incrementally and reset sync timeout per chunk |
| 13 | Export to CSV / Text | Dump the full guild recipe database to a text file for guild websites or spreadsheets. | Useful for guild management outside the game. |
| 14 | Locale Support | Handle multi-locale guilds where recipe names differ by client language. Use spellID-based keys (already partially implemented) with localized display names. | Relevant for EU servers where players may run different language clients. |
| 15 | Code Modularisation | Split large files (Data.lua, MainFrame.lua, Comms.lua) into focused sub-modules for easier onboarding and contribution. | Files over 1,000 lines are harder for new contributors to navigate. Smaller, single-purpose modules reduce merge conflicts and make PRs easier to review. |

## Tier 5 — Server-Wide Craft Marketplace

| # | Feature | Description | Why |
|---|---------|-------------|-----|
| 16 | Craft Marketplace | A "Market" tab where any player on the server can list up to 5 recipes they're selling as a crafting service. Other addon users can browse listings and whisper sellers directly. | Turns GuildCrafts from a guild tool into a server-wide crafting service board. Fills a gap WoW doesn't have natively. |

### Implementation Plan

**Architecture:**
- Completely separate from guild sync. The guild recipe book stays as-is. The marketplace is an opt-in layer on top.
- New module: `Market.lua` — handles listings, channel communication, and caching.
- New UI tab: "Market" added to the main window alongside the existing guild view.

**Critical API Constraint — `SendAddonMessage` vs `SendChatMessage`:**
- Guild sync (Tier 1–4) uses `C_ChatInfo.SendAddonMessage()` via AceComm. This sends invisible addon data with reasonable rate limits — but it **only works on GUILD, PARTY, RAID, and WHISPER channels**.
- Custom channels (like `GCMarket`) **cannot use `SendAddonMessage`**. The addon must use `SendChatMessage()` instead, which sends real visible text into a public channel. A Lua `ChatFrame_AddMessageEventFilter` hides the messages from addon users, but non-addon users see raw text.
- This changes everything about the communication design. Compressed/serialized data (AceSerializer + LibDeflate) would appear as gibberish in the channel, triggering Blizzard's anti-spam system and inviting mass-reports from trolls.

**Communication — Passive Broadcast Model (no request/response):**
- ~~Previous plan used request/response: `MARKET_REQUEST` → N sellers respond with jitter.~~
- **Problem**: Even with jitter, 50 sellers responding within 5 seconds = 50 `SendChatMessage` calls flooding a public channel. This causes client lag, triggers spam detection, and exposes the addon to mass-reporting.
- **New model: broadcast-only, passive listen.**
  - Sellers broadcast their listings **only** on login and when they manually update/add/remove a listing. No automated periodic re-broadcasts.
  - All other addon users **passively listen** on the channel and cache what they hear. No request messages, no responses.
  - Listings expire from the local cache after 30 minutes.
  - **Keeping-alive without spam**: A seller who logs in and plays for 3 hours without changing listings would vanish from everyone's cache after 30 minutes. To prevent this, the seller's client runs an automatic re-broadcast every 25 minutes (just under the 30-min TTL). This is max 5 short messages spaced 1–2 seconds apart, once every 25 minutes — negligible traffic that will never trigger spam detection. Additionally, the Market tab has a manual "Refresh My Listings" button with a 15-minute cooldown for sellers who want explicit control.
  - This reduces traffic from O(N) response storms to O(1) per seller action. A server with 200 active sellers generates ~200 messages total at peak login, spread across the login window — not 200 responses to a single request. Ongoing keep-alive adds ~200 × 5 messages per 25-minute window across the entire server, spread naturally by login time offsets.

**Lightweight Wire Format (no AceSerializer):**
- AceSerializer + LibDeflate produce opaque binary-looking strings that trigger Blizzard's spam detector and look like bot output to other players.
- Instead, use a **human-readable micro-format** that is trivially parseable but doesn't look like spam:
  ```
  [GC]L:22861,Alchemy,Potions Master,Free for guildies
  [GC]L:27984,Enchanting,,PST
  [GC]R:22861
  ```
  - `[GC]L:` = listing (create/update). Fields: itemID, profession, spec (optional), tip (optional).
  - `[GC]R:` = remove listing.
  - **Item IDs, not names** — EU servers mix English, German, and French clients on the same realm. Localized item names would break cross-language discovery. Item IDs are universal. Receivers call `GetItemInfo(itemID)` to resolve the local name and icon. Note: `GetItemInfo` can return `nil` on first call for unseen items — handle the `GET_ITEM_INFO_RECEIVED` event callback for async resolution.
  - Sender name comes from the chat message metadata (no need to include it in payload).
  - Max 5 `[GC]L:` messages per broadcast. Each message is a single short line.
  - **255-character hard limit** — `SendChatMessage` silently truncates or drops messages exceeding 255 characters. The tip field is capped at 60 characters in the UI. As a safety net, the broadcast function must always apply `string.sub(payload, 1, 255)` before sending.
- A `ChatFrame_AddMessageEventFilter` strips `[GC]` messages from addon users' chat windows so they never see them.
- **UI Taint warning**: WoW's chat filters are notorious for causing UI taint (where standard Blizzard buttons stop working) if not implemented correctly. The filter must be a plain function reference — no closures over secure frames, no calls to protected functions, no modifications to Blizzard UI elements inside the filter callback. Test thoroughly with `/run SetCVar("taintLog", 1)` and check `BugSack` / `!BugGrabber` for taint traces.
- **Reference implementation** — taint-safe filter (the filter's only job is hiding text; data collection happens in a separate `CHAT_MSG_CHANNEL` handler via AceEvent):
  ```lua
  -- Local function: no globals, no closures over secure frames, no side effects.
  local function GuildCraftsMarketFilter(self, event, msg, author, ...)
      if msg and string.sub(msg, 1, 4) == "[GC]" then
          return true  -- hide from chat window
      end
      return false, msg, author, ...
  end

  ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", GuildCraftsMarketFilter)
  ```
  - The filter returns `true` to suppress, or `false` + pass-through args to allow.
  - Data ingestion (parsing `[GC]L:` into cache) must be a **separate** `CHAT_MSG_CHANNEL` event handler (e.g. via `self:RegisterEvent`), not inside the filter. Mixing concerns inside the filter risks taint.

**Custom Channel Resilience:**
- WoW custom channels can be hijacked — the oldest member becomes "Owner" and can password-lock the channel, blocking all other users. Trolls do this on popular servers.
- The addon **must** handle channel join failures gracefully: disable market features silently, notify the user, never error or block.
- Fallback strategy: if the primary channel (`GCMarket`) is locked, try rotating fallback channels (`GCMarket1`, `GCMarket2`).
- Consider a deterministic channel name that rotates (e.g. based on date or realm hash) to make hijacking harder to sustain.

**Blizzard TOS & Spam Avoidance:**
- Blizzard has broken addons that create large automated networks in public channels (e.g. ClassicLFG). To stay compliant:
  - **Max 5 listings** per player — keeps it feeling like a bulletin board, not an automated system. Non-negotiable.
  - **No automated matching or trading** — players must whisper to arrange crafts manually.
  - **No price data aggregation** — the market is a service board, not an AH replacement.
  - **100% opt-in** — no market data is sent unless the player explicitly lists recipes for sale.
- **Anti-spam specifics** (because `SendChatMessage` is used):
  - Human-readable wire format — never send compressed/serialized blobs that look like bot output.
  - No request/response pattern — eliminates message storms that trigger rate limits or spam flags.
  - Broadcast only on player-initiated actions (login, manual listing update) — never automated periodic sends.
  - Respect `SendChatMessage` throttle: space messages 1–2 seconds apart when sending multiple listings on login.
  - If Blizzard's spam filter mutes a message (detected via `ChatFrame_MessageEventHandler` failure), back off and retry later — never rapid-fire retry.

**Listing Flow:**
1. Player opens their recipe list in the guild view and clicks "List for Sale" on up to 5 recipes.
2. Listings are stored locally in SavedVariables.
3. On login, the addon waits 10–15 seconds (`C_Timer.After`) before joining the market channel and broadcasting. `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` is the most stressed moment for the client — dozens of addons load data simultaneously, and the server floods the client with updates. Firing 5 `SendChatMessage` calls immediately risks messages being swallowed or triggering an instant disconnect from server-side throttling.
4. After the initial delay, the addon broadcasts up to 5 `[GC]L:` messages to the market channel, spaced 1–2 seconds apart.
5. The seller's client automatically re-broadcasts every 25 minutes to keep listings alive in other users' caches (just under the 30-min TTL). A manual "Refresh My Listings" button (15-min cooldown) is also available.
6. Other addon users passively receive and cache these listings. Receivers resolve item IDs to local names via `GetItemInfo` (with `GET_ITEM_INFO_RECEIVED` fallback for uncached items).

**Data Model per Listing (local cache):**
```
{
    seller     = "PlayerName-Realm",
    itemID     = 22861,               -- universal item ID (language-independent)
    itemName   = "Flask of Supreme Power", -- resolved locally via GetItemInfo
    profName   = "Alchemy",
    spec       = "Potions Master",    -- optional
    tip        = "Free for guildies", -- optional seller note (max 60 chars)
    receivedAt = timestamp,           -- when we last heard this listing (for 30-min TTL)
}
```

**Browsing & Contact:**
- Market tab shows all cached listings, searchable and sortable by item name, profession, or seller.
- Each listing has a "Whisper" button that opens a whisper to the seller.
- If both parties have the addon, "Request Craft" works the same way as the guild version.
- Listings expire from the cache after 30 minutes without a refresh. Stale entries are hidden automatically.

**Data Trust & Anti-Abuse (server-wide = untrusted senders):**
- **Rate limiting**: Ignore users who flood more than N listing messages per minute.
- **Validation**: Reject listings with invalid item names, excessive length, or more than 5 per sender.
- **Local blocklist**: `/gc market ignore PlayerName` to permanently hide a spammer's listings.
- **No DR/BDR needed**: Unlike guild sync, the marketplace doesn't need a coordinator. Every user broadcasts their own listings and caches what they receive. Simple gossip protocol.

**Additional Constraints:**
- **Channel slot**: WoW allows max 10 custom channels per player. Market uses 1 slot. If all 10 are taken, warn the user and don't join.
- **Privacy**: Listing is fully opt-in. No recipes are shared on the market channel unless the player explicitly marks them for sale.
- **Non-addon visibility**: Because `SendChatMessage` is used, players without GuildCrafts who join the `GCMarket` channel will see raw `[GC]L:` messages. The human-readable format is intentional — it looks like bulletin board posts, not bot spam.

**Milestone Sequence:**
1. Implement custom channel join/leave with fallback handling and error resilience.
2. Add "List for Sale" toggle to recipe rows in the UI (max 5).
3. Implement passive broadcast-on-change (`[GC]L:` / `[GC]R:` via `SendChatMessage`) with throttled spacing and `ChatFrame_AddMessageEventFilter` to hide messages from addon users.
4. Build the Market tab with listing display, search, and "Whisper" button.
5. Add cache expiry (30-min TTL), rate limiting, validation, and local blocklist.
6. Polish: seller notes, spec display, sort/filter options, channel rotation fallback, spam-filter backoff.
