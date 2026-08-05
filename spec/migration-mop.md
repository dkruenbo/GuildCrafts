# GuildCrafts — MoP Classic Migration Guide

> Target: Mists of Pandaria Classic (interface version `~50400`, TBD)
> Current: TBC Classic (interface version `20506`)

MoP Classic launched in 2026 and represents the biggest API migration for GuildCrafts. MoP uses the **`C_TradeSkillUI` namespace** for all profession interaction — a full replacement of the classic `GetNumTradeSkills` / `GetTradeSkillInfo` API. Enchanting also unifies under the same system (no more separate Craft API).

---

## Summary of changes

| Area | Type | Effort |
|------|------|--------|
| TOC interface version | Mechanical | 2 min |
| **Complete scanning rewrite** — `C_TradeSkillUI` | Major rewrite | 6–12 h |
| Delete Craft API path (Enchanting) | Delete code | 10 min |
| Replace `GetSkillLineInfo` detection with `GetProfessions` / `GetProfessionInfo` | Rewrite | 2–4 h |
| Add Inscription + Archaeology to tracked list | Mechanical | 10 min |
| Replace specialisation table | Replace data | 30 min |
| Generate `Data_MOP.lua` recipe IDs | Data gen | 2–4 h |
| Expansion filter — add Pandaria | UI + data | 1–2 h |
| Bump `DATA_FORMAT_VERSION` | Mechanical | 5 min |
| **Built-in guild recipe viewer overlap** | Design decision | TBD |
| Reduce `SYNC_CHUNK_SIZE` | Mechanical | 5 min |
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

Shared `.lua` files are listed in every TOC. Version-specific data files (e.g. `Data_MOP.lua`) are only listed in the TOCs that need them. Version-specific behaviour in shared code uses runtime guards (`C_TradeSkillUI` existence, `GetClassicExpansionLevel()`, API checks).

**CurseForge:** one project, one zip upload containing all TOC files. CurseForge auto-selects the right build per user.

---

## Task 1 — Create `GuildCrafts_Mists.toc`

Create a new file `GuildCrafts/GuildCrafts_Mists.toc`. It lists the shared files plus all expansion data files:

```
## Interface: 50400
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
Data_TBC.lua
Data_WOTLK.lua
Data_MOP.lua
SyncPausePolicy.lua
Comms.lua
Favorites.lua
Tooltip.lua
MinimapButton.lua

# UI
UI\MainFrame.lua
```

> **Exact interface number TBD.** Verify at Blizzard's official build info or `GetBuildInfo()` on a MoP Classic character. Likely in the `504xx` range.

The MoP TOC includes all data files (`Data_TBC.lua`, `Data_WOTLK.lua`, `Data_MOP.lua`) because MoP characters can know recipes from all previous expansions.

---

## Task 2 — Complete scanning rewrite (`C_TradeSkillUI`)

This is the largest single change. MoP replaces the entire profession scanning API.

### What's gone

These functions **do not exist** on the MoP Classic client:

| Removed Function | Was Used For |
|---|---|
| `GetNumTradeSkills()` | Number of items in the tradeskill window |
| `GetTradeSkillInfo(index)` | Recipe name, type, and availability |
| `GetTradeSkillItemLink(index)` | Item link for a recipe |
| `GetTradeSkillRecipeLink(index)` | Recipe link |
| `GetTradeSkillNumReagents(index)` | Reagent count |
| `GetTradeSkillReagentInfo(index, i)` | Reagent details |
| `GetTradeSkillCooldown(index)` | Cooldown remaining |
| `GetTradeSkillLine()` | Current tradeskill name + skill levels |
| `GetNumCrafts()` | (Enchanting Craft window count) |
| `GetCraftInfo(index)` | (Enchanting Craft window info) |
| `GetCraftItemLink(index)` | (Enchanting Craft window link) |

### What replaces them

| New Function | Purpose |
|---|---|
| `C_TradeSkillUI.GetAllRecipeIDs()` | Returns array of all recipe spell IDs |
| `C_TradeSkillUI.GetRecipeInfo(recipeSpellID)` | Returns table with name, type, learned status, etc. |
| `C_TradeSkillUI.GetRecipeItemLink(recipeID)` | Returns item link for recipe output |
| `C_TradeSkillUI.GetRecipeCooldown(recipeID)` | Cooldown remaining |
| `C_TradeSkillUI.OpenTradeSkill(skillLineID)` | Opens a profession programmatically |
| `C_TradeSkillUI.CloseTradeSkill()` | Closes the profession window |
| `C_TradeSkillUI.IsTradeSkillReady()` | Returns true when data is loaded |
| `C_TradeSkillUI.GetBaseProfessionInfo()` | Returns profession name, icon, etc. |
| `C_TradeSkillUI.GetTradeSkillLineForRecipe(recipeID)` | Returns skill line info for a recipe |

### Rewriting `ScanTradeSkill`

The current `ScanTradeSkill()` iterates by index (`for i = 1, GetNumTradeSkills()`). The MoP replacement iterates by recipe ID:

```lua
-- Pseudocode for MoP scanning
function Data:ScanTradeSkill()
    if not C_TradeSkillUI.IsTradeSkillReady() then return end

    local profInfo = C_TradeSkillUI.GetBaseProfessionInfo()
    if not profInfo or not profInfo.professionName then return end

    local profName = profInfo.professionName
    if not self.TRACKED_PROFESSIONS[profName] then return end

    local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs()
    if not recipeIDs then return end

    local recipes = {}
    for _, recipeID in ipairs(recipeIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and info.learned then
            -- info.recipeID is the spell ID
            -- Use negative spell ID as recipe key (same convention)
            local itemLink = C_TradeSkillUI.GetRecipeItemLink(recipeID)
            local key
            if itemLink then
                local itemID = tonumber(itemLink:match("item:(%d+)"))
                key = itemID or -recipeID
            else
                key = -recipeID
            end
            recipes[key] = true
        end
    end

    -- Store into member entry
    ...
end
```

### Events to register

MoP fires different events than TBC:

| Replace | With |
|---|---|
| `TRADE_SKILL_SHOW` | `TRADE_SKILL_LIST_UPDATE` or `TRADE_SKILL_SHOW` (verify) |
| `TRADE_SKILL_UPDATE` | `TRADE_SKILL_LIST_UPDATE` |
| `CRAFT_SHOW` | **Delete** — no longer used |
| `CRAFT_UPDATE` | **Delete** |

> **Verify on MoP Classic:** check which events actually fire when opening a profession window. Use `/script local f=CreateFrame("Frame"); f:RegisterAllEvents(); f:SetScript("OnEvent", function(_, e) if e:find("TRADE") or e:find("CRAFT") then print(e) end end)`.

---

## Task 3 — Guard the Craft API path (Enchanting)

In MoP, Enchanting uses the same `C_TradeSkillUI` API as all other professions. The Craft API path is already behind a runtime guard (`if GetNumCrafts then`) from the multi-TOC changes — it simply never fires on MoP where `GetNumCrafts` is nil.

**No additional changes needed** — the guard from the WotLK/Classic Era multi-TOC work handles this automatically.

---

## Task 4 — Replace profession detection

### Current approach (TBC)

TBC uses `GetSkillLineInfo()` in a loop over `GetNumSkillLines()` to discover which professions the player has. This API does not exist in MoP.

### MoP approach

Use `GetProfessions()` + `GetProfessionInfo()`:

```lua
function Data:GetPlayerProfessions()
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    local professions = {}
    for _, idx in ipairs({prof1, prof2}) do
        if idx then
            local name, icon, skillLevel, maxSkillLevel, numAbilities, spellOffset, skillLine,
                  skillModifier, specIndex, specOffset = GetProfessionInfo(idx)
            if name and self.TRACKED_PROFESSIONS[name] then
                professions[name] = {
                    skillLevel = skillLevel,
                    maxSkillLevel = maxSkillLevel,
                    skillLine = skillLine,
                    specIndex = specIndex,
                }
            end
        end
    end
    return professions
end
```

> **`GetProfessionInfo` return values:** `name, icon, skillLevel, maxSkillLevel, numAbilities, spelloffset, skillLine, skillModifier, specializationIndex, specializationOffset`

---

## Task 5 — Add Inscription + Archaeology

MoP has both Inscription and Archaeology. Inscription has craftable items; Archaeology does not and should **not** be tracked.

### 5a — Add Inscription to tracked professions

**`GuildCrafts/Data.lua`:**

```lua
TRACKED_PROFESSIONS["Inscription"] = true
PROFESSION_SPELL_IDS["Inscription"] = 45357
```

Add `"Inscription"` to `PRIMARY_PROF_NAMES`.

### 5b — Add Inscription icon

**`GuildCrafts/UI/MainFrame.lua`:**

```lua
["Inscription"] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
```

### 5c — Do NOT track Archaeology

Archaeology is accessed via `GetProfessions()` return index 3, but it doesn't have craftable recipes in the same sense. Exclude it from `TRACKED_PROFESSIONS`.

---

## Task 6 — Replace specialisation table

MoP specialisations are narrower than TBC. Alchemy Master specs from TBC persist in WotLK and MoP. Engineering Gnomish/Goblin persists. All others were removed by MoP.

```lua
local SPECIALISATION_SPELLS = {
    -- Alchemy (persist from TBC through MoP)
    [28672] = { prof = "Alchemy", spec = "Potion Master",        desc = "Specialises in creating extra potions." },
    [28675] = { prof = "Alchemy", spec = "Elixir Master",        desc = "Specialises in creating extra elixirs." },
    [28677] = { prof = "Alchemy", spec = "Transmutation Master", desc = "Specialises in creating extra transmutations." },
    -- Engineering
    [20219] = { prof = "Engineering", spec = "Gnomish Engineer",  desc = "Unlocks Gnomish gadgets." },
    [20222] = { prof = "Engineering", spec = "Goblin Engineer",   desc = "Unlocks Goblin explosives." },
    -- Blacksmithing — specs removed in 4.0.1 (Cata prepatch)
    -- Leatherworking — specs removed in 4.0.1
    -- Tailoring — specs removed in 4.0.1
}
```

> **Verify on MoP Classic:** check `IsSpellKnown(28672)` on an Alchemy Potion Master. If the spec system was fully removed in MoP Classic (not just Cata), remove Alchemy specs too. Blizzard's MoP Classic re-release may or may not preserve these.

---

## Task 7 — Generate `Data_MOP.lua`

MoP spans five expansions of recipes: Vanilla, TBC, WotLK, Cata, and MoP.

### Recipe pipeline

```bash
python3 tools/gen_mop_spells.py
# outputs GuildCrafts/Data_MOP.lua
```

Use wago.tools with the MoP Classic build number. Filter `SkillLineAbility` for all profession skill lines. The output file provides `GuildCrafts.MOP_ITEM_IDS` with expansion tags:

```lua
GuildCrafts.MOP_ITEM_IDS = {
    [12345] = "ORIG",    -- Vanilla recipe
    [23456] = "TBC",     -- TBC recipe
    [34567] = "WOTLK",   -- WotLK recipe
    [45678] = "CATA",    -- Cata recipe
    [56789] = "MOP",     -- MoP recipe
}
```

Add to TOC:
```
Data_MOP.lua
```

---

## Task 8 — Expansion filter — add Cata and Pandaria

The TBC expansion filter has `ORIG` / `TBC`. MoP needs five tiers.

### 8a — Update `DB_DEFAULTS`

```lua
expansionFilter = { ORIG = true, TBC = true, WOTLK = true, CATA = true, MOP = true },
```

### 8b — Update `GetExpansionTag`

```lua
function Data:GetExpansionTag(_profName, recipeKey)
    local ids = GuildCrafts.MOP_ITEM_IDS
    if not ids then return nil end
    return ids[recipeKey]   -- returns "ORIG", "TBC", "WOTLK", "CATA", or "MOP"
end
```

### 8c — Update UI filter buttons

Create five expansion filter buttons. Consider a dropdown instead of five separate buttons to save horizontal space:

```
[All] [Vanilla] [TBC] [WotLK] [Cata] [MoP]
```

Or a single dropdown:
```
Expansion: [All ▾]
            Vanilla
            TBC
            WotLK
            Cata
            MoP
```

---

## Task 9 — Reduce `SYNC_CHUNK_SIZE`

MoP characters potentially know recipes from all five expansions. The total recipe count per profession is significantly higher than TBC. Reduce chunk size to avoid hitting the 4000-byte AceComm limit:

**File:** `GuildCrafts/Comms.lua`

```lua
SYNC_CHUNK_SIZE = 2   -- was 5
```

> **Profile payload size in-game** before deciding. If the average member payload fits in 3 chunks at size 3, keep it at 3. If it blows past the limit, drop to 2.

---

## Task 10 — `DATA_FORMAT_VERSION`

In the multi-TOC model, `DATA_FORMAT_VERSION` does **not** need a per-version bump. MoP guilds never sync with TBC or WotLK guilds — they run on different servers. The same `DATA_FORMAT_VERSION = 2` works for all versions.

Only bump it if the **wire protocol itself** changes (new fields, different serialisation, etc.). The `C_TradeSkillUI` scanning rewrite changes how recipes are **collected** locally, but the **wire format** (recipe keys, member entries, sync messages) stays the same.

---

## Task 11 — Version bump

All TOC files share one version number. Bump once in `Core.lua`:

**`GuildCrafts/Core.lua`:**
```lua
GuildCrafts.DISPLAY_VERSION = "X.Y.Z"
```

Every TOC uses the same `## Version: X.Y.Z`. The addon is one product with one version, shipping for multiple game versions.

---

## Task 12 — Design decision: built-in guild recipe viewer

MoP (and WotLK/Cata before it) have a **built-in guild recipe viewer** in the guild tab. Blizzard's native API:

- `QueryGuildRecipes()` — requests guild recipe data from server
- `GetNumGuildTradeSkill()` — number of listed tradeskills
- `GetGuildTradeSkillInfo(index)` — returns skillID, player, online status
- `CanViewGuildRecipes(skillID)` — permission check
- `ViewGuildRecipes(skillLineID)` — opens recipe view for that profession
- `GetGuildMemberRecipes(name, skillLineID)` — returns recipes for a specific member
- `GetGuildRecipeInfoPostQuery()` — returns info after a query completes
- `GetGuildRecipeMember(index)` — returns member names for a specific recipe

### So what's the point of GuildCrafts on MoP?

**GuildCrafts still adds value because:**

1. **Offline coverage** — Blizzard's built-in viewer only shows online members. GuildCrafts caches and syncs data for offline members too.
2. **Search across all professions** — Blizzard's viewer requires you to drill into one profession at a time, then one member at a time. GuildCrafts can search "who can craft [Enchant Weapon: Jade Spirit]?" in one step.
3. **Favorites** — star recipes you care about.
4. **Tooltip integration** — hover over any item and see who in the guild can craft it, without opening the guild panel.
5. **Cross-profession view** — see all crafters for a specific output item, regardless of which profession crafts it.

### Optional: seed from Blizzard API

Consider using `QueryGuildRecipes()` / `GetGuildMemberRecipes()` to **seed** the local DB with data from online guild members, reducing the need for full sync. This is an optimisation, not a requirement.

---

## What does NOT need to change

- **Comms protocol** — sync, DR election, chunked transfers, RESUME — all expansion-agnostic
- **AceDB schema** — per-member data structure is identical
- **Recipe key system** — positive itemID / negative spellID works identically
- **Favorites** — expansion-agnostic
- **MinimapButton** — unchanged
- **All Ace3 libraries** — MoP Classic-compatible
- **LibDeflate** — MoP Classic-compatible
- **SyncPausePolicy** — combat/instance/zone guards work identically

---

## MoP-specific edge cases

### Daily cooldowns

MoP has several daily profession cooldowns (e.g. Imperial Silk, Balanced Trillium Ingot, Jard's Peculiar Energy Source). These are scanned by `C_TradeSkillUI.GetRecipeCooldown(recipeID)`. Cooldown scanning requires the profession window to be open. This is unchanged in principle from TBC, but the API call is different:

```lua
-- TBC:   local cooldown = GetTradeSkillCooldown(index)
-- MoP:   local cooldown = C_TradeSkillUI.GetRecipeCooldown(recipeID)
```

### Discovery recipes

Some MoP recipes are learned through discovery (e.g. Alchemist's Trillium researches). These recipes appear in `C_TradeSkillUI.GetAllRecipeIDs()` once learned. No special handling needed — they're scanned like any other learned recipe.

### Spirits of Harmony crafting

Some recipes require Spirits of Harmony (BoP currency). This affects reagent scanning if displayed in the future, but the current GuildCrafts system only tracks which recipes are known, not reagent availability. **No changes needed.**

### Monk class

MoP adds Monks. No impact on GuildCrafts — professions are not class-restricted (aside from DK Runeforging, which GuildCrafts already ignores).

### Pandaren race

MoP adds Pandaren, who start without a faction. Pandaren on the Wandering Isle (level 1–12) cannot join guilds. Not a concern for GuildCrafts — the addon only activates for guild members.

### Recipe count growth

A MoP character who has been playing since Vanilla could know 500+ recipes across a single profession. This is significantly more than the ~150–200 typical in TBC.

**Impact on sync payload:**
- Each recipe key takes ~6–8 bytes serialized
- 500 recipes ≈ 3–4 KB per profession per member
- A member with 2 professions ≈ 6–8 KB total
- Chunked transfer (at `SYNC_CHUNK_SIZE = 2`) means 3–4 chunks per such member

**Monitor for:** AceComm throttling, sync timeouts for large guilds with many professions.

### Tooltip API

MoP Classic likely uses `TooltipDataProcessor.AddTooltipPostCall`. The existing runtime guard in `Tooltip.lua` should handle this. Verify in-game.

---

## Recommended test checklist

1. All professions appear in left panel (including Inscription, excluding Archaeology)
2. Opening a profession window triggers scan via `C_TradeSkillUI`
3. `TRADE_SKILL_SHOW` / `TRADE_SKILL_LIST_UPDATE` events fire correctly
4. No references to `GetNumTradeSkills` / `GetTradeSkillInfo` remain
5. No references to `GetNumCrafts` / `GetCraftInfo` remain
6. Enchanting scans via `C_TradeSkillUI` (same as all professions)
7. `GetProfessions()` / `GetProfessionInfo()` detect both professions correctly
8. Alchemy/Engineering specs detected (if they persist in MoP Classic)
9. Expansion filter shows five tiers: Vanilla / TBC / WotLK / Cata / MoP
10. Recipe count displays correctly for high-recipe-count characters
11. Sync works between two MoP Classic clients
12. Chunk transfer completes for a member with 500+ recipes
13. Tooltip crafter list appears when hovering items
14. `/gc debug` shows no Lua errors
15. Profession skill level shows correct cap (e.g., 600/600 for MoP max)

---

## Open questions — verify on live MoP Classic

These items cannot be determined from documentation alone. Test on a MoP Classic character:

1. **Exact interface version** — `GetBuildInfo()` fourth return value
2. **Which events fire** when opening a profession window — `TRADE_SKILL_SHOW`? `TRADE_SKILL_LIST_UPDATE`? Both?
3. **`C_TradeSkillUI.GetRecipeInfo` return format** — what fields are in the returned table? (`learned`, `name`, `recipeID`, `skillLineAbilityID`, `difficulty`, etc.)
4. **Do Alchemy specs persist** in MoP Classic? They were removed in Cata retail (4.0.3) but may be present in MoP Classic as a re-release
5. **`TooltipDataProcessor`** — is it present on the MoP Classic client?
6. **`GetProfessions()`** — does it exist and return indices correctly?
7. **`C_TradeSkillUI.OpenTradeSkill(skillLineID)`** — can we programmatically open a profession for scanning without the user manually opening it?
8. **AceComm payload size** — what is the actual byte size of a serialized 500-recipe member entry?
