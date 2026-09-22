-- SPDX-License-Identifier: GPL-3.0-or-later
-- TNS|MAV Index|TNE
--
-- Standalone builder for the vehicle-discovered parameter index.
--
-- WHY THIS IS A TOOLS SCRIPT AND NOT PART OF THE PARAMETERS PAGE
-- On a radio the whole telemetry application shares one Lua heap. Measured against the
-- allocator cap, building the index from inside the Parameters page needed about 128 KiB,
-- because the browser modules (params, pview, pinput, pdb) are already resident and the builder
-- is the largest module on top of them. This tool needs about 80 KiB at worst: it runs in its
-- own Lua state with the permanent scripts paused, and it never loads the browser. A tool is
-- also not subject to the permanent-script instruction budget, so the build does not have to be
-- spread across callbacks; that budget is the only reason the builder is stepwise.
--
-- The index written here is exactly the one the Parameters page browses, including the
-- identity-derived filename, so a firmware change still resolves to "no index yet".
--
-- ENTER starts. EXIT aborts a running build, or leaves once it has finished.
local FOLDER = '/SCRIPTS/MAV/'
local PING_MS = 100          -- 10 ms ticks between bridge wake-ups while searching
local IDENTITY_MS = 50       -- identity is cheap but can be missed on a busy link
local TIMEOUT_MS = 2000      -- ticks before giving up on the vehicle answering

local wire, maker, session, errorText
local sys, comp, vehicle, versionText
local lastPing, identityAt, startedAt

local state = {phase = 'loading', built = 0}

-- The index filename carries the identity it describes, so a firmware change simply means no
-- index exists yet. It sits directly in SCRIPTS/MAV rather than a subfolder, because EdgeTX's
-- io library exposes only open/close/read/write/seek: there is no mkdir, and FatFs does not
-- create a missing parent, so a subfolder would fail on any card that lacks it. This mirrors
-- params.lua exactly; the two must not drift.
local function indexKey(v, major, minor)
  local code, label
  if v == 1 or v >= 19 and v <= 25 then code, label = 'p', 'Plane'
  elseif v == 2 or v == 3 or v == 4 or v == 13 or v == 14 or v == 15 or v == 29 then
    code, label = 'c', 'Copter'
  end
  if not code then return nil, 'Unsupported vehicle' end
  if major < 1 or major > 99 or minor < 0 or minor > 99 then
    return nil, 'Unsupported firmware'
  end
  return string.format('i%02d%02d%s', major, minor, code), label
end

-- Loads a module from its shipped cache when present, otherwise compiles it once. The source
-- prototype is discarded before the cache is read back: a source-compiled chunk keeps full
-- debug information, so calling it directly would hold more memory for the whole session.
local function loadModule(name)
  local base = FOLDER .. name
  local chunk = loadScript(base .. '.luac', 'b')
  if not chunk then
    local source = assert(loadScript(base .. '.lua', 'tc'))
    source = nil
    if collectgarbage then collectgarbage('collect') end
    chunk = loadScript(base .. '.luac', 'b')
    if not chunk then chunk = assert(loadScript(base .. '.lua', 'tx')) end
  end
  local module = chunk()
  return module
end

local function fail(message)
  if session then session = nil end
  state.phase, errorText = 'failed', message
end

local function onHeartbeat(payload, source, component)
  if source == 0 or component ~= 1 or string.byte(payload, 6) ~= 3 then return end
  if state.phase ~= 'searching' then return end
  sys, comp, vehicle = source, component, string.byte(payload, 5)
  state.phase, identityAt = 'identity', getTime()
  crossfireTelemetryPush(0xAA, wire.versionRequest(sys, comp))
end

local function onVersion(now, payload)
  local major, minor, patch = wire.version(payload)
  local key, label = indexKey(vehicle, major, minor)
  if not key then fail(label) return end
  versionText = label .. ' ' .. major .. '.' .. minor .. '.' .. patch
  -- The builder writes where the page will look, so the two cannot disagree. The session owns
  -- the list request, its keep-alive ping, the idle seal and its own outcome.
  local builder = maker(io, FOLDER .. key)
  session = builder.session(wire, sys, comp, major .. '.' .. minor, label)
  if session.start(now) then state.phase = 'building' else fail(session.error) end
end

local function dispatch(frame, now)
  local id, payload, source, component = wire.decode(frame)
  if not id then return end
  if state.phase == 'searching' then
    if id == 0 then onHeartbeat(payload, source, component) end
    return
  end
  if source ~= sys or component ~= comp then return end
  if state.phase == 'identity' then
    if id == 148 then onVersion(now, payload) end
    return
  end
  -- Streamed values answer no individual reservation, so they are handled before anything else
  -- and only from the target the heartbeat locked. The bridge guarantees that while its bounded
  -- list session is open.
  if state.phase == 'building' and id == 22 then
    local streamed = wire.parameter(payload)
    if streamed then session.stream(streamed.name, streamed.count, now) end
  end
end

local function init()
  local ok, result = pcall(function()
    wire = loadModule('wire')
    maker = loadModule('index')
  end)
  if not ok or type(wire) ~= 'table' or type(maker) ~= 'function' then
    errorText = tostring(result or 'MAV modules unavailable')
    state.phase = 'failed'
    return
  end
  -- Wake the bridge. A zero-broadcast ping also creates the bridge's local subscription.
  crossfireTelemetryPush(0xAA, wire.ping())
  lastPing, startedAt = getTime(), getTime()
  state.phase = 'searching'
end

local function advance(now)
  if state.phase == 'searching' then
    if now - lastPing >= PING_MS then
      crossfireTelemetryPush(0xAA, wire.ping())
      lastPing = now
      -- Without a bridge there is nothing to talk to, so do not search forever.
      if now - startedAt >= TIMEOUT_MS then fail('No parameter bridge') end
    end
    return
  end
  if state.phase == 'identity' then
    if now - identityAt >= IDENTITY_MS then
      crossfireTelemetryPush(0xAA, wire.versionRequest(sys, comp))
      identityAt = now
      if now - startedAt >= TIMEOUT_MS then fail('No firmware identity') end
    end
    return
  end
  if state.phase ~= 'building' then return end
  session.tick(now)
  state.built = session.built
  if session.state == 'done' then
    state.phase = 'done'
  elseif session.state == 'failed' then
    fail(session.error or 'Index build failed')
  end
end

local function draw()
  local title, detail, hint = 'MAV index', 'Searching for vehicle...', 'EXIT: close'
  if state.phase == 'loading' then
    detail = 'Loading modules...'
  elseif state.phase == 'identity' then
    detail = 'Reading firmware identity...'
  elseif state.phase == 'building' then
    title = 'Building index'
    detail = state.built .. ' names found'
    hint = 'EXIT: abort'
  elseif state.phase == 'done' then
    title, detail = 'Index built', versionText or 'Parameter index written'
    hint = 'Return to Parameters'
  elseif state.phase == 'failed' then
    title, detail = 'Build failed', errorText or 'Unknown error'
    hint = 'ENTER: retry'
  end
  -- A Tools script draws over whatever was on screen, so without clearing first the previous
  -- menu stays visible underneath this text. Both branches are needed: a colour radio draws
  -- into an LCD buffer that must be filled, while a monochrome one is cleared to its own
  -- background. The test is the same one the telemetry core uses to detect colour.
  if lcd.clear then lcd.clear() end
  local color = lcd.RGB ~= nil and CUSTOM_COLOR ~= nil
  if color then
    lcd.setColor(CUSTOM_COLOR, BLACK or 0)
    lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, CUSTOM_COLOR)
  end
  -- One text row per step, so the three lines sit at the top, middle and bottom of any screen.
  local step = color and math.max(20, math.ceil(LCD_H / 8)) or 9
  local row = lcd.drawText
  row(0, 0, title, INVERS or 0)
  row(0, step * 2, detail, 0)
  row(0, LCD_H - step, hint, 0)
end

local function retry()
  errorText, session = nil, nil
  sys, comp, vehicle, versionText = nil, nil, nil, nil
  startedAt, lastPing = getTime(), getTime()
  crossfireTelemetryPush(0xAA, wire.ping())
  state.phase, state.built = 'searching', 0
end

local function run(event)
  local now = getTime()
  if event == EVT_VIRTUAL_ENTER or event == EVT_ENTER_BREAK then
    if state.phase == 'failed' then retry() end
  elseif event == EVT_VIRTUAL_EXIT or event == EVT_EXIT_BREAK then
    if state.phase == 'building' then
      -- Aborting drops the session. A part-built index can never be mistaken for a complete
      -- one, because the manifest is only written by a finished build.
      session = nil
      state.phase, errorText = 'failed', 'Aborted'
      return 0
    end
    return 1
  end
  if state.phase ~= 'failed' and state.phase ~= 'done' then advance(now) end
  -- The tool owns its own telemetry queue, so this is still a single consumer. The payload
  -- from crossfireTelemetryPop is already the raw envelope, marker and length included, so it
  -- is decoded directly rather than wrapped again.
  local command, value = crossfireTelemetryPop()
  if command == 0xAA and value then dispatch(value, now) end
  draw()
  return 0
end

-- Exposes the build outcome so a caller (or the host test) can tell whether the index was
-- written without having to read the screen. 'phase' is one of loading, searching, identity,
-- building, done or failed; 'error' carries the reason for a failure.
local function status()
  return state.phase, errorText, state.built
end

return {init = init, run = run, status = status}
