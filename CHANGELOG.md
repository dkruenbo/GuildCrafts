# Changelog

## 1.0.3 — 2026-02-25

### Bug Fixes

- **Partial reagent scan fix**: Re-scans recipes when stored reagent count is less than expected, fixing cases where item cache misses caused incomplete reagent data (e.g. missing Large Prismatic Shards on Enchant Gloves - Spell Strike)

## 1.0.2 — 2026-02-23

### Other

- DR/BDR role change messages moved to debug only (no longer clutter chat)
- Fixed `/gc minimap` toggle ("MinimapButton module not loaded")

## 1.0.1 — 2026-02-23

### Bug Fixes

- **Staleness display**: New entries with `lastUpdate = 0` no longer show as "683 months old"
- **Self-eviction**: Solo DR no longer evicts itself from the addon user list on sync retry
- **One-way HELLO**: HELLO broadcasts now receive a reply, so peers discover each other correctly
- **Re-sync on discovery**: Newly discovered addon users via HELLO now trigger a re-sync after 2 seconds
- **Scroll clipping**: Added bottom padding to all scrollable panels to prevent the last entry from being cut off
- **Square minimap button**: Minimap button now correctly positions on square minimaps (e.g. Titan Panel, SexyMap)
- **Search welcome bleed-through**: Welcome text no longer shows through search results
- **Search reagents**: Search results now display reagent lists for matching recipes
- **Sync timeout (two root causes)**:
  - DR now sends an empty acknowledgement when already converged, so the requester stops waiting
  - DR no longer tries to sync with itself
- **Refresh welcome bleed-through**: Welcome text no longer reappears when the member list refreshes while viewing a member's recipes
- **Reagents in sync**: Reagent and category data is now included in sync payloads sent to other players
- **Backfill timestamp bump**: Re-scanning a profession now bumps the timestamp when reagent/category data is backfilled onto existing recipes, ensuring the updated data propagates via sync
- **Stale synced copies ("already converged")**: Added a data format version so copies synced before reagents were included get re-pulled automatically
- **Craft request popup dismiss**: Accept/Decline buttons now always dismiss the popup, even if downstream logic errors
- **Craft request combat suppression**: Craft request popups are deferred until combat ends instead of appearing mid-fight
- **Craft request sound removed**: Craft request popups no longer play a sound

### Other

- Login reminder to open each profession window once for scanning
- Removed nested `.git` directory from LibDeflate (caused CurseForge upload rejection)

## 1.0.0 — 2026-02-22

- Initial release
