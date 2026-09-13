-- Desktop drawing recorder. Runs the real display code with sample telemetry.
LCD_W, LCD_H = tonumber(arg[2]) or 128, tonumber(arg[3]) or 96
SOLID, INVERS, FORCE, ERASE = 0, 2, 2, 4
GREY = function(n) return n * 65536 end
EVT_PAGE_BREAK = 10
local sensors = {Ptch = 0.12, Roll = 0.3, Yaw = -1.5, RxBt = 16.4,
  Sats = 14, RQly = 98, GSpd = 42, GAlt = 123, Curr = 3.2}
getTime = function() return 1200 end
getRSSI = function() return 98 end
getFieldInfo = function(name) if sensors[name] then return {id = name} end end
getValue = function(id) return sensors[id] end
local queue = {}
local function push(message, severity)
  local data = {0xF1, severity}
  for i = 1, #message do data[#data + 1] = message:byte(i) end
  queue[#queue + 1] = data
end
push("Battery 1 low voltage", 3)
push("EKF3 IMU0 is using GPS", 6)
push("PreArm: AHRS: waiting for home position", 4)
push("PreArm: AHRS: waiting for home position", 4)
push("Reached waypoint 3, distance 450m from home", 6)
local function data(id, value)
  local p = {0xF0, id % 256, math.floor(id / 256)}
  for i = 1, 4 do local byte = value % 256 p[#p + 1] = byte value = (value - byte) / 256 end
  queue[#queue + 1] = p
end
data(0x5007, 16777217)
data(0x5001, 262)
data(0x5004, 450 * 4 + 75 * 33554432)
crossfireTelemetryPop = function()
  local data = table.remove(queue, 1)
  if data then return 0x80, data end
end
local right = 0
local advances = {}
for code = 32, 126 do
  advances[code] = arg[4] and tonumber(arg[4]:sub(code - 31, code - 31)) or 6
end
lcd = {
  clear = function() end,
  getLastRightPos = function() return right end,
  drawText = function(x, y, text, flags)
    right = x
    for i = 1, #text do right = right + (advances[text:byte(i)] or 6) end
    if y < LCD_H then print(string.format("T\t%d\t%d\t%d\t%s", x, y, flags, text)) end
  end,
  drawLine = function(x1, y1, x2, y2, pattern, flags)
    print(string.format("L\t%d\t%d\t%d\t%d\t%d", x1, y1, x2, y2, flags))
  end,
}
local app = assert(loadfile("src/SCRIPTS/TELEMETRY/MAV.lua"))()
app.init()
while #queue > 0 do app.background() end
app.run(arg[1] == "messages" and 10 or 0)
