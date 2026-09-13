# MAV-LUA handoff — 2026-09-14

## Current state

v0.1.2 is the first hardware-confirmed release with Navigation, Messages, ready-to-arm status, and a usable ArduPilot parameter browser. The accepted radio build uses a bounded live window: it retains at most eight displayed parameters and four in-flight requests, performs no parameter-database filesystem writes, and never starts parameter traffic until Load is pressed.

The user confirmed that the application now works on the TBS Alpha/EdgeTX 2.11 setup. Readiness and arming display correctly, and the home-direction triangle has usable contrast. The remaining usability problem is speed: crossing an eight-row boundary refetches that window, making repeated navigation through a large parameter set slow and tedious.

## Next priority

Improve parameter navigation without returning to a full-list download or an unbounded cache. The preferred direction is bounded background prefetch plus a small neighboring-window cache:

1. Keep the visible eight rows immediately usable.
2. Prefetch the next window while idle and retain at most the previous/current/next windows.
3. Invalidate cached rows on target change, link loss, explicit reload, and after a verified write where necessary.
4. Preserve the four-request TX window, adaptive timeout/backoff, one shared CRSF queue consumer, and the 10,000-instruction callback ceiling.
5. Add deterministic tests for direction reversals, cache eviction, stale-data invalidation, PAGE interruption, and sustained memory bounds before another radio soak.

Do not reintroduce the abandoned full parameter download or SD parameter database. Those approaches caused radio freezes and allocation failures; the bounded live browser is the accepted baseline.

## Safety and protocol contracts

- `READY` comes from MAVLink `SYS_STATUS` pre-arm present/enabled/health masks; `ARMED` comes from the explicit ArduPilot status bit. Status text is never used as state.
- Parameter writes require fresh disarmed state, a reread of the original value, explicit Save, one `PARAM_SET`, and a separately requested matching readback. Unknown outcomes are not retried.
- The matching ExpressLRS TX bridge accepts only unsigned MAVLink PING, `PARAM_REQUEST_READ`, and `PARAM_SET` from handset Lua system/component 254/190.
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
python tools/build.py --luac .build/luac.exe --luac-post .build/luac53.exe --version v0.1.2
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
