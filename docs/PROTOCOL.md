# Transport and firmware notes

## Why sensors and a custom-frame reader

[EdgeTX's CRSF dispatcher](https://github.com/EdgeTX/edgetx/blob/main/radio/src/telemetry/crossfire.cpp) handles GPS, battery, attitude, flight mode and link statistics as firmware telemetry sensors. Unhandled frames are forwarded to the Lua telemetry queue. Reading ordinary attitude/GPS frames only through `crossfireTelemetryPop()` would therefore leave Navigation empty on normal firmware.

MAV reads ten known sensor names. It consumes at most eight custom packets per callback through one `crossfireTelemetryPop()` call site, stopping after two status-text candidates, including malformed ones. Both `run()` and `background()` use that same dispatcher so collection continues while the telemetry page is hidden. Other permanent script consumers must not share that raw queue.

The additional text-frame limit matters: [OpenTX's permanent-script budget](https://github.com/opentx/opentx/blob/2.3/radio/src/lua/interface.cpp) is 10,000 Lua instructions per callback. Eight full-length status packets plus Navigation drawing measured approximately 18,400 instructions in the desktop harness. Two text candidates leave drawing headroom; the rest stay in firmware's queue. The firmware queue is finite, so sustained traffic faster than the callback drain rate can still lose messages. There is no delivery acknowledgement or loss recovery in this status conversion.

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

## Memory contract

- One retained script on monochrome radios, with no dynamic module loading.
- Twenty reusable history-entry tables and at most 50 text bytes per entry.
- Ten cached sensor identifiers/units and ten current values; no enumeration of all sensors.
- No dependency on the global `table` library, `bit32`, `CENTERED`, images, localization or third-party Lua libraries.
- Only visible rows and the selected entry's preview are formatted for display; no retained wrapped-line cache.
- No queued message popups. Status history and the Navigation unread count carry notifications.

The reference's [integrated handoff](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/status-messages/CODEX_HANDOFF_EdgeTX_MAVLink_Status_Messages.md) reports that earlier full-INAV combinations still ran out of memory after receiving messages. Its [standalone handoff](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/status-messages/CODEX_HANDOFF_Discrete_MAVLink_Status_Screen.md) supplies the constraints used here. This repository extends that standalone architecture with the user's requested small Navigation page; it does not reuse the failed integrated architecture.

## Bytecode

The Tango build checks the full 18-byte header (beginning `1b 4c 75 61 52 00 01 04 04 04 08 00`): Lua 5.2, format 0, little endian, 4-byte int, 4-byte serialized string length, 4-byte instructions and 8-byte floating-point numbers. **It also walks every function and constant**, enforcing firmware number/string tags 5/6, bounded vector/string lengths, stripped debug data and no trailing bytes. `tools/lua52.py` performs this independent validation before binary packaging. This is not a universal EdgeTX bytecode format.

The first package matched the header but incorrectly encoded constants with stock Lua's tags 3/4. FreedomTX reserves tags 2/3 for read-only tables and light functions, shifting numbers and strings to 5/6. Its loader can lose alignment on those unexpected tags, reading payload bytes as enormous allocation counts. The observed immediate `block too big` failure on FreedomTX 1.4.0 is consistent with this format mismatch; it does not by itself establish an exhausted Lua heap. Revision 2 fixes serialization and adds regression tests that reject stock-tag chunks with otherwise identical headers.

Source contracts: [FreedomTX's type tags](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lua.h), [constant loader](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lundump.c), and [allocation-overflow guard](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/thirdparty/Lua/src/lmem.h).

Both `MAV.lua` and `MAV.luac` contain the corrected identical bytecode. [FreedomTX's file-selection logic](https://github.com/tbs-fpv/freedomtx/blob/2.3-freedomtx/radio/src/lua/interface.cpp) can prefer an existing same-name compiled cache; installing both overwrites that cache too. Only MAV is listed as the telemetry script. Readable source is included under `SOURCE/`, away from radio script discovery paths.

The reference Lua patches include [lua.h (type tags)](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lua.h), [ldump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/ldump.c), [lundump.c](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/lundump.c), and [luaconf.h](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/blob/7883be9d73a0f1c81f2f065e85f719ead83753d9/3rdparty/lua-5.2.4/src/luaconf.h). The local bootstrap translates tags in the serializer/loader while keeping the host VM's internal types and allocations native; it does not emulate all firmware runtime behavior.
