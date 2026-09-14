# Transport and firmware notes

## Why sensors and a custom-frame reader

[EdgeTX's CRSF dispatcher](https://github.com/EdgeTX/edgetx/blob/main/radio/src/telemetry/crossfire.cpp) handles GPS, battery, attitude, flight mode and link statistics as firmware telemetry sensors. Unhandled frames are forwarded to the Lua telemetry queue. Reading ordinary attitude/GPS frames only through `crossfireTelemetryPop()` would therefore leave Navigation empty on normal firmware.

MAV reads ten known sensor names. It pops at most eight packets per callback through one `crossfireTelemetryPop()` call site, stopping after **one custom-command candidate**, including malformed or unsupported payloads. Firmware identity is the only two-chunk parameter reply and may consume a bounded second `0xAA` candidate while its simple loading screen is visible. Both `run()` and `background()` use that same dispatcher so collection continues while the telemetry page is hidden. Other permanent script consumers must not share that raw queue.

The custom-frame limit matters: [OpenTX's permanent-script budget](https://github.com/opentx/opentx/blob/2.3/radio/src/lua/interface.cpp) is 10,000 Lua instructions per callback. MAV reserves drawing headroom for grey fill, home navigation and proportional wrapping. Tests exercise full-length text and nine-tuple passthrough packets with full history and extreme attitude. The firmware queue is finite, so sustained traffic faster than the callback drain rate can still lose messages. There is no delivery acknowledgement or loss recovery in this status conversion.

API references: [getValue](https://luadoc.edgetx.org/2.11/lua-api-reference/variables/getvalue), [crossfireTelemetryPop](https://luadoc.edgetx.org/edgetx_2.4/part_iii_-_opentx_lua_api_reference/general-functions-less-than-greater-than-luadoc-begin-general/crossfiretelemetrypop), [current firmware value/validity implementation](https://github.com/EdgeTX/edgetx/blob/main/radio/src/lua/api_general.cpp), [unit enumeration](https://github.com/EdgeTX/edgetx/blob/main/radio/src/dataconstants.h).

## Status payload

The contract is taken from the reference's hardware-validated branch and checked against [ExpressLRS's converter](https://github.com/ExpressLRS/ExpressLRS/blob/master/src/lib/MAVLink/MAVLink.cpp).

| Item | Value |
| --- | --- |
| Command | `0x80`, or legacy `0x7F` |
| Payload byte 1 | `0xF1` |
| Payload byte 2 | MAVLink severity, integral byte |
| Payload bytes 3–52 | Up to 50 text bytes, optional NUL terminator |

This specific Lua contract has no destination/origin prefix before the subtype. Do not add speculative header offsets from other extended CRSF frame types. Firmware/transport changes need captured frames and a separate decoder contract. See the [TBS CRSF specification](https://github.com/tbs-fpv/tbs-crsf-spec/blob/main/crsf.md).

Severity 0–7 renders as EMR, ALR, CRT, ERR, WRN, NOT, INF, DBG; 0–3 get `!`. Other integral byte values render as UNK. Reject malformed bytes before constructing a message string. Stop at NUL; bytes beyond the first 50 or after NUL are not displayed. No chunk IDs are transmitted by this conversion, so concatenating fragments would risk combining unrelated messages.

## Ready-to-arm system status

The matching ELRS TX converter forwards MAVLink `SYS_STATUS` as standard CRSF frame `0xAC`: three big-endian uint32 masks in `present`, `enabled`, `health` order. EdgeTX 2.11 does not decode this frame as a sensor, so its default CRSF path delivers the twelve payload bytes unchanged to Lua. The Lua decoder reads bit 28 directly from the first byte of each disjoint field, avoiding uint32 assembly under EdgeTX's int32/float32 Lua ABI.

`MAV_SYS_STATUS_PREARM_CHECK` is authoritative only when present. While disarmed, `READY` means the check is disabled or healthy, `NOT READY` means it is enabled and unhealthy, and `READY?` means the capability, readiness frame, or explicit arm state is absent/stale. Armed state still comes from passthrough `0x5001` and displays `ARMED`; this matters because ArduPilot reports the pre-arm bit healthy after arming. Only `READY` and `ARMED` use inverse video. Both signals expire after three seconds and clear on link loss. `STATUSTEXT` remains informational and never changes readiness.

This matches Mission Planner's `connected && (health.prearm || !enabled.prearm)` rule. The matching TX bridge observes a fresh ArduPilot heartbeat and requests one-shot `SYS_STATUS` at most once per second while the message is missing or older than two seconds; an active `EXT_STAT` stream suppresses those requests. This path does not depend on opening or loading Parameters.

## Parameter identity and exact reads

Standard MAVLink has no category or wildcard parameter query. The v0.1.3 browser therefore packages compact Plane and Copter name databases generated from official ArduPilot 4.6, 4.7, and 4.8-dev metadata. Load first discovers an ArduPilot component-1 heartbeat, then sends a strictly formed `MAV_CMD_REQUEST_MESSAGE` for `AUTOPILOT_VERSION`. The bridge forwards that unsigned reply in standard CRSF `0xAA` chunks; the Lua decoder retains only the in-progress two-chunk packet. Vehicle type plus `flight_sw_version` major/minor selects the database. Unsupported versions or vehicle families fail before any parameter request.

Each database stores fixed 22-byte top-level and optional second-level category records followed by fixed 16-byte parameter names. Repeated numbered groups are nested under their common base, so `RC`, `RC1` through `RC16` appear inside one `RC` folder. The high count bit distinguishes folders, whose offsets point to child records. The four-field Lua manifest holds identity, path, and top-level count. Opening any category page reads at most 176 bytes; opening a name page uses [EdgeTX's bounded IO API](https://luadoc.edgetx.org/2.10/part_ii_-_opentx_lua_api_programming_guide/included_lua_libraries/io-library) to seek directly to `category_offset + (row - 1) * 16` and read at most 128 bytes. All browse levels wrap at their first and last items, and scrolling does not use MAVLink. ENTER sends `PARAM_REQUEST_READ` with index `-1` and the exact selected name; ArduPilot's matching `PARAM_VALUE` also carries index `-1`, so the bridge matches its name before examining indexed reservations. Optional or board-specific names absent from the connected vehicle time out as unavailable.

The TX bridge keeps one bounded named-read reservation in addition to legacy indexed-read compatibility. It forwards only a matching `PARAM_VALUE`. Write safeguards are unchanged: reread the selected name, preserve its wire type, require a fresh disarmed heartbeat, transmit one `PARAM_SET`, and require a separate matching readback. A post-transmission timeout remains an unknown outcome and is never retried automatically.

## AP state and home payloads

The same custom commands carry `0xF0` single tuples and `0xF2` counted tuples. `F0` is seven bytes: subtype, little-endian uint16 ID, little-endian uint32 value. `F2` starts with subtype and count, followed by exactly `count` six-byte tuples. Counts 1–9 are accepted. Length and all bytes are validated before changing any state. Unknown IDs are ignored. Arithmetic decoding avoids a dependency on `bit32`.

| ID | Decoding |
| --- | --- |
| `0x5001` AP status | Bits 0–4 are `(custom_mode + 1) & 31`; bit 8 is armed. No pre-arm readiness bit is present. |
| `0x5007` parameter report | Upper byte 1 identifies frame type; low 24 bits are MAV_TYPE, used only to select a mode-name family. |
| `0x5004` home | Distance is bits 2–11 × 10^(bits 0–1), metres. Bits 25–31 encode absolute bearing **to home** in three-degree increments. The dial reverses it by 180 degrees for the aircraft's bearing **from home**. This reciprocal-bearing interpretation is intended for local flight, not long-distance geodesic navigation. |

Sources: [ELRS converter and HOME_POSITION handling](https://github.com/ExpressLRS/ExpressLRS/blob/master/src/lib/MAVLink/MAVLink.cpp), [ELRS bit packing](https://github.com/ExpressLRS/ExpressLRS/blob/master/src/lib/MAVLink/ardupilot_custom_telemetry.cpp), [ArduPilot native passthrough](https://github.com/ArduPilot/ardupilot/blob/master/libraries/AP_Frsky_Telem/AP_Frsky_SPort_Passthrough.cpp). The packing helper's home-bearing comment says aircraft-relative, but its caller computes absolute bearing from geographic coordinates; the dial follows that calculation.

AP status and home each have a three-second freshness timer. The armed bit gates the primary indicator as described above; it is not itself readiness. A blank/numeric `FM` sensor falls back to custom mode. Unknown families/IDs remain numeric. These status tuples do not request or write autopilot parameters.

ELRS's home conversion can emit zero distance before receiving home coordinates. The script therefore hides zero home distance, rejects reserved bearings ≥360°, and hides the filled direction triangle below two metres. Its small scanlines split at the attitude horizon so it is white over the dark half and black over grey ground. This does not add a home-lock flag to the transport; compare against the ground station during hardware acceptance.

## Proportional text and grey drawing

Use `lcd.getTextWidth` where exported. FreedomTX instead exports `lcd.getLastRightPos`: a normal-font measurement draw at `(0, LCD_H + 1)` advances that cursor while its pixel bounds checks discard the entire glyph. Measurements occur only during visible `run()`, never in background. Strings that cross the physical right edge may measure conservatively because clipped glyphs stop being condensed; binary fitting still finds an in-bounds prefix. Firmware with neither API retains a conservative fixed-width fallback. No font cache or bitmap is retained.

Ground scanlines are clipped to the circle and banked horizon. On Tango, `GREY(8)` supplies the grey level and `FORCE` avoids XOR holes in foreground strokes. Color uses solid grey bands; one-bit displays retain spaced lines. Firmware references: [text cursor, glyph clipping and grey pixel implementation](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/gui/common/stdlcd/lcd_4bits.cpp), [Lua LCD API](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/lua/api_lcd.cpp).

### FreedomTX 1.40 runtime correction

The [1.40 VM](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/thirdparty/Lua/src/lvm.c) falls through from `OP_TAILCALL` into `OP_RETURN` after calling C. With zero arguments, the call instruction's `B=1` becomes a zero-result return. Assigning the C result to a local before returning avoids the defective path. `textWidth` also falls back if a measurement API returns nil. The packager rejects zero-argument tail-call instructions.

`tools/firmware_test.py` reproduces that fallthrough in a separate host runner and registers a native C cursor getter. The original firmware failure is reproduced by the fixture; the corrected source and stripped artifact are tested with the same defect present. A Lua-function cursor mock does not expose this C-call bug.

The [1.40 type names](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/thirdparty/Lua/src/ltm.c) include `lightfunction` for native read-only functions. Grey capability detection accepts both `function` and `lightfunction`. Radio text remains native black/white `lcd.drawText`; desktop previews now use the original firmware bitmap glyphs. No smoothing, fonts, or grey text have been added to the radio runtime.

## Memory contract

- One retained core script on monochrome radios; optional parameter chunks load only on supported modern firmware.
- Twenty reusable history-entry tables and at most 50 text bytes per entry.
- Ten cached sensor identifiers/units and ten current values; no enumeration of all sensors.
- No dependency on the global `table` library, `bit32`, `CENTERED`, images, localization or third-party Lua libraries.
- Only visible rows and the selected entry's preview are formatted for display; no retained wrapped-line cache.
- No queued message popups. Status history, its unread count and Navigation's latest-message line carry notifications.

The Parameters page retains one four-field database manifest, at most eight decoded category/name records, one selected value, and one outstanding exact-name request. Database files are read-only package assets; runtime code neither builds nor writes them. No complete live parameter list, prefetched value window, SD cache, or `params.tmp` is retained.

## Bytecode

The Tango build checks the full 18-byte header (beginning `1b 4c 75 61 52 00 01 04 04 04 08 00`): Lua 5.2, format 0, little endian, 4-byte int, 4-byte serialized string length, 4-byte instructions and 8-byte floating-point numbers. **It also walks every function and constant**, enforcing firmware number/string tags 5/6, bounded vector/string lengths, stripped debug data and no trailing bytes. `tools/lua52.py` performs this independent validation before binary packaging. This is not a universal EdgeTX bytecode format.

The first package matched the header but incorrectly encoded constants with stock Lua's tags 3/4. FreedomTX reserves tags 2/3 for read-only tables and light functions, shifting numbers and strings to 5/6. Its loader can lose alignment on those unexpected tags, reading payload bytes as enormous allocation counts. The observed immediate `block too big` failure on FreedomTX 1.4.0 is consistent with this format mismatch; it does not by itself establish an exhausted Lua heap. Revision 2 fixes serialization and adds regression tests that reject stock-tag chunks with otherwise identical headers.

Source contracts: [FreedomTX's type tags](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lua.h), [constant loader](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lundump.c), and [allocation-overflow guard](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lmem.h).

Both `MAV.lua` and `MAV.luac` contain the corrected identical bytecode. [FreedomTX's file-selection logic](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/lua/interface.cpp) can prefer an existing same-name compiled cache; installing both overwrites that cache too. Only MAV is listed as the telemetry script. Readable source is included under `SOURCE/`, away from radio script discovery paths.

The reference Lua patches include [lua.h (type tags)](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lua.h), [ldump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/ldump.c), [lundump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lundump.c), and [luaconf.h](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/luaconf.h). The local bootstrap translates tags in the serializer/loader while keeping the host VM's internal types and allocations native; it does not emulate all firmware runtime behavior.
