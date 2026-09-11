# v0.1.0: first working MAV MVP

On 2026-09-12 the user confirmed that the corrected r2 build works on their Tango 2 running FreedomTX 1.4.0, after the initial package failed immediately on load.

The preserved build contains one independent MAV telemetry script, Navigation and Messages pages, bounded 20-entry status history, duplicate counts, roller selection and a wrapped full-message preview. It has no page-action footer and no parameter editor.

## Preserved hardware candidate

[`MAV-LUA-tango2-freedomtx-r2.zip`](../releases/v0.1.0/MAV-LUA-tango2-freedomtx-r2.zip)

SHA-256: `01555ef389218a0eb324200b8105bd44306f24812a9ce49751566a6d50fdd181`

The archived candidate is byte-for-byte the package tested by the user. Its bundled documentation predates this confirmation; this record supplies the updated result. Both `MAV.lua` and `MAV.luac` contain the same 9,833-byte stripped binary. The compiler emits FreedomTX number/string tags 5/6 and 32-bit string sizes; validation walks all constants rather than trusting the header alone.

## Validation recorded before this checkpoint

- 79 Lua assertions across telemetry, packets, layouts and instruction budgets.
- A 25,500-cycle simulated traffic test with approximately 0.04 KiB retained-heap growth.
- Seven independent bytecode ABI tests, including rejection of the failed binary format.
- Compiled-package smoke test and 5,000-cycle soak; approximately 0.26 KiB retained-heap growth on the 64-bit host.
- Color-widget adapter tests. Other physical radios remain untested.

These are desktop measurements, not radio heap measurements. The user's confirmation establishes that the corrected package loads and displays on Tango; a complete 15-minute hardware soak has not been reported.

## Known issues and next iteration

1. Navigation fields and message lines leave unused space on the right. The top-right message counter aligns correctly. Font measurement and wrapping need to match the radio's actual font.
2. The hatched navball ground is difficult to read. Investigate solid grey where supported, with a suitable monochrome fallback.
3. Flight mode does not appear on this setup. Verify the sensor naming/API path and use actual autopilot telemetry where available.
4. Add the latest status message along Navigation's bottom line.
5. Add compact readiness/arming status based on explicit autopilot state.
6. Add home distance and an N/E/S/W instrument indicating the aircraft's bearing **from home**. Prefer autopilot home information; an arm-time GPS capture must not silently become an arbitrary startup position.

Parameters remain deferred. Preserve the bytecode fix, bounded memory, sole raw-queue consumer, and permanent-script instruction budget throughout further development.
