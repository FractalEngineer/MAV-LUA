# MAV-LUA development guide

## Working agreement

- Keep README.md user-facing: features, installation, controls and previews. Put implementation details here.
- Keep the independent MAV name. Text uses native bitmap glyphs and integer coordinates. Grey belongs only to the navball ground; no antialiasing or per-letter scaling in previews.
- Commit a working radio state when the user approves it. v0.1.1 is explicitly authorized now. The new Parameters work must remain uncommitted until the user confirms it on hardware.
- Never rewrite an existing release tag. Every new tag ships source AND compiled packages for both pre-edgetx-2.11rc1 and post-edgetx-2.11rc1. RC1 itself belongs to post.
- Preserve required LICENSE/SPDX notices and the desktop font notices. There is no attribution section in the user README.
- Use one telemetry queue consumer. A parameter module receives packets from that consumer; it must not pop the shared queue itself.
- Parameter downloads are opt-in. Do not write a value on scroll or while editing. Require an explicit save action and matching autopilot readback before reporting success. No automatic parameter download on load/page switch.
- Do not equate a CRSF device parameter with an autopilot parameter. Stock ELRS 4.1 converts telemetry but does not expose a raw parameter stream to handset Lua. Any bridge requirement must be documented and shown honestly in the UI.

## Current hardware and versions

The user confirmed the r4 fixes for release and source Lua on a TBS Alpha running EdgeTX 2.11. Earlier Tango 2 testing used FreedomTX 1.4.0. The Alpha is connected to a Zorro internal ELRS 4.1 module via the full-duplex external-bay serial connection. New Lua 5.3 compiled artifacts are host-validated until specifically radio-confirmed. A 15-minute hardware soak has not been reported.

EdgeTX 2.11 RC1 changes from Lua 5.2 to 5.3. The new ABI uses int32 and float32: assembling a uint32 can overflow integers or discard low bits as float. Decode disjoint packed byte fields directly. Source syntax must remain compatible with Lua 5.2 unless a lazily loaded modern-only module explicitly checks support.

The legacy binary format has number/string tags 5/6 and size32/double64. The modern format has standard tags, size32/int32/float32. Compiler bootstrap downloads have pinned SHA-256 checks. Long string sizes must also be 32-bit, not just the header field. The independent readers in tools/lua52.py and tools/lua53.py validate nested prototypes.

## Build, test and release

Windows commands (omit .exe on Linux):

```powershell
python tools/build.py --bootstrap --toolchain-only
python tools/build53.py
python tools/firmware_test.py
.build/lua.exe tests/test_mav.lua
.build/lua53.exe tests/test_mav.lua
.build/lua.exe tests/test_widget.lua
python tools/build.py --luac .build/luac.exe --luac-post .build/luac53.exe --version v0.1.1
.build/lua.exe tests/test_package.lua
.build/lua53.exe tests/test_package.lua .build/MAV-post.lua
.build/lua-freedomtx140.exe tests/test_freedomtx140.lua .build/MAV.lua
python -m unittest discover -s tests -p "test_*.py"
```

Use --archive to bootstrap from an existing pinned Lua tarball. Development packages use --version dev. Source packages for the two families intentionally contain the same portable source. Compiled packages contain both discovery .lua and cache .luac names, plus corresponding source under SOURCE/. Never install source over an old binary cache without removing that cache.

For a release, finish tests, regenerate previews, copy the release assets/checksums under releases/<tag>/, commit, create an annotated tag with the changelog in its message, and push commit/tag atomically. Publish the four ZIPs and SHA256SUMS.txt. The tag-triggered GitHub workflow also builds and attaches these assets for future tags. Keep parameters under development out of the confirmed v0.1.1 tag.

Tests include source and compiled ABI checks, bounded history, malformed packets, geometry, real C cursor behavior under the legacy tail-call defect, grey-only instrument pixels, sustained traffic, and the 10,000-instruction callback budget. The desktop runner is not a full firmware emulator. Lua mock internals are excluded in the dedicated Tango instruction counter because firmware APIs are C functions.

tools/preview.py uses original FreedomTX STD or SQT5 bitmap sheets. Font assets are desktop-only. Exported images go to ignored dist/previews; reviewed README images are copied to docs/images. Avoid treating generated desktop previews as hardware screenshots.

## Telemetry implementation


Standard CRSF frames become firmware sensors; custom status frames reach Lua. This is a **MAVLink-over-CRSF viewer**, not a direct serial MAVLink endpoint. The validated status path is the one established by the [reference status-messages branch](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/tree/status-messages) and described in [ExpressLRS's MAVLink documentation](https://www.expresslrs.org/software/mavlink/).

| Display | Sensor | Expected units |
| --- | --- | --- |
| Navball / heading | `Ptch`, `Roll`, `Yaw` | Radians; ArduPilot/ELRS positive pitch means nose up |
| Battery / current | `RxBt` or `BtRx`, `Curr` | Volts / amps |
| Satellites / link | `Sats`, `RQly` | Count / percent |
| Flight mode | `FM`, or custom `0x5001` + `0x5007` | Transmitted text preferred; fallback decodes ArduPilot Plane/VTOL, Copter and Rover/Boat modes |
| Arm state | Custom `0x5001` | Explicit armed bit; not inferred from mode text |
| Home distance / dial | Custom `0x5004` | Metres; dial marks the aircraft's bearing FROM home |
| Ground speed | `GSpd` | km/h by default; knots, mph, m/s and ft/s labels follow sensor metadata |
| Altitude | `GAlt`, falling back to `Alt` | Metres or feet, following sensor metadata |

Keep stock attitude, voltage and current units. Renamed sensors require updating the compact `names` list in the source and rebuilding. Reload the model after changing sensor assignments. Missing names are retried once per second; existing IDs are cached.

- `FM` is displayed as sent. In the referenced ELRS/ArduPilot convention, a trailing `*` means disarmed. Absence of `*` is not independently treated as proof of arming.
- Missing `FM` uses the passthrough mode and vehicle type. Unknown types/modes remain numeric (`M5`, for example), rather than guessing an aircraft family. These packed mode IDs are ArduPilot-specific.
- The top-right status is `ARMD` for confirmed armed, `!RDY` after a recent `PreArm:` message, or `RDY` after the exact message `Ready to arm`. Disarmed without an explicit readiness report is `RDY?`; missing/stale arm telemetry is `ARM?`. This transport has no pre-arm readiness bit. Readiness text expires after ten seconds and is cleared on arm/disarm transitions.
- N/S/E/W stay north-up. The dial's chevron locates the aircraft relative to home; it is independent of yaw. `HDG` remains the aircraft's heading. The home distance is repeated in `HOM` and over the instrument (`k` means kilometres). ELRS derives these values from the autopilot's home position, so no Lua capture-at-arm is needed. This follows home changes made by the autopilot and works when the script starts after arming.
- Home and AP status expire three seconds after their last custom frame and clear on link loss. Zero home distance is ambiguous before ELRS receives `HOME_POSITION`, so it displays `--m`; the direction marker is hidden below two metres. Home validity and update rate still need confirmation on the user's link.
- Satellite count is not a GPS-fix or home-position indicator. Neither is invented from satellite count.
- `GAlt` is relative altitude in the referenced ELRS MAVLink conversion. Other senders may supply GPS altitude above sea level. The screen does not invent or subtract a home altitude.
- Global link loss blanks readings and crosses out the attitude instrument. Newer firmware's `getSourceValue()` also suppresses individually stale sensors. FreedomTX/older APIs cannot distinguish an individually stale cached value while the overall link remains active; a stationary value is not treated as evidence of freshness.
- Missing attitude is crossed out, never displayed as level. Zero is a valid pitch, roll, speed or altitude reading.
- Status is capped at 50 received bytes. The conversion does not carry MAVLink 2 chunk IDs; longer messages cannot be reconstructed here. Control/non-ASCII bytes become spaces.
- No parameter requests/writes, command transmission, alarms, speech, configuration menus, logging, maps, or background module-loading graph is included in v1. The received `0x5007` vehicle-type report is telemetry, not a parameter browser.

See [the protocol notes](docs/PROTOCOL.md) for the source and API contracts.


## Protocol and historical failure analysis

# Transport and firmware notes

## Why sensors and a custom-frame reader

[EdgeTX's CRSF dispatcher](https://github.com/EdgeTX/edgetx/blob/main/radio/src/telemetry/crossfire.cpp) handles GPS, battery, attitude, flight mode and link statistics as firmware telemetry sensors. Unhandled frames are forwarded to the Lua telemetry queue. Reading ordinary attitude/GPS frames only through `crossfireTelemetryPop()` would therefore leave Navigation empty on normal firmware.

MAV reads ten known sensor names. It pops at most eight packets per callback through one `crossfireTelemetryPop()` call site, stopping after **one custom-command candidate**, including malformed or unsupported payloads. Both `run()` and `background()` use that same dispatcher so collection continues while the telemetry page is hidden. Other permanent script consumers must not share that raw queue.

The custom-frame limit matters: [OpenTX's permanent-script budget](https://github.com/opentx/opentx/blob/2.3/radio/src/lua/interface.cpp) is 10,000 Lua instructions per callback. r3 reserves drawing headroom for grey fill, home navigation and proportional wrapping. Tests exercise full-length text and nine-tuple passthrough packets with full history and extreme attitude. The firmware queue is finite, so sustained traffic faster than the callback drain rate can still lose messages. There is no delivery acknowledgement or loss recovery in this status conversion.

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

## AP state and home payloads (r3)

The same custom commands carry `0xF0` single tuples and `0xF2` counted tuples. `F0` is seven bytes: subtype, little-endian uint16 ID, little-endian uint32 value. `F2` starts with subtype and count, followed by exactly `count` six-byte tuples. Counts 1–9 are accepted. Length and all bytes are validated before changing any state. Unknown IDs are ignored. Arithmetic decoding avoids a dependency on `bit32`.

| ID | Decoding |
| --- | --- |
| `0x5001` AP status | Bits 0–4 are `(custom_mode + 1) & 31`; bit 8 is armed. No pre-arm readiness bit is present. |
| `0x5007` parameter report | Upper byte 1 identifies frame type; low 24 bits are MAV_TYPE, used only to select a mode-name family. |
| `0x5004` home | Distance is bits 2–11 × 10^(bits 0–1), metres. Bits 25–31 encode absolute bearing **to home** in three-degree increments. The dial reverses it by 180 degrees for the aircraft's bearing **from home**. This reciprocal-bearing interpretation is intended for local flight, not long-distance geodesic navigation. |

Sources: [ELRS converter and HOME_POSITION handling](https://github.com/ExpressLRS/ExpressLRS/blob/master/src/lib/MAVLink/MAVLink.cpp), [ELRS bit packing](https://github.com/ExpressLRS/ExpressLRS/blob/master/src/lib/MAVLink/ardupilot_custom_telemetry.cpp), [ArduPilot native passthrough](https://github.com/ArduPilot/ardupilot/blob/master/libraries/AP_Frsky_Telem/AP_Frsky_SPort_Passthrough.cpp). The packing helper's home-bearing comment says aircraft-relative, but its caller computes absolute bearing from geographic coordinates; the dial follows that calculation.

AP status and home each have a three-second freshness timer. Readiness is only an explicit text report (`PreArm:` or exact `Ready to arm`) with a ten-second lifetime, cleared by an armed-state transition. `RDY?` is disarmed with unknown readiness; `ARM?` means no fresh arm-state report. A blank/numeric `FM` sensor falls back to custom mode. Unknown families/IDs remain numeric. No ArduPilot parameter requests or writes occur.

ELRS's home conversion can emit zero distance before receiving home coordinates. The script therefore hides zero home distance, rejects reserved bearings ≥360°, and hides the chevron below two metres. This does not add a home-lock flag to the transport; compare against the ground station during hardware acceptance.

## Proportional text and grey drawing (r3)

Use `lcd.getTextWidth` where exported. FreedomTX instead exports `lcd.getLastRightPos`: a normal-font measurement draw at `(0, LCD_H + 1)` advances that cursor while its pixel bounds checks discard the entire glyph. Measurements occur only during visible `run()`, never in background. Strings that cross the physical right edge may measure conservatively because clipped glyphs stop being condensed; binary fitting still finds an in-bounds prefix. Firmware with neither API retains a conservative fixed-width fallback. No font cache or bitmap is retained.

Ground scanlines are clipped to the circle and banked horizon. On Tango, `GREY(8)` supplies the grey level and `FORCE` avoids XOR holes in foreground strokes. Color uses solid grey bands; one-bit displays retain spaced lines. Firmware references: [text cursor, glyph clipping and grey pixel implementation](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/gui/common/stdlcd/lcd_4bits.cpp), [Lua LCD API](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/lua/api_lcd.cpp).

### FreedomTX 1.40 runtime corrections (r4)

The [1.40 VM](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/thirdparty/Lua/src/lvm.c) falls through from `OP_TAILCALL` into `OP_RETURN` after calling C. With zero arguments, the call instruction's `B=1` becomes a zero-result return. Thus `return lcd.getLastRightPos()` returns no value, and r3 fails on Navigation's first width subtraction. Assigning the C result to a local and returning that value avoids the defective path. `textWidth` also falls back if a measurement API returns nil. The packager now rejects zero-argument tail-call instructions.

`tools/firmware_test.py` reproduces that fallthrough in a separate host runner and registers a native C cursor getter. The old r3 source reproduced the reported arithmetic error at Navigation line 319; the corrected source and stripped artifact are tested with that same defect present. A Lua-function cursor mock does not expose this C-call bug.

The [1.40 type names](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/thirdparty/Lua/src/ltm.c) include `lightfunction` for native read-only functions. Grey capability detection accepts both `function` and `lightfunction`. Radio text remains native black/white `lcd.drawText`; desktop previews now use the original firmware bitmap glyphs. No smoothing, fonts, or grey text have been added to the radio runtime.

## Memory contract

- One retained script on monochrome radios, with no dynamic module loading.
- Twenty reusable history-entry tables and at most 50 text bytes per entry.
- Ten cached sensor identifiers/units and ten current values; no enumeration of all sensors.
- No dependency on the global `table` library, `bit32`, `CENTERED`, images, localization or third-party Lua libraries.
- Only visible rows and the selected entry's preview are formatted for display; no retained wrapped-line cache.
- No queued message popups. Status history, its unread count and Navigation's latest-message line carry notifications.

The reference's [integrated handoff](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/status-messages/CODEX_HANDOFF_EdgeTX_MAVLink_Status_Messages.md) reports that earlier full-INAV combinations still ran out of memory after receiving messages. Its [standalone handoff](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/status-messages/CODEX_HANDOFF_Discrete_MAVLink_Status_Screen.md) supplies the constraints used here. This repository extends that standalone architecture with the user's requested small Navigation page; it does not reuse the failed integrated architecture.

## Bytecode

The Tango build checks the full 18-byte header (beginning `1b 4c 75 61 52 00 01 04 04 04 08 00`): Lua 5.2, format 0, little endian, 4-byte int, 4-byte serialized string length, 4-byte instructions and 8-byte floating-point numbers. **It also walks every function and constant**, enforcing firmware number/string tags 5/6, bounded vector/string lengths, stripped debug data and no trailing bytes. `tools/lua52.py` performs this independent validation before binary packaging. This is not a universal EdgeTX bytecode format.

The first package matched the header but incorrectly encoded constants with stock Lua's tags 3/4. FreedomTX reserves tags 2/3 for read-only tables and light functions, shifting numbers and strings to 5/6. Its loader can lose alignment on those unexpected tags, reading payload bytes as enormous allocation counts. The observed immediate `block too big` failure on FreedomTX 1.4.0 is consistent with this format mismatch; it does not by itself establish an exhausted Lua heap. Revision 2 fixes serialization and adds regression tests that reject stock-tag chunks with otherwise identical headers.

Source contracts: [FreedomTX's type tags](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lua.h), [constant loader](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lundump.c), and [allocation-overflow guard](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lmem.h).

Both `MAV.lua` and `MAV.luac` contain the corrected identical bytecode. [FreedomTX's file-selection logic](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/lua/interface.cpp) can prefer an existing same-name compiled cache; installing both overwrites that cache too. Only MAV is listed as the telemetry script. Readable source is included under `SOURCE/`, away from radio script discovery paths.

The reference Lua patches include [lua.h (type tags)](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lua.h), [ldump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/ldump.c), [lundump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lundump.c), and [luaconf.h](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/luaconf.h). The local bootstrap translates tags in the serializer/loader while keeping the host VM's internal types and allocations native; it does not emulate all firmware runtime behavior.
