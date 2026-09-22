# MAV-LUA handoff — 2026-09-22

## Current state

v0.1.3 is the current hardware-confirmed release with Navigation, Messages, ready-to-arm status, and a streamlined ArduPilot parameter browser. It never starts parameter traffic until Load is pressed.

The neighboring-window prefetch/cache was hardware-tested and rejected: the TBS Alpha again froze completely after several scrolls. v0.1.3 replaces indexed browsing with a category-first, read-only database. Load discovers the ArduPilot vehicle and requests `AUTOPILOT_VERSION`; the result selects an exact 4.6, 4.7, or 4.8 Plane/Copter database. Category and name scrolling are local. Opening an eight-name page reads exactly 128 bytes from the packaged `.pdb`; only ENTER on a name sends an exact-name `PARAM_REQUEST_READ`.

The tiny database manifests retain only firmware/vehicle identity, path, and top-level category count. Fixed 22-byte category records and 16-byte names are paged directly from `.pdb`; repeated numbered groups such as RC/RC1..RC16 are nested under one bounded second-level folder. All browse levels wrap at their first and last items. Runtime state retains only the current eight categories or names. It never downloads the full live list and never writes parameter data to SD. The databases are generated from official ArduPilot metadata. ArduPilot exact-name replies use `param_index=-1`; both Lua and the TX bridge accept that sentinel instead of treating it as an out-of-range or empty indexed slot. Host tests cover complete 201-name OSD1 scrolling with no parameter requests, firmware selection, direct page reads, named-read retries, and write safeguards. Firmware discovery, nested browsing, wraparound, reads, editing, and verified saves were accepted on hardware with Plane 4.8.

## Failed attempt: the vehicle-discovered index

A later attempt replaced the packaged databases with an index built on the radio from the vehicle's own streamed parameter list. **It failed on hardware and was reverted.** It is preserved on the `self-building-index` branch for reference. Do not merge it as-is.

The failure: the build reports `not enough memory for buffer allocation` from around 700 names found, and the radio sometimes freezes at the same point. The builder cannot complete inside the radio heap.

What was tried, and what each did not achieve:

- Building in the Parameters page needed about 128 KiB with the browser resident, which exhausted the heap on every retry.
- Moving the build into `SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua` reached the build. A Tools script gets its own Lua state with the permanent scripts paused and is not subject to the instruction budget, but the build still exhausted the heap while running.
- Removing the `table` library dependency (a Lua merge sort and join) fixed a real crash — `table` is `nil` on a monochrome radio — without fixing the memory use.
- Removing per-record `string.rep` padding and eliminating a looped `..` concatenation in the run phase reduced the peak the host measured from 509 KiB to 197 KiB at 700 names, and changed nothing on the radio.
- Writing records individually in bounded batches, and re-sending the list request until a name arrived (which fixed a first-attempt failure), were both correct changes on their own terms. Neither made the build fit.

Two conclusions worth keeping:

- **The host memory harness is not a trustworthy predictor for this path.** It runs under a capped allocator, and forcing collection at a tight cap hides accumulated garbage, so it reported improvements that hardware did not confirm. Host peak figures for a build of this kind should be treated as indicative only, and never as evidence a radio path is fixed.
- **Adding safeguards to a failing build did not converge.** The build failed across many iterations with a different symptom each time. Any future attempt should establish that the whole build fits the radio heap *before* adding features on top of it, rather than discovering the ceiling mid-implementation.

Kept from this work: `src/uninstall-mav-lua.bat`, which removes every MAV-LUA file from the card it is run from and is useful regardless of how the index is eventually built.

## Next priority

Two directions are open. The immediate one is to reconsider how parameter names are obtained at all, since both the packaged-database approach and the on-radio build now have hardware evidence against them. The other is the [v0.2.0 roadmap](docs/V0.2.0-ROADMAP.md): keep ExpressLRS as a generic, bounded MAVLink transport and move firmware identity, database selection, reply correlation, and wire conversion behind MAV-LUA adapters, so PX4 can be added later without another ExpressLRS bridge change.

Do not reintroduce the abandoned full live-list download, `params.tmp`, or runtime database writes. Those approaches caused radio freezes and allocation failures. The packaged `.pdb` files are immutable installation assets with fixed 16-byte name records, not a downloaded cache. If the index idea is revisited, note that the ExpressLRS bridge change it needs is a bounded list session accepting `PARAM_REQUEST_LIST`; that bridge work is separable from the builder and was validated with native tests, but it is upstream-neutral and ships on its own branch.

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
