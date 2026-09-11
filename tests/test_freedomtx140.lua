-- Run with .build/lua-freedomtx140.exe; cursor getter is C, not a Lua mock.
assert(firmwareCursor, "use tools/firmware_test.py's runner")
firmwareCursorValue = 24
local function broken() return firmwareCursor() end
local function safe() local result = firmwareCursor() return result end
assert(broken() == nil and safe() == 24, "runner must reproduce FreedomTX's lost tail-call return")

LCD_W, LCD_H, SOLID, INVERS, FORCE = 128, 96, 0, 2, 2
EVT_ENTER_BREAK = 10
GREY = function(n) return n * 65536 end
local hostType = type
type = function(value)
  if value == GREY then return "lightfunction" end
  return hostType(value)
end
getTime = function() return 10 end
getRSSI = function() return 99 end
getFieldInfo = function(name) return {id = name} end
local sensors = {Ptch = 0.1, Roll = 0.3, RxBt = 16.4, FM = "FBWA", Sats = 12}
getValue = function(id) return sensors[id] end
local output, grey = "", false
lcd = {
  clear = function() output = "" end,
  getLastRightPos = firmwareCursor,
  drawText = function(x, y, s, flags)
    firmwareCursorValue = x + #s * 6
    if y < LCD_H then output = output .. s .. "\n" end
  end,
  drawLine = function(x1, y1, x2, y2, pattern, flags)
    if flags == 8 * 65536 + FORCE then grey = true end
  end,
}
table, bit32 = nil, nil
local app = assert(loadfile(arg[1] or "src/SCRIPTS/TELEMETRY/MAV.lua", "bt"))()
app.init()
app.run(0)
assert(output:find("FBWA", 1, true) and output:find("16.4V", 1, true))
assert(grey, "grey ground must remain available")
app.run(10)
assert(output:find("No messages", 1, true))
print("PASS: reproduced firmware tail-call defect; application loads and renders both pages")
