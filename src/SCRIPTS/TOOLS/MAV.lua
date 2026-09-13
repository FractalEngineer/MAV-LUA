-- SPDX-License-Identifier: GPL-3.0-or-later
-- Optional full-screen entry for radios whose telemetry menu reserves PAGE.
-- EdgeTX suspends permanent telemetry scripts while a tool is running.
local app, errorText
local function init()
  -- Modern distributions are source. Ignore a leftover legacy binary cache.
  local chunk = loadScript('/SCRIPTS/TELEMETRY/MAV.lua', string.pack and 'tx' or 'bt')
  if chunk then app = chunk() app.init() else errorText = 'MAV load failed' end
end
local function run(event)
  if app then app.run(event) else lcd.drawText(0, 0, errorText or 'MAV load failed', 0) end
  return 0
end
return {init=init, run=run}
