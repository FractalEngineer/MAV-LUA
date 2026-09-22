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
2. Press Load. Confirm the displayed vehicle and firmware version. On a firmware version that has never been indexed, confirm the page says there is no index and names **Tools > MAV Index** rather than attempting a build itself.
3. Open **Tools > MAV Index** and press ENTER. Confirm it finds the vehicle, shows the firmware identity, reports names as they arrive, and finishes with **Index built**. Confirm EXIT aborts a running build and that no index is left behind afterwards.

   **A build that reports `0 names` or `No parameter stream: reflash the TX module` almost always means the TX module firmware is stale, not that the vehicle is at fault.** Reading the list needs the bridge change that accepts `PARAM_REQUEST_LIST`; a module built before it silently drops the request, while identity still works because that path is older. Compare the module's build time against `MavLuaBridge.h` and reflash if the firmware is older.
4. Return to Parameters and press Load. Confirm the first-level categories match the vehicle, then open `RC` and confirm it contains `RC`, `RC1` through `RC16`; EXIT should restore the selected top-level `RC` folder.
5. Open `OSD`, then `OSD1`, and scroll across many eight-name pages in both directions. Scrolling must remain responsive and must not create parameter telemetry. PAGE away during firmware detection and return to confirm clean cancellation.
6. Leave the browser active for at least 15 minutes while navigating large categories. Check for resets, sluggish controls, allocation errors, and correct recovery from link loss.
7. Select a harmless numeric parameter and compare the on-demand value with the ground station. Change it, back out, and confirm no write occurred.
8. Repeat the edit and explicitly Save while disarmed. Require `Saved and verified`, then independently confirm the value. Test an armed or stale-heartbeat attempt and confirm it is blocked.
9. Interrupt one save after transmission. The UI must report an unconfirmed outcome and must not automatically repeat the write.

The v0.1.3 category-first browser was accepted with ArduPilot Plane 4.8 on the Alpha/Zorro setup after firmware selection, nested-group navigation, wraparound, exact-name reads, editing, and verified saves. That release browsed packaged read-only databases; the replacement vehicle-discovered index must be re-accepted on hardware before it is reported as confirmed. Repeat the soak for every new index builder, firmware adapter, or material transport change.

Pay particular attention to the Tools build, because it is the newest and largest structural change. Confirm the tool opens from the radio's Tools menu, that it reaches the vehicle without the telemetry screen running, and that a completed build is then visible from Parameters. Also confirm the radio remains responsive throughout, since the build is where the heap was previously exhausted.
