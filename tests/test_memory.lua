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
-- Model EdgeTX's loader honestly so the cached and first-open paths are both covered.
-- Both packages now ship a .luac beside each .lua, so an installed open loads bytecode. A
-- package built without caches has none, so its first open compiles each module and the
-- firmware then writes a cache; later opens load bytecode directly. Forcing compilation while
-- a valid cache exists re-pays the whole compile peak, which is the regression this guards
-- against, so it is counted and asserted rather than tolerated.
--
-- 'buildfirst' models the real radio sequence: the page already opened successfully, so the
-- five opening modules are cached, but a build has never run and so its module is not. That
-- is the case which exhausted memory on hardware before the builder's cache shipped, and it is
-- invisible to the other modes.
local mode = arg[5]
local warm = mode ~= 'nocache' and mode ~= 'buildfirst'
local written, compiles = {}, 0
if mode == 'buildfirst' then
  for _, name in ipairs({'wire', 'pview', 'pdb', 'pinput', 'params'}) do
    written[name .. '.luac'] = true
  end
end
loadScript = function(path, mode)
  local name = path:match('[^/]+$')
  if path:sub(-5) == '.luac' then
    if not (warm or written[name]) then return nil end
    return loadfile(cacheRoot .. '/' .. name)
  end
  assert(path:sub(-4) == '.lua', 'module source path must be explicit')
  assert(mode == 'tc' or mode == 'tx', 'unexpected source load mode ' .. tostring(mode))
  if mode == 'tc' then
    compiles = compiles + 1
    written[name:gsub('%.lua$', '.luac')] = true
  end
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
-- A warm open must be cache-only. Compiling while a cache exists re-pays the whole compile
-- peak and is what made the radio report "not enough memory" on an open that then worked on
-- retry. A first open has no cache and legitimately compiles each module once; the build-first
-- case has the opening modules cached and must compile only the builder.
if mode == 'buildfirst' then
  assert(compiles == 0, 'build-first open compiled ' .. compiles .. ' already-cached module(s)')
elseif warm then
  assert(compiles == 0, 'warm open recompiled ' .. compiles .. ' cached module(s)')
else
  assert(compiles >= 5, 'first open must compile the module set once, saw ' .. compiles)
end
print(mode == 'buildfirst' and 'Build-first open: opening set all cached' or
  warm and 'Warm open: loaded entirely from cache' or
  ('First open: compiled ' .. compiles .. ' module(s)'))
-- The index builder is loaded on demand, only when a build is requested, so its cost lands
-- on the build path rather than on every open. This measures that incremental cost, which is
-- the figure that matters for a radio: a build must fit alongside the already-open app.
-- Loaded the way loadParameterModule does: prefer the cache, compile only when absent.
if arg[4] == 'builder' then
  local before = memoryStats(true)
  -- Mirrors loadParameterModule: cached bytecode when present, otherwise compile once.
  local chunk = loadScript('/SCRIPTS/MAV/index.luac', 'b')
  if not chunk then chunk = loadScript('/SCRIPTS/MAV/index.lua', 'tc') end
  local maker = assert(chunk)()
  collectgarbage('collect')
  local after = memoryStats()
  assert(type(maker) == 'function', 'index builder module loads and returns a factory')
  print('Builder bytes live/peak:', after, '(delta from Load:', after - before, ')')
end
