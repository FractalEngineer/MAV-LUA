-- SPDX-License-Identifier: GPL-3.0-or-later
-- TNS|MAV Heap|TNE
--
-- Measure what this radio's Lua heap can actually do, so a memory design is chosen from
-- radio evidence instead of from host numbers.
--
-- WHY THIS EXISTS
-- A vehicle-discovered parameter index kept failing on hardware with
-- "not enough memory for buffer allocation" from around 700 names, while the host harness
-- reported it fitting comfortably. That harness runs under a capped allocator, and forcing
-- collection at a tight cap hides accumulated garbage, so its figures never predicted the
-- radio. One failed attempt looked like progress for many iterations because of that.
-- Nothing had ever measured the radio heap directly. This does.
--
-- IT MEASURES THREE CONFIGURATIONS, NOT ONE
-- A first version filled the heap with every module resident, which is the worst case and
-- answered the wrong question: it reported only a few KiB free and a 2-6 KiB largest block,
-- without ever measuring the configuration a build actually runs in. The build needs `wire`
-- and `index` only, roughly 23 KiB, not the browser and the telemetry core on top. The
-- difference between those configurations is the entire decision, so each is measured in a
-- clean state, cheapest first:
--
--   bare   nothing loaded          - the tool's total budget
--   build  wire + index            - what the index build has to work with
--   full   every radio-side module - what the browser carries, and whether the app can even
--                                    be loaded inside a tool's own state
--
-- WHAT EACH RESULT LINE REPORTS, appended to /MAVHEAP.TXT as it is measured:
--   * the resident cost of every module, and the running total
--   * how many 1 KiB blocks can be held at once, i.e. memory obtainable at that point
--   * the largest single contiguous allocation that succeeds
--
-- The last number matters most. `luaL_Buffer`, `string.rep`, `string.gsub` expansion and
-- `io.read(n)` all need ONE contiguous allocation, and their failure is what the radio
-- reports as "not enough memory for buffer allocation", whereas plain `..` reports only
-- "not enough memory". A large obtainable total with a small largest block means a build must
-- avoid assembling strings at all, however careful it is about total bytes.
--
-- WHY EVERY RESULT IS WRITTEN IMMEDIATELY
-- This deliberately allocates until it fails, so it may stall the radio. A report drawn only
-- on screen would lose precisely the measurement that matters. Each line is flushed to the
-- card before the next step, so a lock-up still leaves the answer: power-cycle, read
-- MAVHEAP.TXT, and the last line says how far it got. It is safe to run more than once; each
-- run appends and a separator marks where the new run begins.
--
-- This is a diagnostic. It lives in tools/diag/ rather than src/ on purpose, because the
-- package build globs every .lua under src/ and a diagnostic must never ship to a user.

local OUT = '/MAVHEAP.TXT'
-- Size of one fill block, and how many are allocated per callback. Small blocks keep the
-- screen drawing between steps; a single huge request would only show a frozen UI.
local BLOCK = 1024
local FILL_PER_RUN = 16
-- Upper bound for the largest-block search, so this cannot exhaust a desktop interpreter,
-- where there is no radio ceiling to discover. On a radio the real limit is always reached
-- first. The fill cap bounds the fill phase for the same reason.
local MAX_PROBE = 65536
local MAX_FILL_BLOCKS = 4096

-- The configurations to measure. Each is measured from a clean state: the previous
-- configuration's modules are dropped and collected before the next begins, so the numbers
-- describe that configuration rather than everything accumulated so far.
local CONFIGS = {
  {name = 'bare', modules = {}},
  {name = 'build', modules = {
    '/SCRIPTS/MAV/wire.lua',
    '/SCRIPTS/MAV/index.lua',
  }},
  {name = 'full', modules = {
    '/SCRIPTS/MAV/wire.lua',
    '/SCRIPTS/MAV/pdb.lua',
    '/SCRIPTS/MAV/pview.lua',
    '/SCRIPTS/MAV/pinput.lua',
    '/SCRIPTS/MAV/params.lua',
    '/SCRIPTS/MAV/index.lua',
    '/SCRIPTS/TELEMETRY/MAV.lua',
  }},
}

local phase = 'idle'
local configAt = 1
local loaded, moduleAt = {}, 1
local moduleFailures = 0
local hold, blockCount = {}, 0
local lo, hi, best = 1, MAX_PROBE, 0
local totalBlocks, largestBlock = 0, 0
local detail, errorText = 'ENTER: measure heap', nil
local writeFailed = false

-- One line per result, opened and closed each time. A held-open handle would be cheaper, but
-- then a stall mid-run loses the buffered tail, which is the whole point of writing
-- immediately. Append mode means a re-run never destroys an earlier result.
local function append(text)
  local file = io.open(OUT, 'a')
  if not file then writeFailed = true return false end
  local ok = io.write(file, text .. '\n') and true or false
  io.close(file)
  if not ok then writeFailed = true end
  return ok
end

-- Lua's reported usage in KiB. collectgarbage('count') is in the base library, so it exists
-- on the radio, and the builder already calls collectgarbage('collect').
local function used()
  return collectgarbage('count')
end

-- Whether a compiled cache sits beside a source path. This matters because EdgeTX's 'bt' mode
-- prefers a cache, a cache is stripped of debug information while a source compile keeps it,
-- and the two differ by several KiB. Without recording the form, two runs of identical code
-- look like a radio inconsistency: the first compiles from source, firmware then writes a
-- cache, and every later run loads that. Measured on hardware, that alone accounted for a
-- 14.49 KiB baseline falling to 11.13 KiB, and for later errors reading "?:0" instead of a
-- line number.
local function loadForm(path)
  local base = string.sub(path, 1, -5)  -- drop '.lua'
  local cache = io.open(base .. '.luac', 'r')
  if cache then
    io.close(cache)
    return 'cache'
  end
  return 'source'
end

-- Screen text is convenience only. It is formatted through pcall because the fill phase calls
-- it while the heap is deliberately almost exhausted, and formatting allocates: a failure here
-- must cost a stale caption, never the measurement being taken.
local function show(format, ...)
  local ok, text = pcall(string.format, format, ...)
  if ok then detail = text end
end

local function startConfig(name)
  append('')
  append('=== configuration: ' .. name .. ' ===')
  collectgarbage('collect')
  append('  start: ' .. used() .. ' KiB used after a full collect')
end

local function finishConfig(name)
  append('  ' .. name .. ' RESULT: ' .. (totalBlocks * BLOCK / 1024)
    .. ' KiB obtainable, largest contiguous ' .. (largestBlock / 1024) .. ' KiB')
end

local function nextConfig()
  local config = CONFIGS[configAt]
  if config then finishConfig(config.name) end
  -- Drop everything the configuration held, so the next one is measured from a clean state
  -- rather than on top of the previous one's resident cost.
  loaded = {}
  hold = {}
  moduleAt, moduleFailures = 1, 0
  blockCount, totalBlocks = 0, 0
  lo, hi, best, largestBlock = 1, MAX_PROBE, 0, 0
  collectgarbage('collect')
  collectgarbage('collect')
  configAt = configAt + 1
  if not CONFIGS[configAt] then
    append('')
    append('all configurations measured')
    append('done')
    phase = 'done'
    return true
  end
  startConfig(CONFIGS[configAt].name)
  phase = 'load'
  return true
end

local function step()
  local config = CONFIGS[configAt]
  if not config then
    append('done')
    phase = 'done'
    return true
  end

  if phase == 'load' then
    local path = config.modules[moduleAt]
    if not path then
      collectgarbage('collect')
      -- The load count is part of the result, not decoration. A module that cannot load on
      -- this radio is a finding in itself, and it also makes the fill numbers below
      -- optimistic: an unloaded module leaves its share of the heap available to be filled.
      append('  loaded ' .. #loaded .. ' of ' .. #config.modules .. ' modules (' ..
        moduleFailures .. ' failed), ' .. used() .. ' KiB used')
      phase = 'fill'
      return true
    end
    collectgarbage('collect')
    local before = used()
    -- Retained deliberately: the delta is the RESIDENT cost of this configuration.
    local ok, err = pcall(function()
      local chunk = loadScript(path, 'bt')
      if not chunk then error('loadScript returned nil') end
      local module = chunk()
      if module == nil then error('chunk returned nil') end
      loaded[#loaded + 1] = module
    end)
    collectgarbage('collect')
    local delta = used() - before
    if not ok then moduleFailures = moduleFailures + 1 end
    append('  ' .. path .. ' (' .. loadForm(path) .. '): '
      .. (ok and 'ok' or ('FAILED: ' .. tostring(err)))
      .. ', ' .. delta .. ' KiB resident')
    show('%s %d/%d', config.name, moduleAt, #config.modules)
    moduleAt = moduleAt + 1
    return true
  end

  if phase == 'fill' then
    for _ = 1, FILL_PER_RUN do
      if blockCount >= MAX_FILL_BLOCKS then
        append('  fill: capped at ' .. blockCount .. ' blocks = '
          .. (blockCount * BLOCK / 1024) .. ' KiB')
        hold = {}
        collectgarbage('collect')
        totalBlocks = blockCount
        phase = 'largest'
        return true
      end
      -- Held, not discarded: this measures how much memory can actually be occupied at once,
      -- which is what a build needs. A failure here is a normal outcome, so it is caught
      -- rather than allowed to reach the firmware's panic handler.
      local ok = pcall(function()
        hold[blockCount + 1] = string.rep('\0', BLOCK)
      end)
      if not ok then
        -- Release before reporting. Formatting a message allocates, and at this point the
        -- heap is by definition full, so building the text first fails and loses the very
        -- measurement the run exists to produce. An earlier version did that and wrote
        -- "ERROR: not enough memory" instead of the number.
        hold = {}
        collectgarbage('collect')
        totalBlocks = blockCount
        append('  fill: stopped at ' .. blockCount .. ' blocks = '
          .. (blockCount * BLOCK / 1024) .. ' KiB obtainable')
        phase = 'largest'
        return true
      end
      blockCount = blockCount + 1
    end
    show('%s fill %d KiB', config.name, blockCount * BLOCK / 1024)
    return true
  end

  if phase == 'largest' then
    -- A binary search for the biggest single contiguous allocation. This is the number that
    -- decides whether any design may build a string, because `string.rep`, `string.gsub`
    -- expansion and `io.read(n)` each need one unbroken block. A large free total can still be
    -- too fragmented to satisfy them, so the total alone is not enough.
    if lo > hi then
      largestBlock = best
      append('  largest single allocation: ' .. best .. ' bytes ('
        .. (best / 1024) .. ' KiB)')
      return nextConfig()
    end
    local mid = math.floor((lo + hi) / 2)
    local ok = pcall(function()
      local block = string.rep('\0', mid)
      if #block ~= mid then error('short allocation') end
    end)
    collectgarbage('collect')
    if ok then best, lo = mid, mid + 1 else hi = mid - 1 end
    show('%s probe %d B', config.name, mid)
    return true
  end

  return false
end

local function draw()
  -- A tool draws over whatever was on screen, so clear first. Both branches are needed: a
  -- colour radio draws into a buffer that must be filled, a monochrome one is cleared to its
  -- own background. The test is the same one the telemetry core uses.
  if lcd.clear then lcd.clear() end
  local color = lcd.RGB ~= nil and CUSTOM_COLOR ~= nil
  if color then
    lcd.setColor(CUSTOM_COLOR, BLACK or 0)
    lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, CUSTOM_COLOR)
  end
  local row = color and math.max(20, math.ceil(LCD_H / 8)) or 9
  local hint = 'EXIT: leave'
  if phase == 'idle' then
    hint = 'ENTER: start'
    if writeFailed then detail = 'Cannot write ' .. OUT end
  elseif phase == 'done' then
    hint = 'Read MAVHEAP.TXT'
    if errorText then detail = errorText end
  else
    local config = CONFIGS[configAt]
    hint = config and ('measuring ' .. config.name) or 'finishing'
  end
  lcd.drawText(0, 0, 'MAV heap probe', INVERS or 0)
  lcd.drawText(0, row * 2, detail or '', 0)
  lcd.drawText(0, LCD_H - row, hint, 0)
end

local function init()
  if not (lcd and io and collectgarbage) then
    errorText = 'Not an EdgeTX Lua environment'
    phase = 'done'
    return
  end
  -- A separator, so several runs in one file stay distinguishable. getTime is not guaranteed
  -- formatting, so its raw value is recorded rather than dressed up.
  local stamp = getTime and getTime() or '?'
  append('--- MAV heap probe, t=' .. tostring(stamp)
    .. ' (probe loaded from ' .. loadForm('/SCRIPTS/TOOLS/MAVHEAP.lua') .. ') ---')
end

local function run(event)
  if phase == 'idle' then
    if event == EVT_VIRTUAL_ENTER or event == EVT_ENTER_BREAK then
      phase = 'start'
    elseif event == EVT_VIRTUAL_EXIT or event == EVT_EXIT_BREAK then
      return 1
    end
  end
  -- One unit of work per callback, so the screen keeps updating and a stall is visible. A
  -- memory error escaping this would reach the firmware's panic handler, so every step is
  -- protected and the outcome is written down before it is shown.
  if phase == 'start' then
    startConfig(CONFIGS[1].name)
    phase = 'load'
  elseif phase ~= 'idle' and phase ~= 'done' then
    local ok, err = pcall(step)
    if not ok then
      errorText = tostring(err)
      append('ERROR: ' .. errorText)
      phase = 'done'
    end
  end
  draw()
  return 0
end

-- Exposed so a host test can tell how far the run got and what it measured, without having to
-- parse the report it wrote.
local function status()
  return phase, configAt, largestBlock, errorText
end

return {init = init, run = run, status = status}
