# Changelog

## v0.1.1

- Clearer navigation with solid grey ground, a north-up home-bearing dial, home distance and the latest status message.
- Explicit arm state and a flight-mode fallback when the radio's mode sensor is unavailable.
- Full-width message wrapping and right-aligned telemetry values.
- Fixed the load-time nil-arithmetic failure on older Lua firmware.
- Correct unsigned telemetry decoding with EdgeTX 2.11's 32-bit Lua numbers.
- Crisp native-font previews and a simplified user guide.
- Source and compiled packages for pre-EdgeTX 2.11 RC1 and EdgeTX 2.11 RC1-and-later.
- Confirmed by the user on Tango 2 and with source Lua on TBS Alpha running EdgeTX 2.11. The Lua 5.3 compiled package has host validation; source is the hardware-confirmed choice on Alpha.

## v0.1.0

- First working Navigation and Messages pages on Tango 2.
- Twenty-message history, severity, duplicate counts and roller scrolling.
- Independent MAV script with a corrected compiled Lua format.
