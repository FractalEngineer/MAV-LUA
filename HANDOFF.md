# MAV-LUA handoff — 2026-09-15

## Current state

v0.1.3 is the current hardware-confirmed release with Navigation, Messages, ready-to-arm status, and a streamlined ArduPilot parameter browser. It never starts parameter traffic until Load is pressed.

The neighboring-window prefetch/cache was hardware-tested and rejected: the TBS Alpha again froze completely after several scrolls. v0.1.3 replaces indexed browsing with a category-first, read-only database. Load discovers the ArduPilot vehicle and requests `AUTOPILOT_VERSION`; the result selects an exact 4.6, 4.7, or 4.8 Plane/Copter database. Category and name scrolling are local. Opening an eight-name page reads exactly 128 bytes from the packaged `.pdb`; only ENTER on a name sends an exact-name `PARAM_REQUEST_READ`.

The tiny database manifests retain only firmware/vehicle identity, path, and top-level category count. Fixed 22-byte category records and 16-byte names are paged directly from `.pdb`; repeated numbered groups such as RC/RC1..RC16 are nested under one bounded second-level folder. All browse levels wrap at their first and last items. Runtime state retains only the current eight categories or names. It never downloads the full live list and never writes parameter data to SD. The databases are generated from official ArduPilot metadata. ArduPilot exact-name replies use `param_index=-1`; both Lua and the TX bridge accept that sentinel instead of treating it as an out-of-range or empty indexed slot. Host tests cover complete 201-name OSD1 scrolling with no parameter requests, firmware selection, direct page reads, named-read retries, and write safeguards. Firmware discovery, nested browsing, wraparound, reads, editing, and verified saves were accepted on hardware with Plane 4.8.

## Next priority

Implement the [v0.2.0 roadmap](docs/V0.2.0-ROADMAP.md): keep ExpressLRS as a generic, bounded MAVLink transport and move firmware identity, database selection, reply correlation, and wire conversion behind MAV-LUA adapters. The acceptance test is that PX4 can be added later without another ExpressLRS bridge change.

Do not reintroduce the abandoned full live-list download, `params.tmp`, or runtime database writes. Those approaches caused radio freezes and allocation failures. The packaged `.pdb` files are immutable installation assets with fixed 16-byte name records, not a downloaded cache.

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
.build/lua-freedomtx140.exe tests/test_freedomtx140.lua .build/MAV.lua
```

For ExpressLRS, run from `C:/Users/titan/Desktop/Github_Projects/ExpressLRS/src`:

```powershell
pio test -e native -f test_mavlua
$env:ELRS_UNIFIED_CONFIG='radiomaster.tx_2400.zorro'
pio run -e Unified_ESP32_2400_TX_via_UART
```

New MAV-LUA releases contain exactly two ZIPs plus `SHA256SUMS.txt`. Never rewrite an existing tag or alter historical release assets.
