#!/usr/bin/env python3
"""
Generates GuildCrafts/Data_MOP.lua — a pre-built lookup table of MoP recipe keys.

Uses the wago.tools DBC CSV export endpoint (no pagination, no auth required).
Fetches SkillLineAbility and SpellEffect tables for the MoP Classic build,
then classifies any recipe not already in Data_TBC.lua or Data_WOTLK.lua as MoP.

Emits MOP_ITEM_IDS keyed the same way the addon keys recipes:
  positive key = createdItemId  (all non-enchanting recipes)
  negative key = -spellId       (enchanting recipes)

Usage:
  pip install requests
  python3 tools/gen_mop_spells.py

Output: GuildCrafts/Data_MOP.lua
"""

import csv
import io
import re
import sys

try:
    import requests
except ImportError:
    sys.exit("Missing dependency: pip install requests")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# TODO: verify this build at https://wago.tools/builds before generating.
MOP_BUILD = "5.5.4.69078"

OUTPUT         = "GuildCrafts/Data_MOP.lua"
DATAGEN_SRC    = "tools/DataGenerated.lua"
DATA_TBC_SRC   = "GuildCrafts/Data_TBC.lua"
DATA_WOTLK_SRC = "GuildCrafts/Data_WOTLK.lua"

BASE_CSV_URL = "https://wago.tools/db2/{table}/csv"

# MoP Classic profession skill line IDs.
SKILL_LINE_IDS = {
    "Alchemy":        171,
    "Blacksmithing":  164,
    "Cooking":        185,
    "Enchanting":     333,
    "Engineering":    202,
    "Inscription":    773,
    "Jewelcrafting":  755,
    "Leatherworking": 165,
    "Mining":         186,
    "Skinning":       393,
    "Tailoring":      197,
}

ENCHANTING_SKILL_LINE = SKILL_LINE_IDS["Enchanting"]
EFFECT_CREATE_ITEM    = 24

# Enchanting spells to exclude (profession rank spells, Disenchant ability)
ENCHANTING_EXCLUDE_SPELLS = {
    7411, 7412, 7413, 13920,   # profession rank spells
    13262,                      # Disenchant ability
}

# ---------------------------------------------------------------------------
# CSV fetching
# ---------------------------------------------------------------------------

def fetch_csv(table: str) -> list[dict]:
    """Download the full CSV export for a DBC table and return rows as dicts."""
    url = BASE_CSV_URL.format(table=table)
    params = {"build": MOP_BUILD, "locale": "enUS"}
    print(f"  GET {url}?build={MOP_BUILD} ...", end=" ", flush=True)
    resp = requests.get(url, params=params, timeout=120)
    resp.raise_for_status()
    reader = csv.DictReader(io.StringIO(resp.text))
    rows = list(reader)
    print(f"{len(rows)} rows")
    return rows

# ---------------------------------------------------------------------------
# Step 1: spell → skill line
# ---------------------------------------------------------------------------

def build_spell_to_skillline() -> dict:
    tracked = set(SKILL_LINE_IDS.values())
    rows = fetch_csv("SkillLineAbility")
    spell_to_skillline = {}
    for row in rows:
        try:
            sl = int(row["SkillLine"])
            sp = int(row["Spell"])
        except (KeyError, ValueError):
            continue
        if sl in tracked and sp > 0:
            spell_to_skillline[sp] = sl
    return spell_to_skillline

# ---------------------------------------------------------------------------
# Step 2: spell → created item ID
# ---------------------------------------------------------------------------

def build_spell_to_item() -> dict:
    rows = fetch_csv("SpellEffect")
    spell_to_item = {}
    for row in rows:
        try:
            effect   = int(row["Effect"])
            spell_id = int(row["SpellID"])
            item_id  = int(row["EffectItemType"])
        except (KeyError, ValueError):
            continue
        if effect == EFFECT_CREATE_ITEM and item_id > 0:
            spell_to_item[spell_id] = item_id
    return spell_to_item

# ---------------------------------------------------------------------------
# Known-key extraction from existing Lua sources
# ---------------------------------------------------------------------------

def load_known_spell_ids_from_datagen(path: str) -> set:
    try:
        src = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        print(f"  Warning: {path} not found; skipping ORIG subtraction.", file=sys.stderr)
        return set()
    return {int(m.group(1)) for m in re.finditer(r'spellID\s*=\s*(\d+)', src)}


def load_known_keys_from_lua(path: str) -> set:
    try:
        src = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        print(f"  Warning: {path} not found; skipping subtraction.", file=sys.stderr)
        return set()
    return {int(m.group(1)) for m in re.finditer(r'\[(-?\d+)\]\s*=\s*1', src)}

# ---------------------------------------------------------------------------
# Key assignment
# ---------------------------------------------------------------------------

def assign_recipe_key(spell_id: int, skill_line_id: int, spell_to_item: dict):
    item_id = spell_to_item.get(spell_id)
    if item_id and item_id > 0:
        return item_id
    if skill_line_id == ENCHANTING_SKILL_LINE:
        if spell_id in ENCHANTING_EXCLUDE_SPELLS:
            return None
        return -spell_id
    return None  # passive/buff — skip

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print(f"MoP build: {MOP_BUILD}\n")

    print("Step 1: SkillLineAbility (spell → skill line)...")
    spell_to_skillline = build_spell_to_skillline()
    print(f"  {len(spell_to_skillline)} spells across tracked professions\n")

    print("Step 2: SpellEffect (spell → created item)...")
    spell_to_item = build_spell_to_item()
    print(f"  {len(spell_to_item)} create-item effects\n")

    print("Step 3: subtracting known ORIG spells...")
    known_datagen = load_known_spell_ids_from_datagen(DATAGEN_SRC)
    print(f"  Known ORIG spell IDs: {len(known_datagen)}")
    remaining_spells = {sid: sline for sid, sline in spell_to_skillline.items()
                        if sid not in known_datagen}
    print(f"  Post-ORIG subtraction: {len(remaining_spells)} spells\n")

    print("Step 4: assigning recipe keys...")
    recipe_keys = []
    skipped = 0
    for spell_id, skill_line_id in sorted(remaining_spells.items()):
        key = assign_recipe_key(spell_id, skill_line_id, spell_to_item)
        if key is not None:
            recipe_keys.append(key)
        else:
            skipped += 1
    recipe_keys = sorted(set(recipe_keys), key=lambda x: (x >= 0, abs(x)))
    print(f"  {len(recipe_keys)} keys ({skipped} passives skipped)\n")

    print("Step 5: subtracting keys already in Data_TBC.lua and Data_WOTLK.lua...")
    tbc_keys = load_known_keys_from_lua(DATA_TBC_SRC)
    wotlk_keys = load_known_keys_from_lua(DATA_WOTLK_SRC)
    existing_keys = tbc_keys | wotlk_keys
    before = len(recipe_keys)
    recipe_keys = [k for k in recipe_keys if k not in existing_keys]
    print(f"  Removed {before - len(recipe_keys)} overlaps → {len(recipe_keys)} MoP-only keys\n")

    # Count by profession for the header
    prof_counts = {}
    inv_skill = {v: k for k, v in SKILL_LINE_IDS.items()}
    for spell_id, skill_line_id in remaining_spells.items():
        key = assign_recipe_key(spell_id, skill_line_id, spell_to_item)
        if key is not None and key not in existing_keys:
            prof = inv_skill.get(skill_line_id, "Unknown")
            prof_counts[prof] = prof_counts.get(prof, 0) + 1

    prof_summary = "   ".join(f"{p}: {c:>5}" for p, c in
                              sorted(prof_counts.items(), key=lambda x: -x[1]))

    print(f"Step 6: writing {OUTPUT}...")
    lines = [
        "----------------------------------------------------------------------",
        "-- GuildCrafts/Data_MOP.lua",
        "-- Generated by tools/gen_mop_spells.py — do not edit by hand.",
        f"-- Source: wago.tools DBC CSV, build {MOP_BUILD}",
        "--",
        f"-- Recipe counts by profession ({len(recipe_keys)} total):",
        f"--   {prof_summary}",
        "----------------------------------------------------------------------",
        "local _, _ns = ... -- luacheck: ignore (WoW addon bootstrap)",
        "local GuildCrafts = _G.GuildCrafts",
        "",
        "-- MOP_ITEM_IDS: recipe keys as stored by the addon",
        "--   positive = createdItemId  (all non-enchanting recipes)",
        "--   negative = -spellId       (enchanting recipes)",
        "local MOP_ITEM_IDS = {",
    ]
    for i in range(0, len(recipe_keys), 10):
        chunk = recipe_keys[i:i + 10]
        lines.append("    " + "".join(f"[{k}]=1," for k in chunk))
    lines += [
        "}",
        "GuildCrafts.MOP_ITEM_IDS = MOP_ITEM_IDS",
    ]

    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")

    print(f"Done. {len(recipe_keys)} MoP recipe keys written to {OUTPUT}")


if __name__ == "__main__":
    main()
