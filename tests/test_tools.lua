-- Exercise the actual packaged entry, with a stale core cache on modern radios.
local root = assert(arg[1])
LCD_W, LCD_H, SOLID, INVERS = 128, 96, 0, 1
EVT_PAGE_FIRST, EVT_PAGE_BREAK, EVT_VIRTUAL_ENTER = 40, 41, 42
local screen, killed, sent = '', 0, 0
local failLoad = arg[2] == 'error' or arg[2] == 'moduleerror'
getTime = function() return 100 end
getRSSI = function() return 0 end
getValue = function() return 0 end
getFieldInfo = function() return nil end
killEvents = function(event) killed = event end
crossfireTelemetryPop = function() return nil end
crossfireTelemetryPush = function() sent = sent + 1 return true end
-- Only checking the initial prompt: no storage or parameter traffic is allowed.
io.seek = function() error('PAGE must not touch parameter storage') end
lcd = {clear=function() screen='' end, drawLine=function() end,
  drawText=function(_,y,s) if y<LCD_H then screen=screen..s..'\n' end end}
local compiled, sawCompile, sawBinary, sawFallback, fallbackPath = {}, false, false, false
loadScript = function(path, mode)
  local failing = arg[2] == 'moduleerror' and 'pinput' or 'params'
  if failLoad and path == '/SCRIPTS/MAV/' .. failing .. '.lua' then
    return nil, 'test loader failure'
  end
  local source = path
  if path:sub(-5) == '.luac' then
    sawBinary = true
    -- A build without LUA_COMPILER does not create the cache. Deliberately do
    -- not use the stale file injected by the deliverable test.
    source = arg[2] ~= 'literal' and compiled[path] or nil
    if not source then return nil end
  else
    assert(path:sub(-4)=='.lua', 'loadScript must use an explicit filename')
    if mode == 'tc' then
      sawCompile = true
      if arg[2] ~= 'literal' then compiled[path .. 'c'] = path end
    elseif mode == 'tx' then
      if path:sub(1, 13) == '/SCRIPTS/MAV/' then sawFallback, fallbackPath = true, path end
    elseif mode == 'bt' and path == '/SCRIPTS/TELEMETRY/MAV.lua' then
      -- Legacy Tools entries load the packaged bytecode through the .lua alias.
    else error('unexpected source load mode ' .. tostring(mode)) end
  end
  return loadfile(root .. source, 'bt')
end
local app = assert(loadfile(root .. '/SCRIPTS/TOOLS/MAV.lua'))()
app.init()
app.run(0)
local nav = screen
app.run(42)
assert(screen==nav, 'ENTER must not change Navigation')
app.run(40)
assert(killed==40 and screen:find('MESSAGES',1,true), 'PAGE opens Messages')
app.run(41)
assert(screen:find('MESSAGES',1,true), 'PAGE release cannot double-switch')
app.run(40)
for i=1,8 do app.run(0) end
assert(screen:find('PARAMETERS',1,true), 'third page is included in the ZIP')
if failLoad and string.pack then
  assert(screen:gsub('%s',''):find('testloaderfailure',1,true), 'show the actual loader error')
  assert(not screen:find('Install',1,true), 'do not misdiagnose a loader error as missing files')
  assert(screen:find('ENTER: retry',1,true), 'failed module loads can be retried')
  failLoad = false
  app.run(42)
  for i=1,8 do app.run(0) end
end
assert(screen:find(string.pack and '> LOAD <' or 'Needs EdgeTX 2.11',1,true))
if string.pack then
  assert(sawCompile and sawBinary, 'modern loader must compile source then load binary cache')
  assert(sawFallback == (arg[2] == 'literal'),
    'source fallback is only for builds without LUA_COMPILER: ' .. tostring(fallbackPath))
end
assert(sent==0, 'page entry must not request parameters')
print('PASS: packaged Tools entry, cache selection, PAGE/ENTER and opt-in third page')
