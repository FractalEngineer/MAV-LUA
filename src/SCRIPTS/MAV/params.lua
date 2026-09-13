-- SPDX-License-Identifier: GPL-3.0-or-later
-- Lazy, opt-in ArduPilot parameter browser. Keeps only one live page in RAM.
local wire, fetch, view, moduleLoader
local controls
local s = {state='prompt', total=0, rows={}, selected=1, pageStart=0,
  steps={0.000001, 0.00001, 0.0001, 0.001, 0.01, 0.1, 1, 10, 100, 1000, 10000, 100000, 1000000}}
local function ready(now)
  return s.heartbeatAt and now >= s.heartbeatAt and now - s.heartbeatAt <= 300 and not s.armed
end
local function failure(message)
  if fetch then fetch.clear() end
  s.pending, s.state, s.errorText = nil, 'error', message
end
local function request(kind, index)
  s.pending = {kind=kind, index=index, tries=0}
end
local function loadPage(index, backwards, now)
  s.rows, s.selected, s.pageStart = {}, 1, index
  s.selectLast, s.state = backwards or nil, 'loading'
  s.loadStart, s.loadTime, s.nextAt = now, now, now
  fetch.reset(index, s.total, now)
end
local function begin(now)
  if not fetch then s.state, s.prepareAt = 'preparing', now return end
  s.total, s.sys, s.comp, s.heartbeatAt = 0, nil, nil, nil
  s.rows, s.selected, s.pageStart, s.nextAt = {}, 1, 0, now
  s.state = 'connect'
  request('connect')
end
local function cancel()
  if fetch then fetch.clear() end
  s.pending, s.state = nil, 'prompt'
end
local function receive(frame, now)
  if s.state == 'prompt' or s.state == 'preparing' or s.state == 'connect' and not s.pending then return end
  local id, payload, source, component = wire.decode(frame)
  if id == 0 then
    if s.state == 'connect' and (not s.pending or not s.pending.sent) then return end
    -- Autopilot component, ArduPilot encoding. Do not guess PX4's bytewise values.
    if source == 0 or component ~= 1 or string.byte(payload, 6) ~= 3 then return end
    if not s.sys and s.state == 'connect' then s.sys, s.comp = source, component end
    if s.sys ~= source or s.comp ~= component then return end
    s.heartbeatAt, s.armed = now, string.byte(payload, 7) >= 128
    if s.state == 'connect' then
      s.pending = nil
      loadPage(0, false, now)
    end
    return
  end
  if id == 22 and s.state == 'loading' and source == s.sys and component == s.comp then
    local p = wire.parameter(payload)
    local err = p and fetch.receive(p, now)
    if err then failure(err) end
    return
  end
  if id ~= 22 or source ~= s.sys or component ~= s.comp or not s.pending or not s.pending.sent
    or s.pending.kind == 'write' or s.pending.kind == 'connect' then return end
  local p = wire.parameter(payload)
  if not p or p.index ~= s.pending.index then return end
  if s.total > 0 and s.total ~= p.count then failure('List changed: reload') return end
  local kind = s.pending.kind
  if not s.current or s.current.name ~= p.name or s.current.kind ~= p.kind then
    failure('Parameter changed') return
  end
  s.pending = nil
  if kind == 'edit' then
    s.current, s.edited, s.stepIndex = p, p.value, 7
    if p.kind == 9 then
      local target = p.value == 0 and 0.1 or math.abs(p.value) * 0.1
      s.stepIndex = 1
      while s.stepIndex < #s.steps and s.steps[s.stepIndex + 1] <= target do s.stepIndex = s.stepIndex + 1 end
    end
    s.state = 'edit'
  elseif kind == 'check' then
    if p.value ~= s.current.value then failure('Value changed: reopen') return end
    if not ready(now) then failure('Disarm / check link') return end
    s.state = 'saving'
    request('write', p.index)
  elseif kind == 'verify' then
    if p.value ~= s.sentValue then failure('Readback differs') return end
    s.current = p
    if s.rows[s.selected] then s.rows[s.selected] = p end
    s.state = 'saved'
  end
end
local function tick(now, linked, visible)
  if (s.state == 'loading' or s.pending and s.pending.kind ~= 'connect') and not linked then
    failure(s.state == 'saving' and 'Save unconfirmed' or 'Link lost') return
  end
  if not visible then
    if s.state == 'preparing' then s.state = 'prompt'
    elseif s.state == 'connect' or s.state == 'loading' then
      cancel()
    end
    return
  end
  if s.state == 'preparing' then
    local ok, result = pcall(moduleLoader, 'fetch')
    if not ok then s.state, s.errorText = 'error', tostring(result)
    else fetch = result begin(now) end
    return
  end
  if s.sys and s.state ~= 'prompt' and s.state ~= 'error'
    and (not s.pending or s.pending.kind ~= 'connect')
    and (not s.lastPing or now < s.lastPing or now - s.lastPing >= 300) then
    crossfireTelemetryPush(0xAA, wire.ping())
    s.lastPing = now
    return
  end
  if s.state == 'loading' then
    s.loadTime = now
    local p, err = fetch.tick(now, s.sys, s.comp, wire, crossfireTelemetryPush)
    if err then failure(err) return end
    if p then
      if s.total > 0 and s.total ~= p.count then failure('List changed: reload') return end
      s.total = p.count
      s.rows[#s.rows + 1] = p
      if #s.rows == 8 or p.index + 1 >= s.total then
        fetch.clear()
        s.selected = s.selectLast and #s.rows or 1
        s.selectLast, s.state = nil, 'list'
      end
    end
    return
  end
  if s.pending then
    if s.pending.at and now >= s.pending.at and now - s.pending.at < 120 then return end
    if s.nextAt and now >= s.nextAt - 10 and now < s.nextAt then return end
    if s.pending.tries >= 4 then
      failure(s.pending.kind == 'connect' and 'No parameter bridge'
        or s.state == 'saving' and 'Save unconfirmed' or 'No reply') return
    end
    local kind = s.pending.kind
    if kind == 'write' and not ready(now) then failure('Disarm / check link') return end
    local frame = kind == 'connect' and wire.ping()
      or kind == 'write' and wire.write(s.sys, s.comp, s.current, s.edited)
      or wire.read(s.sys, s.comp, s.pending.index)
    local accepted = crossfireTelemetryPush(0xAA, frame)
    s.pending.at, s.pending.tries = now, s.pending.tries + 1
    s.pending.sent = accepted == true
    if accepted then s.nextAt = now + 10 end
    if accepted and kind == 'write' then
      -- Never retransmit PARAM_SET. A lost reply is an uncertain outcome.
      s.sentValue = s.edited
      request('verify', s.current.index)
      s.nextAt = now + 10
    elseif not accepted then s.pending.at = now end
    return
  end
end
local function page(index, backwards, now) loadPage(index, backwards, now) end
local function input(action, now) return controls.input(action, now) end
local function leave()
  local result = controls.leave()
  return result
end
local function draw(text, right, width, height, step) view(s, text, right, width, height, step) end
local function editing() return s.state == 'edit' end
local function loading() return s.state == 'loading' end
-- Load one small chunk per foreground callback, after the previous loader returns.
local function init(load)
  moduleLoader = load
  if not wire then wire = load('wire')
  elseif not view then view = load('pview')
  elseif not controls then
    controls = load('pinput')(s,
      {begin=begin, page=page, cancel=cancel, failure=failure, request=request, ready=ready})
  end
  return controls ~= nil
end
return {init=init, receive=receive, tick=tick, input=input, draw=draw, leave=leave, editing=editing, loading=loading}
