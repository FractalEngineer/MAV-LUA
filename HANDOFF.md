# MAV-LUA handoff — 2026-09-22

## Current state

**This branch is archived. The on-radio parameter index is shelved.** It got much further than the
first attempt, but it still could not finish a build on hardware, and the radio has been measured
well enough now to say why without another guess.

v0.1.3 remains the working release. **Packaged-database browsing is the browse source again**, and
that is a deliberate reversal of this branch's premise: the prebuilt `.pdb` assets work on hardware
today, and the replacement did not. See `main` for the shipped state.

What shipped from this work is kept on `main`: `src/uninstall-mav-lua.bat` and
the documentation of what was measured here.

## What the radio actually has

`tools/diag/MAVHEAP.lua` measures the Lua heap directly on the device, appending each result to
`/MAVHEAP.TXT` as it goes so a stall still leaves the answer. Three consecutive runs produced:

| Configuration | Modules loaded | Used | Obtainable | Largest contiguous |
| --- | --- | --- | --- | --- |
| `bare` | none | 13.4 KiB | 56 KiB | 22.9 KiB |
| `build` | wire + index | 38.2 KiB | **30 KiB** | 16.0 KiB |
| `full` | all seven | 58.6 KiB | 9 KiB | 5.3 KiB |

Total Lua heap in a Tools state is therefore about **68 KiB**, consistent across all three
configurations. Two runs were byte-identical and a third differed by 7-9 KiB, so treat any budget
as having that much uncertainty. This is the first direct measurement of the radio heap; every
earlier attempt was guessed from host numbers, which is why they kept looking like progress.

Three findings that outlive the attempt:

- **A build has about 30 KiB.** That is the whole budget for staging tables, sort runs and file
  buffers combined. It is not much, and it is the number any future design has to fit.
- **The binding constraint is total size, not fragmentation.** A 16 KiB largest contiguous block is
  ample for the ~1 KiB blocks the builder uses, so `luaL_Buffer` limits are not the problem.
- **The application core cannot load inside a Tools state.** `/SCRIPTS/TELEMETRY/MAV.lua` failed to
  load with only 9 KiB left, so a tool cannot host the browser. Moving the editor into a Tool would
  not have worked, whatever the builder did.

## What was tried, and what each attempt achieved

The attempt failed at approximately **739 names found**. In rough order:

1. **Keeping packaged `.pdb` assets.** They worked on hardware but over-listed reality by three to
   four times, so pilots met names their vehicle did not have, and every ArduPilot release needed
   regeneration. Replacing them was a legitimate goal; it just did not land.
2. **Building in the Parameters page.** Needed about 128 KiB with the browser resident, so it
   exhausted the heap on every retry.
3. **Moving the build to a Tools script.** Reached the build, which is real progress, but still
   exhausted the heap while running. A tool gets its own Lua state and no instruction budget, but
   it does not get more memory: `custom_l_alloc` draws every state from one file-scope pool.
4. **Removing the `table` dependency.** Fixed a genuine crash, since `table` is `nil` on a
   monochrome radio, and changed nothing about memory.
5. **Removing the per-record `string.rep` and a looped `..` concatenation.** Cut the host-measured
   run-phase peak from 509 KiB to 197 KiB and changed nothing on the radio.
6. **Lean labelling tables.** Replaced six label-keyed tables and a duplicated label list with
   integer-indexed arrays and a permutation, after proving that labels are contiguous in the
   sorted file (23 labels produced 23 runs, 0 splits, including the RC/RC1..RC12 family). Reduced
   resident header-phase staging by 26% on the host, from 47.1 to 34.9 KiB.

Step 6 is the one that matters for a future attempt: it is the only change that attacked the
measured constraint rather than a guessed one, and it still did not fit. That is evidence the
remaining cost is structural rather than a table or two.

## Why this took so long, and the lesson worth keeping

**The host memory harness is not a valid predictor for this path.** It runs under a capped
allocator, and forcing collection at a tight cap hides accumulated garbage, so it reported
improvements that hardware never confirmed. Several iterations looked like convergence for that
reason. `AGENTS.md` now states this as a rule.

Related: on every pass the measuring instrument needed fixing before the subject did. The host
harness masked garbage; the probe used `path:find`, which EdgeTX does not support because strings
have no metatable; the test harness accumulated drawn strings and faked a 32 KiB leak; the staging
measurement double-divided its units. Each was caught by testing the instrument rather than
trusting it, which is worth continuing.

A second lesson: **adding safeguards to a failing build did not converge.** Every change reduced a
measured number and none changed the outcome. A future attempt should establish that the whole
operation fits the budget before building features on it.

## If this is ever revisited

Start from the measured budget rather than from a design, and prefer a shape whose memory is
O(page) rather than O(list):

- The external merge sort exists only to produce one globally alphabetical name file. Ordering by
  category-then-name instead removes the sort and the merge entirely, and nothing then holds more
  than a page.
- Browsing by filtered scan keeps peak memory independent of vehicle size. A Tools script has no
  instruction budget, so the scan can spread across callbacks.
- Measure the design on the radio with `tools/diag/MAVHEAP.lua` **before** implementing it, not
  after.

The ExpressLRS list session needed by any such design is implemented and tested on the
`feature/mavlink-lua-parameter-list` branch. Nothing consumes it, so treat it as an unproven
prerequisite rather than a working feature.

## Safety and protocol contracts

- `READY` comes from MAVLink `SYS_STATUS` pre-arm present/enabled/health masks; `ARMED` comes from the explicit ArduPilot status bit. Status text is never used as state.
- Parameter writes require fresh disarmed state, a reread of the original value, explicit Save, one `PARAM_SET`, and a separately requested matching readback. Unknown outcomes are not retried.
- The matching ExpressLRS TX bridge accepts only unsigned MAVLink PING, `PARAM_REQUEST_READ`, `PARAM_SET`, and a strict `MAV_CMD_REQUEST_MESSAGE(AUTOPILOT_VERSION)` from handset Lua system/component 254/190.
- The legacy CRSF `0xAA` envelope is claimed by the TX module in `TXModuleEndpoint::handleRaw`, because its first payload bytes are a chunk marker and MAVLink length rather than CRSF addresses. Keep the interception there; intercepting in the handset before routing was rejected in review.
- Parameter names are only usable once read from the vehicle. Never seed the browse tree from packaged metadata.
- The index is written directly into `SCRIPTS/MAV/`, never a subdirectory. `io` has no `mkdir` and FatFs will not create a missing parent, so the builder can only write where the package already ships a folder.
- The builder writes fixed-size records to the open file one at a time, in bounded batches. Never accumulate a run or a copy in one string with `..`, and never pad with a per-record `string.rep`; both exhaust the heap, the second while reporting `not enough memory for buffer allocation`.
- Navigation/Messages remain available on older firmware; parameter modules load only on EdgeTX 2.11 or newer.
- Both packages ship stripped `.luac` caches, because firmware compiles a module whose cache is missing and that compile is what exhausts the heap.
- **The TX module firmware must be newer than the last change to `src/lib/MavLuaBridge/MavLuaBridge.h`.** A module built before `PARAM_REQUEST_LIST` support silently drops the list request, so a build reports `0 names` while identity still works. That asymmetry has already been mistaken for a code bug.

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
