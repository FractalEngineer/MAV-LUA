-- Black-box smoke and heap measurement of the actual stripped radio artifact.
local path = arg[1] or ".build/MAV.lua"
LCD_W, LCD_H, SOLID, INVERS = 128, 96, 0, 1
EVT_ENTER_BREAK, EVT_VIRTUAL_NEXT, EVT_EXIT_BREAK = 10, 12, 11
local now, queue, output = 0, nil, ""
local sensors = {Ptch = 0.1, Roll = -0.3, Yaw = 2, RxBt = 16.4,
  Sats = 12, RQly = 99, FM = "AUTO*", GAlt = 100, GSpd = 35, Curr = 3}
getTime = function() return now end
getRSSI = function() return 99 end
getFieldInfo = function(name) return sensors[name] and {id = name} end
getValue = function(id) return sensors[id] end
crossfireTelemetryPop = function()
  local p = queue
  queue = nil
  if p then return 0x80, p end
end
local drawCount = 0
lcd = {
  clear = function() output = "" end,
  drawText = function(x, y, text) output = output .. text .. "\n" drawCount = drawCount + 1 end,
  drawLine = function() drawCount = drawCount + 1 end,
}
table, bit32, CENTERED = nil, nil, nil
local function heap()
  -- Several full sweeps also settle Lua's gradually shrinking intern table.
  for i = 1, 4 do collectgarbage("collect") end
  return collectgarbage("count")
end
local before = heap()
local app = assert(loadfile(path, "b"))()
app.init()
app.run(0)
assert(output:find("AUTO*", 1, true) and output:find("16.4V", 1, true))
local function message(i)
  local text = "Warning " .. i .. string.rep("W", 35)
  queue = {0xF1, 4}
  for j = 1, #text do queue[#queue + 1] = text:byte(j) end
end
for i = 1, 30 do message(i) app.background() end
app.run(10)
assert(output:find("Warning 30", 1, true) and output:find("1/20", 1, true))
app.run(12)
assert(output:find("2/20", 1, true))
app.run(11)
assert(output:find("AUTO*", 1, true))
local full = heap()
local maxInstructions = 0
for i = 1, 5000 do
  now = now + 10
  message(i)
  local instructions = 0
  debug.sethook(function() instructions = instructions + 100 end, "", 100)
  app.run(i % 11 == 0 and 10 or 0)
  debug.sethook()
  maxInstructions = math.max(maxInstructions, instructions)
end
local after = heap()
assert(after - full < 3, "stripped runtime retains growing state: " .. (after - full) .. " KiB")
print(string.format("PASS: stripped bytecode, missing libraries, both pages, history, 5,000-cycle soak"))
print(string.format("Host 64-bit heap delta: %.2f KiB loaded/full; %.2f KiB soak growth; max ~%d instructions/run",
  full - before, after - full, maxInstructions))
