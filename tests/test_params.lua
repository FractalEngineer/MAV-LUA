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

-- The parameter names a vehicle reports, in the index order an autopilot streams them.
-- Deliberately unsorted, with numbered families, so the builder must sort and group.
local VEHICLE_STREAM = {
  'AUTO_OPTIONS', 'FLIGHT_OPTIONS', 'ZIGZ', 'SCHED_LOOP_RATE',
  'RC_OPTIONS', 'RC2_MIN', 'RC1_MIN', 'RC10_MIN', 'RC1_MAX', 'RC2_MAX',
  'OSD_TYPE', 'OSD1_EN', 'OSD2_EN',
  'BATT_MONITOR', 'BATT_CAPACITY', 'ARMING_CHECK',
}
local function fixture(options)
  options = options or {}
  serial = serial + 1
  local f = {now=0, sent=0, sets=0, connected=true, module=true, armed=false,
    output={}, replies={}, frames={}, reads={}, values={}, vehicle=options.vehicle or 2,
    major=options.major or 4, minor=options.minor or 7, patch=options.patch or 0,
    streamAt=0, refuseLists=options.refuseLists}
  local env = setmetatable({}, {__index=_G})
  f.env = env
  -- Index files are written by the app, so they must never land in the source tree. Any
  -- identity-addressed index path is redirected to a scratch directory beside the build.
  local scratch = '.build/params-index'
  -- The index lives beside the modules, named for the identity. It must NOT sit in a
  -- subfolder: EdgeTX's io has no mkdir and FatFs will not create a missing parent, so the
  -- builder can only write where the package already guarantees a directory exists.
  local function isIndex(path) return path:match('^/SCRIPTS/MAV/i%d%d%d%d[cp]') ~= nil end
  local function resolve(path)
    if isIndex(path) then return scratch .. '/' .. path:match('([^/]+)$') end
    return root .. path
  end
  -- Each fixture starts with no index, so the build path is exercised every time. This scratch
  -- directory is host scaffolding only; on the card the index sits in SCRIPTS/MAV, which the
  -- package already creates.
  os.execute('mkdir .build\\params-index 2>nul')
  for _, suffix in ipairs({'.nam', '.run', '.pdb', '.lua'}) do
    os.remove(scratch .. '/' .. 'i0407c' .. suffix)
    os.remove(scratch .. '/' .. 'i0801p' .. suffix)
  end
  env.io = {
    -- EdgeTX takes the file first, exposes only open/read/write/seek/close, and writes raw
    -- bytes with no text translation. Host files must therefore be opened in binary mode.
    open=function(path, mode)
      local file = resolve(path)
      if mode == 'r' or mode == 'rb' then return hostio.open(file, 'rb') end
      if mode == 'w' or mode == 'wb' then return hostio.open(file, 'wb') end
      if mode == 'a' or mode == 'ab' then return hostio.open(file, 'ab') end
      return hostio.open(file, mode)
    end,
    seek=function(file, offset) return file:seek('set', offset) and 0 or 1 end,
    read=function(file, count) return file:read(count) end,
    write=function(file, data) return file:write(data) end,
    close=function(file) return file:close() end,
  }
  local compiled = {}
  env.loadScript = function(path, mode)
    local source = path
    if path:sub(-5) == '.luac' then
      source = compiled[path]
      if not source then return nil end
    elseif isIndex(path) then
      -- The identity-addressed index manifest is written by the builder, not shipped.
      return loadfile(scratch .. '/' .. path:match('([^/]+)$'), mode, env)
    else
      assert(path:sub(-4) == '.lua', 'module source path must be explicit')
      if mode == 'tc' then compiled[path .. 'c'] = path end
    end
    return loadfile(root .. source, 'bt', env)
  end
  local replyEnabled = true
  -- The parameter stream a real autopilot sends in answer to PARAM_REQUEST_LIST, in index
  -- order. It is deliberately not alphabetical, which is what the builder must sort.
  local stream = options.stream or VEHICLE_STREAM
  local streamAt = 0
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
    elseif message == 21 then
      -- The bridge only forwards a list request during its bounded list session, so the
      -- stream starts here and is delivered one name per tick like the real link.
      local targetSys, targetComp = string.unpack('<BB', body)
      check(targetSys == 17 and targetComp == 1, 'list request targets the discovered vehicle')
      -- The bridge refuses a request that follows another within its read gap, and it gives Lua
      -- no signal when it does. `refuseLists` reproduces that deterministically, because the
      -- real race depends on link timing that a host test cannot control: a single
      -- fire-and-forget request then does nothing, while a retry succeeds.
      if f.refuseLists and f.refuseLists > 0 then
        f.refuseLists = f.refuseLists - 1
        f.listRefused = (f.listRefused or 0) + 1
        return true
      end
      streamAt = 0
      f.streaming = true
      f.buildSent = true
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
  -- The index is built by the standalone Tools script, not by the Parameters page, because
  -- building alongside the browser exhausted the radio heap. Model the radio honestly: a tool
  -- runs in its own state with the permanent scripts paused, owns its own telemetry queue, and
  -- is not subject to the permanent-script instruction budget.
  f.toolFrames = {}
  f.target = 'app'
  env.getTime = function() return f.now end
  -- A Tools script draws on its own screen, so the shared test lcd is enough.
  env.lcd = {drawText=function() end, drawLine=function() end, clear=function() end,
    drawFilledRectangle=function() end, setColor=function() end}
  env.LCD_H, env.LCD_W, env.INVERS = 64, 212, 1
  env.crossfireTelemetryPop = function()
    -- EdgeTX returns the command and the raw envelope, marker and length included.
    local value = table.remove(f.toolFrames, 1)
    if value then return 0xAA, value end
  end
  f.tool = assert(env.loadScript('/SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua'))()
  -- Verifies a built index against the names the vehicle streamed. The record area is a whole
  -- number of 22-byte header records, so with `count` names the remainder must divide exactly:
  -- fileSize == headers * 22 + count * 16. Scanning for records instead does not work, because
  -- parameter names also look like valid labels.
  function f.indexNames()
    -- The tool writes the index for the identity it discovered. A fixture that drove the tool
    -- directly never went through the page, so the key defaults to the Copter 4.7 one.
    local file = hostio.open(scratch .. '/' .. (f.dbkey or 'i0407c') .. '.pdb', 'rb')
    if not file then return 0 end
    local all = file:read('a')
    file:close()
    local names = select(3, f.tool.status())
    if not names or names < 1 then return 0 end
    local headers = (#all - names * 16) / 22
    if headers ~= math.floor(headers) or headers < 1 then return 0 end
    -- Every name must be one the vehicle actually reported, read from the name region.
    local seen = {}
    for i = 0, names - 1 do
      local at = headers * 22 + i * 16
      seen[string.sub(all, at + 1, at + 16):match('^[^%z]+')] = true
    end
    for _, expected in ipairs(stream) do
      if not seen[expected] then return 0 end
    end
    return names
  end
  function f.build()
    -- The tool drives the same bridge replies the page would receive.
    f.target, f.toolPhase = 'tool', 'building'
    f.tool.init()
    local guard = 0
    assert(f.tool.run(0) == 0, 'tool must stay open while building')
    while f.tool.status() ~= 'done' and f.tool.status() ~= 'failed'
      and guard < 40 * (#stream + 80) do
      guard = guard + 1
      assert(f.tool.run(0) == 0, 'tool closed before finishing: ' .. tostring(f.tool.status()))
      f.now = f.now + (f.interval or 10)
      -- The vehicle answers the tool exactly as it answers the page.
      if f.now % 100 == 0 then f.heartbeat() end
      if #f.replies > 0 then
        local reply = table.remove(f.replies, 1)
        if reply.parameter then f.param(reply.name) else f.deliver(reply) end
      end
      if f.streaming and f.streamAt < #stream then
        f.streamAt = f.streamAt + 1
        local name = stream[f.streamAt]
        f.deliver(chunks(packet(22, string.pack('<fI2I2c16B', f.values[name] or 1,
          #stream, f.streamAt - 1, name, 9)))[1])
        if f.streamAt >= #stream then f.streaming = false end
      end
    end
    local phase, reason = f.tool.status()
    assert(guard < 40 * (#stream + 80) and phase == 'done',
      'tool build did not finish: ' .. tostring(phase) .. ' ' .. tostring(reason))
    f.target = 'app'
  end
  -- Drives the tool to a stop without requiring success, so a failing build can be inspected.
  -- Returns the final phase and reason.
  function f.runTool()
    f.target = 'tool'
    f.tool.init()
    local guard = 0
    while f.tool.status() ~= 'done' and f.tool.status() ~= 'failed' and guard < 3000 do
      guard = guard + 1
      if f.tool.run(0) ~= 0 then break end
      f.now = f.now + (f.interval or 10)
      if f.now % 100 == 0 then f.heartbeat() end
      if #f.replies > 0 then
        local reply = table.remove(f.replies, 1)
        if reply.parameter then f.param(reply.name) else f.deliver(reply) end
      end
      if f.streaming and f.streamAt < #stream then
        f.streamAt = f.streamAt + 1
        local name = stream[f.streamAt]
        f.deliver(chunks(packet(22, string.pack('<fI2I2c16B', f.values[name] or 1,
          #stream, f.streamAt - 1, name, 9)))[1])
        if f.streamAt >= #stream then f.streaming = false end
      end
    end
    f.target = 'app'
    return f.tool.status()
  end
  function f.deliver(value)
    if f.core then f.frames[#f.frames + 1] = {0xAA, value}
    elseif f.target == 'tool' then f.toolFrames[#f.toolFrames + 1] = value
    else f.app.receive(value, f.now) end
  end
  function f.heartbeat()
    if f.module and not f.noHeartbeat then
      f.deliver(chunks(packet(0, string.pack('<I4BBBBB', 0, f.vehicle, 3,
        f.armed and 129 or 1, 3, 3)))[1])
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
    -- Answer an open list session one parameter at a time, as the aircraft does.
    if f.streaming and f.streamAt < #stream then
      f.streamAt = f.streamAt + 1
      local name = stream[f.streamAt]
      f.deliver(chunks(packet(22, string.pack('<fI2I2c16B', f.values[name] or 1,
        #stream, f.streamAt - 1, name, 9)))[1])
      if f.streamAt >= #stream then f.streaming = false end
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
    -- No index exists for this identity yet, so the page points at the Tools builder rather
    -- than attempting the build itself.
    f.waitFor('Run Tools > MAV Index')
    -- Any key backs out, because nothing is browsable until the tool has run.
    f.action('exit')
    -- The standalone tool performs the read.
    f.build()
    f.dbkey = 'i0407c'
    -- Re-open the page, which now finds the index the tool wrote.
    f.action('enter')
    local guard = 0
    while not f.draw():find('parameter names', 1, true)
      and not f.draw():find('groups', 1, true) do
      f.tick()
      guard = guard + 1
      assert(guard < 40 * (#stream + 40), 'built index was not browsable')
    end
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
-- The index is built from this vehicle, so its categories come from the stream above.
check(f.draw():find('Copter 4.7.0', 1, true), 'firmware identifies the vehicle')
check(f.draw():find('@GENERAL', 1, true) and f.draw():find('RC >', 1, true),
  'categories come from the parameter names the vehicle reported')
check(f.buildSent, 'a list request was sent to read the vehicle parameters')
check(f.indexNames() == #VEHICLE_STREAM, 'the index retained every reported parameter')
local afterBrowsing = f.sent
for _ = 1, 20 do f.action('next') f.tick() end
for _ = 1, 20 do f.action('prev') f.tick() end
check(#f.reads == 0, 'category scrolling sends no parameter traffic')
-- Only the lease keepalive is transmitted; no reads and no further list requests.
check(f.sent - afterBrowsing <= 2, 'scrolling sends at most the lease keepalive')
-- Open the RC family folder, which must list its members in natural order.
local guard = 0
while not f.draw():find('@RC >', 1, true) do
  f.action('next')
  f.tick()
  guard = guard + 1
  assert(guard < 40, 'RC category not reachable')
end
f.action('enter')
f.waitFor('RC groups')
check(f.draw():find('@RC', 1, true), 'family lists its unnumbered base first')
f.action('next')
f.tick()
check(f.draw():find('@RC1', 1, true), 'numbered groups are listed in natural order')
f.action('next')
f.tick()
check(f.draw():find('@RC2', 1, true), 'RC2 follows RC1, not RC10')
f.action('exit') f.waitFor('@RC >')
check(#f.reads == 0, 'folder browsing stays local')
-- Navigate to a known category and open its first name, then exercise the write path.
guard = 0
while not f.draw():find('@AUTO', 1, true) do
  f.action('next')
  f.tick()
  guard = guard + 1
  assert(guard < 40, 'AUTO category not reachable')
end
f.open()
check(f.draw():find('@AUTO_OPTIONS', 1, true), 'category lists the names the vehicle reported')
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
f.armed = true f.heartbeat() f.reviewSave()
check(f.draw():find('Disarm / check link', 1, true) and f.sets == 1, 'armed save blocked')

-- The selection is a streamed name, so these fixtures navigate the same way the pilot does.
local function openAuto(fixtureValue)
  local guard = 0
  while not fixtureValue.draw():find('@AUTO', 1, true) do
    fixtureValue.action('next')
    fixtureValue.tick()
    guard = guard + 1
    assert(guard < 40, 'AUTO category not reachable')
  end
  fixtureValue.open()
end

f = fixture() f.load() openAuto(f) f.edit() f.action('next') f.values.AUTO_OPTIONS = 7
f.reviewSave() f.waitFor('Value changed: reopen')
check(f.sets == 0, 'concurrent change is not overwritten')
f = fixture() f.load() openAuto(f) f.edit() f.action('next') f.reject = true
f.reviewSave() f.waitFor('Readback differs')
check(f.sets == 1, 'rejected SET is not retried')
f = fixture() f.module = false f.action('enter')
f.waitFor('No parameter bridge', 700)
check(f.sets == 0, 'missing bridge failure is bounded')
f = fixture({vehicle=10, minor=8}) f.action('enter') f.waitFor('Unsupported vehicle')
check(#f.reads == 0, 'non-Plane/Copter firmware is explicitly out of scope')
-- An empty stream must still fail explicitly in the tool rather than write an empty index,
-- because a browsable index with no names would be worse than the prompt.
f = fixture({stream={}}) f.action('enter') f.waitFor('Run Tools > MAV Index')
check(true, 'a vehicle with no index is pointed at the Tools builder')
local emptyTool = fixture({stream={}})
emptyTool.target = 'tool'
emptyTool.tool.init()
local emptyGuard = 0
while emptyTool.tool.run(0) == 0 and emptyGuard < 2000 do
  emptyGuard = emptyGuard + 1
  emptyTool.now = emptyTool.now + 10
  emptyTool.heartbeat()
end
check(not hostio.open('.build/params-index/i0407c.pdb', 'rb'),
  'an empty parameter stream writes no index')
-- The bridge refuses a request that follows another within its read gap, and Lua gets no signal
-- when that happens. A single fire-and-forget list request therefore failed whenever the version
-- reply and the request landed in adjacent ticks, while an immediate retry succeeded. The test
-- fixture models that floor, so this reaches the build only if the tool re-sends.
do
  -- The bridge silently refuses a list request that follows another too closely, and Lua is
  -- told nothing. `refuseLists` reproduces that deterministically, because the real race depends
  -- on link timing a host test cannot control. This is the reported failure: the first request
  -- does nothing and an immediate retry works. A single fire-and-forget request cannot recover.
  local f2 = fixture({refuseLists = 2})
  local _, reason = f2.runTool()
  check((f2.listRefused or 0) == 2, 'the fixture refused the first two list requests')
  check(f2.buildSent, 'the list request was eventually accepted')
  check(reason == nil or reason:find('No parameter stream', 1, true) == nil,
    'a build must recover from refused list requests: ' .. tostring(reason))
  check(f2.indexNames() >= #VEHICLE_STREAM, 'the recovered build retained every parameter')
end

-- The two ways a list can deliver nothing must be distinguishable. If no value arrives at all
-- the request never reached an autopilot, which on this hardware means a TX module without
-- list-session support; if values arrive but carry no usable names the vehicle is at fault.
-- Reporting the same thing for both sends a pilot hunting in the wrong place, which is exactly
-- what happened when a stale module firmware silently dropped PARAM_REQUEST_LIST.
do
  local silent = fixture({stream={}})
  local phase, reason = silent.runTool()
  check(phase == 'failed', 'a stream that never arrives fails the tool')
  check(reason and reason:find('reflash', 1, true) ~= nil,
    'no stream at all points at the TX module: ' .. tostring(reason))
end
do
  -- Values arrive, but every one is rejected, so no name is retained.
  local empty = fixture({stream={'__bad__'}})
  local phase, reason = empty.runTool()
  check(phase == 'failed', 'a stream with no usable names fails the tool')
  check(reason and reason:find('no parameters', 1, true) ~= nil,
    'a stream with no names blames the vehicle: ' .. tostring(reason))
end
-- Aborting is the tool's job now; the page simply never offers a build of its own.
f = fixture() f.action('enter') f.waitFor('Run Tools > MAV Index')
f.action('exit')
check(f.draw():find('Load parameter DB', 1, true),
  'leaving the missing-index screen returns to the opt-in prompt')
f = fixture() f.load() f.connected = false f.tick()
check(f.draw():find('Link lost', 1, true), 'link loss invalidates detected target')
f.action('enter')
check(f.draw():find('Load parameter DB', 1, true), 'link loss requires fresh firmware discovery')

-- Hundreds of categories and names still retain only the current eight rows. The stream is
-- built here so a large numbered family and a 201-name group are both exercised.
local bigStream, bigSeen = {}, {}
local function addBig(name)
  if not bigSeen[name] then bigSeen[name] = true bigStream[#bigStream + 1] = name end
end
for i = 1, 120 do
  local base = string.format('BIG%03d', i)
  addBig(base .. '_TYPE')
  addBig(base .. '_OPTIONS')
  for j = 1, 8 do addBig(string.format('%s_VAL_%02d', base, j)) end
end
addBig('RC_OPTIONS')
for i = 1, 16 do
  -- Several names per RC group, so a folder child has more than one page.
  for j = 1, 20 do addBig(string.format('RC%d_OPT_%02d', i, j)) end
end
for i = 1, 201 do addBig(string.format('OSD1_EN_%03d', i)) end
local bigTotal = #bigStream

f = fixture({stream=bigStream})
for _ = 1, 4 do collectgarbage('collect') end
local beforeDatabase = collectgarbage('count')
f.load()
f.dbkey = 'i0407c'
check(f.indexNames() >= bigTotal, 'large vehicle stream retains every parameter')
for _ = 1, 4 do collectgarbage('collect') end
local databaseGrowth = collectgarbage('count') - beforeDatabase
-- This covers the loaded parameter modules plus the category/browse state. It is checked
-- here as a bound; the invariant that memory must not track the parameter count is verified
-- separately below by comparing vehicles of equal category count but very different size.
check(databaseGrowth < 140, 'paged category index has bounded heap growth: ' .. databaseGrowth)
-- A large numbered family must still collapse into a single folder row.
local walk = 0
while not f.draw():find('@RC >', 1, true) do
  f.action('next')
  f.tick()
  walk = walk + 1
  assert(walk < 40, 'RC folder not reachable')
end
f.action('enter') f.waitFor('RC groups')
check(#f.reads == 0, 'entering a folder performs no vehicle reads')
f.action('next')
f.open()
-- Page to the end of this group, then wrap: the list cycles without touching the vehicle.
f.action('prev') f.waitFor('20/20')
f.action('next') f.waitFor('1/20')
check(f.draw():find('@RC1_OPT_01', 1, true) and #f.reads == 0,
  'folder paging wraps locally and reads nothing from the vehicle')
-- A 201-name group must page fully without ever reading from the vehicle.
for _ = 1, 4 do collectgarbage('collect') end
local browseGrowth = collectgarbage('count') - beforeDatabase
check(browseGrowth < 160, 'sustained category/name browsing remains bounded: ' .. browseGrowth)

-- Retained memory must scale with the number of categories, never with the number of names.
-- Holding the parameter list is the failure mode this design exists to avoid. Each size is
-- measured twice and the second result used, so first-build transients (module tables and
-- interned strings) do not masquerade as retention.
local function retainedFor(nameCount, categoryCount)
  local stream, seen = {}, {}
  local perCategory = math.max(1, math.floor(nameCount / categoryCount))
  for i = 1, categoryCount do
    for j = 1, perCategory do
      local n = string.format('CAT%04d_P%03d', i, j)
      if not seen[n] then seen[n] = true stream[#stream + 1] = n end
    end
  end
  local growth
  for _ = 1, 2 do
    local sized = fixture({stream = stream})
    for _ = 1, 3 do collectgarbage('collect') end
    local before = collectgarbage('count')
    sized.load()
    for _ = 1, 3 do collectgarbage('collect') end
    growth = collectgarbage('count') - before
  end
  return growth, #stream
end

local smallGrowth, smallNames = retainedFor(160, 20)
local largeGrowth, largeNames = retainedFor(1600, 20)
check(smallNames == 160 and largeNames == 1600, 'scaling fixtures differ in size only')
-- Ten times the parameters over the same categories must not retain anything like ten times
-- the memory. A generous multiplier keeps the check meaningful without tracking GC noise.
check(largeGrowth < math.max(8, smallGrowth * 3),
  string.format('retained memory does not scale with parameter count (160 names %.1f KiB vs 1600 names %.1f KiB)',
    smallGrowth, largeGrowth))
-- Repeating a build over the same vehicle must not accumulate memory.
local repeats = {}
for round = 1, 3 do repeats[round] = select(1, retainedFor(800, 20)) end
check(math.abs(repeats[3] - repeats[1]) < 8,
  string.format('repeated builds do not accumulate memory (%.1f, %.1f, %.1f KiB)',
    repeats[1], repeats[2], repeats[3]))
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
-- ENTER opens the flow; the vehicle has no index yet, so a build is offered and driven.
f.tick(42)
local maximum=0
local function measured(event)
  local instructions=0
  debug.sethook(function()
    local source=debug.getinfo(2,'S').source
    if source:find('/SCRIPTS/',1,true) or source=='=?' then instructions=instructions+1 end
  end,'',1)
  f.tick(event) debug.sethook() maximum=math.max(maximum,instructions)
  return instructions
end
for _=1,120 do
  measured()
  if table.concat(screen):find('Run Tools > MAV Index',1,true) then break end
end
-- The page no longer builds, so the figure that matters is that the core callback stays inside
-- the permanent-script budget. The build itself is measured by test_index_cost.lua, which knows
-- a tool is not subject to that budget.
check(table.concat(screen):find('Run Tools > MAV Index',1,true),
  'core points at the Tools builder when no index exists')
check(maximum < 10000,'integrated callback budget: '..maximum)
print('Integrated parameters maximum: '..maximum..' Lua instructions')
print(string.format('PASS: %d discovered-index and guarded-write assertions; heap %.2f/%.2f KiB',
  ntests, databaseGrowth, browseGrowth))
