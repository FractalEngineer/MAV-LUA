# Parameter index layout and provenance

## The index comes from the vehicle

A parameter name is only usable once it has actually been read from the connected flight controller. There is no offline or pre-populated browsing: MAV does not ship a list of parameter names, and browsing never works before the autopilot has been read. This is the same rule Mission Planner follows.

MAV reads the vehicle's own parameters once and writes a fixed-record **index** to the SD card. Browsing afterwards reads that index locally and sends no parameter requests.

The index is derived, not authoritative. It describes one vehicle as of the last build, so a name that is not in the index does not exist on that vehicle as far as MAV is concerned. Rebuilding is the only way to discover parameters added by a firmware update.

## Record layout

The index uses fixed records so any page can be read by seeking, without parsing or retaining the whole file.

- A tiny manifest records only firmware family, vehicle family, file path, and top-level count.
- Top-level and optional second-level category records are a fixed 22 bytes: a 16-byte NUL-padded name, a 4-byte offset, and a 2-byte count.
- Parameter names are NUL-padded fixed 16-byte records.
- The high bit of a record's count identifies a family folder; its offset then points to fixed child records instead of names.

Every level seeks directly to at most eight records. Opening a category page reads at most 176 bytes and opening a name page reads at most 128.

Grouping rules: the first token before `_` forms a parameter group, and singleton prefixes are placed under `GENERAL`. When a base has at least two numbered instance groups, those groups and the unnumbered base group are nested in one family folder: for example, `RC` contains `RC`, `RC1` through `RC16`.

## Bounded build

The build must stay bounded, because the naive alternatives failed on radio. Streaming the complete list into memory, writing one SD record per received parameter, and a `params.tmp` scratch file each froze the radio or failed allocations.

The intended build therefore:

1. Captures the `PARAM_VALUE` stream to a single temporary file.
2. Sorts that file in bounded fixed-size runs.
3. Emits the category records in one sequential pass.
4. Renames the result atomically, so a failed or interrupted build cannot damage a good index.

A vehicle that has never completed a build has no browsable names.

## The builder is a Tools script

The build runs in `SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua`, not inside the Parameters page. Building it in-page needed about 128 KiB against the allocator cap because the browser modules were already resident, and that exhausted the radio heap; the tool needs about 80 KiB at worst because `luaExecStandalone` gives it its own Lua state with the permanent scripts paused and it never loads the browser. The Parameters page only reports that no index exists and points at the tool. Both use the same identity-derived filename, so they cannot disagree about which index a vehicle should have.

The index is written into `SCRIPTS/MAV/` beside the modules, as `i<major><minor><plane|copter>.pdb` plus a matching manifest. It cannot live in a subdirectory: `io` offers only open/close/read/write/seek, so Lua cannot create a directory, and FatFs does not create a missing parent. Earlier releases appeared to have a `DB` folder only because the packaged databases created it, so the builder could write there by accident; with those assets gone the folder does not exist and a write into it fails.

