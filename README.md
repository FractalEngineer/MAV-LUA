# MAV-LUA

MAVLink telemetry for your radio: a compact flight display, status-message viewer, and opt-in ArduPilot parameter browser for ExpressLRS.

## Features

- **Navigation:** attitude indicator, flight mode, battery, link quality, satellites, altitude, and Mission Planner-style ready-to-arm status.
- **Home guidance:** north-up direction-from-home marker and distance. The filled marker changes contrast across the horizon.
- **Messages:** the latest 20 MAVLink status messages, with severity, repeat counts, and full-width text wrapping.
- **Parameters:** Mission Planner-style first-level categories backed by compact, firmware-specific ArduPilot name databases. Browsing is local; values are read only when selected.
- **Small-radio friendly:** native bitmap text, integer drawing, bounded memory, and both telemetry-screen and Tools entry points.

| Navigation | Messages |
| --- | --- |
| ![Navigation preview](docs/images/navigation.png) | ![Messages preview](docs/images/messages.png) |

| Categories | Browse | Edit | Review |
| --- | --- | --- | --- |
| ![Parameter categories preview](docs/images/parameters-groups.png) | ![Parameter browser preview](docs/images/parameters-list.png) | ![Parameter editor preview](docs/images/parameters-edit.png) | ![Save review preview](docs/images/parameters-save.png) |

Navigation and Messages have been tested on Tango 2/FreedomTX 1.4 and TBS Alpha/EdgeTX 2.11. The v0.1.3 category-first parameter browser, exact-name reads, editing, verified saves, and readiness path were tested with ArduPilot Plane 4.8 on the Alpha setup described below.

## Installation

Download the matching package from [Releases](https://github.com/FractalEngineer/MAV-LUA/releases/latest):

| Firmware | Package |
| --- | --- |
| EdgeTX 2.11 RC1 or newer | `MAV-LUA-<version>_source.zip` |
| Earlier EdgeTX/FreedomTX | `MAV-LUA-<version>_precompiled.zip` |

1. Remove old MAV `.luac` caches before installing the source package: `SCRIPTS/TELEMETRY/MAV.luac`, `SCRIPTS/TOOLS/MAV.luac`, files under `SCRIPTS/MAV`, and `WIDGETS/MAV/main.luac` where present.
2. Copy the package's complete `SCRIPTS` folder to the SD card. Color-radio users should copy `WIDGETS` as well.
3. Select **MAV** as a telemetry screen, or launch **MAV** from Tools on radios whose telemetry menu reserves PAGE.
4. Discover telemetry sensors, then reload the model or restart the radio.

Use an ArduPilot vehicle over ExpressLRS MAVLink mode. Disable other telemetry scripts that consume the same CRSF queue.

## Controls

| Input | Action |
| --- | --- |
| PAGE | Cycle Navigation, Messages, and Parameters |
| Roller | Scroll messages, browse parameters, or edit a value |
| Enter | Select, confirm, or open the parameter editor |
| Menu in Parameters | Change the numeric edit step or return to Load |
| Exit | Back out or discard an edit |

On touch radios, horizontal swipes change pages, vertical swipes scroll, and taps select. Hold Exit to close the Tools application.

If Enter still changes pages after updating, the radio is loading an old cache. Remove the `.luac` files listed above, reinstall the complete package, and restart.

## Ready-to-arm status

`READY` means the autopilot reports its pre-arm check healthy, or that check is disabled. `NOT READY` means an enabled pre-arm check is failing. `ARMED` is driven by the explicit armed bit, and `READY?` means readiness or arm telemetry is missing or stale. Only `READY` and `ARMED` are inverted for at-a-glance recognition. Status-message text never changes this indicator.

## Parameters

Parameters require EdgeTX 2.11 or newer and the matching TX-side bridge proposed in [ExpressLRS PR #3779](https://github.com/ExpressLRS/ExpressLRS/pull/3779). Stock ExpressLRS MAVLink telemetry does not expose autopilot parameter replies to handset Lua. The bridge is TX-only; it preserves normal telemetry conversion and the existing MAVLink OTA uplink.

- Press **Load** to read `AUTOPILOT_VERSION` and select the matching vehicle/version database.
- Browse first-level categories and parameter names locally. Each eight-name page is a direct 128-byte read from the packaged database and sends no parameter requests.
- Repeated numbered groups are nested under one family (`RC` contains `RC`, `RC1` through `RC16`), cutting the first level roughly in half.
- Select a name to fetch that one value. Names for disabled or board-specific features may report `Parameter unavailable`.
- Menu changes the step size while editing.
- Enter opens review. Choose **Save** and wait for **Saved and verified**; Exit discards the draft.

Writes require a fresh disarmed heartbeat. MAV rereads the original value, sends `PARAM_SET` once, and requires a separate matching readback before reporting success. An unconfirmed write is never repeated automatically.

v0.1.3 includes read-only Plane and Copter name databases generated from official ArduPilot 4.6, 4.7, and 4.8-dev metadata. It never downloads all live parameters or writes a runtime database. Only the current eight categories or names are retained. Parameter descriptions, enum labels, bitmask editors, search, PX4, and other autopilot families are not yet included.

[Parameter database provenance](docs/PARAMETER-DATABASES.md)

[v0.2.0 roadmap: firmware-agnostic bridge and radio-side firmware adapters](docs/V0.2.0-ROADMAP.md)

[Changelog](CHANGELOG.md) · [Protocol notes](docs/PROTOCOL.md) · [GPL-3.0 license](LICENSE)
