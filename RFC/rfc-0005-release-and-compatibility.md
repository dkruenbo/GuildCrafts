# GuildCrafts Protocol — RFC 0005

**Status:** Informational  
**Applies to:** GuildCrafts v1.0.0+

---

## Table of Contents

1. [Version Fields](#1-version-fields)
2. [Version Bump Checklist](#2-version-bump-checklist)
3. [Interface / TOC Versioning](#3-interface--toc-versioning)
4. [Compatibility Layers](#4-compatibility-layers)
   - 4.1 [Tooltip Pipeline (2.5.6 / Classic Era 1.15.9)](#41-tooltip-pipeline-256--classic-era-1159)
   - 4.2 [TradeSkill API (WotLK modernisation)](#42-tradeskill-api-wotlk-modernisation)
5. [Git Workflow](#5-git-workflow)
6. [Branch Strategy](#6-branch-strategy)
7. [Pull Request & Merge Process](#7-pull-request--merge-process)
8. [Release Process](#8-release-process)
9. [CHANGELOG Conventions](#9-changelog-conventions)
10. [CurseForge Distribution](#10-curseforge-distribution)

---

## 1. Version Fields

GuildCrafts uses four distinct version identifiers:

| Field | Location | Type | Purpose |
|-------|----------|------|---------|
| `DISPLAY_VERSION` | `Core.lua` | string `"X.Y.Z"` | Human-readable version shown in tooltips, `/gc version`, and CurseForge. |
| `## Version` | `GuildCrafts.toc` | string `"X.Y.Z"` | Loaded by WoW and reported in the addon list. Must match `DISPLAY_VERSION`. |
| `GuildCrafts.VERSION` | `Core.lua` | integer | Wire protocol version. Carried in every sync envelope. Bump only on backward-incompatible wire format changes. Currently `2`. |
| `GuildCrafts.DATA_FORMAT_VERSION` | `Core.lua` | integer | Member entry schema version. Bump when the sync payload structure changes. See RFC-0003 §11. Currently `2`. |

`VERSION` and `DATA_FORMAT_VERSION` are independent. A display-version bump
(e.g. 1.10.0 → 1.11.0) typically leaves both integers unchanged.

---

## 2. Version Bump Checklist

Before committing a display-version bump, update **all three** of these
locations. They must always match:

| File | Field |
|------|-------|
| `GuildCrafts/Core.lua` | `GuildCrafts.DISPLAY_VERSION = "X.Y.Z"` |
| `GuildCrafts/GuildCrafts.toc` | `## Version: X.Y.Z` |
| `CHANGELOG.md` | `## X.Y.Z — YYYY-MM-DD` (new entry at the top) |

Wire protocol integers (`VERSION`, `DATA_FORMAT_VERSION`) are bumped
separately and only when the corresponding protocol layer changes. They do
not need to match the display version.

---

## 3. Interface / TOC Versioning

The `## Interface` field in `GuildCrafts.toc` must match the client build
number of the target WoW version:

| Game version | Interface number |
|---|---|
| TBC Classic 2.5.5 | `20505` |
| TBC Classic 2.5.6 | `20506` |
| WotLK Classic 3.4.x | `30400` (approximate; confirm at release) |

The interface number is bumped when Blizzard releases a new client patch that
changes the number. It is **not** bumped for every display-version release.

Blizzard performs a tolerated-mismatch window for minor patch differences, so
an addon with a slightly older `## Interface` value will still load. However,
setting the exact current value suppresses the "outdated addon" warning in the
UI.

---

## 4. Compatibility Layers

### 4.1 Tooltip Pipeline (2.5.6 / Classic Era 1.15.9)

TBC 2.5.6 (released July 21, 2026) aligned with Classic Era 1.15.9 and
introduced the modern `TooltipDataProcessor` API, replacing the
`OnTooltipSetItem` script event.

GuildCrafts detects the API at runtime:

```lua
-- Tooltip.lua, OnEnable()
if TooltipDataProcessor then
    -- 2.5.6 / modern pipeline
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, handler)
else
    -- 2.5.5 / legacy
    self:SecureHookScript(GameTooltip,    "OnTooltipSetItem", handler)
    self:SecureHookScript(ItemRefTooltip, "OnTooltipSetItem", handler)
end
```

This guard must be preserved whenever Tooltip.lua is modified. The handler
body (`tooltip:GetItem()` and crafter lookup) is identical for both paths.

### 4.2 TradeSkill API (WotLK modernisation)

WotLK Classic replaces several classic TradeSkill globals with modern
namespace APIs. Compatibility wrappers live in `Data.lua` (on the
`wotlk-migration` branch only; not on `main`):

| Classic API | Modern replacement | Wrapper |
|---|---|---|
| `GetSpellInfo(id)` → multiple returns | `C_Spell.GetSpellInfo(id).name` | `GetSpellName(spellID)` local helper |
| `GetNumSkillLines()` + `GetSkillLineInfo(i)` loop | `C_SkillLine.GetSkillLines()` table | `IterSkillLines()` local iterator |
| `GetNumTradeSkills()` (may be absent) | — | `if not GetNumTradeSkills then return end` nil guard |
| `GetTradeSkillNumReagents()` (may be absent) | — | `if not GetTradeSkillNumReagents then return nil end` nil guard |

Each wrapper prefers the modern API and falls back to the classic API, so the
same code runs on both TBC and WotLK clients.

---

## 5. Git Workflow

- **Branch naming:** `feature/patch-N-description`
- **Merges:** squash-merge into `main`, branch deleted after merge.
- **Feature branch force-push:** allowed (branches are never shared before PR).
- **After a rebase:** `git push --force-with-lease` (preferred over `--force`).

**Never** commit, push, create a PR, or merge without explicit instruction
from the maintainer.

---

## 6. Branch Strategy

| Branch | Purpose |
|--------|---------|
| `main` | Production-ready code targeting TBC Classic (current live). |
| `feature/patch-N-*` | Short-lived feature/fix branches, squash-merged into `main`. |
| `wotlk-migration` | Long-lived local branch with WotLK API compat guards. **Never pushed** until Blizzard announces WotLK Classic Anniversary. |

The `wotlk-migration` branch diverges from `main` after v1.10.1 and carries
additional commits for:
- `Data.lua` API compat wrappers (§4.2 above)
- `GuildCrafts.toc` `## Interface` targeting WotLK
- `CHANGELOG.md` `2.0.0 — TBD` entry at the top

Changes shipped to `main` are cherry-picked onto `wotlk-migration` as needed.
The reverse does not apply — `wotlk-migration`-only changes must not be
cherry-picked to `main`.

---

## 7. Pull Request & Merge Process

```bash
# Push the feature branch
git push -u origin feature/patch-N-description

# Create the PR
gh pr create --title "feat: ..." --base main

# Squash-merge and delete branch
gh pr merge <num> --squash --delete-branch --subject "feat: ..."
```

PR titles follow conventional commits where practical:
- `feat:` — new user-visible feature
- `fix:` — bug fix
- `chore:` — internal/tooling change with no user impact
- `docs:` — documentation only

---

## 8. Release Process

After merging a PR that bumps the display version:

1. Confirm all three version fields are consistent (§2).
2. Confirm `## Interface` matches the current live client build (§3).
3. Zip the release, **excluding `.DS_Store`** (macOS Finder creates them
   automatically and they must not be distributed):

```bash
zip -r GuildCrafts-X.Y.Z.zip GuildCrafts/ -x "*.DS_Store"
```

4. Upload the zip to CurseForge. Update the description if required.

---

## 9. CHANGELOG Conventions

File: `CHANGELOG.md` at the repository root.

**Entry format:**

```markdown
## X.Y.Z — YYYY-MM-DD

### New features
- ...

### Improvements
- ...

### Fixes
- ...
```

Rules:
- Date format: `YYYY-MM-DD` (ISO 8601).
- New entries are inserted **at the top**, below the document header.
- Sections (`### New features`, `### Improvements`, `### Fixes`) are only
  included when there is at least one item for that section.
- Credit contributors by name in the relevant bullet when applicable.
- The `wotlk-migration` branch maintains its own CHANGELOG with a `2.0.0 — TBD`
  entry at the top; `main` entries are cherry-picked below it.

---

## 10. CurseForge Distribution

- Project page: GuildCrafts on CurseForge (WoW TBC Classic category).
- Supported clients: TBC Classic; WotLK Classic to be added when the
  `wotlk-migration` branch is published.
- `CURSEFORGE_DESCRIPTION.md` contains the rendered project description
  (Markdown is rendered by CurseForge).
- Do not include development files (`spec/`, `tools/`, `.DS_Store`,
  `CLAUDE.md`, `CONTRIBUTING.md`) in the release zip — the zip command targets
  the `GuildCrafts/` subdirectory only.
