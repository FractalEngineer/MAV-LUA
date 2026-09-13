-- Run with the int32/float32 runner: .build/lua53 tests/test_params.lua [compiled-root]
local root = arg[1] or 'src'
local vectors = dofile('tests/fixtures/mavlink.lua')
local ntests = 0
local function check(condition, message) assert(condition, message) ntests = ntests + 1 end
local function envelope(hex)
  local p = {0, #hex / 2}
  for b in hex:gmatch('%x%x') do p[#p + 1] = tonumber(b, 16) end
  return p
end
local function hex(p)
  local out = ''
  for i = 3, #p do out = out .. string.format('%02x', p[i]) end
  return out
end
local wire = assert(loadfile(root .. '/SCRIPTS/MAV/wire.lua'))()
check(hex(wire.ping()) == vectors.ping, 'PING matches independently generated pymavlink bytes')
check(hex(wire.read(17, 1, 300)) == vectors.read, 'READ target, index, CRC and sequence')
check(hex(wire.write(17, 1, {name='TEST_PARAM',kind=9},1.25)) == vectors.set, 'SET float32 layout and CRC')
for _, name in ipairs({'heartbeat','heartbeat1','value','value1','truncated'}) do
  local id, payload, sys, comp = wire.decode(envelope(vectors[name]))
  check(sys == 17 and comp == 1, name .. ' MAVLink source')
  if id == 22 then
    local p = wire.parameter(payload)
    check(p.name == 'TEST_PARAM' and p.value == 1.25 and p.index == 300 and p.count == 301 and p.kind == 9,
      name .. ' fields')
  else check(id == 0 and #payload == 9 and payload:byte(6) == 3, name .. ' heartbeat / zero padding') end
end
for _, mutate in ipairs({
  function(p) p[1] = 1 end, function(p) p[2] = p[2] - 1 end,
  function(p) p[12] = (p[12] + 1) % 256 end, function(p) p[#p] = nil end,
  function(p) p[3] = -1 end, function(p) p[3] = 256 end,
  function(p) p[3] = 1.5 end, function(p) p[3] = 'bad' end,
  function(p) p[5] = 1 end,
}) do
  local p = envelope(vectors.value) mutate(p)
  check(wire.decode(p) == nil, 'malformed envelope is ignored')
end

local function frame(id, payload, sys, comp)
  local s = string.char(#payload, 0, sys or 17, comp or 1, id) .. payload
  local crc = 65535
  local input = s .. string.char(id == 0 and 50 or 220)
  for i = 1, #input do
    crc = bit32.bxor(crc, input:byte(i))
    for _ = 1, 8 do
      local odd = crc % 2 crc = math.floor(crc / 2)
      if odd == 1 then crc = bit32.bxor(crc, 0x8408) end
    end
  end
  s = string.char(254) .. s .. string.pack('<I2', crc)
  local p = {0, #s}
  for i = 1, #s do p[#p + 1] = s:byte(i) end
  return p
end

local serial = 0
local function fixture(count)
  serial = serial + 1
  local f = {now=0, sent=0, sets=0, total=count or 19, values={}, connected=true,
    module=true, armed=false, output={}, replies={}, frames={}, reads={}}
  -- The runtime deliberately has no Lua filesystem API.
  local env = setmetatable({table=nil, io=nil}, {__index=_G})
  f.env = env
  local compiled = {}
  env.loadScript = function(path, mode)
    if f.failFetch and path == '/SCRIPTS/MAV/fetch.lua' then return nil, 'fetch load failed' end
    local source = path
    if path:sub(-5) == '.luac' then
      source = compiled[path]
      if not source then return nil end
    else
      assert(path:sub(-4) == '.lua', 'module source path must be explicit')
      if mode == 'tc' then compiled[path .. 'c'] = path end
    end
    return loadfile(root .. source, 'bt', env)
  end
  local replyEnabled = true
  env.crossfireTelemetryPush = function(command, packet)
    check(command == 0xAA, 'one MAVLink envelope transport')
    f.sent = f.sent + 1
    if f.busy then return false end
    if not f.module then return true end
    local id, payload, sys, comp = wire.decode(packet)
    check(sys == 254 and comp == 190, 'GCS source IDs')
    if id == 20 then
      local index, targetSystem, targetComponent = string.unpack('<i2BB', payload)
      check(targetSystem == 17 and targetComponent == 1, 'request targets discovered vehicle')
      f.reads[#f.reads + 1] = index
      if replyEnabled and not f.drop then f.replies[#f.replies + 1] = index end
    elseif id == 23 then
      f.sets = f.sets + 1
      local value, targetSystem, targetComponent, name = string.unpack('<fBBc16', payload)
      check(targetSystem == 17 and targetComponent == 1, 'write targets discovered vehicle')
      name = name:match('^[^%z]*')
      for i = 0, f.total - 1 do
        if f.name(i) == name and not f.reject then f.values[i] = value break end
      end
    end
    return true
  end
  f.app = assert(env.loadScript('/SCRIPTS/MAV/params.lua'))()
  local function loadModule(name) return assert(env.loadScript('/SCRIPTS/MAV/' .. name .. '.lua'))() end
  while not f.app.init(loadModule) do collectgarbage('collect') end
  function f.deliver(packet)
    if f.core then f.frames[#f.frames + 1] = {0xAA, packet} else f.app.receive(packet, f.now) end
  end
  function f.heartbeat()
    if f.module and not f.noHeartbeat then
      f.deliver(frame(0, string.pack('<I4BBBBB', 0, 1, 3, f.armed and 129 or 1, 3, 3)))
    end
  end
  function f.name(index) return string.format('P_%04d', index) end
  function f.reply(index, source, kind, name, value)
    f.deliver(frame(22, string.pack('<fI2I2c16B', value or f.values[index] or 1,
      f.total, index, name or f.name(index), kind or 9), source))
  end
  function f.tick(event)
    f.now = f.now + (f.interval or 10)
    if f.now % 100 == 0 then f.heartbeat() end
    if f.core then f.core.run(event or 0) else f.app.tick(f.now, f.connected, true) end
    if #f.replies > 0 then f.reply(table.remove(f.replies, 1)) end
  end
  function f.draw(w, h)
    f.output = {}
    f.app.draw(function(x, y, value, inverse)
      check(x >= 0 and y >= 0 and y < (h or 96), 'parameter text row is in bounds')
      f.output[#f.output + 1] = (inverse and '@' or '') .. value
    end, function(_, value) f.output[#f.output + 1] = value end, w or 128, h or 96, 9)
    return table.concat(f.output, '\n')
  end
  function f.action(action) f.app.input(action, f.now) end
  function f.waitFor(value, limit)
    for _ = 1, limit or 300 do
      if f.draw():find(value, 1, true) then return end
      f.tick()
    end
    error('Timed out waiting for ' .. value .. ':\n' .. f.draw())
  end
  function f.load()
    f.action('enter')
    f.waitFor('All parameters')
  end
  function f.edit()
    f.action('enter')
    f.waitFor('Step:')
  end
  function f.reviewSave() f.action('enter') f.action('next') f.action('enter') end
  function f.suspendReplies(value) replyEnabled = not value end
  function f.close() end
  return f
end

if arg[2] == 'fixture' then return fixture end

local f = fixture()
for _ = 1, 30 do f.tick() end
check(f.sent == 0 and f.draw():find('@> LOAD <', 1, true), 'single Load button is opt-in')
check(not f.draw():find('Later', 1, true), 'Later choice is removed')
f.load()
check(#f.reads <= 12 and f.draw():find('P_0000', 1, true), 'Load fetches only the first bounded page')
for _ = 1, 7 do f.action('next') end
check(f.draw():find('P_0007', 1, true), 'roller selects within live page')
f.action('next') f.waitFor('P_0008')
check(f.draw():find('9/19', 1, true), 'roller loads the next indexed page')
f.action('prev') f.waitFor('P_0007')
check(f.draw():find('8/19', 1, true), 'roller loads the previous indexed page and selects its end')
f.edit()
for _ = 1, 20 do f.action('next') end
check(f.sets == 0, 'scrolling only edits local draft')
f.action('exit')
check(f.sets == 0, 'EXIT discards draft')
f.edit() f.action('menu') f.action('next') f.reviewSave()
f.waitFor('Saved and verified')
check(f.sets == 1 and f.values[7] == 2, 'exactly one PARAM_SET and matching readback')
f.action('enter') f.edit()
check(f.draw():find('Was: 2', 1, true), 'verified value updates the live row')
f.action('next') f.action('enter')
check(f.sets == 1, 'save review defaults Back')
f.action('enter') check(f.draw():find('Step:', 1, true), 'Back returns editor')
f.armed = true f.heartbeat() f.reviewSave()
check(f.draw():find('Disarm / check link', 1, true) and f.sets == 1, 'armed saves are blocked')

f = fixture() f.load() f.edit() f.action('next') f.values[0] = 7
f.reviewSave() f.waitFor('Value changed: reopen')
check(f.sets == 0, 'concurrent change is not overwritten')
f = fixture() f.load() f.edit() f.action('next') f.reject = true
f.reviewSave() f.waitFor('Readback differs')
check(f.sets == 1, 'rejected write is neither repeated nor reported saved')
f = fixture() f.module = false f.action('enter')
f.waitFor('No parameter bridge', 700)
check(f.sets == 0, 'missing bridge failure is bounded and honest')
f = fixture() f.failFetch = true f.action('enter') f.tick()
check(f.draw():find('fetch load failed', 1, true) and f.sent == 0, 'deferred downloader failure precedes traffic')

-- A huge advertised list still retains and requests only one eight-row window.
f = fixture(8192)
for _ = 1, 4 do collectgarbage('collect') end
local before = collectgarbage('count')
f.load()
for _ = 1, 4 do collectgarbage('collect') end
local growth = collectgarbage('count') - before
check(growth < 35 and #f.reads <= 12, '8192-count list remains a bounded live window: ' .. growth)
for _, dims in ipairs({{128,64},{128,96},{212,64},{480,272}}) do f.draw(dims[1], dims[2]) end

-- Real core + sole CRSF queue, including firmware-like PAGE FIRST.
f = fixture(24)
local e = f.env
e.LCD_W,e.LCD_H,e.INVERS,e.SOLID,e.FORCE,e.ERASE = 128,96,1,0,2,4
e.EVT_PAGE_FIRST,e.EVT_PAGE_BREAK,e.EVT_VIRTUAL_ENTER,e.EVT_EXIT_BREAK = 40,41,42,43
e.EVT_VIRTUAL_NEXT,e.EVT_VIRTUAL_PREV,e.EVT_VIRTUAL_MENU = 44,45,46
e.getTime=function() return f.now end e.getRSSI=function() return 99 end
local sensor={Ptch=-1.57,Roll=0,Yaw=1,RxBt=16,Sats=15,RQly=99,FM='AUTO',GSpd=31,GAlt=120,Curr=5}
e.getFieldInfo=function(name) return sensor[name] and {id=name} end
e.getValue=function(name) return sensor[name] end e.GREY=function(n) return n*65536 end
local killed, screen, cursor = 0, {}, 0
e.killEvents=function(event) killed=event end
e.crossfireTelemetryPop=function() local p=table.remove(f.frames,1) if p then return p[1],p[2] end end
e.lcd={clear=function() screen={} end,drawLine=function() end,
  drawText=function(x,y,value) cursor=x+#value*6 if y<e.LCD_H then screen[#screen+1]=value end end,
  getLastRightPos=function() return cursor end}
f.core=assert(loadfile(root..'/SCRIPTS/TELEMETRY/MAV.lua','bt',e))() f.core.init()
f.tick(40) f.tick(41) f.tick(40)
for _=1,8 do f.tick() end
check(table.concat(screen):find('LOAD',1,true) and f.sent==0,'core opens opt-in parameter prompt without io')
f.tick(42)
local maximum=0
for _=1,120 do
  local instructions=0
  debug.sethook(function()
    local source=debug.getinfo(2,'S').source
    if source:find('/SCRIPTS/',1,true) or source=='=?' then instructions=instructions+1 end
  end,'',1)
  f.tick() debug.sethook() maximum=math.max(maximum,instructions)
  if table.concat(screen):find('All parameters',1,true) then break end
end
check(table.concat(screen):find('All parameters',1,true),'integrated raw queue opens first live page')
check(maximum < 10000,'integrated callback budget: '..maximum)
print('Integrated parameters maximum: '..maximum..' Lua instructions')
print(string.format('PASS: %d parameter assertions; 8192-count live-window growth %.2f KiB', ntests, growth))
