# MAV-LUA handoff — 2026-09-22

## Current state

v0.1.3 is the current hardware-confirmed release with Navigation, Messages, ready-to-arm status, and a streamlined ArduPilot parameter browser. It never starts parameter traffic until Load is pressed.

The neighboring-window prefetch/cache was hardware-tested and rejected: the TBS Alpha again froze completely after several scrolls. v0.1.3 replaces indexed browsing with a category-first, read-only database. Load discovers the ArduPilot vehicle and requests `AUTOPILOT_VERSION`; the result selects an exact 4.6, 4.7, or 4.8 Plane/Copter database. Category and name scrolling are local. Opening an eight-name page reads exactly 128 bytes from the packaged `.pdb`; only ENTER on a name sends an exact-name `PARAM_REQUEST_READ`.

The tiny database manifests retain only firmware/vehicle identity, path, and top-level category count. Fixed 22-byte category records and 16-byte names are paged directly from `.pdb`; repeated numbered groups such as RC/RC1..RC16 are nested under one bounded second-level folder. All browse levels wrap at their first and last items. Runtime state retains only the current eight categories or names. It never downloads the full live list and never writes parameter data to SD. The databases are generated from official ArduPilot metadata. ArduPilot exact-name replies use `param_index=-1`; both Lua and the TX bridge accept that sentinel instead of treating it as an out-of-range or empty indexed slot. Host tests cover complete 201-name OSD1 scrolling with no parameter requests, firmware selection, direct page reads, named-read retries, and write safeguards. Firmware discovery, nested browsing, wraparound, reads, editing, and verified saves were accepted on hardware with Plane 4.8.

## Shelved: the vehicle-discovered index

Two attempts replaced the packaged databases with an index built on the radio from the vehicle's own
streamed parameter list. **Both failed on hardware and the line is shelved.** The work is preserved
on the `self-building-index` branch for reference; do not merge it as-is. **Packaged `.pdb` browsing
is the browse source again** — it works on hardware today, and it is what ships.

The second attempt got much further and still could not finish a build at about **739 names found**.

### What the radio actually has

This is the part worth keeping, because it is measured rather than inferred.
`tools/diag/MAVHEAP.lua` measures the Lua heap on the device directly, appending each result to
`/MAVHEAP.TXT` as it is taken so a stall still leaves the answer. Three runs gave:

| Configuration | Modules loaded | Used | Obtainable | Largest contiguous |
| --- | --- | --- | --- | --- |
| `bare` | none | 13.4 KiB | 56 KiB | 22.9 KiB |
| `build` | wire + index | 38.2 KiB | **30 KiB** | 16.0 KiB |
| `full` | all modules | 58.6 KiB | 9 KiB | 5.3 KiB |

A Tools state therefore has about **68 KiB** of Lua heap, and a build's whole budget for staging
tables, sort runs and file buffers is about **30 KiB**. Two runs were identical and a third differed
by 7–9 KiB, so treat any budget as having that much uncertainty.

Three conclusions that outlive the attempt:

- **The limit is total size, not fragmentation.** A 16 KiB largest contiguous block is ample for the
  ~1 KiB blocks a builder uses, so `luaL_Buffer` behaviour is not the constraint.
- **The application core cannot load inside a Tools state.** It needs more than the 9 KiB left in the
  `full` configuration, so moving the editor into a Tool could not have worked either.
- **Reducing a measured number was not enough.** A lean rewrite cut resident header-phase staging by
  26% on the host, 47.1 → 34.9 KiB, and still did not fit. That points at the design rather than at a
  table or two: the external merge sort exists only to produce one globally alphabetical name file,
  so peak memory scales with the vehicle. Ordering by category-then-name instead would remove the
  sort and the merge entirely and keep memory O(page).

### What was tried, and what each attempt achieved

- Building in the Parameters page needed about 128 KiB with the browser resident, so it exhausted the
  heap on every retry.
- Moving the build into `SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua` reached the build. A Tools script gets
  its own Lua state and is exempt from the permanent-script instruction budget, but **not more
  memory**: EdgeTX's `custom_l_alloc` draws every state from one pool.
- Removing the `table` dependency fixed a genuine crash, since `table` is `nil` on a monochrome radio,
  and changed nothing about memory.
- Removing per-record `string.rep` padding and a looped `..` concatenation in the run phase cut the
  host-measured peak from 509 to 197 KiB and changed nothing on the radio.
- Re-sending the list request until a name arrived fixed a real first-attempt failure.
- Replacing six label-keyed staging tables and a duplicated label list with integer-indexed arrays and
  a permutation was the only change that attacked the measured constraint. Labels were verified
  contiguous in the sorted file, 23 labels producing 23 runs and 0 splits, including RC/RC1..RC12.
  It still did not fit.

### Lessons

- **The host memory harness is not a trustworthy predictor for this path.** It runs under a capped
  allocator, and forcing collection at a tight cap hides accumulated garbage, so it reported
  improvements hardware never confirmed. Several iterations looked like convergence for that reason.
- **Adding safeguards to a build that does not fit did not converge.** Every change reduced a measured
  number and none changed the outcome. A future attempt should establish the fit *before* building
  features on it.
- **On every pass the measuring instrument needed fixing before the subject did.** The host harness
  masked garbage; the probe used `path:find`, which EdgeTX does not support because strings have no
  metatable; a test harness accumulated drawn strings and faked a 32 KiB leak; a staging measurement
  double-divided its units. Each was caught by testing the instrument rather than trusting it.

Kept from this work: `src/uninstall-mav-lua.bat`, `tools/diag/MAVHEAP.lua` with
`tests/test_heap_probe.lua`, and `tests/test_radio_libs.lua`.

## Next priority

The [v0.2.0 roadmap](docs/V0.2.0-ROADMAP.md) is still the sound direction, and it does **not** depend
on how names are obtained: keep ExpressLRS a generic, bounded MAVLink transport, and move firmware
identity, database selection, reply correlation, and wire conversion behind MAV-LUA adapters so PX4
needs no further bridge change.

Avoid the abandoned full live-list download, `params.tmp`, and runtime database writes; those caused
radio freezes and allocation failures. The packaged `.pdb` files are immutable installation assets
with fixed 16-byte name records, not a downloaded cache. If the index is ever revisited, start from
the measured 30 KiB build budget, prefer an O(page) design, and confirm the fit with
`tools/diag/MAVHEAP.lua` before implementing. The ExpressLRS list session such a design needs exists
on `feature/mavlink-lua-parameter-list`, but nothing consumes it.

## Safety and protocol contracts

- `READY` comes from MAVLink `SYS_STATUS` pre-arm present/enabled/health masks; `ARMED` comes from the explicit ArduPilot status bit. Status text is never used as state.
- Parameter writes require fresh disarmed state, a reread of the original value, explicit Save, one `PARAM_SET`, and a separately requested matching readback. Unknown outcomes are not retried.
- The matching ExpressLRS TX bridge accepts only unsigned MAVLink PING, `PARAM_REQUEST_READ`, `PARAM_SET`, and a strict `MAV_CMD_REQUEST_MESSAGE(AUTOPILOT_VERSION)` from handset Lua system/component 254/190.
- Navigation/Messages remain available on older firmware; parameter modules load only on EdgeTX 2.11 or newer.
- A source install may create stripped `.luac` caches through EdgeTX's compiler. Remove old MAV caches when replacing packages.

## Repositories and hardware

| Item | State |
| --- | --- |
| MAV-LUA | `C:/Users/titan/Desktop/Github_Projects/Mine/MAV-LUA`, branch `main` |
| ExpressLRS | `C:/Users/titan/Desktop/Github_Projects/ExpressLRS`, branch `feature/mavlink-lua-parameters`, based on `a60b68af` |
| Confirmed setup | TBS Alpha, EdgeTX 2.11, RadioMaster Zorro internal ELRS module over the full-duplex external-bay connection, 333 Hz Full / 940k handset baud |
| Earlier UI testing | Tango 2 / FreedomTX 1.4.0 |

The ExpressLRS branch contains the TX-only handset bridge, readiness forwarding, and native tests. Preserve `src/user_defines.txt`; it contains the user's private build settings and must never be staged, printed, or overwritten.

## Validation

Run from the MAV-LUA repository:

```powershell
python tools/build.py --bootstrap --toolchain-only
python tools/build53.py
python tools/firmware_test.py
.build/lua.exe tests/test_mav.lua
.build/lua53.exe tests/test_mav.lua
.build/lua.exe tests/test_widget.lua
.build/lua53.exe tests/test_params.lua
.build/lua53.exe tests/test_pipeline.lua
python -m unittest discover -s tests -p "test_*.py"
python tools/build.py --luac .build/luac.exe --luac-post .build/luac53.exe --version v0.1.3
.build/lua.exe tests/test_package.lua
.build/lua53.exe tests/test_package.lua .build/MAV-post.lua
.build/lua53.exe tests/test_params.lua .build/post
.build/lua53.exe tests/test_pipeline.lua .build/post
.build/lua-freedomtx140.exe tests/test_freedomtx140.lua .build/MAV.lua
```

For ExpressLRS, run from `C:/Users/titan/Desktop/Github_Projects/ExpressLRS/src`:

```powershell
pio test -e native -f test_mavlua
$env:ELRS_UNIFIED_CONFIG='radiomaster.tx_2400.zorro'
pio run -e Unified_ESP32_2400_TX_via_UART
```

New MAV-LUA releases contain exactly two ZIPs plus `SHA256SUMS.txt`. Never rewrite an existing tag or alter historical release assets.
