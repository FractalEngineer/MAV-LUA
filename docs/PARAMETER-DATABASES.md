# Parameter database provenance

The files under `SCRIPTS/MAV/DB` are read-only installation assets generated from ArduPilot's official `apm.pdef.json` metadata. They contain names only: no defaults, descriptions, enum labels, or values. Runtime code never modifies them.

| Database family | ArduPilot source tag | Commit |
| --- | --- | --- |
| 4.6 Plane/Copter | `Copter-4.6.3` | `92b0cd788ec29406f26c6f9c31d5ceedbd1cc538` |
| 4.7 Plane/Copter | `Copter-4.7.0` | `1511f27194f1dcc3728270883047bdf022b3fd53` |
| 4.8-dev Plane/Copter | `master` snapshot | `35356c656c14b86af59528710f873a700c31b344` |

Generation uses each checkout's `Tools/autotest/param_metadata/param_parse.py` for the Plane and Copter vehicle directories, followed by `tools/param_db.py`. `SIM_` and `SITL_` names are excluded. The first token before `_` forms a parameter group, and singleton prefixes are placed under `GENERAL`. When a base has at least two numbered instance groups, those groups and the unnumbered base group are nested in one family folder: for example, `RC` contains `RC`, `RC1` through `RC16`.

Each `.pdb` begins with fixed 22-byte top-level records (`name[16]`, byte offset, count), then any second-level records, followed by NUL-padded 16-byte MAVLink parameter names. The high bit of a record's count identifies a family folder; its offset points to fixed child records instead of names. Its tiny companion Lua manifest records only firmware family, vehicle family, file path, and top-level count. Every level seeks directly to at most eight records without parsing or retaining the whole database.

Metadata contains parameters for optional features and board variants. Selecting a name that is absent on the connected vehicle produces `Parameter unavailable`; it does not trigger a list scan or alter the vehicle.
