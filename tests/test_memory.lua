-- Tiny host harness: measure cold source compilation with the core retained.
-- The allocator counter also captures temporary parser allocations between calls.
local root = arg[1] or 'src'
local cacheRoot = assert(arg[3], 'stripped cache root required')
LCD_W, LCD_H, SOLID, INVERS = 128, 96, 0, 1
EVT_PAGE_FIRST, EVT_PAGE_BREAK, EVT_VIRTUAL_ENTER, EVT_VIRTUAL_NEXT = 40, 41, 42, 43
local screen, remaining = '', 0
getTime = function() return 100 end
getRSSI = function() return 0 end
getValue = function() return 0 end
getFieldInfo = function() return nil end
killEvents = function() end
crossfireTelemetryPop = function()
  if remaining == 0 then return end
  local message = string.rep('W', 48) .. string.format('%02d', remaining)
  remaining = remaining - 1
  local p = {0xF1, 4}
  for i=1,#message do p[#p+1]=message:byte(i) end
  return 0x80, p
end
local sent = 0
crossfireTelemetryPush = function() sent = sent + 1 return true end
io.seek = function() error('opening Parameters must not access cache') end
io.open = function() return true end
io.close = function() end
lcd = {clear=function() screen='' end, drawLine=function() end,
  drawText=function(_,y,s) if y<LCD_H then screen=screen..s..'\n' end end}
loadScript = function(path, mode)
  if path:sub(-5) == '.luac' then
    return loadfile(cacheRoot .. '/' .. path:match('[^/]+$'))
  end
  assert(path:sub(-4) == '.lua', 'module source path must be explicit')
  assert(mode == 'tc', 'source load must request native cache compilation')
  return loadfile(root .. path)
end
collectgarbage('collect')
memoryStats(true)
local app = assert(loadfile(root .. '/SCRIPTS/TELEMETRY/MAV.lua'))()
app.init() app.run(0)
if arg[2] == 'history' then
  remaining = 20
  for i=1,20 do app.run(0) collectgarbage('step', 10) end
end
collectgarbage('collect')
print('Navigation bytes live/peak:', memoryStats())
app.run(40) app.run(40)
for i=1,12 do app.run(0) collectgarbage('step', 10) end
assert(screen:find('> LOAD <', 1, true), screen)
assert(sent == 0, 'opening Parameters must not transmit')
print('Parameters bytes live/peak:', memoryStats())
app.run(42) app.run(0)
assert(screen:find('Connecting...', 1, true), screen)
assert(sent == 1, 'Load starts one bounded bridge subscription')
print('Load bytes live/peak:', memoryStats())
