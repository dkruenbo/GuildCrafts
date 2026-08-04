# GuildCrafts — Classic Era / Hardcore / SoD Migration Guide

> Target: Classic Era, Hardcore, Season of Discovery (interface version `11507`, patch 1.15.x)
> Current: TBC Classic (interface version `20506`)

All three game modes share the same 1.15.x client — one build covers Classic Era, Hardcore, and Season of Discovery.

---

## Summary of changes

| Area | Type | Effort |
|------|------|--------|
| TOC interface version | Mechanical | 2 min |
| Remove Jewelcrafting from tracked professions | Mechanical | 5 min |
| Replace specialisation table | Replace data | 30 min |
| Remove `[TBC]` expansion filter | Mechanical + UI | 30 min |
| Generate `Data_Classic.lua` recipe IDs | Data gen | 2–4 h |
| Tooltip compat — revert to legacy-only path | Mechanical | 10 min |
| Bump `DATA_FORMAT_VERSION` | Mechanical | 5 min |
| Version bump + changelog | Mechanical | 5 min |

---

## Multi-TOC strategy

GuildCrafts uses a **multi-TOC** layout — one addon folder, multiple `.toc` files. The WoW client auto-loads the TOC matching its interface version. All code lives on `main`; no per-version branches.

```
GuildCrafts/
  GuildCrafts.toc              # TBC (current, Interface: 20506)
  GuildCrafts_Vanilla.toc      # Classic Era / Hardcore / SoD (Interface: 11507)
  GuildCrafts_Wrath.toc        # WotLK Classic (Interface: 30403)
  GuildCrafts_Mists.toc        # MoP Classic (Interface: ~50400)
```

Shared `.lua` files are listed in every TOC. Version-specific data files (e.g. `Data_TBC.lua`) are only listed in the TOCs that need them. Version-specific behaviour in shared code uses runtime guards (`WOW_PROJECT_ID`, API existence checks).

**CurseForge:** one project, one zip upload containing all TOC files. CurseForge auto-selects the right build per user.

---

## Task 1 — Create `GuildCrafts_Vanilla.toc`

Create a new file `GuildCrafts/GuildCrafts_Vanilla.toc`. It lists the same shared files as the TBC TOC but **omits** `Data_TBC.lua`:

```
## Interface: 11507
## Title: GuildCrafts
## Notes: Track all learned recipes across guild members' professions
## Author: GuildCrafts Team
## Version: @VERSION@
## SavedVariables: GuildCraftsDB
## SavedVariablesPerCharacter: GuildCraftsCharDB
## X-Category: Guild

# Libraries
Libs\embeds.xml

# Core modules
Core.lua
Data.lua
SyncPausePolicy.lua
Comms.lua
Favorites.lua
Tooltip.lua
MinimapButton.lua

# UI
UI\MainFrame.lua
```

Notice: no `Data_TBC.lua` — Classic Era has no TBC recipes.

---

## Task 2 — Version-gate profession lists

Jewelcrafting does not exist in Classic Era (added in TBC). Since shared code is loaded by all TOCs, **guard the profession list at runtime** instead of deleting entries.

### 2a — `GuildCrafts/Data.lua`

After building the base tables, add a version guard:

```lua
-- Remove professions that don't exist on this client
local expansionLevel = GetClassicExpansionLevel and GetClassicExpansionLevel() or 99
if expansionLevel < 1 then  -- Classic Era (expansion 0)
    TRACKED_PROFESSIONS["Jewelcrafting"] = nil
    PROFESSION_SPELL_IDS["Jewelcrafting"] = nil
    -- Also rebuild PRIMARY_PROF_NAMES without JC
end
if expansionLevel < 2 then  -- pre-WotLK
    TRACKED_PROFESSIONS["Inscription"] = nil
    PROFESSION_SPELL_IDS["Inscription"] = nil
end
```

### 2b — `GuildCrafts/UI/MainFrame.lua`

The UI is already data-driven from `PRIMARY_PROF_NAMES` and `TRACKED_PROFESSIONS`. Once those tables are version-gated in `Data.lua`, the UI automatically excludes missing professions. No UI changes needed.

---

## Task 3 — Replace the specialisation table

The TBC specialisation table includes Alchemy specs (Potion/Elixir/Transmutation Master) which were added in TBC and do not exist in Vanilla/Classic. Blacksmithing, Engineering, and Leatherworking specs do exist in Classic.

**Replace** the entire `SPECIALISATION_SPELLS` table with:

```lua
-- Classic Era profession specialisations keyed by spellID
-- Alchemy has no specs in Classic (added in TBC).
local SPECIALISATION_SPELLS = {
    -- Blacksmithing
    [9787]  = { prof = "Blacksmithing", spec = "Armorsmith",    desc = "Specialises in crafting plate armor." },
    [9788]  = { prof = "Blacksmithing", spec = "Weaponsmith",   desc = "Specialises in crafting weapons." },
    -- Engineering
    [20219] = { prof = "Engineering",   spec = "Gnomish Engineer", desc = "Unlocks Gnomish gadgets and backfiring devices." },
    [20222] = { prof = "Engineering",   spec = "Goblin Engineer",  desc = "Unlocks explosive Goblin devices and launchers." },
    -- Leatherworking
    [10656] = { prof = "Leatherworking", spec = "Dragonscale Leatherworking", desc = "Specialises in dragonscale mail armor." },
    [10658] = { prof = "Leatherworking", spec = "Elemental Leatherworking",   desc = "Specialises in elemental leather armor." },
    [10660] = { prof = "Leatherworking", spec = "Tribal Leatherworking",      desc = "Specialises in tribal leather armor." },
    -- Tailoring — no specialisations in Classic (added in TBC)
}
```

> **Verify spell IDs in-game before shipping.** Use `/script print(IsSpellKnown(9787))` on a Classic Era character with the Armorsmith spec to confirm.

---

## Task 4 — Remove `[TBC]` expansion filter

Classic Era has no TBC recipes. The expansion filter system should either be removed entirely or simplified to show only `"ORIG"` recipes.

### 4a — `Data_TBC.lua` excluded from Vanilla TOC

`GuildCrafts_Vanilla.toc` (Task 1) already omits `Data_TBC.lua`. The file is present in the addon folder but never loaded on Classic Era. `GuildCrafts.TBC_ITEM_IDS` will be `nil`.

### 4b — `GetExpansionTag` handles nil gracefully

The existing `GetExpansionTag` already returns `"ORIG"` when `GuildCrafts.TBC_ITEM_IDS` is nil (since `Data_TBC.lua` is not loaded). Verify this is the case; if not, add a nil guard:

```lua
function Data:GetExpansionTag(_profName, recipeKey)
    local ids = GuildCrafts.TBC_ITEM_IDS
    if not ids then return "ORIG" end
    return ids[recipeKey] and "TBC" or "ORIG"
end
```

### 4c — Hide expansion filter on Classic Era

With only `"ORIG"` recipes, the expansion filter buttons are pointless. Hide them at runtime:

```lua
-- In CreateTopBar or wherever expansion buttons are created:
if not GuildCrafts.TBC_ITEM_IDS then
    -- No expansion data loaded → hide all filter buttons
    return
end
```

### 4d — `DB_DEFAULTS` — version-gate defaults

Use a runtime guard when setting defaults:
```lua
expansionFilter = GuildCrafts.TBC_ITEM_IDS
    and { ORIG = true, TBC = true }
    or  { ORIG = true },
```

---

## Task 5 — Tooltip compat — legacy path only

Classic Era 1.15.x **originally** used the legacy `OnTooltipSetItem` hook. However, as of patch 1.15.9 (which aligned with TBC 2.5.6), Classic Era **also** has `TooltipDataProcessor`.

**Verdict:** the existing runtime guard in `Tooltip.lua` handles both paths correctly. If the Classic Era client is on 1.15.9+, it uses the modern path; if on an earlier build, it uses the legacy path. **No changes needed.**

However, verify in-game which path fires on the target Classic Era build. If `TooltipDataProcessor` is nil on the target build, the legacy path handles it. If present, the modern path handles it. Either way, the existing code is correct.

---

## Task 6 — Enchanting — CRAFT_SHOW path

Classic Era Enchanting uses the `CRAFT_SHOW` event and the separate Craft API (`GetNumCrafts`, `GetCraftInfo`, etc.), identical to TBC. In the multi-TOC model, `CRAFT_SHOW` registration must be **guarded at runtime** so it only fires on clients that have the Craft API:

```lua
-- Core.lua OnInitialize
if GetNumCrafts then
    self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
end
```

This guard allows the same `Core.lua` to be loaded on WotLK/MoP (where `GetNumCrafts` is nil) without error.

---

## Task 7 — Generate recipe data

Classic Era needs its own recipe ID lookup table. Two approaches:

### Option A — Generate `Data_Classic.lua` from wago.tools

Same pipeline as the WotLK generator, but targeting the 1.15.x build:

```bash
python3 tools/gen_classic_spells.py
# outputs GuildCrafts/Data_Classic.lua
```

Use the Classic Era build number (e.g. `1.15.7.57361` — verify at wago.tools). Filter `SkillLineAbility` to Classic-only profession skill line IDs (same IDs as TBC, minus Jewelcrafting 755).

The output file provides `GuildCrafts.CLASSIC_ITEM_IDS` — but since there's no expansion filter to distinguish (all recipes are `"ORIG"`), this table is only needed if you want to **exclude** non-Classic recipes that might leak in from a peer running a TBC client.

### Option B — Reuse existing data

Since all Classic recipes are a subset of TBC recipes, and `GetExpansionTag` returns `"ORIG"` for everything, you can skip the data file entirely. All recipes scanned in Classic Era are Vanilla recipes by definition. The existing scan logic will work without any recipe ID table.

**Recommended:** Option B for the initial release. A dedicated `Data_Classic.lua` is only needed if cross-version sync contamination becomes a concern.

---

## Task 8 — `DATA_FORMAT_VERSION`

In the multi-TOC model, `DATA_FORMAT_VERSION` does **not** need a per-version bump. Classic Era guilds never sync with TBC guilds — they run on different servers. The wire format is identical; the same `DATA_FORMAT_VERSION = 2` works for all versions.

Only bump it if the **wire protocol itself** changes (new fields, different serialisation, etc.).

---

## Task 9 — Version bump

All TOC files share one version number. Bump once across all TOCs:

**`GuildCrafts/Core.lua`:**
```lua
GuildCrafts.DISPLAY_VERSION = "X.Y.Z"
```

Every TOC uses the same `## Version: X.Y.Z`. The addon is one product with one version, shipping for multiple game versions.

---

## What does NOT need to change

- **Comms protocol** — sync, DR election, chunked transfers, RESUME recovery are all expansion-agnostic
- **AceDB schema** — per-member data structure is identical
- **Recipe key system** — positive itemID / negative spellID works identically
- **Reagent scanning** — `ScanTradeSkillReagents` uses standard TradeSkill APIs unchanged in Classic
- **Cooldown scanning** — `ScanTradeSkillCooldowns` uses `GetTradeSkillCooldown` unchanged in Classic
- **Enchanting Craft API** — identical to TBC; `ScanCraft()` works as-is
- **Favorites** — expansion-agnostic
- **MinimapButton** — unchanged
- **All Ace3 libraries** — Classic-compatible
- **LibDeflate** — Classic-compatible

---

## Classic Era edge cases

### Mining / Smelting

Mining tracks Smelting recipes via `TRADE_SKILL_SHOW`. The `TRADESKILL_TITLE_SPELL_IDS` alias ("Smelting" → "Mining") must be preserved. This is unchanged from TBC.

### Beast Training (Hunter)

Classic Era has Beast Training, which fires `CRAFT_SHOW`. The existing guard in `ScanCraft()` that checks `GetCraftSkillLine(1)` and rejects non-Enchanting craft windows handles this correctly. **No changes needed.**

### Skill cap display

Classic professions cap at 300/300 (not 375). The addon reads `maxSkillLevel` from `GetTradeSkillLine()` / `GetSkillLineInfo()` at scan time — no hardcoded values. **No changes needed.**

### Season of Discovery additions

SoD adds new recipes and rune abilities that are not present in Classic Era or Hardcore. These are still scanned and synced normally via `TRADE_SKILL_SHOW`. The recipe key system handles them automatically. No special SoD-specific code is needed — the only difference is which recipes exist in the game data.

---

## Recommended test checklist

1. All professions appear in left panel (no Jewelcrafting)
2. Opening each profession window scans recipes correctly
3. Enchanting scans via `CRAFT_SHOW` (Craft API path)
4. No expansion filter buttons visible (or only `[Vanilla]` always-on)
5. Blacksmithing/Engineering/Leatherworking specs detected correctly
6. No Alchemy specs detected (they don't exist in Classic)
7. Sync works between two Classic Era clients
8. `/gc debug` shows no Lua errors
9. Beast Training (Hunter): opening the Beast Training window triggers no scan, no DB entry, no Lua error
10. Skill cap display: verify a maxed character shows `300/300`
11. Tooltip crafter list appears when hovering items
