# First radio acceptance test

Current status: **r2 confirmed working by the user on Tango 2 / FreedomTX 1.4.0 on 2026-09-12**. The first package's immediate `memory allocation error: block too big` was corrected by fixing constant tags. The user reported remaining layout and mode-display issues; a complete execution of the checklist below has not been reported. See [the MVP record](MVP.md).

Record the package SHA-256, radio model, firmware version, Lua build options if known, TX/RX hardware and firmware, autopilot/version, and other permanent scripts on the model.

1. Back up the model settings. Copy both compiled files (`/SCRIPTS/TELEMETRY/MAV.lua` and `MAV.luac`) from `MAV-LUA-tango2-freedomtx-r2.zip`, replacing previous files. Select `MAV` and disable other Lua telemetry-screen assignments. Reload the model. Replacing the cache as well as the entry point prevents firmware loading an older binary.
2. With the vehicle disconnected, open Navigation. Expect `NO LINK`, missing numeric values as `--`, and a crossed attitude instrument. Enter should open Messages and show `No messages`.
3. Connect the known working MAVLink-over-ELRS link and discover telemetry sensors. Confirm battery voltage and mode against the ground station; compare satellite count, ground speed and altitude semantics. Keep propellers removed for this bench test.
4. Tilt the aircraft nose up: the horizon moves down. Roll right: the horizon rises on the right. Check nose down, roll left, and inverted attitudes. Verify the signs on this exact autopilot/transport combination.
5. Enter switches pages both ways. The roller selects older/newer messages. Exit on Messages returns to Navigation. Record any control that differs from these mappings; do not infer mappings from desktop tests. Neither page has a bottom action hint.
6. Emit a warning and an error `STATUSTEXT` from the autopilot through the ground-station/test setup. Confirm WRN and !ERR, visible text, and a Navigation unread count. Repeat the same message inside three seconds; expect `x2` with no extra history entry.
7. Emit a 50-character message, with a recognizable suffix. Select it and read that suffix in the wrapped preview. Messages beyond 50 received bytes cannot be reconstructed by this transport.
8. Send over 20 distinct messages. Confirm only 20 remain and both scroll limits work. While viewing an older message, send another; selection should remain on the same entry unless eviction removes it.
9. Leave the script's radio screen hidden and emit messages. Reopen it and verify background history collection. Confirm no other script is consuming the CRSF queue.
10. Disconnect the link. Navigation must show `NO LINK`, blank sensor readings and a crossed instrument; Messages remains readable. Reconnect and verify recovery. On firmware with `getSourceValue`, also stop an individual sensor stream and wait for firmware's Sensor Lost timeout.
11. Run live traffic with repeated messages and page changes for **at least 15 minutes**. Check for Lua resets, sluggish controls, stale displays, allocation errors and lost status bursts. Record Lua memory readings if the firmware offers them. Desktop heap measurements do not establish radio memory headroom.
12. Reload the model once more; history should reset. To roll back, disable MAV and restore the model's previous telemetry-screen assignment.

Acceptance requires both correct data/control behavior and a successful sustained hardware run. A successful load alone does not establish that the memory problem is solved.
