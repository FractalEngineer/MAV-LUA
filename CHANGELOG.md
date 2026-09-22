# Changelog

## Unreleased

**This release line is archived. The on-radio parameter index is shelved and packaged-database
browsing is the browse source again.** The attempt got much further than the first one, but it
still could not finish a build on hardware: it fails at about 739 names found. The radio has since
been measured directly, so the failure is now understood rather than guessed at. The work is kept
here for reference; see `main` for the shipped state.

### What was measured

`tools/diag/MAVHEAP.lua` is a diagnostic Tools script that measures the Lua heap on the device and
appends each result to `/MAVHEAP.TXT` as it goes, so a stall still leaves the answer. Three runs
gave a `bare` configuration of 56 KiB obtainable, a `build` configuration (wire + index loaded) of
**30 KiB**, and a `full` configuration of 9 KiB. Total Lua heap in a Tools state is about 68 KiB.
Those numbers outlive the attempt, and they are the reason it failed: a build's whole budget for
staging tables, sort runs and file buffers is about 30 KiB.

Two further findings are worth keeping. The binding limit is total size, not fragmentation: a 16 KiB
largest contiguous allocation is ample for the ~1 KiB blocks a builder uses. And the application core
cannot load inside a Tools state at all, because it needs more than the 9 KiB that leaves, so a tool
cannot host the browser.

### What was tried

- Building the index in the Parameters page needed about 128 KiB with the browser resident, so it
  exhausted the heap on every retry.
- Moving the build into a standalone Tools script, **Tools > MAV Index**, reached the build but still
  exhausted the heap while running. A tool gets its own Lua state and is exempt from the
  permanent-script instruction budget, but not more memory: EdgeTX's `custom_l_alloc` draws every
  state from one pool.
- Removing the `table` library dependency fixed a genuine crash, since `table` is `nil` on a
  monochrome radio, and changed nothing about memory.
- Removing a per-record `string.rep` and a looped `..` concatenation cut the host-measured run-phase
  peak from 509 KiB to 197 KiB and changed nothing on the radio.
- Replacing six label-keyed staging tables and a duplicated label list with integer-indexed arrays
  and a permutation reduced resident header-phase staging by 26% on the host, from 47.1 to 34.9 KiB,
  and still did not fit. That is evidence the remaining cost is structural rather than a table or two.

### Why the host figures misled

The host memory harness runs under a capped allocator, and forcing collection at a tight cap hides
accumulated garbage, so it reported improvements hardware never confirmed. Several iterations of this
attempt looked like convergence for that reason. Radio memory claims now require radio evidence.

### Kept

- `src/uninstall-mav-lua.bat`, which removes every MAV-LUA file from the card it is run from. It is
  useful regardless of how names are eventually obtained, and it also removes the stale `.luac`
  caches that otherwise make an update appear to do nothing.
- `tools/diag/MAVHEAP.lua` and `tests/test_heap_probe.lua`, so a future attempt can measure the heap
  before designing against it.
- The ExpressLRS bounded list session on `feature/mavlink-lua-parameter-list`. Nothing consumes it,
  so it is an unproven prerequisite rather than a working feature.

### Also fixed along the way, and still valid

- Optional parameter modules load the compiled `.luac` cache when one exists and compile only when
  it is missing. Forcing compilation while a valid cache existed re-paid the entire compile peak on
  every page open, which the radio reported as `not enough memory` on an open that then succeeded
  when retried.
- Both packages ship a validated `.luac` cache beside each `.lua`.
- An index build with no parameters reports why: no stream points at the TX module firmware, a
  stream with no usable names blames the vehicle.
- The builder writes into `SCRIPTS/MAV/` rather than a subdirectory, because EdgeTX's `io` has no
  `mkdir` and FatFs does not create a missing parent.
- `tests/test_radio_libs.lua` now rejects colon-method calls such as `s:find(...)` in radio-side code
  in addition to missing libraries, because EdgeTX gives strings no metatable and the callee of a
  colon call is a variable rather than a library.

## v0.1.3

- Replaced the hardware-rejected neighboring-window cache with Mission Planner-style first-level category browsing.
- Added read-only ArduPilot 4.6/4.7/4.8-dev name databases for Plane and Copter. Category/name scrolling is local and retains only the current eight names.
- Added strict firmware discovery through `AUTOPILOT_VERSION`, standard CRSF multi-chunk replies, and exact-name parameter reads. Values are requested only when selected; verified-write safeguards are unchanged.
- Nested repeated numbered parameter groups under a common family folder, including the unnumbered base group.
- Added wraparound at both ends of category, nested-group, and parameter-name lists.
- Accepted ArduPilot's `param_index=-1` sentinel in exact-name `PARAM_VALUE` replies so selected values open correctly.
- Corrected the TX bridge's named-reply match so `param_index=-1` is not mistaken for an unused indexed slot.

Hardware confirmation: firmware discovery, nested categories, list wraparound, exact-name reads, editing, and verified saves were tested with Plane 4.8 on the TBS Alpha/EdgeTX 2.11 and RadioMaster Zorro ELRS setup. Browsing no longer downloads or retains the vehicle's complete parameter list.

## v0.1.2

- Added a third Parameters page for EdgeTX 2.11 and newer, using a bounded eight-row live window with up to four indexed reads in flight.
- Added explicit parameter editing with a fresh-value conflict check, disarmed-state gate, one-shot `PARAM_SET`, and separately requested matching readback.
- Added Mission Planner-style `READY`, `NOT READY`, `READY?`, and `ARMED` status from MAVLink `SYS_STATUS` and the explicit ArduPilot armed bit. Only positive `READY` and `ARMED` states use inverse video.
- Added a filled home-direction marker that remains visible across both halves of the attitude indicator.
- Added PAGE navigation across all three pages and a Tools entry for radios that reserve PAGE in telemetry screens.
- Added lazy modern-only parameter modules while retaining Navigation and Messages on older Lua firmware.
- Removed full-list caching and parameter-database filesystem writes. Parameter browsing retains only the current window to stay within tested radio memory limits.
- Hardened package selection and cache handling across Lua 5.2/FreedomTX and Lua 5.3/EdgeTX 2.11.
- Standardized new releases on exactly two archives: `_source` for EdgeTX 2.11 RC1 and newer, and `_precompiled` for earlier firmware.

Known limitation: crossing an eight-row parameter boundary refetches the adjacent window, so browsing large parameter sets is currently slow. Bounded background prefetch/cache work is planned.

Hardware confirmation: Navigation, readiness, and the live parameter browser were tested on TBS Alpha with EdgeTX 2.11 and a RadioMaster Zorro ELRS module connected through the full-duplex external-bay interface. Earlier Navigation and Messages testing covered Tango 2/FreedomTX 1.4.

## v0.1.1

- Clearer navigation with solid grey ground, a north-up home-bearing dial, home distance and the latest status message.
- Explicit arm state and a flight-mode fallback when the radio's mode sensor is unavailable.
- Full-width message wrapping and right-aligned telemetry values.
- Fixed the load-time nil-arithmetic failure on older Lua firmware.
- Correct unsigned telemetry decoding with EdgeTX 2.11's 32-bit Lua numbers.
- Crisp native-font previews and a simplified user guide.
- Source and compiled packages for pre-EdgeTX 2.11 RC1 and EdgeTX 2.11 RC1-and-later.
- Confirmed on Tango 2 and with source Lua on TBS Alpha running EdgeTX 2.11.

## v0.1.0

- First working Navigation and Messages pages on Tango 2.
- Twenty-message history, severity, duplicate counts and roller scrolling.
- Independent MAV script with a corrected compiled Lua format.
