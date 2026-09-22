# Changelog

## Unreleased

- Superseded packaged parameter databases. Parameter names now come from the connected flight controller: MAV reads the vehicle's own parameter list once and builds a fixed-record index on SD, then browses that index locally. Packaged `.pdb` name assets are no longer the browse source, and the assets themselves are removed from the package.
- Moved the index build into a standalone Tools script, **Tools > MAV Index**. Building it from inside the Parameters page needed about 128 KiB because the browser modules were already resident, which exhausted the radio heap and failed on every retry. The tool loads only the wire codec and the builder in its own Lua state, about 80 KiB at worst, and is not limited by the permanent-script instruction budget. The Parameters page now reports that no index exists and points at the tool.
- The tool writes the same identity-derived index the page browses, so the two cannot disagree, and a firmware change still resolves to "no index yet".
- Fixed the index build failing partway through with `attempt to index a nil value (global 'table')`. The builder used `table.sort` and `table.concat`, which exist on the desktop and on a colour radio, but EdgeTX registers the `table` library only for colour radios, so on a monochrome handset it is `nil`. The builder now sorts and joins without any library, and a sandbox test builds a real index with `table` removed.
- Fixed the index build working only on the second attempt. The list request was sent once and never retried, but the TX bridge refuses a request that follows another too closely and tells Lua nothing when it does, so the first attempt silently read nothing. The request is now re-sent until a name arrives, with a bounded number of attempts and a message that distinguishes a module without list support from a vehicle reporting no names.
- The builder no longer treats an instruction count as a hard budget. It runs as a Tools script, which EdgeTX does not give the permanent-script instruction limit, so the previous 8,000-instruction ceiling was measuring the wrong thing and is now a loose regression tripwire alongside a wall-clock check.
- Fixed the index build failing with a bare `Index build failed`: the builder wrote into `SCRIPTS/MAV/DB`, which existed only because the packaged databases created it. EdgeTX's `io` has no `mkdir` and FatFs does not create a missing parent, so removing those assets made the first write fail. The index now sits beside the modules in `SCRIPTS/MAV/`, and the tool clears the screen before drawing so the previous Tools menu no longer shows through.
- An index build that receives no parameters now says why: no stream at all points at the TX module firmware, while a stream with no usable names blames the vehicle. A stale module firmware previously produced a silent `0 names`.
- Optional parameter modules now load the compiled `.luac` cache when one exists and compile only when it is missing. Forcing compilation while a valid cache existed re-paid the entire compile peak on every page open, which the radio reported as `not enough memory` on an open that then succeeded when retried.
- Both packages now ship a validated `.luac` cache beside each `.lua`. A first parameter-index build had no cached builder, so EdgeTX had to compile it; when that compile ran out of heap it failed before writing a cache, so every retry failed the same way. Loading the cache instead of compiling moves that path from about 180 KiB to about 158 KiB.
- A failed index-builder load now reports the loader's own message instead of a generic `Index build failed`, so an out-of-memory compile is distinguishable from a missing index.
- Fixed the index build exhausting the radio heap and freezing around 700 names. The run phase accumulated each run's 64 padded names with `..` and wrote the result in one call, which allocates every intermediate string: about 33 KiB of garbage for a 1 KiB payload, and the collector cannot keep up because its debt threshold scales with live memory. The phase now writes each record separately, in bounded batches, so peak memory fell from 509 KiB to 197 KiB at 700 names and no longer scales with the number of runs. Padding also no longer calls `string.rep` per record; that call grows a `luaL_Buffer`, which is why the failure was reported as `not enough memory for buffer allocation` rather than plain `not enough memory`.
- Added a regression test asserting the run file only ever receives a header or one 16-byte record, because a capped-allocator test cannot detect the accumulation: a tight limit drives the collector continuously and masks it.
- Documented the discovered-index decision, the bounded/atomic build rules, and the ExpressLRS `PARAM_REQUEST_LIST` list session it requires.
- Added `uninstall-mav-lua.bat` to `src/`, which ships at the package root beside `SCRIPTS` so it can remove a previous install in one run before copying new files.

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
