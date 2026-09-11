# MAV-LUA

An independent MAVLink telemetry script named **MAV**, built first for the **Tango 2's 128×96 monochrome screen**. It can take INAV Lua Telemetry's place on the model. One permanent script contains two pages:

- **Navigation:** circular attitude instrument with bank, pitch ladder and ground hatching; flight mode, battery voltage, link quality, satellites, altitude and ground speed. Taller screens also show heading, current and pitch.
- **Messages:** newest-first status history, roller selection, severity, duplicate counts and a wrapped preview of the complete received text.

**Status: first MVP, v0.1.0.** The user confirmed the corrected r2 build runs on Tango 2 / FreedomTX 1.4.0 on 2026-09-12. Navigation and message display are working; mode display and layout improvements remain open. This confirmation does not establish a completed 15-minute soak test or validation of other radios. See [the MVP record](docs/MVP.md) for the exact archived package and known issues. Parameters remain planned for later.

## Install on Tango 2

For Tango 2/FreedomTX, use the **compiled** package built under `dist/`:

| Package | Installation |
| --- | --- |
| `MAV-LUA-tango2-freedomtx-r2.zip` | Copy the whole `SCRIPTS` folder onto the SD card, overwriting both `MAV.lua` and `MAV.luac`. Select `MAV` in the model's Lua telemetry-screen settings. |
| `MAV-LUA-source.zip` | Readable source and color-widget adapter for firmware that compiles source with sufficient memory. Start here for other Lua ABIs. |

The Tango package contains **identical stripped FreedomTX Lua 5.2 bytecode in `MAV.lua` and `MAV.luac`**. The `.lua` filename allows firmware to list MAV; the `.luac` file replaces any cached version that could otherwise take precedence. These are two filenames for one script, not two running scripts. Both use 32-bit string sizes and FreedomTX constant tags (number=5, string=6). A matching Lua header alone is insufficient. Do not install the source package over the Tango binary package. Checksums are in `dist/SHA256SUMS.txt`. Discard the failed `MAV-LUA-tango2-lua52.zip` package.

Configure MAV as the only Lua telemetry script on this constrained model. Disable INAV telemetry-screen assignments; permanent scripts share memory and `crossfireTelemetryPop()` removes packets from one shared queue. MAV has its own filename and does not overwrite or load INAV files. Do not run Yaapu, another status viewer, or a CRSF configuration script concurrently as an additional queue reader.

Reload the model or restart the radio after installation. Discover telemetry sensors in the radio's normal telemetry menu while the aircraft is connected. The script uses the same CRSF sensor names as INAV; it does not change the model or create sensors itself.

The hardware described in the reference uses **FreedomTX on Tango 2, ArduPilot, and matching ExpressLRS 4.1 TX/RX in MAVLink mode**. This replacement accommodates the relevant FreedomTX and EdgeTX APIs. Installing it does not require changing the radio's firmware. A Tango's built-in TBS Crossfire link is not an ExpressLRS link; status availability depends on the actual transmitter, receiver and autopilot transport.

## Controls

| Input | Action |
| --- | --- |
| Roller click / Enter | Switch Navigation ↔ Messages. Opening Messages selects the newest entry. |
| Roller / Next / Previous | Select older/newer messages. Full text wraps below the list. |
| Exit on Messages | Return to Navigation. |
| Radio's PAGE key | Left to firmware for normal telemetry-screen navigation. |

Raw rotary, plus/minus and up/down events are supported as fallbacks to virtual Next/Previous. Repeats scroll too. Exact event mapping still needs confirmation on the user's firmware. Page-switch instructions are omitted from the display; that space is used for telemetry and message content. Message position and unread counts appear in the header. There is no horizontal-scroll gesture to discover.

The newest 20 messages are kept in RAM. Consecutive identical text and severity within three seconds of the last receipt update `xN` (capped at 999). New traffic keeps the newest item selected while following live messages. While reading older entries, selection follows that same entry until it is evicted. `+N` indicates new entries received away from the latest-message view. History resets when the script/model reloads.

## Telemetry contract and limitations

Standard CRSF frames become firmware sensors; custom status frames reach Lua. This is a **MAVLink-over-CRSF viewer**, not a direct serial MAVLink endpoint. The validated status path is the one established by the [reference status-messages branch](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/tree/status-messages) and described in [ExpressLRS's MAVLink documentation](https://www.expresslrs.org/software/mavlink/).

| Display | Sensor | Expected units |
| --- | --- | --- |
| Navball / heading | `Ptch`, `Roll`, `Yaw` | Radians; ArduPilot/ELRS positive pitch means nose up |
| Battery / current | `RxBt` or `BtRx`, `Curr` | Volts / amps |
| Satellites / link | `Sats`, `RQly` | Count / percent |
| Flight mode | `FM` | Transmitted text, preserved including `*` |
| Ground speed | `GSpd` | km/h by default; knots, mph, m/s and ft/s labels follow sensor metadata |
| Altitude | `GAlt`, falling back to `Alt` | Metres or feet, following sensor metadata |

Keep stock attitude, voltage and current units. Renamed sensors require updating the compact `names` list in the source and rebuilding. Reload the model after changing sensor assignments. Missing names are retried once per second; existing IDs are cached.

- `FM` is displayed as sent. In the referenced ELRS/ArduPilot convention, a trailing `*` means disarmed. Absence of `*` is not independently treated as proof of arming.
- Satellite count is not a GPS-fix or home-position indicator. Neither is invented from satellite count.
- `GAlt` is relative altitude in the referenced ELRS MAVLink conversion. Other senders may supply GPS altitude above sea level. The screen does not invent or subtract a home altitude.
- Global link loss blanks readings and crosses out the attitude instrument. Newer firmware's `getSourceValue()` also suppresses individually stale sensors. FreedomTX/older APIs cannot distinguish an individually stale cached value while the overall link remains active; a stationary value is not treated as evidence of freshness.
- Missing attitude is crossed out, never displayed as level. Zero is a valid pitch, roll, speed or altitude reading.
- Status is capped at 50 received bytes. The conversion does not carry MAVLink 2 chunk IDs; longer messages cannot be reconstructed here. Control/non-ASCII bytes become spaces.
- No parameter traffic, command transmission, alarms, speech, configuration menus, logging, maps, or background module-loading graph is included in v1.

See [the protocol notes](docs/PROTOCOL.md) for the source and API contracts.

## Radio coverage

| Display family | Entry point | Current verification |
| --- | --- | --- |
| Tango 2, 128×96 monochrome | Telemetry script; stripped package | User-confirmed working r2 on FreedomTX 1.4.0; see MVP known issues |
| 128×64 monochrome | Same script; fewer navigation fields and list rows | Desktop geometry tests |
| 212×64 monochrome | Same script | Desktop geometry tests |
| 320×240, 480×272, 800×480 color | `/WIDGETS/MAV/main.lua` with `/SCRIPTS/TELEMETRY/MAV.lua` | Desktop geometry and adapter tests; hardware pending |

On color radios, replace the INAV widget with **one MAV widget**. Open it full screen for key/touch input. Tap switches pages; swipe up/down selects messages. Small widget zones show a full-screen prompt. Layouts use actual screen/zone dimensions rather than a radio-name allowlist. This is a compatibility foundation, not a claim that every radio and firmware has been tested. FrSky S.Port, F.Port and other transports need separate adapters in a later version.

## Build and check

Requires Python 3.12+ and GCC. The bootstrap downloads official Lua 5.2.4, checks its pinned SHA-256, and patches serialized string sizes and constant tags to the FreedomTX format. The host interpreter uses native allocation sizes and translates the wire tags to its own internal types on load. Run bootstrap again if upgrading from the first build; reusing that compiler will now fail the independent package validator.

```powershell
python tools/build.py --bootstrap --toolchain-only
.build/lua.exe tests/test_mav.lua
.build/lua.exe tests/test_widget.lua
python tools/build.py --luac .build/luac.exe
python -m unittest discover -s tests -p "test_bytecode.py"
.build/lua.exe tests/test_package.lua
```

On Linux, use `.build/lua` and `.build/luac`. `python tools/build.py` alone builds the source archive without a toolchain or network access. `--archive PATH` uses a previously downloaded official tarball. Build artifacts and reference downloads are ignored by Git.

`python tools/preview.py` renders the real Lua drawing calls into `dist/previews/` using Pillow and a desktop font. `--lua` and `--font` select paths on other operating systems. These previews approximate the radio font; they are not radio screenshots.

Tests cover malformed/custom frames, missing optional APIs and libraries, deduplication, eviction, queue limits, input aliases, telemetry validity, layouts and sustained traffic. Follow [the hardware acceptance procedure](docs/HARDWARE-TEST.md) before treating the package as radio-validated.

## Parameters: later

The proposed third page uses favorites and recently visited parameters first, followed by prefix groups and a short search/filter editor. The roller moves through one list; click opens a value; Back cancels. An explicit review-and-write step displays the old and proposed values, then waits for an acknowledgement/readback before showing success.

Use paged requests and a bounded cache, not a complete parameter table in Tango memory. Keep descriptive metadata on SD and load it only when needed. Parameter browsing/editing must replace or unload page-specific data within the same runtime budget. First verify that the chosen link exposes an actual bidirectional autopilot parameter transport: ordinary CRSF device parameters are not automatically MAVLink autopilot parameters.

## Attribution

Protocol behavior and the Tango memory constraints were informed by FractalEngineer's status-messages work on [INAV Lua Telemetry](https://github.com/FractalEngineer/OpenTX-Telemetry-Widget/tree/status-messages), pinned at `7883be9d73a0f1c81f2f065e85f719ead83753d9`. The new implementation uses one compact runtime, a reusable ring buffer, and a new navigation renderer instead of loading INAV's runtime/modules. Distributed under GPL-3.0-or-later; see [LICENSE](LICENSE). Lua's build-time source distribution carries its own license and is not included in radio runtime packages.
