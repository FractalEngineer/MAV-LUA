-- Run with Lua 5.3: .build/lua53 tests/test_params.lua [package-root]
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
check(hex(wire.ping()) == vectors.ping, 'PING bytes')
check(hex(wire.read(17, 1, 300)) == vectors.read, 'indexed READ compatibility')
check(hex(wire.write(17, 1, {name='TEST_PARAM',kind=9},1.25)) == vectors.set, 'SET bytes')
local named = wire.readName(17, 1, 'BATT_MONITOR')
check(hex(named) == vectors.read_name, 'exact-name READ bytes')
local id, payload, sys, comp = wire.decode(named)
local index, targetSystem, targetComponent, parameterName = string.unpack('<i2BBc16', payload)
check(id == 20 and index == -1 and targetSystem == 17 and targetComponent == 1
  and parameterName:match('^[^%z]+') == 'BATT_MONITOR', 'exact-name READ layout')
local versionRequest = wire.versionRequest(17, 1)
id, payload = wire.decode(versionRequest)
local requested, command, targetSystem2, targetComponent2 = string.unpack('<f', payload),
  string.unpack('<I2', payload, 29), payload:byte(31), payload:byte(32)
check(id == 76 and requested == 148 and command == 512 and targetSystem2 == 17
  and targetComponent2 == 1, 'AUTOPILOT_VERSION request layout')

for _, name in ipairs({'heartbeat','heartbeat1','value','value1','truncated'}) do
  local message, body, source, component = wire.decode(envelope(vectors[name]))
  check(source == 17 and component == 1, name .. ' source')
  if message == 22 then
    local p = wire.parameter(body)
    check(p.name == 'TEST_PARAM' and p.value == 1.25 and p.index == 300
      and p.count == 301 and p.kind == 9, name .. ' fields')
  else check(message == 0 and body:byte(6) == 3, name .. ' heartbeat') end
end

id, payload = wire.decode(envelope(vectors.value_name))
local exact = wire.parameter(payload)
check(id == 22 and exact and exact.name == 'BATT_MONITOR' and exact.index == 65535,
  'exact-name PARAM_VALUE accepts ArduPilot index -1')

local extras = {[0]=50,[22]=220,[148]=178}
local function checksum(s, extra)
  local crc = 65535
  for i = 1, #s + 1 do
    local byte = i <= #s and s:byte(i) or extra
    crc = bit32.bxor(crc, byte)
    for _ = 1, 8 do
      local odd = crc % 2
      crc = math.floor(crc / 2)
      if odd == 1 then crc = bit32.bxor(crc, 0x8408) end
    end
  end
  return crc
end
local function packet(idValue, body, source, component)
  local header
  if idValue < 256 then
    header = string.char(#body, 0, source or 17, component or 1, idValue)
    local content = header .. body
    return string.char(254) .. content .. string.pack('<I2', checksum(content, extras[idValue]))
  end
  header = string.char(#body, 0, 0, 0, source or 17, component or 1,
    idValue % 256, math.floor(idValue / 256) % 256, math.floor(idValue / 65536))
  local content = header .. body
  return string.char(253) .. content .. string.pack('<I2', checksum(content, extras[idValue]))
end
local function chunks(message)
  local count = math.ceil(#message / 58)
  local result = {}
  for current = 0, count - 1 do
    local part = message:sub(current * 58 + 1, current * 58 + 58)
    local frame = {(count - 1) * 16 + current, #part}
    for i = 1, #part do frame[#frame + 1] = part:byte(i) end
    result[#result + 1] = frame
  end
  return result
end
local function versionPayload(major, minor, patch)
  local value = major * 16777216 + minor * 65536 + patch * 256
  return string.pack('<I8I8I4I4I4I4I2I2c8c8c8c18', 0, 0, value, 0, 0, 0, 0, 0,
    '', '', '', '')
end
local versionFrames = chunks(packet(148, versionPayload(4, 7, 0)))
check(#versionFrames == 2 and wire.decode(versionFrames[1]) == nil, 'version reply starts bounded reassembly')
id, payload, sys, comp = wire.decode(versionFrames[2])
local major, minor, patch = wire.version(payload)
check(id == 148 and sys == 17 and comp == 1 and major == 4 and minor == 7 and patch == 0,
  'multi-chunk AUTOPILOT_VERSION decode')

local hostio = io
local serial = 0
local function fixture(options)
  options = options or {}
  serial = serial + 1
  local f = {now=0, sent=0, sets=0, connected=true, module=true,
    output={}, replies={}, frames={}, reads={}, values={}, vehicle=options.vehicle or 2,
    major=options.major or 4, minor=options.minor or 7, patch=options.patch or 0}
  local env = setmetatable({}, {__index=_G})
  f.env = env
  env.io = {
    open=function(path, mode) return hostio.open(root .. path, mode == 'r' and 'rb' or mode) end,
    seek=function(file, offset) return file:seek('set', offset) and 0 or 1 end,
    read=function(file, count) return file:read(count) end,
    close=function(file) return file:close() end,
  }
  local compiled = {}
  env.loadScript = function(path, mode)
    if options.failDatabase and path == '/SCRIPTS/MAV/DB/a47c.lua' then return nil, 'db missing' end
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
  env.crossfireTelemetryPush = function(command, outgoing)
    check(command == 0xAA, 'one MAVLink envelope transport')
    f.sent = f.sent + 1
    if f.busy then return false end
    if not f.module then return true end
    local message, body, source, component = wire.decode(outgoing)
    check(source == 254 and component == 190, 'GCS source IDs')
    if message == 76 then
      if not f.dropVersion then
        local reply = chunks(packet(148, versionPayload(f.major, f.minor, f.patch)))
        for _, value in ipairs(reply) do f.replies[#f.replies + 1] = value end
      end
    elseif message == 20 then
      local requestedIndex, targetSys, targetComp, name = string.unpack('<i2BBc16', body)
      name = name:match('^[^%z]+')
      check(requestedIndex == -1 and targetSys == 17 and targetComp == 1,
        'browser reads selected names only')
      f.reads[#f.reads + 1] = name
      if replyEnabled and not f.drop then f.replies[#f.replies + 1] = {parameter=true,name=name} end
    elseif message == 23 then
      f.sets = f.sets + 1
      local value, targetSys, targetComp, name = string.unpack('<fBBc16', body)
      name = name:match('^[^%z]+')
      check(targetSys == 17 and targetComp == 1, 'write targets discovered vehicle')
      if not f.reject then f.values[name] = value end
    end
    return true
  end
  f.app = assert(env.loadScript('/SCRIPTS/MAV/params.lua'))()
  local function loadModule(name)
    return assert(env.loadScript('/SCRIPTS/MAV/' .. name .. '.lua'))()
  end
  while not f.app.init(loadModule) do collectgarbage('collect') end
  function f.deliver(value)
    if f.core then f.frames[#f.frames + 1] = {0xAA, value} else f.app.receive(value, f.now) end
  end
  function f.heartbeat()
    if f.module and not f.noHeartbeat then
      f.deliver(chunks(packet(0, string.pack('<I4BBBBB', 0, f.vehicle, 3, 1, 3, 3)))[1])
    end
  end
  function f.param(name, value, kind)
    f.deliver(chunks(packet(22, string.pack('<fI2I2c16B', value or f.values[name] or 1,
      1, 0, name, kind or 9)))[1])
  end
  function f.tick(event)
    f.now = f.now + (f.interval or 10)
    if f.now % 100 == 0 then f.heartbeat() end
    if f.core then f.core.run(event or 0) else f.app.tick(f.now, f.connected, true) end
    if #f.replies > 0 then
      local reply = table.remove(f.replies, 1)
      if reply.parameter then f.param(reply.name) else f.deliver(reply) end
    end
  end
  function f.draw(w, h)
    f.output = {}
    f.app.draw(function(x, y, value, inverse)
      check(x >= 0 and y >= 0 and y < (h or 96), 'text row is in bounds')
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
    f.waitFor('parameter names')
  end
  function f.open()
    f.action('enter')
    f.waitFor('ENTER: read value')
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
check(f.sent == 0 and f.draw():find('@> LOAD <', 1, true), 'parameter traffic remains opt-in')
f.load()
check(f.draw():find('Copter 4.7.0', 1, true) and f.draw():find('@GENERAL', 1, true),
  'firmware selects Copter 4.7 categories')
f.action('prev') f.waitFor('@ZIGZ')
check(f.draw():find('134/134', 1, true), 'previous from first category wraps to last')
f.action('next') f.waitFor('@GENERAL')
check(f.draw():find('1/134', 1, true), 'next from last category wraps to first')
for _ = 1, 20 do f.action('next') f.tick() end
for _ = 1, 20 do f.action('prev') f.tick() end
check(#f.reads == 0, 'category scrolling sends no parameter traffic')
local afterBrowsing = f.sent
f.open()
check(f.draw():find('@AUTO_OPTIONS', 1, true), 'first category page comes from packaged DB')
f.action('prev') f.waitFor('30/30')
f.action('next') f.waitFor('@AUTO_OPTIONS')
check(f.draw():find('1/30', 1, true), 'parameter names wrap in both directions')
for _ = 1, 8 do f.action('next') end
f.waitFor('9/30')
check(f.draw():find('@FLTMODE1', 1, true) and f.sent == afterBrowsing,
  'name page crossing performs only a 128-byte local read')
f.action('prev') f.waitFor('@FLIGHT_OPTIONS')
check(f.draw():find('8/30', 1, true) and f.sent == afterBrowsing,
  'local database supports reverse page navigation')
for _ = 1, 7 do f.action('prev') end
f.edit()
check(#f.reads == 1 and f.reads[1] == 'AUTO_OPTIONS', 'ENTER fetches exactly the selected name')
for _ = 1, 20 do f.action('next') end
check(f.sets == 0, 'editing remains local')
f.action('exit')
check(f.sets == 0, 'EXIT discards draft')
f.edit() f.action('menu') f.action('next') f.reviewSave()
f.waitFor('Saved and verified')
check(f.sets == 1 and f.values.AUTO_OPTIONS == 2, 'one SET plus matching exact-name readback')
f.action('enter') f.edit()
check(f.draw():find('Was: 2', 1, true), 'verified value is reread')
f.action('next') f.action('enter')
check(f.sets == 1, 'review defaults Back')
f.action('enter')
check(f.draw():find('Step:', 1, true), 'Back returns to editor')
f.noHeartbeat = true
for _ = 1, 35 do f.tick() end
f.reviewSave()
check(f.draw():find('Check link', 1, true) and f.sets == 1, 'stale heartbeat blocks a save')

f = fixture() f.load() f.open() f.edit() f.action('next') f.values.AUTO_OPTIONS = 7
f.reviewSave() f.waitFor('Value changed: reopen')
check(f.sets == 0, 'concurrent change is not overwritten')
f = fixture() f.load() f.open() f.edit() f.action('next') f.reject = true
f.reviewSave() f.waitFor('Readback differs')
check(f.sets == 1, 'rejected SET is not retried')
f = fixture() f.module = false f.action('enter')
f.waitFor('No parameter bridge', 700)
check(f.sets == 0, 'missing bridge failure is bounded')
f = fixture({minor=5}) f.action('enter') f.waitFor('No DB: Copter 4.5')
check(#f.reads == 0, 'unsupported firmware never starts parameter reads')
f = fixture({vehicle=1, minor=8}) f.load()
check(f.draw():find('Plane 4.8.0', 1, true) and f.draw():find('@GENERAL', 1, true),
  'Plane 4.8 firmware selects its packaged category database')
for _ = 1, 91 do f.action('next') f.tick() end
check(f.draw():find('@RC >', 1, true) and f.draw():find('17 groups', 1, true),
  'numbered parameter groups collapse into a family folder')
f.action('enter') f.waitFor('RC groups')
check(f.draw():find('@RC', 1, true), 'family includes the unnumbered base group')
f.action('prev') f.waitFor('@RC16')
check(f.draw():find('17/17', 1, true), 'nested groups wrap from first to last')
f.action('next') f.waitFor('@RC')
f.action('next')
check(f.draw():find('@RC1', 1, true), 'family contains naturally ordered numbered groups')
f.action('exit') f.waitFor('@RC >')
check(f.draw():find('92/134', 1, true), 'folder back restores the top-level selection')
f = fixture({vehicle=10, minor=8}) f.action('enter') f.waitFor('Unsupported vehicle')
check(#f.reads == 0, 'non-Plane/Copter firmware is explicitly out of scope')
f = fixture({failDatabase=true}) f.action('enter') f.waitFor('Database unavailable')
check(#f.reads == 0, 'missing packaged database is explicit')
f = fixture() f.load() f.connected = false f.tick()
check(f.draw():find('Link lost', 1, true), 'link loss invalidates detected target')
f.action('enter')
check(f.draw():find('Load parameter DB', 1, true), 'link loss requires fresh firmware discovery')

-- Hundreds of categories and names still retain only the current eight rows.
f = fixture()
for _ = 1, 4 do collectgarbage('collect') end
local beforeDatabase = collectgarbage('count')
f.load()
for _ = 1, 4 do collectgarbage('collect') end
local databaseGrowth = collectgarbage('count') - beforeDatabase
check(databaseGrowth < 30, 'paged category index has bounded heap growth: ' .. databaseGrowth)
for _ = 1, 79 do f.action('next') f.tick() end
check(f.draw():find('@OSD >', 1, true), 'large numbered families have one top-level row')
f.action('enter') f.waitFor('OSD groups')
f.action('next') -- OSD1 is the largest child group.
f.open()
for _ = 1, 200 do f.action('next') f.tick() end
check(f.draw():find('201/201', 1, true) and #f.reads == 0,
  'sustained local browsing retains one page and no live reads')
for _ = 1, 4 do collectgarbage('collect') end
local browseGrowth = collectgarbage('count') - beforeDatabase
check(browseGrowth < 30, 'sustained category/name browsing remains bounded: ' .. browseGrowth)
for _, dims in ipairs({{128,64},{128,96},{212,64},{480,272}}) do f.draw(dims[1], dims[2]) end

-- Real core and sole CRSF queue, including the two-chunk version reply.
f = fixture()
local e = f.env
e.LCD_W,e.LCD_H,e.INVERS,e.SOLID,e.FORCE,e.ERASE = 128,96,1,0,2,4
e.EVT_PAGE_FIRST,e.EVT_PAGE_BREAK,e.EVT_VIRTUAL_ENTER,e.EVT_EXIT_BREAK = 40,41,42,43
e.EVT_VIRTUAL_NEXT,e.EVT_VIRTUAL_PREV,e.EVT_VIRTUAL_MENU = 44,45,46
e.getTime=function() return f.now end e.getRSSI=function() return 99 end
local sensor={Ptch=-1.57,Roll=0,Yaw=1,RxBt=16,Sats=15,RQly=99,FM='AUTO',GSpd=31,GAlt=120,Curr=5}
e.getFieldInfo=function(name) return sensor[name] and {id=name} end
e.getValue=function(name) return sensor[name] end e.GREY=function(n) return n*65536 end
local screen, cursor = {}, 0
e.killEvents=function() end
e.crossfireTelemetryPop=function() local p=table.remove(f.frames,1) if p then return p[1],p[2] end end
e.lcd={clear=function() screen={} end,drawLine=function() end,
  drawText=function(x,y,value) cursor=x+#value*6 if y<e.LCD_H then screen[#screen+1]=value end end,
  getLastRightPos=function() return cursor end}
f.core=assert(loadfile(root..'/SCRIPTS/TELEMETRY/MAV.lua','bt',e))() f.core.init()
f.tick(40) f.tick(41) f.tick(40)
for _=1,8 do f.tick() end
check(table.concat(screen):find('LOAD',1,true) and f.sent==0,'core opens opt-in prompt')
f.tick(42)
local maximum=0
for _=1,120 do
  local instructions=0
  debug.sethook(function()
    local source=debug.getinfo(2,'S').source
    if source:find('/SCRIPTS/',1,true) or source=='=?' then instructions=instructions+1 end
  end,'',1)
  f.tick() debug.sethook() maximum=math.max(maximum,instructions)
  if table.concat(screen):find('parameter names',1,true) then break end
end
check(table.concat(screen):find('parameter names',1,true),'integrated queue opens category index')
check(maximum < 10000,'integrated callback budget: '..maximum)
print('Integrated parameters maximum: '..maximum..' Lua instructions')
print(string.format('PASS: %d category database, exact-read and guarded-write assertions; heap %.2f/%.2f KiB',
  ntests, databaseGrowth, browseGrowth))
