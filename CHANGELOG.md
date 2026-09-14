# Changelog

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
