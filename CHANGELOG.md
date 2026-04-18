# Changelog

## [1.0.3] - 2026-04-18

### Fixed

- **`loot` multiplier was duplicating equipment drops ([#3](https://github.com/HumanGenome/WindrosePlus/issues/3)).** The PAK builder scaled every entry in every loot table, including weapons, armor, jewelry, and other one-of-a-kind gear. With `loot = 4`, a chest that should drop 1 sword dropped 4. The patcher now skips entries whose `LootItem` path lives under `InventoryItems/Equipments/` so only stackable resources scale.
- **`stack_size` multiplier was making explicitly-unstackable items stackable ([#3](https://github.com/HumanGenome/WindrosePlus/issues/3)).** The previous check (`MaxCountInSlot > 0`) treated `1` as "stack of one, scale it." Items the game intends to be unique — gear, jewelry, ship cannons, lore notes — were turning into stackable inventory. The check is now `> 1`, so original stack=1 items stay unstackable.

### Added

- **New `cooking_speed` multiplier.** Divides `CookingProcessDuration` on every Recipe in the PAK, which speeds up alchemy elixirs, fermentation, smelting, and any other timed production. Value is a multiplier just like `crop_speed` (`2.0` = half the time). Range `0.1`–`100.0`. Defaults to `1.0`. Surfaces in `wp.config`, `wp.status`, `server_status.json`, and the dashboard.

### Changed

- PAK builder now reads back temp-dir JSON via explicit BOM-less UTF-8 instead of `Get-Content -Raw`. Prevents Windows PowerShell 5.1 from mis-decoding files that an earlier multiplier already wrote, which would have caused `cooking_speed` and `points_per_level` to corrupt prior `craft_cost` / `xp` edits in mixed-shell setups.
- PAK builder clamps every multiplier input to a minimum of `0.01` defensively so passing `0` or a negative value can't divide-by-zero or collapse durations to garbage. Lua already clamps; this hardens the standalone `WindrosePlus-BuildPak.ps1` entry path.
- Dropped a dead `"Character"` filter in the `inventory_size` patcher. It scanned 877 files and matched zero — confirmed against the live game PAK. Net effect: faster builds, no behavior change.

## [1.0.2] - 2026-04-18

### Fixed

- **"Encoding errors" on Windows PowerShell 5.1** (the shell still shipped by default on Windows and on Nitrado hosts). Several bundled scripts and installer output contained em-dash characters in UTF-8 files without a byte-order-mark. Without a BOM, Windows PowerShell falls back to the legacy ANSI codepage and mangles those bytes into parse or display errors — the symptom some users worked around by manually swapping `powershell` for `pwsh` in their launchers. All bundled `.ps1` files now ship with a UTF-8 BOM so both `powershell` (5.1) and `pwsh` (7+) parse them correctly.
- **JSON output from the PAK builder had a BOM on 5.1 but not on 7.** `Set-Content -Encoding UTF8` means "with BOM" on Windows PowerShell and "no BOM" on PowerShell 7 — a long-standing platform gotcha that made PAK contents subtly differ between shells. All JSON writes now emit BOM-less UTF-8 regardless of which shell runs them.

### Changed

- `StartWindrosePlusServer.bat` and `server/start_windrose_plus.bat` prefer PowerShell 7 (`pwsh`) when it's on PATH and fall back to Windows PowerShell 5.1 (`powershell`) otherwise. Both work correctly after the encoding fix above; the preference just picks the newer shell when available.

## [1.0.1] - 2026-04-17

### Fixed

- **Multipliers not applying to the game ([#2](https://github.com/HumanGenome/WindrosePlus/issues/2)).** Editing `windrose_plus.json` updated `wp.config` / `wp.status` but gameplay stayed at defaults because the override PAK the game loads at startup was never being rebuilt. Multiplier edits (and `.ini` edits) now need the rebuild step before launch — `StartWindrosePlusServer.bat` at the server root handles it automatically, or you can call `tools/WindrosePlus-BuildPak.ps1 -ServerDir "<gameDir>"` from your own launcher. Hash cache makes the no-change case a ~millisecond no-op.
- PAK builder now applies `inventory_size` and `points_per_level` multipliers in addition to the existing six. Both were parsed from config previously but never patched into the game files.

### Added

- `tools/bin/repak.exe` and `tools/bin/retoc.exe` are bundled in the release zip. No internet access or manual tool install required for the PAK rebuild step.
- Dashboard shows a "config changed — restart to apply" banner when it detects a stale PAK.
- `GET /api/pak-status` endpoint reports PAK freshness for tooling.
- Build-input hash cache (`R5\Content\Paks\.windroseplus_build.hash`) lets repeat launches of the wrapper exit in a fraction of a second when nothing has changed. Bumps to the bundled tools, the game pak, or the WindrosePlus version all invalidate it automatically.

### Changed

- Dashboard re-reads `windrose_plus.json` on every auth attempt instead of caching it at startup, so RCON password changes take effect without restarting the dashboard. Includes a short retry loop for transient read races.
- `[Multipliers]` in `windrose_plus.ini` now emits a warning and is ignored. Put multipliers in `windrose_plus.json` so the in-game `wp.config` stays honest about what's actually applied.
- `WindrosePlus-BuildPak.ps1` now fails loud with non-zero exit on any error and will not delete an existing override PAK unless invoked with the explicit `-RemoveStalePak` flag.

## [1.0.0] - 2026-04-15

Initial public release.

### What's included

- **8 multipliers** — loot, XP, stack size, craft cost, crop speed, weight, inventory size, points per level
- **2,400+ INI settings** — player stats, talents, weapons, food, gear, creatures, co-op scaling
- **30 admin commands** — server monitoring, player info, entity counts, diagnostics, config management
- **Web dashboard** — password-protected console with autocomplete and Sea Chart live map
- **Live map** — real-time player and mob positions, auto-generated terrain tiles
- **CPU optimization** — idle servers use fewer cores, full restore on player connect
- **Lua mod API** — custom commands, player events, tick callbacks, hot-reload
- **Automated installer** — auto-detects game folder, downloads UE4SS, preserves configs on update

[1.0.3]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.3
[1.0.2]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.2
[1.0.1]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.1
[1.0.0]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.0
