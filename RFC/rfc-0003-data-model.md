# GuildCrafts Protocol — RFC 0003

**Status:** Informational  
**Applies to:** GuildCrafts v1.0.0+

---

## Table of Contents

1. [Overview](#1-overview)
2. [SavedVariables Structure](#2-savedvariables-structure)
3. [Member Entry](#3-member-entry)
   - 3.1 [Live Entry](#31-live-entry)
   - 3.2 [Tombstone Entry](#32-tombstone-entry)
4. [Recipe Keys](#4-recipe-keys)
5. [RecipeDB — Shared Recipe Lookup](#5-recipedb--shared-recipe-lookup)
6. [Guild Partitioning](#6-guild-partitioning)
7. [Version Vector](#7-version-vector)
8. [Profession Localisation](#8-profession-localisation)
9. [Merge Rules](#9-merge-rules)
   - 9.1 [Full Merge (MergeIncoming)](#91-full-merge-mergeincoming)
   - 9.2 [Delta Merge (MergeDelta)](#92-delta-merge-mergedelta)
   - 9.3 [Partial-Scan Guard](#93-partial-scan-guard)
10. [Pruning](#10-pruning)
    - 10.1 [Ex-Guild Members](#101-ex-guild-members)
    - 10.2 [Inactive Members](#102-inactive-members)
    - 10.3 [Tombstone Expiry](#103-tombstone-expiry)
    - 10.4 [Legacy Entries](#104-legacy-entries)
11. [Data Format Versioning](#11-data-format-versioning)
12. [User Preferences](#12-user-preferences)
13. [Thresholds Reference](#13-thresholds-reference)

---

## 1. Overview

GuildCrafts uses AceDB-3.0 to persist all state in the `GuildCraftsDB`
SavedVariable. The database has three distinct concerns:

1. **Guild member recipe data** — shared across all characters in the same
   guild, partitioned per guild so a multi-guild player does not mix data.
2. **Shared recipe metadata** — reagents and categories stored once per
   recipe, not per crafter.
3. **User preferences** — UI settings stored per-profile.

A second SavedVariable, `GuildCraftsCharDB`, holds per-character data
(currently only the favorites list).

---

## 2. SavedVariables Structure

```
GuildCraftsDB
└── global
    ├── minimap
    │   ├── hide        boolean  Whether the minimap button is hidden.
    │   └── minimapPos  number   Position in degrees (0–360, top = 0).
    │
    ├── _recipeDB       table    Shared recipe metadata (see §5).
    │
    └── ["GuildName-Realm"]     Guild partition (one per guild joined).
        ├── ["CharName-Realm"]  Live member entry (see §3.1).
        ├── ["CharName-Realm"]  Tombstone entry (see §3.2).
        └── ...

GuildCraftsCharDB
└── favorites   { [recipeKey] = true, ... }
```

---

## 3. Member Entry

### 3.1 Live Entry

```lua
{
    professions = {
        ["Alchemy"] = {
            recipes = {
                [recipeKey] = {
                    name   = "Flask of Pure Death",  -- localized at scan time
                    source = "craft",                -- "craft" | "enchant"
                    -- reagents and category are NOT stored here (see §5)
                },
                ...
            },
            skillLevel    = 375,       -- current skill level at last scan
            maxSkillLevel = 375,       -- skill cap at last scan
            specialisation = "Elixir Master",  -- or nil
        },
        ...
    },
    lastUpdate  = 1700000000,  -- Unix timestamp of most recent scan
    dataFormat  = 2,           -- DATA_FORMAT_VERSION at last sync/scan
    _absentSince = nil,        -- set when member first disappears from roster
}
```

**`lastUpdate`** is the single source of truth for merge precedence. It is
updated whenever a scan discovers new recipes, a profession is dropped, or
a `DELTA_UPDATE touch` is applied. The local player's own `lastUpdate` is
never overwritten by incoming sync data.

**`dataFormat`** is written when receiving sync data. It is used during the
version-vector diff to identify entries that need a re-pull even when their
timestamps are equal (schema upgrade).

**`_absentSince`** is a local-only field used by the pruning logic. It is
never transmitted in sync payloads.

### 3.2 Tombstone Entry

```lua
{
    _tombstone = true,
    lastUpdate = 1700000000,  -- timestamp of the tombstone write
}
```

A tombstone replaces a live entry when a member's ex-guild grace period
expires. It propagates through the normal sync mechanism so peers learn of
the deletion without needing a direct message. See §10 for lifecycle.

---

## 4. Recipe Keys

A recipe is identified by a single integer **recipeKey**:

| Value | Meaning |
|-------|---------|
| positive | Item ID of the item the recipe creates (`GetItemInfo` lookup). Used by all TradeSkill professions. |
| negative | Negative of the spell ID for the recipe (`-spellID`). Used for Enchanting, which produces no craftable item. |

This convention allows a single numeric key space to cover both crafting and
enchanting without a secondary type discriminator.

---

## 5. RecipeDB — Shared Recipe Lookup

Reagent lists and category strings are expensive to repeat once per crafter.
They are stored in a single shared table keyed by `recipeKey`:

```lua
_recipeDB = {
    [recipeKey] = {
        name     = "Flask of Pure Death",
        category = "Flasks",
        reagents = {
            { name = "Nightmare Vine",  count = 7,  itemID = 22710 },
            { name = "Felweed",         count = 3,  itemID = 22785 },
            ...
        },
    },
    ...
}
```

**Write policy:** reagents are only overwritten when the new list is longer
(more complete). This prevents a partial scan from erasing a complete reagent
list stored from an earlier scan.

**Migration:** on `OnInitialize`, any reagent/category fields found inside
per-crafter recipe entries are extracted to `_recipeDB` and removed from the
per-crafter storage. This migration is idempotent and runs on every load for
legacy databases.

**Scope:** `_recipeDB` lives at `db.global` (not inside the guild partition)
so reagent data gathered from one guild persists when the player joins a
second guild.

---

## 6. Guild Partitioning

Member data is stored under a **guild partition key** derived from the
player's guild name and realm at the time of first access:

```
guildKey = GetGuildInfo("player") .. "-" .. GetRealmName()
           e.g. "Kindred Spirits-Thekal"
```

All member entries for that guild live under `db.global[guildKey]`. This
isolates data when a player moves between guilds or across realms.

**Lazy migration:** on first access to the guild partition, `MigrateToGuildPartition`
moves any legacy flat member entries (written by addon versions prior to
guild partitioning) into the current partition.

**Canonical member-key migration:** `MergeRealmlessKeys` runs on first access
to the current guild partition to normalize display-realm punctuation and
missing realm suffixes, then either renames keys or merges them into the
canonical `Name-Realm` entry, keeping the newer `lastUpdate`. Newer tombstones
remain authoritative during the merge. The same canonical form is used for
roster keys, AceComm senders, sync vectors, and member favorites.

---

## 7. Version Vector

The **version vector** is a flat table used during sync to determine what
each peer needs:

```lua
{ ["Alice-Realm"] = 1700000000, ["Bob-Realm"] = 1700001234, ... }
```

It is built by `Data:GetVersionVector()`, which iterates the guild DB and
returns `memberKey → entry.lastUpdate` for all non-tombstone entries.

During `ProcessSyncRequest` (RFC-0002 §5.2):
- If local `ts > incoming ts`, or the key is absent from the incoming vector:
  the entry is included in SYNC\_RESPONSE.
- If incoming `ts > local ts`, or the key is absent locally:
  the member key is added to the SYNC\_PULL list.
- If timestamps are equal but the local `dataFormat` is lower than
  `DATA_FORMAT_VERSION`: the member key is added to SYNC\_PULL to force a
  schema-upgrade push.

---

## 8. Profession Localisation

All professions are stored using **canonical English keys** regardless of the
client's language. The localisation layer converts at scan time using spell
IDs for the rank-1 profession spell:

```lua
PROFESSION_SPELL_IDS = {
    ["Alchemy"]        = 2259,
    ["Blacksmithing"]  = 2018,
    ["Cooking"]        = 2550,
    ["Enchanting"]     = 7411,
    ["Engineering"]    = 4036,
    ["Jewelcrafting"]  = 25229,
    ["Leatherworking"] = 2108,
    ["Tailoring"]      = 3908,
    ["Mining"]         = 2575,
    ["Herbalism"]      = 2366,
    ["Skinning"]       = 8613,
}
```

`Data:GetCanonicalProfName(localizedName)` looks up the locale-to-canonical
map (built lazily from `GetSpellInfo` calls) and returns the English key.
This map also covers tradeskill window title aliases, e.g. "Smelting" → "Mining".

Recipe names in per-crafter entries are stored as scanned (possibly
localised). `Data:GetLocalizedRecipeName(recipeKey)` re-derives the
current-client name via `GetItemInfo`/`GetSpellInfo` at display time,
falling back to the stored name only when the API returns nil.

---

## 9. Merge Rules

### 9.1 Full Merge (MergeIncoming)

Called when a SYNC\_RESPONSE chunk is received. Merges entire member entries.

An incoming entry **wins** (replaces local) when:

```
incomingEntry.lastUpdate > localEntry.lastUpdate
OR
incomingEntry.lastUpdate == localEntry.lastUpdate
    AND incomingEntry.dataFormat > localEntry.dataFormat
```

**Own-data guard:** the local player's own entry is never overwritten.
Synced payloads strip reagent/cooldown data, so the local scan is always
more complete.

**Tombstone rules:**
- Incoming tombstone beats local live entry when `incoming.lastUpdate > local.lastUpdate`.
- Local tombstone blocks incoming live entry unless `incoming.lastUpdate > tombstone.lastUpdate`
  (member re-joined and re-scanned after being tombstoned).

### 9.2 Delta Merge (MergeDelta)

Called for individual recipe additions from DELTA\_UPDATE. Adds a single
recipe to a member's profession entry. A tombstone blocks the delta unless
the delta's `lastUpdate` is strictly newer (resurrection case).

### 9.3 Partial-Scan Guard

Before applying a winning entry in a full merge, the incoming recipe counts
are compared against the local counts per profession. If any profession in
the incoming data has more than 0 recipes but fewer than **50%** of the
locally stored count, the merge is blocked and a debug message is emitted.
This prevents a partially scanned entry from overwriting a complete local
copy.

The guard is skipped when there is no prior local data for the member, and
is applied (with a simpler check) during tombstone-resurrection merges.

---

## 10. Pruning

`Data:PruneRoster()` runs on every `GUILD_ROSTER_UPDATE` event when the
player is not in combat. It skips if the guild roster is not yet loaded
(< 2 members returned).

### 10.1 Ex-Guild Members

Members absent from the guild roster receive an `_absentSince` timestamp on
first detection. After **7 days** (`EX_GUILD_GRACE_PERIOD`), their entry is
replaced with a tombstone (`_tombstone = true`, `lastUpdate = now`).

If a member returns to the guild before the grace period expires,
`_absentSince` is cleared.

If a tombstone exists for a member who is currently in the guild (e.g. a
spurious tombstone propagated from a peer with a faulty roster read), the
tombstone is cleared so live data can flow in.

### 10.2 Inactive Members

Members still in the guild roster but with no scan in **45 days**
(`INACTIVE_MEMBER_THRESHOLD`) are hard-deleted (no tombstone). These members
have not used the addon in a very long time; there is no useful data to
preserve or propagate.

### 10.3 Tombstone Expiry

Tombstones older than **30 days** (`TOMBSTONE_EXPIRY`) are hard-deleted. By
this point every peer will have received the tombstone and applied the
deletion locally.

### 10.4 Legacy Entries

Member entries with a nil or zero `lastUpdate` (written by very early addon
versions) are hard-deleted for any member other than the local player.

---

## 11. Data Format Versioning

`GuildCrafts.DATA_FORMAT_VERSION` (integer, currently 2) tracks breaking
changes to the per-member sync payload schema. It is:

- Written into `entry.dataFormat` when sync data is stored.
- Compared during version-vector diffing: equal timestamps but
  `localEntry.dataFormat < DATA_FORMAT_VERSION` triggers a SYNC\_PULL so the
  DR can supply the up-to-date schema.
- **Not** the same as `GuildCrafts.VERSION` (wire protocol version).

Increment `DATA_FORMAT_VERSION` when the structure of a member entry or its
profession/recipe sub-tables changes in a way that requires peers to re-share
their data even if their scan timestamps have not changed.

---

## 12. User Preferences

Stored in the AceDB profile scope (per-character by default):

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `showOnlineOnly` | boolean | false | Filter member list to online-only. |
| `expansionFilter` | table | `{ ORIG=true, TBC=true }` | Which recipe expansions to show. |
| `showTooltipCrafters` | boolean | true | Show crafter list in item tooltips. |

Minimap preferences (position and visibility) are stored at `db.global.minimap`
so they persist across all profiles and characters.

---

## 13. Thresholds Reference

| Constant | Value | Description |
|----------|-------|-------------|
| `STALE_DISPLAY_THRESHOLD` | 30 days | Age at which a member's data shows "[Nd ago]" tag in the UI. |
| `EX_GUILD_GRACE_PERIOD` | 7 days | Absent-from-roster grace window before tombstone is written. |
| `INACTIVE_MEMBER_THRESHOLD` | 45 days | No-scan threshold for still-in-guild members before hard-delete. |
| `TOUCH_BROADCAST_THRESHOLD` | 25 days | Data age above which a no-new-recipes scan broadcasts a timestamp touch. |
| `TOMBSTONE_EXPIRY` | 30 days | Age after which a tombstone is hard-deleted. |
| `DATA_FORMAT_VERSION` | 2 | Current member entry schema version. |
| Partial-scan ratio | 50% | Minimum ratio of incoming:existing recipe count to accept a merge. |
