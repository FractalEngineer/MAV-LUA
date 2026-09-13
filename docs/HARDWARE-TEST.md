# Radio acceptance testing

This checklist is for MAV-LUA v0.1.2 and later. Back up the model, remove propellers, and record the package checksum, radio and firmware versions, TX/RX hardware, ExpressLRS version, and autopilot version.

## Navigation and messages

1. Open Navigation with the vehicle disconnected. Confirm `NO LINK`, blank numeric values, and a crossed attitude indicator.
2. Connect the vehicle and compare voltage, mode, satellites, speed, altitude, attitude signs, home distance, and home direction against a ground station.
3. Compare `READY` and `NOT READY` against Mission Planner while disarmed, then verify `ARMED` after arming. Only `READY` and `ARMED` should be inverted. Removing readiness/status traffic for three seconds should produce `READY?`.
4. Verify the filled home marker remains visible over the dark and grey halves of the navball. Rotating the vehicle in place must not rotate this north-up direction-from-home marker.
5. Emit warning and error status text. Confirm severity, repeat counts, the Navigation preview, full-text wrapping, the 20-message limit, and collection while the screen is hidden.
6. Disconnect and reconnect telemetry. Live values must clear and recover; stored messages should remain until model reload.

## Parameters

1. Open Parameters on EdgeTX 2.11 or newer. Confirm that no request is sent before pressing Load.
2. Press Load and browse across several eight-row boundaries in both directions. PAGE away during connection and fetching, then return and continue.
3. Leave the browser active for at least 15 minutes while navigating large index ranges. Check for resets, sluggish controls, allocation errors, stale values, and correct recovery from link loss.
4. Select a harmless numeric parameter and compare the refreshed value with the ground station. Change it, back out, and confirm no write occurred.
5. Repeat the edit and explicitly Save while disarmed. Require `Saved and verified`, then independently confirm the value. Test an armed or stale-heartbeat attempt and confirm it is blocked.
6. Interrupt one save after transmission. The UI must report an unconfirmed outcome and must not automatically repeat the write.

The v0.1.2 browser is intentionally bounded: it does not download or retain the full parameter database. Waiting while crossing an eight-row boundary is expected in this release and is the main target for follow-up optimization.
