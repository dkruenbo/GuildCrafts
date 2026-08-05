        # GuildCrafts — WotLK Classic Migration Guide

        > Target: WotLK Classic (interface version `30403`, patch 3.4.3)
        > Current: TBC Classic (interface version `20505`)

        This document is a complete, ordered task list. Each item includes the exact file, line reference, and the code change required. No investigation needed — start at Task 1 and work down.

        ---

        ## Summary of changes

        | Area | Type | Effort |
        |------|------|--------|
        | TOC interface version | Mechanical | 2 min |
        | Delete entire Craft API path (Enchanting) | Delete code | 30 min |
        | Add Inscription profession | Additive | 30 min |
        | Replace specialisation table | Replace data | 1–2 h |
        | Add `[Wrath]` expansion filter + `Data_WOTLK.lua` | Additive + data gen | 2–4 h |
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

        Shared `.lua` files are listed in every TOC. Version-specific data files (e.g. `Data_WOTLK.lua`) are only listed in the TOCs that need them. Version-specific behaviour in shared code uses runtime guards (`WOW_PROJECT_ID`, API existence checks).

        **CurseForge:** one project, one zip upload containing all TOC files. CurseForge auto-selects the right build per user.

        ---

        ## Task 1 — Create `GuildCrafts_Wrath.toc`

        Create a new file `GuildCrafts/GuildCrafts_Wrath.toc`. It lists the same shared files as the TBC TOC, plus `Data_WOTLK.lua`:

        ```
        ## Interface: 30403
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
        SyncPausePolicy.lua
        Comms.lua
        Favorites.lua
        Tooltip.lua
        MinimapButton.lua

        # UI
        UI\MainFrame.lua
        ```

        The WotLK TOC includes **both** `Data_TBC.lua` and `Data_WOTLK.lua` because WotLK characters can know Vanilla and TBC recipes too.

        ---

        ## Task 2 — Guard the Craft API path behind runtime check

        In WotLK, Enchanting uses the standard `TRADE_SKILL_SHOW` / `GetTradeSkillLine` API like every other profession. The `CRAFT_SHOW` / Craft API path is only needed on Vanilla and TBC clients. In the multi-TOC model, **guard it at runtime** instead of deleting it:

        ### 2a — `GuildCrafts/Core.lua`

        **Wrap** the `CRAFT_SHOW` event registration in an API existence check:
        ```lua
        -- Only register CRAFT_SHOW on clients that have the Craft API (Vanilla/TBC)
        if GetNumCrafts then
            self:RegisterEvent("CRAFT_SHOW", "OnCraftShow")
        end
        ```

        The `OnCraftShow` handler and `ScanCraft()` function can remain in the code — they simply never fire on WotLK+ clients where `GetNumCrafts` is nil.

        ### 2b — `GuildCrafts/Data.lua`

        **Wrap** `ScanCraft()` in a guard:
        ```lua
        function Data:ScanCraft()
            if not GetNumCrafts then return end
            -- ... existing implementation
        end
        ```

        The Craft API local references (`GetNumCrafts`, `GetCraftInfo`, etc.) should use safe lookups:
        ```lua
        local GetNumCrafts = GetNumCrafts    -- nil on WotLK+, that's fine
        local GetCraftInfo = GetCraftInfo
        ```

        ---

        ## Task 3 — Add Inscription

        Inscription (Scribes) is a new primary profession added in WotLK (patch 3.0).

        ### 3a — `GuildCrafts/Data.lua`

        **Add** to `TRACKED_PROFESSIONS` (around line 55, alongside other primary crafting profs):
        ```lua
        ["Inscription"]    = true,
        ```

        **Add** to `PROFESSION_SPELL_IDS` (around line 81, the locale-map lookup table):
        ```lua
        ["Inscription"]    = 45357,   -- rank-1 Inscription spell ID (WotLK)
        ```

        **Add** to `PRIMARY_PROF_NAMES` (line 1544):
        ```lua
        local PRIMARY_PROF_NAMES = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering",
                                    "Inscription", "Jewelcrafting", "Leatherworking", "Tailoring" }
        ```

        ### 3b — `GuildCrafts/UI/MainFrame.lua`

        **Add** to `PROFESSION_ICONS` (around line 662, inside the Primary block):
        ```lua
        ["Inscription"]    = "Interface\\Icons\\INV_Inscription_Tradeskill01",
        ```

        The icon `INV_Inscription_Tradeskill01` is the standard WotLK Inscription icon and is present in the WotLK client.

        > **No other changes needed.** The rest of the UI, sync, and data paths are data-driven from `PRIMARY_PROF_NAMES` and `TRACKED_PROFESSIONS`. Inscription will appear in the left panel, be scanned on `TRADE_SKILL_SHOW`, synced, and searchable automatically.

        ---

        ## Task 4 — Replace the specialisation table

        The current `SPECIALISATION_SPELLS` table in `Data.lua` (lines 154–180) is entirely TBC-specific. WotLK removed all Blacksmithing sub-specs (Armorsmith/Weaponsmith/Master Swordsmith/Hammersmith/Axesmith) and all three Tailoring cloth specs (Mooncloth/Shadoweave/Spellfire) and all three Leatherworking specs. Only Alchemy and Engineering specs survive into WotLK, and WotLK adds no new profession specialisations.

        **Replace** the entire `SPECIALISATION_SPELLS` table with:

        ```lua
        -- WotLK profession specialisations keyed by spellID
        -- Each entry maps to { prof, spec, desc }
        -- Note: Blacksmithing, Leatherworking, and Tailoring lost all specs in WotLK.
        local SPECIALISATION_SPELLS = {
            -- Alchemy (unchanged from TBC — same spell IDs, same descriptions)
            [28675] = { prof = "Alchemy",     spec = "Potion Master",        desc = "Chance to create extra potions when crafting." },
            [28677] = { prof = "Alchemy",     spec = "Elixir Master",        desc = "Chance to create extra elixirs when crafting." },
            [28672] = { prof = "Alchemy",     spec = "Transmutation Master", desc = "Chance to create extra materials when transmuting." },
            -- Engineering (unchanged from TBC — same spell IDs, same descriptions)
            [20219] = { prof = "Engineering", spec = "Gnomish Engineer",     desc = "Unlocks Gnomish gadgets and backfiring devices." },
            [20222] = { prof = "Engineering", spec = "Goblin Engineer",      desc = "Unlocks explosive Goblin devices and launchers." },
        }
        ```

        > **Verify spell IDs before shipping.** The five spell IDs above were present in TBC and are expected to carry over unchanged to WotLK Classic, but confirm against the WotLK Classic API or a spell database (wowhead.com/wotlk). Use `/script print(IsSpellKnown(28675))` on a WotLK Classic PTR to verify.

        > **Silent failure mode:** if any spell ID in `PROFESSION_SPELL_IDS` is wrong, `GetSpellInfo` returns `nil`, the profession is silently excluded from the locale map, `GetOpenProfessionName()` never matches it, and the profession is never scanned — no Lua error, just missing data. This applies especially to Inscription's `45357`: verify it in-game before release with `/script print(GetSpellInfo(45357))`; the output should be `"Inscription"`.

        > **Existing saved data:** Guild members who had TBC-only specs stored (`Armorsmith`, `Dragonscale Leatherworking`, etc.) will have those spec labels silently retained in their DB entry but `DetectSpecialisations()` will clear them on next login since `IsSpellKnown` returns false. No manual migration needed.

        ---

        ## Task 5 — Add `[Wrath]` expansion filter

        The current filter system supports `"ORIG"` (Vanilla) and `"TBC"`. WotLK needs a `"WOTLK"` tier.

        This task has two parts: the data file and the UI.

        ### 5a — Generate `GuildCrafts/Data_WOTLK.lua`

        Unlike the TBC pipeline (which read from hand-curated `DataGenerated.lua` + `MasterRecipes.lua`), the WotLK data is sourced directly from the game's DBC tables via the **wago.tools REST API** — no manual curation required. Write a standalone `tools/gen_wotlk_spells.py` that hits the API and emits `Data_WOTLK.lua` directly, bypassing the intermediate Lua source files entirely.

        #### Data source: wago.tools DBC API

        wago.tools exposes every WoW game version's DBC tables as paginated JSON. Two tables give us everything needed:

        | DBC table | What we extract |
        |-----------|----------------|
        | `SkillLineAbility` | spellID → skillLine (profession ID); tells us which spells belong to which profession |
        | `SpellEffect` (effect type 24 = "create item") | spellID → `EffectItemType` (the created itemID) for non-enchanting recipes |

        Enchanting recipes produce no item — they are identified by belonging to the Enchanting skill line (ID 333) with no `EffectItemType`, the same as the existing `enchant:(%d+)` negative-key logic.

        **WotLK Classic profession skill line IDs:**
        ```
        Alchemy=171   Blacksmithing=164   Cooking=185    Enchanting=333
        Engineering=202   Herbalism=182   Inscription=773   Jewelcrafting=755
        Leatherworking=165   Mining=186   Skinning=393   Tailoring=197
        ```

        #### Step 1 — Find the correct WotLK Classic build number

        Go to **https://wago.tools/** and look for the WotLK Classic entry in the build list. The current WotLK Classic patch 3.4.3 build is typically `3.4.3.52237` (verify — Blizzard occasionally re-releases hotfix builds under a new number). Use the exact build string in all API calls below.

        #### Step 2 — Fetch SkillLineAbility (spellID → profession)

        ```
        GET https://wago.tools/db2/SkillLineAbility?build=3.4.3.52237&locale=enUS
            &filter[SkillLine]=171
            &fields=Spell,SkillLine,MinSkillLineRank
            &page=1
        ```

        Repeat for each profession skill line ID. The response is paginated JSON:
        ```json
        {
        "data": [
            { "Spell": 2259, "SkillLine": 171, "MinSkillLineRank": 1 },
            ...
        ],
        "links": { "next": "...?page=2" }
        }
        ```
        Follow `links.next` until exhausted. Collect all `Spell` IDs per skill line into a dict: `spell_to_skillline = { spellID: skillLineID }`.

        #### Step 3 — Fetch SpellEffect to get createdItemId

        ```
        GET https://wago.tools/db2/SpellEffect?build=3.4.3.52237&locale=enUS
            &filter[Effect]=24
            &fields=SpellID,EffectItemType
            &page=1
        ```

        Effect type 24 = "Create Item". Paginate until done. Build: `spell_to_item = { spellID: createdItemId }`.

        #### Step 4 — Classify as WOTLK vs already-known

        Any `spellID` in `spell_to_skillline` that is **not** already present in `tools/DataGenerated.lua` as `"ORIG"` or `"TBC"` is a WotLK recipe. Load the existing expansion tags from `DataGenerated.lua` (reuse the regex from `gen_tbc_spells.py`) and subtract:

        ```python
        known_orig_tbc = load_datagen_known_spells("tools/DataGenerated.lua")
        wotlk_spells = {sid for sid in spell_to_skillline if sid not in known_orig_tbc}
        ```

        #### Step 5 — Assign recipe keys (same logic as TBC)

        For each `spellID` in `wotlk_spells`:
        - If `spell_to_item[spellID]` exists and `> 0` → key is `+createdItemId` (positive)
        - If spell is in Enchanting skill line (333) and no item → key is `-spellID` (negative)
        - Otherwise skip (passive/buff spells that sneak into the skill line)

        #### Step 6 — Emit `GuildCrafts/Data_WOTLK.lua`

        Same structure as `Data_TBC.lua`:
        ```lua
        -- GuildCrafts/Data_WOTLK.lua
        -- Generated by tools/gen_wotlk_spells.py — do not edit by hand.
        -- Source: wago.tools DBC API, build 3.4.3.52237
        local _, _ns = ...
        local GuildCrafts = _G.GuildCrafts
        local WOTLK_ITEM_IDS = {
            [33994] = 1,   -- createdItemId (positive key)
            [-64268] = 1,  -- enchant spellId (negative key)
            ...
        }
        GuildCrafts.WOTLK_ITEM_IDS = WOTLK_ITEM_IDS
        ```

        #### Fallback: Ackis Recipe List

        If wago.tools is unavailable or has gaps (particularly for obscure Enchanting spell IDs), [Ackis Recipe List](https://github.com/Ackis/AckisRecipeList) on GitHub has a hand-curated WotLK recipe database in Lua with spellIDs, itemIDs, professions, and sources. It covers all WotLK recipes through the final patch. Parse `DB/` files as a secondary source to fill any holes.

        #### Running the generator

        ```bash
        python3 tools/gen_wotlk_spells.py
        # outputs GuildCrafts/Data_WOTLK.lua
        ```

        Requires `requests` (`pip install requests`). The script makes ~15–20 paginated API calls total (one batch per profession per table). Runtime is a few seconds.

        > **Stub file:** Until the generator is run, ship a stub so the addon loads without error:
        > ```lua
        > -- GuildCrafts/Data_WOTLK.lua
        > -- Generated by tools/gen_wotlk_spells.py — do not edit by hand.
        > -- Placeholder until WotLK recipe source data is available.
        > local WOTLK_ITEM_IDS = {}
        > GuildCrafts.WOTLK_ITEM_IDS = WOTLK_ITEM_IDS
        > ```
        > With an empty table all recipes will fall through to `"TBC"` or `"ORIG"` — correct behaviour until WotLK data is populated.

        Add the new file to `GuildCrafts/GuildCrafts.toc` after `Data_TBC.lua`:
        ```
        Data_TBC.lua
        Data_WOTLK.lua
        ```

        ### 5b — Update `GetExpansionTag` in `Data.lua`

        Current (lines 191–194):
        ```lua
        function Data:GetExpansionTag(_profName, recipeKey)
            local ids = GuildCrafts.TBC_ITEM_IDS
            if not ids then return nil end
            return ids[recipeKey] and "TBC" or "ORIG"
        end
        ```

        Replace with:
        ```lua
        function Data:GetExpansionTag(_profName, recipeKey)
            local wotlk = GuildCrafts.WOTLK_ITEM_IDS
            if wotlk and wotlk[recipeKey] then return "WOTLK" end
            local tbc = GuildCrafts.TBC_ITEM_IDS
            if tbc and tbc[recipeKey] then return "TBC" end
            return "ORIG"
        end
        ```

        ### 5c — Update `DB_DEFAULTS` in `Data.lua`

        Current (line 219):
        ```lua
        expansionFilter = { ORIG = true, TBC = true },
        ```

        Change to:
        ```lua
        expansionFilter = { ORIG = true, TBC = true, WOTLK = true },
        ```

        ### 5d — Update `UI/MainFrame.lua` — add `[Wrath]` button

        **Search bar button creation** (around line 410–448):

        The existing code creates two buttons: `tbcBtn` (width 40, rightOffset -84) and `origBtn` (width 56, rightOffset -128). Add a third `wrathBtn` to the left of both:

        ```lua
        local wotlkBtn = makeExpBtn("Wrath", -172, 46)
        wotlkBtn:SetScript("OnClick",  function() UI:ToggleExpansionFilter("WOTLK") end)
        wotlkBtn:SetScript("OnEnter",  function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
            GameTooltip:AddLine("Wrath Recipes", 1, 1, 1)
            GameTooltip:AddLine("Show Wrath of the Lich King recipes.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        wotlkBtn:SetScript("OnLeave",  function() GameTooltip:Hide() end)
        self._expFilterWOTLKBtn = wotlkBtn
        ```

        Adjust the `rightOffset` values of `tbcBtn` and `origBtn` to make room (shift them right by ~50px each):
        ```lua
        local tbcBtn   = makeExpBtn("TBC",    -130, 40)
        local origBtn  = makeExpBtn("Vanilla", -174, 56)
        ```

        > Exact pixel values depend on your search bar width. Adjust as needed so all three buttons fit.

        **`_UpdateExpansionFilterVisuals`** (around line 2542–2560):

        Update the nil guard at the top of the function to also check the new button, then add it to the loop. **Edge case:** the existing guard only checks `_expFilterOrigBtn`; if `_expFilterWOTLKBtn` is nil for any reason (e.g. called before `CreateTopBar`), the loop will crash on `info.btn._textFS`.

        Update the guard:
        ```lua
        if not self._expFilterOrigBtn or not self._expFilterWOTLKBtn then return end
        ```

        Add the Wrath button to the loop:
        ```lua
        for _, info in ipairs({
            { btn = self._expFilterOrigBtn,  tag = "ORIG"  },
            { btn = self._expFilterTBCBtn,   tag = "TBC"   },
            { btn = self._expFilterWOTLKBtn, tag = "WOTLK" },
        }) do
        ```

        **`ToggleExpansionFilter`** (around line 2562 onwards):

        The existing guard prevents both filters from being off simultaneously. With three filters the logic needs updating — prevent all three being off at once:
        ```lua
        function UI:ToggleExpansionFilter(tag)
            if not GuildCrafts.db then return end
            local f = GuildCrafts.db.profile.expansionFilter
            -- Count how many are currently active
            local activeCount = 0
            for _, t in ipairs({"ORIG", "TBC", "WOTLK"}) do
                if f[t] then activeCount = activeCount + 1 end
            end
            -- Prevent turning off the last active filter
            if f[tag] and activeCount <= 1 then return end
            f[tag] = not f[tag]
            self:_UpdateExpansionFilterVisuals()
            self:Refresh()
        end
        ```

        ---

        ## Task 6 — `DATA_FORMAT_VERSION`

        In the multi-TOC model, `DATA_FORMAT_VERSION` does **not** need a per-version bump. WotLK guilds never sync with TBC guilds — they run on different servers. The wire format is identical; the same `DATA_FORMAT_VERSION = 2` works for all versions.

        Only bump it if the **wire protocol itself** changes (new fields, different serialisation, etc.).

        ---

        ## Task 7 — Version bump

        All TOC files share one version number. Bump once in `Core.lua`:

        **`GuildCrafts/Core.lua`:**
        ```lua
        GuildCrafts.DISPLAY_VERSION = "X.Y.Z"
        ```

        Every TOC uses the same `## Version: X.Y.Z`. The addon is one product with one version, shipping for multiple game versions.

        ---

        ## What does NOT need to change

        - **Comms protocol** — the sync, DR election, DELTA_UPDATE, heartbeat, and SYNC_REQUEST/RESPONSE system is expansion-agnostic. The comms layer requires no expansion-specific changes.
        - **AceDB schema** — the per-member data structure (`professions`, `lastUpdate`, `recipes`, `skillLevel`, etc.) is identical for WotLK.
        - **Locale map system** — `BuildLocaleMap()` uses `GetSpellInfo` with rank-1 spell IDs. The same function works in WotLK; just add Inscription's spell ID (Task 3a).
        - **Recipe key system** — positive itemID / negative spellID keys work identically in WotLK. No changes needed.
        - **Reagent scanning** — `ScanTradeSkillReagents` uses standard TradeSkill APIs unchanged in WotLK.
        - **Cooldown scanning** — `ScanTradeSkillCooldowns` uses `GetTradeSkillCooldown` which is unchanged.
        - **Tooltip system** — `Tooltip.lua` is expansion-agnostic.
        - **Favorites** — `Favorites.lua` is expansion-agnostic.
        - **MinimapButton** — unchanged.
        - **All Ace3 libraries** — already WotLK-compatible.
        - **LibDeflate** — already WotLK-compatible.

        ---

        ## Task 8 — Update `CHANGELOG.md`

        Keep all existing entries as history. Add a new entry at the top:

        ```markdown
        ## X.Y.Z — YYYY-MM-DD

        ### WotLK Classic support

        - Interface version bumped to `30403` (WotLK Classic patch 3.4.3)
        - **Inscription** added as a tracked primary profession — recipes scan automatically on `TRADE_SKILL_SHOW`
        - **Craft API path guarded** — Enchanting now scans via the standard TradeSkill API on WotLK+; the TBC-only `CRAFT_SHOW` event and all `GetCraft*` functions are behind a runtime guard (`if GetNumCrafts then`)
        - **Wrath expansion filter** — new `[Wrath]` toggle button alongside `[Vanilla]` and `[TBC]`; recipe browser and search respect the filter; `Data_WOTLK.lua` provides the classification lookup
        - **Specialisation table updated** — TBC-only specs (Armorsmith, Weaponsmith, Mooncloth/Shadoweave/Spellfire Tailoring, Dragonscale/Elemental/Tribal Leatherworking) removed; Alchemy and Engineering specs unchanged
        ```

        ---

        ## Task 9 — Update `CURSEFORGE_DESCRIPTION.md`

        ### 9a — Replace the feature-complete banner with a version notice

        CurseForge has **one description per project**. Write it to cover both versions, with a short banner at the top so players know both are supported.

        Replace line 1:
        ```
        > **GuildCrafts is now considered feature-complete. Only critical fixes may be addressed going forward.**
        ```
        With:
        ```
        > Supports **WoW TBC Classic** and **WoW WotLK Classic**. Go to the **Files** tab to pick the right version for your client.
        ```

        ### 9b — Update "Supported Version"

        Replace:
        ```markdown
        # Supported Version

        Built for **WoW TBC Anniversary Edition**  
        Interface version **20505**

        Supports all crafting and gathering professions:

        **Crafting:** Alchemy · Blacksmithing · Enchanting · Engineering · Jewelcrafting · Leatherworking · Tailoring
        ```
        With:
        ```markdown
        # Supported Versions

        | Version | Interface | File |
        |---------|-----------|------|
        | WoW TBC Classic | 20505 | v1.x — [Files tab](https://www.curseforge.com/wow/addons/guildcrafts/files) |
        | WoW WotLK Classic | 30403 | v2.x — [Files tab](https://www.curseforge.com/wow/addons/guildcrafts/files) |

        **Crafting (TBC):** Alchemy · Blacksmithing · Enchanting · Engineering · Jewelcrafting · Leatherworking · Tailoring

        **Crafting (WotLK):** Alchemy · Blacksmithing · Enchanting · Engineering · **Inscription** · Jewelcrafting · Leatherworking · Tailoring
        ```

        ### 9c — Update "Cooldown Tracking"

        Replace the examples list to cover both expansions:
        ```markdown
        Examples include:

        *   Mooncloth · Shadowcloth · Spellcloth *(TBC)*
        *   Transmutes (Alchemy)
        *   Major cooldowns vary by profession
        ```

        ### 9d — Update "Specializations"

        Replace the list to cover both expansions:
        ```markdown
        GuildCrafts tracks profession specializations such as:

        *   Transmutation Master · Elixir Master · Potion Master *(both)*
        *   Goblin / Gnomish Engineering *(both)*
        *   Mooncloth · Shadoweave · Spellfire Tailoring *(TBC only)*
        *   Armorsmith · Weaponsmith · Leatherworking specs *(TBC only)*

        So you always know **who can craft which variant**.
        ```

        ### 9e — Update "Project Status"

        Replace the entire section:
        ```markdown
        ## Project Status

        GuildCrafts is actively maintained for both **TBC Classic** and **WotLK Classic**.

        Critical bug fixes and expansion-specific improvements will continue to be addressed on both branches.
        ```

        ---

        ## Task 10 — WotLK-specific edge cases

        ### 10a — Runeforging (Death Knights)

        Death Knights have a "Runeforging" tradeskill that fires `TRADE_SKILL_SHOW` and is visible via the standard TradeSkill API. It is not a real crafting profession and should never be stored or synced.

        **Verdict: the existing guard is safe.** `ScanTradeSkill()` already does this at line ~898:
        ```lua
        local profName = self:GetOpenProfessionName()
        if not profName or not TRACKED_PROFESSIONS[profName] then
            GuildCrafts:Debug("Open profession not tracked:", profName or "nil")
            return
        end
        ```
        `TRACKED_PROFESSIONS["Runeforging"]` is nil, so the function returns immediately and silently. No data is stored, no error is thrown.

        **Action required:** none for the guard itself. However, verify in-game what string `GetTradeSkillLine()` actually returns for the Runeforging window — it may return `"Runeforging"` or a localised equivalent. If `GetOpenProfessionName()` returns nil instead (e.g. if `GetTradeSkillLine` is unavailable for that window), the nil check still catches it. Add to test checklist: open the Runeforging window on a DK and confirm no `/gc debug` output and no DB entry is written.

        ---

        ### 10b — Blizzard's native Guild Profession UI

        WotLK added a built-in guild profession browser — players can view professions from the guild roster and click "View Crafters". This introduces new API functions (`GetGuildTradeSkillInfo`, related roster events) and adds a profession column to the guild window.

        **Two concerns:**

        **1. Visual clash** — GuildCrafts adds its own elements near the guild frame area and hooks some roster events. Test that the new Blizzard profession column in the guild window does not overlap or conflict with any GuildCrafts-injected frames. Check specifically:
        - The minimap button and main frame anchoring
        - Any `GUILD_ROSTER_UPDATE` handler — GuildCrafts already listens to this event (in `Core.lua`). Verify it doesn't interfere with Blizzard's own profession data population.

        **2. Bootstrapping opportunity (optional enhancement)** — Blizzard's API exposes basic profession names for guild members who have not installed GuildCrafts. You could read this data during `GUILD_ROSTER_UPDATE` to pre-populate profession names (without recipe lists) for non-addon members. This would make the left panel more complete in guilds with low addon adoption. This is not required for the WotLK release — log it as a future improvement if it becomes desirable.

        ---

        ### 10c — Daily cooldown resets (Alchemy transmutes)

        **The problem:** `ScanTradeSkillCooldowns` (line ~720) stores cooldowns as:
        ```lua
        cooldowns[skillName] = {
            endTime = now + cdRemaining,   -- absolute epoch time
            duration = cdRemaining,
        }
        ```
        `GetTradeSkillCooldown` returns *seconds remaining at scan time*, so `endTime` is accurate when synced. Peers display remaining time as `endTime - time()`.

        In TBC, cooldowns are rolling 24-hour timers — this model is correct. In WotLK, Blizzard changed many Alchemy transmutes (and previously cloth cooldowns, which are removed in WotLK) to reset at a **fixed daily server reset time** (typically midnight server time). If a peer's stored `endTime` is 3 hours in the future but the server reset fires at midnight, the actual cooldown is gone — but GuildCrafts will still display "3 hours remaining" until the owning player rescans.

        **Verdict: display-only staleness, no data corruption.** The fix timeline is bounded: the error resolves the next time the owning player opens their profession window. The maximum false "still on cooldown" window is one server reset cycle.

        **Recommended mitigation:** when displaying a peer's cooldown in the UI, show the "last scanned" timestamp alongside it (e.g. `Transmute — ready in 3h  ·  scanned 14h ago`). This already exists for member entries in general — verify it is also shown in the cooldown section of the member detail panel. If it is not, add it so users can judge data freshness themselves.

        No code change to the storage model is needed.

        ---

        ### 10d — Profession chat links (`trade:` format)

        WotLK added a new hyperlink type for linking an entire profession window to chat. The format is:
        ```
        |Htrade:spellID:skillLevel:maxSkill:GUID:...|h[Profession Name]|h
        ```
        This is generated when a player shift-clicks their profession name in the skill panel.

        **Verdict: no conflict with current scanning.** `GetTradeSkillRecipeLink(index)` still returns `item:` or `enchant:` links for individual recipes — the `trade:` format is only for the profession-level link and never appears in recipe scanning. The existing `enchant:(%d+)` and `spell:(%d+)` patterns in `GetRecipeKey()` are unaffected.

        **Enhancement opportunity (optional):** the `trade:` link contains the player's GUID and current skill level. You could add a button in the member detail panel that generates a `trade:` link and inserts it into the chat edit box, letting users open that player's profession window directly from GuildCrafts. This is a nice-to-have — not required for the WotLK release. Log as a future improvement.

        ### 10e — `SCAN_EXEMPT` list missing Inscription (and First Aid)

        `Core.lua` line 143 has a hardcoded exemption list for professions that fire `TRADE_SKILL_SHOW` but have no recipes to scan, so they are excluded from the "please open these windows" login warning:
        ```lua
        local SCAN_EXEMPT = { Herbalism = true, Skinning = true }
        ```

        **Problem 1 — First Aid:** First Aid exists in WotLK and fires `TRADE_SKILL_SHOW`. It is not in `TRACKED_PROFESSIONS` so it will never be scanned, but it *does* appear in `GetSkillLineInfo`. If `DetectProfessions` encounters it, `GetCanonicalProfName` will return `"First Aid"` (unrecognised), `TRACKED_PROFESSIONS["First Aid"]` is nil, and it is silently skipped — that part is fine. No action needed.

        **Problem 2 — Inscription:** Inscription has recipes and should *not* be scan-exempt. The existing logic is correct — adding Inscription to `TRACKED_PROFESSIONS` is sufficient. Just confirm `SCAN_EXEMPT` does not need updating. It doesn't.

        **Problem 3 — `SCAN_EXEMPT` is not `IsGatheringProfession`:** `IsGatheringProfession` (line ~1647) returns `true` for Herbalism and Skinning. `SCAN_EXEMPT` duplicates this logic rather than calling it. This is a latent maintenance hazard — if Mining were ever added to `IsGatheringProfession` it would still appear in the warning. Not a WotLK blocker, but worth noting.

        **Action required:** none is blocking. However, add Mining to `SCAN_EXEMPT` as a defensive measure (Mining tracks Smelting recipes but not gathering), and consider replacing the hardcoded table with a call to `Data:IsGatheringProfession(profName)`:
        ```lua
        local SCAN_EXEMPT = { Herbalism = true, Skinning = true, Mining = true }
        ```
        Or replace the whole pattern:
        ```lua
        if not SCAN_EXEMPT[profName] and not self.Data:IsGatheringProfession(profName) then
        ```

        ---

        ### 10f — `GuildCrafts.VERSION` (protocol version) vs `DATA_FORMAT_VERSION`

        There are two separate version integers in `Core.lua`:
        ```lua
        GuildCrafts.VERSION = 2          -- sent in HELLO/HEARTBEAT, used for peer display
        GuildCrafts.DATA_FORMAT_VERSION = 2  -- used in sync to force re-pull of old-format entries
        ```

        Task 6 bumps `DATA_FORMAT_VERSION`. But `GuildCrafts.VERSION` also needs to be bumped. This is the integer sent in every `HELLO` and `HEARTBEAT` payload and stored in `addonUsers[key].version`. It is displayed in `/gc comms` and used to detect whether a peer is running an outdated build.

        If `VERSION` stays at 2, a WotLK client and a TBC client would appear identical to each other's sync logic — but in the multi-TOC model this is a non-issue because they run on different servers and never encounter each other.

        **Action required:** bump `GuildCrafts.VERSION` to match `DATA_FORMAT_VERSION` if and when the wire protocol changes. In the multi-TOC model, WotLK guilds never sync with TBC guilds (different servers), so bumping for expansion separation is unnecessary:
        ```lua
        -- Only bump when the wire protocol itself changes
        GuildCrafts.VERSION = 2
        GuildCrafts.DATA_FORMAT_VERSION = 2
        ```

        Add this to Task 7 in the spec. The two values do not need to track each other permanently — they serve different purposes — but at a major expansion boundary bumping both makes them unambiguous.

        ---

        ### 10g — `TRADESKILL_TITLE_SPELL_IDS` aliasing for Inscription

        The addon has a mechanism (`TRADESKILL_TITLE_SPELL_IDS`) to map a tradeskill window title that differs from its `GetSkillLineInfo` name back to the correct canonical key. Currently only Smelting → Mining is registered:
        ```lua
        local TRADESKILL_TITLE_SPELL_IDS = {
            ["Mining"] = 2656,  -- "Smelting" window title → "Mining"
        }
        ```

        In WotLK, Inscription's tradeskill window is titled **"Inscription"** and its `GetSkillLineInfo` name is also **"Inscription"** — no mismatch. No alias entry needed.

        However, verify in-game: if the locale map (`_localeToCanonical`) maps the localised profession name correctly via `PROFESSION_SPELL_IDS[Inscription] = 45357`, then `GetOpenProfessionName` will return `"Inscription"` and `TRACKED_PROFESSIONS["Inscription"]` will be true. If the window title differs on any locale, add a `TRADESKILL_TITLE_SPELL_IDS` entry exactly as Mining/Smelting does.

        **Action required:** none until verified in-game. Add to test checklist: confirm Inscription scans correctly on at least one non-English client locale (or note it as unverified).

        ### 10h — Hardcoded 375 skill cap

        **Verdict: completely safe.** A search of all addon files finds **zero hardcoded references to 375** in any logic path. Every skill level display in `MainFrame.lua` reads directly from stored API values:
        ```lua
        -- Line 809, 898, 1834 — all three skill display sites use the same pattern:
        profData.skillLevel .. "/" .. profData.maxSkillLevel
        ```
        `maxSkillLevel` is stored from `GetTradeSkillLine()` / `GetSkillLineInfo()` at scan time — so when a WotLK player is Grand Master (450/450), that is exactly what gets stored and displayed. No magic number involved anywhere.

        **Action required:** none.

        ---

        ### 10i — Rogue Poisons removed in WotLK

        **Verdict: never tracked, no action needed.** Rogue Poisons were a TBC crafting system (rogues brewed their own poisons via a Poisons skill). It is not present in `TRACKED_PROFESSIONS`, `PRIMARY_PROF_NAMES`, or `PROFESSION_SPELL_IDS`. `TRADE_SKILL_SHOW` fires for Poisons in TBC — and the existing `TRACKED_PROFESSIONS` guard silently drops it the same way it drops Runeforging. In WotLK the mechanic was removed entirely so the event never fires at all.

        **Action required:** none.

        ---

        ### 10j — Payload size growth (Inscription glyphs)

        WotLK adds significantly more recipes per player than TBC — most visibly Inscription, which has ~350+ glyph recipes alone (one per class/spell combination). All other professions also gain new recipes.

        **Why the current architecture handles it:** the sync system already chunks by *members*, not by recipe count — `SYNC_CHUNK_SIZE = 5` members per chunk, 1 second between chunks. A single member entry with 400 Inscription recipes will be one large serialised blob in one chunk, not split further. The 1.3.8 `onComplete` fix ensures this single heavy chunk completes before the next sync request starts.

        **The real concern is per-chunk message size.** `SendMessage` already compresses payloads over 200 bytes via LibDeflate:
        ```lua
        -- Compress large messages (> 200 bytes)
        if LibDeflate and #serialized > 200 then
            local deflated = LibDeflate:CompressDeflate(serialized)
            ...
            toSend = "Z" .. encoded  -- "Z" prefix = compressed
        end
        ```
        Recipe data is highly compressible (repetitive integer keys). Even so, a single member with Inscription + other professions could produce a serialised chunk that, even after compression, approaches the WoW addon channel message size limit (~4 KB per `SendAddonMessage` call). AceComm-3.0 handles multi-part splitting automatically via its own internal chunking on top of yours — so there is no hard cliff, but latency per member will increase.

        **Recommended mitigation:** lower `SYNC_CHUNK_SIZE` from 5 to 2 or 3. This keeps individual `ScheduleTimer` callbacks lighter and reduces the risk of a single timer firing a 4 KB+ payload. The tradeoff is a longer total sync time for large guilds.

        > **Note:** With Chunk RESUME recovery (Patch 3), the cost of smaller chunks is low — a dropped chunk now recovers in ~4s rather than 120s, so the penalty for splitting more aggressively is minimal. With RESUME in place, prefer `SYNC_CHUNK_SIZE = 2` rather than `3`.

        ```lua
        -- Comms.lua — consider reducing for WotLK payload growth
        local SYNC_CHUNK_SIZE = 2   -- was 5; reduced for WotLK payload growth (RESUME mitigates the latency cost)
        ```

        Monitor in testing: a 25-member guild with full Inscription coverage is the stress case. Use `/gc debug` to watch chunk timing.

        ---

        ## Recommended test checklist

        1. All professions appear in left panel (including Inscription)
        2. Opening each profession window scans recipes and prints "Scanned X: N new recipe(s)"
        3. Enchanting scans via `TRADE_SKILL_SHOW` (no `CRAFT_SHOW` errors in log)
        4. Inscription scans correctly
        5. `[Vanilla]` / `[TBC]` / `[Wrath]` filter buttons toggle correctly; all three cannot be off simultaneously
        6. Wrath recipes classified correctly (spot-check 2–3 known Wrath recipes)
        7. Alchemy/Engineering specs detected via `IsSpellKnown` on a specialised character
        8. No stale TBC specs (Armorsmith etc.) persisting after login on a WotLK character
        9. Sync works between two WotLK clients (HELLO → SYNC_REQUEST → SYNC_RESPONSE)
        10. `/gc debug` shows no Lua errors
        11. **Runeforging (DK):** open the Runeforging window on a Death Knight — no debug output, no DB entry written, no Lua error
        12. **Blizzard guild profession UI:** open the guild window, verify no visual overlap between Blizzard's profession column and any GuildCrafts-injected elements
        13. **Cooldown display:** verify the member detail panel shows a "last scanned" timestamp alongside any cooldown entries so users can judge staleness
        14. **`GuildCrafts.VERSION`:** confirm `/gc comms` shows version 3 for WotLK peers and version 2 for any TBC peers still in the user list
        15. **First Aid / other non-tracked tradeskills:** open First Aid window — no scan, no DB entry, no Lua error
        16. **Inscription locale:** scan Inscription on a non-English client if possible; confirm it maps to `"Inscription"` key in the DB
        17. **Skill cap display:** verify a Grand Master character shows `450/450`, not `375/375` or any capped value
        18. **Payload stress test:** sync a guild member with full Inscription (~350+ glyphs) — confirm all chunks arrive, no timeout, no data loss; use `/gc debug` to watch chunk timing
