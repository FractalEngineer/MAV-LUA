# MAV-LUA development guide

## Latest handoff — 2026-09-15

Read [HANDOFF.md](HANDOFF.md) before continuing. v0.1.3 is the hardware-confirmed baseline for Navigation, Messages, ready-to-arm status, and category-first ArduPilot parameter browsing. The next feature line is the firmware-agnostic transport and radio-side adapter work in [docs/V0.2.0-ROADMAP.md](docs/V0.2.0-ROADMAP.md).

## Working agreement

- Keep README user-facing. Put implementation state and next steps in HANDOFF; keep protocol detail in `docs/PROTOCOL.md`.
- Preserve the independent MAV name, native bitmap glyphs, integer coordinates, and grey only for navball ground.
- Use one telemetry queue consumer. Parameter code receives packets from the core dispatcher and must not pop the CRSF queue itself.
- Parameter traffic is opt-in. Never write on scroll or during editing. Require explicit Save and matching autopilot readback before reporting success.
- Do not equate CRSF device parameters with autopilot parameters. Stock ExpressLRS telemetry does not expose a raw autopilot parameter stream to handset Lua.
- Keep parameter state bounded. Do not restore the full live-list download, runtime SD database writes, or `params.tmp`; those designs failed on radio. Packaged immutable `.pdb` name assets are intentional.
- Preserve LICENSE/SPDX and desktop font notices.
- Never rewrite a release tag. New releases ship exactly two ZIPs plus `SHA256SUMS.txt`; historical assets remain unchanged.

## Hardware and compatibility

The v0.1.3 parameter browser and readiness path are confirmed with ArduPilot Plane 4.8 on a TBS Alpha running EdgeTX 2.11, connected to a RadioMaster Zorro internal ELRS module through the full-duplex external-bay serial interface. Reported link settings are 333 Hz Full and 940k handset baud. Navigation and Messages were also tested on Tango 2/FreedomTX 1.4.0.

EdgeTX 2.11 RC1 changed from Lua 5.2 to Lua 5.3 and uses int32/float32. Decode disjoint packed byte fields directly; assembling uint32 values can overflow integers or discard low float bits. Modern-only modules must remain lazily loaded after capability checks so the core still parses on Lua 5.2.

The legacy binary format uses number/string tags 5/6 and size32/double64. The modern host-validation format uses standard tags and size32/int32/float32. Lua 5.3 bytecode is an internal validation artifact, not a radio deliverable.

## Build, test, and release

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
.build/lua53.exe tests/test_params.lua .build/post
.build/lua53.exe tests/test_pipeline.lua .build/post
.build/lua-freedomtx140.exe tests/test_freedomtx140.lua .build/MAV.lua
```

Use `--archive` to bootstrap from an existing pinned Lua tarball. Output goes under `dist/<version>/`. `_source` targets EdgeTX 2.11 RC1 and newer; `_precompiled` targets earlier firmware and includes discovery `.lua`, cache `.luac`, and readable source under `SOURCE/`. Remove old caches before installing source.

For a release: run all checks, regenerate previews, copy the two ZIPs and checksums to `releases/<tag>/`, commit, create an annotated tag with its changelog, push commit and tag atomically, then publish those three assets. The tag workflow independently rebuilds the same deliverable set.

Tests cover both Lua ABIs, malformed telemetry, bounded history/state, geometry, the FreedomTX C tail-call defect, sustained traffic, write safeguards, pipeline ordering/retries, package contents, and the 10,000-instruction callback limit. Desktop allocation thresholds are regression checks, not radio heap specifications.

## Telemetry contract

Firmware telemetry sensors provide attitude, battery, current, satellites, link quality, speed, altitude, and usually flight mode. The core caches only known sensor names and retries missing names once per second.

| Display | Sensor/source |
| --- | --- |
| Attitude/heading | `Ptch`, `Roll`, `Yaw` |
| Battery/current | `RxBt` or `BtRx`, `Curr` |
| Satellites/link | `Sats`, `RQly` |
| Flight mode | `FM`, fallback custom `0x5001` + `0x5007` |
| Armed state | custom `0x5001` bit 8 |
| Ready-to-arm | CRSF `0xAC` carrying MAVLink `SYS_STATUS` masks |
| Home distance/direction | custom `0x5004` |
| Ground speed | `GSpd` |
| Altitude | `GAlt`, fallback `Alt` |

Standard CRSF frames become firmware sensors; unhandled frames reach `crossfireTelemetryPop()`. Both foreground and background use the same bounded dispatcher. Most callbacks stop after one custom candidate; the visible firmware-identity screen may accept a second `0xAA` chunk. Key callbacks skip parameter work to retain Navigation drawing headroom.

Status text uses command `0x80` or legacy `0x7F`, subtype `0xF1`, one severity byte, and up to 50 text bytes. Control bytes are sanitized, duplicates within three seconds increment a count, and the last 20 entries are retained.

AP status/home use subtype `0xF0` single tuples or `0xF2` counted tuples. Accept exactly sized payloads and the known four-byte padded converter variant. State expires after three seconds and clears on link loss. The home marker is north-up, locates the aircraft from home, and is independent of yaw.

CRSF `0xAC` carries big-endian uint32 `present`, `enabled`, and `health` masks. Read MAV_SYS_STATUS_PREARM_CHECK bit 28 directly from each first byte. While disarmed, healthy or disabled displays `READY`; enabled and unhealthy displays `NOT READY`; absent/stale state displays `READY?`; the explicit armed bit displays `ARMED`. Only READY and ARMED use inverse video. Never derive readiness from disarm state or `STATUSTEXT`.

## Parameter browser

Optional modules live under `src/SCRIPTS/MAV/` and load one chunk per foreground callback. The core checks `string.pack`, `bit32`, and CRSF transmit support before loading them. EdgeTX's native compiler path loads source with `tc`, drops the source prototype, collects, then loads the stripped cache with `b`; firmware without compiler support falls back to `tx`. Older firmware displays `Needs EdgeTX 2.11` without loading parameter modules.

Load requests `AUTOPILOT_VERSION` and selects a packaged ArduPilot 4.6/4.7/4.8 database for Plane or Copter. Each `.pdb` uses fixed 22-byte category records and 16-byte name records; its tiny Lua manifest holds only identity, path, and category count. Category/name scrolling reads at most eight local records and sends no parameter traffic. ENTER requests only the selected exact name. Optional feature names can be unavailable on a specific vehicle.

Only one connect, identity, exact-name read, conflict check, or verification request is pending at a time. Reads may make at most four attempts and accept only the requested target/name/type. `PARAM_SET` is transmitted once; verification uses a separate named read and an absent reply remains an unknown outcome.

Editing rereads the selected value, preserves its wire type, and permits only exactly represented integers or float32 values. Save defaults to Back. Explicit Save rereads the old value to detect a concurrent change, sends SET once, then requires a separate matching readback. An armed or stale heartbeat blocks writes. A timeout after transmission is an unknown outcome and must not trigger an automatic retry.

PAGE cycles Navigation, Messages, and Parameters. ENTER selects; EXIT backs out; MENU changes step or returns to Load. A pending save cannot be left with PAGE until verified or timed out. Tools provides equivalent control on radios whose telemetry menu reserves PAGE.

## ExpressLRS bridge

The native checkout is `C:/Users/titan/Desktop/Github_Projects/ExpressLRS` on `feature/mavlink-lua-parameters`, based on upstream `a60b68af`. `origin` is ExpressLRS/ExpressLRS and `myfork` is FractalEngineer/ExpressLRS. Preserve `src/user_defines.txt`; it contains private user build settings and must never be staged or printed.

The TX-only library is under `src/lib/MavLuaBridge/`, with hooks in `CRSFHandset.cpp`, `MAVLink.cpp`, and `tx_main.cpp`, plus native Unity tests under `src/test/test_mavlua/`. It reuses ExpressLRS MAVLink mode's uplink and downlink paths; no RX change is required.

The handset envelope is CRSF command `0xAA`, chunk marker, data length, then MAVLink packet bytes. Lua sends system/component 254/190. Accepted uplink messages are PING, `PARAM_REQUEST_READ`, `PARAM_SET`, and a strict `MAV_CMD_REQUEST_MESSAGE(AUTOPILOT_VERSION)`. Downlink forwarding is limited to unsigned HEARTBEAT, `PARAM_VALUE`, and a requested `AUTOPILOT_VERSION`; packets over 58 bytes use standard bounded chunks. A zero broadcast PING creates a ten-second local subscription and is not sent to the aircraft.

The next ArduPilot component-1 heartbeat locks the system target. Writes require a disarmed heartbeat no older than three seconds. Link loss clears the bridge. Readiness monitoring requests `SYS_STATUS` at most once per second only while it is missing/stale; an active stream suppresses requests.

Validate in the ExpressLRS `src` directory:

```powershell
pio test -e native -f test_mavlua
$env:ELRS_UNIFIED_CONFIG='radiomaster.tx_2400.zorro'
pio run -e Unified_ESP32_2400_TX_via_UART
```

## Next development step

Follow [docs/V0.2.0-ROADMAP.md](docs/V0.2.0-ROADMAP.md): make the ELRS transport firmware-agnostic, move autopilot identity and wire quirks behind radio-side adapters, and add PX4 without another bridge change. Preserve bounded state, queue ownership, callback limits, link/target invalidation, and all write safeguards.
