# Radio acceptance testing

This checklist is for MAV-LUA v0.1.3 and later. Back up the model, remove propellers, and record the package checksum, radio and firmware versions, TX/RX hardware, ExpressLRS version, and autopilot version.

## Navigation and messages

1. Open Navigation with the vehicle disconnected. Confirm `NO LINK`, blank numeric values, and a crossed attitude indicator.
2. Connect the vehicle and compare voltage, mode, satellites, speed, altitude, attitude signs, home distance, and home direction against a ground station.
3. Compare `READY` and `NOT READY` against Mission Planner while disarmed, then verify `ARMED` after arming. Only `READY` and `ARMED` should be inverted. Removing readiness/status traffic for three seconds should produce `READY?`.
4. Verify the filled home marker remains visible over the dark and grey halves of the navball. Rotating the vehicle in place must not rotate this north-up direction-from-home marker.
5. Emit warning and error status text. Confirm severity, repeat counts, the Navigation preview, full-text wrapping, the 20-message limit, and collection while the screen is hidden.
6. Disconnect and reconnect telemetry. Live values must clear and recover; stored messages should remain until model reload.

## Parameters

1. Open Parameters on EdgeTX 2.11 or newer. Confirm that no request is sent before pressing Load.
2. Press Load. Confirm the displayed vehicle and firmware version, then compare the first-level categories with the matching ArduPilot firmware family. Open `RC` and confirm it contains `RC`, `RC1` through `RC16`; EXIT should restore the selected top-level `RC` folder.
3. Open `OSD`, then `OSD1`, and scroll across many eight-name pages in both directions. Scrolling must remain responsive and must not create parameter telemetry. PAGE away during firmware detection and return to confirm clean cancellation.
4. Leave the browser active for at least 15 minutes while navigating large categories. Check for resets, sluggish controls, allocation errors, and correct recovery from link loss.
5. Select a harmless numeric parameter and compare the on-demand value with the ground station. Change it, back out, and confirm no write occurred.
6. Repeat the edit and explicitly Save. Require `Saved and verified`, then independently confirm the value. Test a stale-heartbeat attempt and confirm it is blocked.
7. Interrupt one save after transmission. The UI must report an unconfirmed outcome and must not automatically repeat the write.

The v0.1.3 category-first browser was accepted with ArduPilot Plane 4.8 on the Alpha/Zorro setup after firmware selection, nested-group navigation, wraparound, exact-name reads, editing, and verified saves. It uses packaged, read-only databases and retains only the current eight category or name records. Repeat the soak for every new database family, firmware adapter, or material transport change.
