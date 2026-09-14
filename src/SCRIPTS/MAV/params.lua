-- SPDX-License-Identifier: GPL-3.0-or-later
-- Category-first ArduPilot browser. Names come from a packaged database;
-- telemetry reads only the value selected by the pilot.
local wire, view, database, controls, moduleLoader
local s = {state='prompt', rows={}, selected=1, pageStart=1,
  categoryRows={}, categorySelected=1, categoryPageStart=1,
  categoryIndexOffset=0,
  steps={0.000001, 0.00001, 0.0001, 0.001, 0.01, 0.1, 1, 10, 100, 1000, 10000, 100000, 1000000}}

local function ready(now)
  return s.heartbeatAt and now >= s.heartbeatAt and now - s.heartbeatAt <= 300 and not s.armed
end

local function clearGroup()
  for i = #s.rows, 1, -1 do s.rows[i] = nil end
  s.selected, s.pageStart = 1, 1
  s.group, s.groupName, s.groupTotal = nil, nil, nil
end

local function failure(message)
  s.pending, s.state, s.errorText = nil, 'error', message
end

local function request(kind, name)
  s.pending = {kind=kind, name=name, tries=0}
end

local function databaseKey(vehicle, major, minor)
  local code, label
  if vehicle == 1 or vehicle >= 19 and vehicle <= 25 then code, label = 'p', 'Plane'
  elseif vehicle == 2 or vehicle == 3 or vehicle == 4 or vehicle == 13 or vehicle == 14
    or vehicle == 15 or vehicle == 29 then code, label = 'c', 'Copter'
  end
  if not code then return nil, 'Unsupported vehicle' end
  if major ~= 4 or minor ~= 6 and minor ~= 7 and minor ~= 8 then
    return nil, 'No DB: ' .. label .. ' ' .. major .. '.' .. minor
  end
  return 'DB/a' .. major .. minor .. code, label
end

local function begin(now)
  clearGroup()
  s.database, s.dbkey, s.dbVersion, s.vehicleName, s.firmware = nil, nil, nil, nil, nil
  for i = #s.categoryRows, 1, -1 do s.categoryRows[i] = nil end
  s.categoryTotal = nil
  s.sys, s.comp, s.vehicle, s.heartbeatAt, s.armed = nil, nil, nil, nil, nil
  s.categorySelected, s.categoryPageStart, s.categoryIndexOffset = 1, 1, 0
  s.folderName, s.parentPageStart, s.parentSelected = nil, nil, nil
  s.nextAt, s.lastPing = now, nil
  s.state = 'connect'
  request('connect')
end

local function cancel()
  clearGroup()
  for i = #s.categoryRows, 1, -1 do s.categoryRows[i] = nil end
  s.pending, s.database, s.categoryTotal, s.state = nil, nil, nil, 'prompt'
  s.folderName, s.categoryIndexOffset = nil, 0
end

local function receive(frame, now)
  if s.state == 'prompt' or s.state == 'database' or s.state == 'groupLoading' then return end
  local id, payload, source, component = wire.decode(frame)
  if not id then return end
  if id == 0 then
    if source == 0 or component ~= 1 or string.byte(payload, 6) ~= 3 then return end
    if not s.sys and s.state == 'connect' then
      s.sys, s.comp, s.vehicle = source, component, string.byte(payload, 5)
    end
    if s.sys ~= source or s.comp ~= component then return end
    s.heartbeatAt, s.armed = now, string.byte(payload, 7) >= 128
    if s.state == 'connect' and s.pending and s.pending.sent then
      s.pending, s.state = nil, 'identity'
      request('version')
    end
    return
  end
  if source ~= s.sys or component ~= s.comp or not s.pending or not s.pending.sent then return end
  if id == 148 and s.pending.kind == 'version' then
    local major, minor, patch = wire.version(payload)
    local key, label = databaseKey(s.vehicle, major, minor)
    s.pending = nil
    if not key then failure(label) return end
    s.dbkey, s.vehicleName = key, label
    s.dbVersion = major .. '.' .. minor
    s.firmware = label .. ' ' .. major .. '.' .. minor .. '.' .. patch
    s.state = 'database'
    return
  end
  if id ~= 22 or s.pending.kind == 'connect' or s.pending.kind == 'version'
    or s.pending.kind == 'write' then return end
  local p = wire.parameter(payload)
  if not p or p.name ~= s.pending.name then return end
  local kind = s.pending.kind
  s.pending = nil
  if kind == 'edit' then
    s.current, s.edited, s.stepIndex = p, p.value, 7
    if p.kind == 9 then
      local target = p.value == 0 and 0.1 or math.abs(p.value) * 0.1
      s.stepIndex = 1
      while s.stepIndex < #s.steps and s.steps[s.stepIndex + 1] <= target do
        s.stepIndex = s.stepIndex + 1
      end
    end
    s.state = 'edit'
  elseif not s.current or p.kind ~= s.current.kind then
    failure('Parameter changed')
  elseif kind == 'check' then
    if p.value ~= s.current.value then failure('Value changed: reopen') return end
    if not ready(now) then failure('Disarm / check link') return end
    s.state = 'saving'
    request('write', p.name)
  elseif kind == 'verify' then
    if p.value ~= s.sentValue then failure('Readback differs') return end
    s.current, s.state = p, 'saved'
  end
end

local function tick(now, linked, visible)
  if s.sys and s.state ~= 'prompt' and s.state ~= 'connect' and s.state ~= 'error'
    and not linked then
    local message = s.state == 'saving' and 'Save unconfirmed' or 'Link lost'
    clearGroup()
    for i = #s.categoryRows, 1, -1 do s.categoryRows[i] = nil end
    s.database, s.categoryTotal, s.sys, s.comp = nil, nil, nil, nil
    failure(message)
    return
  end
  if not visible then
    if s.state == 'connect' or s.state == 'identity' or s.state == 'database'
      or s.state == 'categoryLoading'
      or s.state == 'groupLoading' then cancel() end
    return
  end
  if s.state == 'database' then
    local ok, result = pcall(moduleLoader, s.dbkey)
    if not ok or type(result) ~= 'table' or result[1] ~= s.dbVersion
      or result[2] ~= s.vehicleName or type(result[3]) ~= 'string'
      or type(result[4]) ~= 'number'
      or result[4] < 1 then
      failure('Database unavailable')
    else
      s.database, s.categoryTotal, s.categoryIndexOffset = result, result[4], 0
      s.folderName = nil
      database(2, 1, false)
    end
    return
  elseif s.state == 'categoryLoading' then
    database(6)
    return
  elseif s.state == 'groupLoading' then
    database(5)
    return
  end
  if s.sys and s.state ~= 'prompt' and s.state ~= 'error'
    and (not s.pending or s.pending.kind ~= 'connect')
    and (not s.lastPing or now < s.lastPing or now - s.lastPing >= 300) then
    crossfireTelemetryPush(0xAA, wire.ping())
    s.lastPing = now
    return
  end
  if not s.pending then return end
  if s.pending.at and now >= s.pending.at and now - s.pending.at < 120 then return end
  if s.nextAt and now >= s.nextAt - 10 and now < s.nextAt then return end
  if s.pending.tries >= 4 then
    local kind = s.pending.kind
    failure(kind == 'connect' and 'No parameter bridge'
      or kind == 'version' and 'No firmware identity'
      or s.state == 'saving' and 'Save unconfirmed' or 'Parameter unavailable')
    return
  end
  local kind = s.pending.kind
  if kind == 'write' and not ready(now) then failure('Disarm / check link') return end
  local frame = kind == 'connect' and wire.ping()
    or kind == 'version' and wire.versionRequest(s.sys, s.comp)
    or kind == 'write' and wire.write(s.sys, s.comp, s.current, s.edited)
    or wire.readName(s.sys, s.comp, s.pending.name)
  local accepted = crossfireTelemetryPush(0xAA, frame)
  s.pending.at, s.pending.tries, s.pending.sent = now, s.pending.tries + 1, accepted == true
  if accepted then s.nextAt = now + 10 else s.pending.at = now end
  if accepted and kind == 'write' then
    -- PARAM_SET is transmitted once; a missing reply has an unknown outcome.
    s.sentValue = s.edited
    request('verify', s.current.name)
    s.nextAt = now + 10
  end
end

local function input(action, now) return controls.input(action, now) end
local function leave()
  local result = controls.leave()
  return result
end
local function draw(text, right, width, height, step) view(s, text, right, width, height, step) end
local function editing() return s.state == 'edit' end
local function loading() return s.state == 'identity' end

-- Load one small chunk per foreground callback, after the previous loader returns.
local function init(load)
  moduleLoader = load
  if not wire then wire = load('wire')
  elseif not view then view = load('pview')
  elseif not database then database = load('pdb')(s, failure, clearGroup)
  elseif not controls then
    controls = load('pinput')(s, {begin=begin, cancel=cancel, failure=failure,
      request=request, ready=ready, clearGroup=clearGroup, database=database})
  end
  return controls ~= nil
end

return {init=init, receive=receive, tick=tick, input=input, draw=draw,
  leave=leave, editing=editing, loading=loading}
