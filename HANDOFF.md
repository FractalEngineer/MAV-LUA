# MAV-LUA handoff — 2026-09-21

## Current state

v0.1.3 is the current hardware-confirmed release with Navigation, Messages, ready-to-arm status, and a streamlined ArduPilot parameter browser. It never starts parameter traffic until Load is pressed.

The packaged-database browser is superseded, and the packaged `.pdb` assets are now **deleted** from `src/`. v0.1.3 selected a packaged ArduPilot 4.6/4.7/4.8 Plane/Copter database from the `AUTOPILOT_VERSION` reply and browsed it locally. That worked on hardware, but the metadata over-listed reality by roughly three to four times, so pilots met names the vehicle did not have, and every ArduPilot release needed the assets regenerated. The replacement is a **vehicle-discovered index**: `PARAM_REQUEST_LIST` streams the vehicle's own parameters once, MAV builds a fixed-record index on SD in bounded runs, and browsing afterwards reads at most eight local records by seek. Names exist only because they were actually read from that flight controller.

There is no offline or pre-populated browsing, and this is deliberate: Mission Planner has no such feature either. A vehicle that has never been indexed has no browsable names until a build completes. Packaged `.pdb` name assets must not return as the browse source, and neither may `tools/param_db.py` as the browse generator.

The neighboring-window prefetch/cache was hardware-tested and rejected: the TBS Alpha again froze completely after several scrolls. Equally, the naive full live-list download with per-record SD writes and a `params.tmp` scratch file froze the radio and failed allocations. The discovered index must therefore be built in one deliberate bounded pass, not streamed to memory and not written record-by-record.

**The build is a Tools script, not part of the Parameters page.** Building in-page alongside the browser measured about 128 KiB against the allocator cap; `SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua` needs about 80 KiB at worst. A Tools script runs in its own Lua state with the permanent scripts paused, does not load the browser, and is not subject to the permanent-script instruction budget. The page only reports that no index exists and points at the tool. Do not merge the build back into the page.

**The builder must not build a large string by concatenating.** The run phase used to accumulate each run's 64 padded names with `..` and write the result in a single call. Repeated concatenation allocates every intermediate string, and Lua's collector is incremental with a debt threshold that scales with live memory, so around 33 KiB of garbage accumulated per 1 KiB run. Measured over a streamed 700-name list, the run phase peaked at **509 KiB** against a 179 KiB baseline, which no radio heap survives, and the failure arrived as a name count rather than a size because it scales with the number of runs. Writing each record separately, in bounded batches, cut the peak to **197 KiB** at 700 names and left it proportionate at 1,400. The minimum viable heap fell to about 100 KiB at 700 names, versus roughly 174 KiB of retained demand before.

Two diagnostics are worth knowing, because they name different calls. Plain `..` raises `not enough memory`. `string.rep`, `string.gsub` expansion and `io.read('*a')` grow a `luaL_Buffer` and instead raise `not enough memory for buffer allocation` from `resizebox` in `lauxlib.c`. The pilot's exact report was the second one, and it came from `padded` calling `string.rep` once per record; padding now slices a NUL string built once at load, so that call is gone. Neither message is acceptable during a build.

A capped-allocator test **cannot** catch the accumulation, because a tight limit drives the collector continuously and masks it: the pre-fix builder passed a small-heap check. `tests/test_index_writes.lua` therefore asserts the shape of the writes, with the run file receiving nothing larger than one 16-byte record.

## Next priority

Implement the [v0.2.0 roadmap](docs/V0.2.0-ROADMAP.md) around the discovered-index decision:

1. Extend the ExpressLRS bridge with a bounded list session: accept `PARAM_REQUEST_LIST` and forward streamed `PARAM_VALUE` without a per-index reservation, hard-capped by time and packet count, lease-gated, and mutually exclusive with normal reads. This is the first change and it is required before any index can be built.
2. Build the SD index in the standalone Tools script: stream names to a temporary file, run a bounded external merge-sort over fixed-size runs, then emit category records in one sequential pass and rename atomically. The page must never grow the builder back.
3. Select the index when present and report its vehicle/version identity before parameter traffic.
4. Move autopilot identity, reply correlation, and wire conversion behind radio-side adapters so PX4 needs no further bridge change.
5. Run the same sustained radio soak used for v0.1.3, plus a rebuild after link loss mid-download.

Do not reintroduce packaged `.pdb` browsing as the source, the abandoned full live-list retention, `params.tmp`, or per-record runtime database writes.

## Safety and protocol contracts

- `READY` comes from MAVLink `SYS_STATUS` pre-arm present/enabled/health masks; `ARMED` comes from the explicit ArduPilot status bit. Status text is never used as state.
- Parameter writes require fresh disarmed state, a reread of the original value, explicit Save, one `PARAM_SET`, and a separately requested matching readback. Unknown outcomes are not retried.
- The matching ExpressLRS TX bridge accepts only unsigned MAVLink PING, `PARAM_REQUEST_READ`, `PARAM_SET`, and a strict `MAV_CMD_REQUEST_MESSAGE(AUTOPILOT_VERSION)` from handset Lua system/component 254/190.
- The legacy CRSF `0xAA` envelope is claimed by the TX module in `TXModuleEndpoint::handleRaw`, because its first payload bytes are a chunk marker and MAVLink length rather than CRSF addresses. Keep the interception there; intercepting in the handset before routing was rejected in review.
- Parameter names are only usable once read from the vehicle. Never seed the browse tree from packaged metadata.
- The index build belongs in `SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua`. It and `params.lua` must agree on the identity-derived index filename; that one rule is what stops the two drifting.
- The builder writes fixed-size records to the open file one at a time, in bounded batches. Never accumulate a run or a copy in one string with `..`, and never pad with a per-record `string.rep`; both exhaust the radio heap, the second while reporting `not enough memory for buffer allocation`. `tests/test_index_writes.lua` guards the write shape, because a capped-allocator test cannot see the accumulation.
- The index is written directly into `SCRIPTS/MAV/`, never a subdirectory. `io` has no `mkdir` and FatFs will not create a missing parent, so the builder can only write where the package already ships a folder. A subdirectory is what broke the build after the packaged databases were removed.
- Navigation/Messages remain available on older firmware; parameter modules load only on EdgeTX 2.11 or newer.
- Both packages ship stripped `.luac` caches. Firmware compiles a module whose cache is missing, and that compile is what exhausts the heap on a first index build; a module that fails to compile is never written a cache, so the failure would repeat on every retry. A cache only has to load, never compile, and firmware still prefers newer source and falls back to compiling, so a stale cache degrades to a compile. Install both names together and remove old MAV caches, since firmware compares modification times.
- **The TX module firmware must be newer than the last change to `src/lib/MavLuaBridge/MavLuaBridge.h`.** The bridge gained `PARAM_REQUEST_LIST` support in a later commit than the first bridge, so a module built before it silently drops the list request: a build then reports `0 names` while identity still works, because that path is older. That asymmetry has already been mistaken for a code bug once. Compare the firmware build time against the header and reflash when the firmware is older.

## Repositories and hardware

| Item | State |
| --- | --- |
| MAV-LUA | `C:/Users/titan/Desktop/Github_Projects/Mine/MAV-LUA`, branch `main` |
| ExpressLRS | `C:/Users/titan/Desktop/Github_Projects/ExpressLRS`, branch `feature/mavlink-lua-parameters`, based on `a60b68af` |
| Confirmed setup | TBS Alpha, EdgeTX 2.11, RadioMaster Zorro internal ELRS module over the full-duplex external-bay connection, 333 Hz Full / 940k handset baud |
| Earlier UI testing | Tango 2 / FreedomTX 1.4.0 |

The ExpressLRS branch contains the TX-only handset bridge, readiness forwarding, and native tests. Its 0xAA interception lives in `TXModuleEndpoint::handleRaw`, not in `CRSFHandset`, and the converted-frame sizes use `CRSF_FRAME_SIZE(sizeof(frame.p))`. Preserve `src/user_defines.txt`; it contains the user's private build settings and must never be staged, printed, or overwritten.

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
.build/lua53.exe tests/test_index.lua
.build/lua53.exe tests/test_index_sandbox.lua src
.build/lua53.exe tests/test_index_writes.lua src
.build/lua53.exe tests/test_index_cost.lua src
.build/lua53.exe tests/test_tool_screen.lua src
.build/lua53.exe tests/test_radio_libs.lua src
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
