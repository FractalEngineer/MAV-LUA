-- Desktop drawing recorder. Runs the real display code with sample telemetry.
LCD_W, LCD_H = tonumber(arg[2]) or 128, tonumber(arg[3]) or 96
SOLID, INVERS = 0, 1
EVT_ENTER_BREAK = 10
local sensors = {Ptch = 0.12, Roll = 0.3, Yaw = -1.5, RxBt = 16.4,
  Sats = 14, FM = "FBWA*", RQly = 98, GSpd = 42, GAlt = 123, Curr = 3.2}
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
crossfireTelemetryPop = function()
  local data = table.remove(queue, 1)
  if data then return 0x80, data end
end
lcd = {
  clear = function() end,
  drawText = function(x, y, text, flags) print(string.format("T\t%d\t%d\t%d\t%s", x, y, flags, text)) end,
  drawLine = function(x1, y1, x2, y2) print(string.format("L\t%d\t%d\t%d\t%d", x1, y1, x2, y2)) end,
}
local app = assert(loadfile("src/SCRIPTS/TELEMETRY/MAV.lua"))()
app.init()
app.background()
app.background()
app.run(arg[1] == "messages" and 10 or 0)
