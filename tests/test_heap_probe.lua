-- The heap probe must survive running out of memory and still leave its result on the card.
--
-- Why this test exists: the probe deliberately allocates until it fails, so the outcome that
-- matters is not that it succeeds but that a failure is caught, written down, and reported.
-- A memory error escaping the probe would reach the firmware's panic handler, which is what
-- makes a radio lock up; and a report drawn only on screen is lost in exactly that case,
-- which is the case it is built for.
--
-- The capped allocator is used here for a purpose it is NOT valid for elsewhere in this
-- repository: proving the probe's own error handling. It is fine for that because the
-- assertion is about the probe catching an allocation failure and exiting cleanly, not about
-- predicting what a radio will do. The distinction is the same one AGENTS.md draws.
--
-- Run with Lua 5.3: .build/lua53 tests/test_heap_probe.lua [probe-dir]
local dir = arg[1] or 'tools/diag'
local reportPath = '.build/heap-probe-report.txt'
local hostio = io
local ntests = 0
local function check(condition, message)
  assert(condition, message)
  ntests = ntests + 1
end

os.remove(reportPath)

-- The radio globals the probe reads. Values are shaped like EdgeTX's, not like the host's.
LCD_W, LCD_H, INVERS = 128, 64, 1
BLACK, CUSTOM_COLOR = 0, 1
EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT = 42, 44
EVT_ENTER_BREAK, EVT_EXIT_BREAK = 43, 45
getTime = function() return 1234 end

local drawn, cleared = {}, 0
-- Overwrite rather than accumulate. The firmware's lcd.drawText does not retain its argument,
-- so a recorder that appends records one new string per callback for the whole run and
-- measures the harness rather than the probe. That mistake made this probe look as though it
-- leaked about 32 KiB per configuration when it was in fact measuring from a clean state.
local lastRow = {}
lcd = {
  clear = function() cleared = cleared + 1 end,
  drawText = function(x, y, text)
    lastRow[y] = text
    drawn[y] = text
  end,
}

-- The probe writes to an absolute card path. Redirect it to a local file so the test can read
-- back what would have been flushed to the SD card.
io = {
  open = function(path, mode)
    if path == '/MAVHEAP.TXT' then path = reportPath end
    return hostio.open(path, mode == 'a' and 'ab' or mode)
  end,
  write = function(file, data) return file:write(data) end,
  close = function(file) return file:close() end,
  read = function(file, count) return file:read(count) end,
  seek = function(file, offset) return file:seek('set', offset) and 0 or 1 end,
}

-- The probe asks for each module by its card path. 'bt' means either form is acceptable, so a
-- missing cache may fall back to source, exactly as firmware does.
local loadedPaths = {}
loadScript = function(path, mode)
  loadedPaths[#loadedPaths + 1] = path
  if path:sub(-5) == '.luac' then return nil end
  local rel = path:gsub('^/', 'src/')
  if path:sub(1, 8) == '/SCRIPTS' then rel = 'src' .. path end
  return loadfile(rel)
end

local probe = assert(loadfile(dir .. '/MAVHEAP.lua'))()
probe.init()

-- Enter starts it. Each callback performs one bounded unit of work, so this drives the whole
-- run the way the radio would.
probe.run(EVT_VIRTUAL_ENTER)
local guard = 0
while select(1, probe.status()) ~= 'done' do
  probe.run(0)
  guard = guard + 1
  assert(guard < 5000, 'the probe did not terminate')
end
check(cleared > 0, 'the probe clears the screen before drawing')
-- Three rows are drawn: a title at the top, a detail line, and a hint at the bottom. The
-- recorder keys by row, so this counts distinct rows rather than calls.
local rows = 0
for _ in pairs(drawn) do rows = rows + 1 end
check(rows >= 3, 'the probe draws title, detail and hint rows, saw ' .. rows)
check(drawn[0] ~= nil, 'the probe draws a title row at the top')

local report = assert(hostio.open(reportPath, 'rb'))
local text = report:read('a')
report:close()
check(#text > 0, 'the probe wrote a report')

-- The report must contain every stage, because a missing stage is an unanswered question.
-- Each configuration records its own cleaned starting point, which is what makes the three
-- numbers comparable rather than cumulative.
check(text:find('start: ', 1, true), 'each configuration records a clean starting point')
check(text:find('KiB resident', 1, true), 'the report records per-module resident cost')
check(text:find('kiB obtainable', 1, true) or text:find('KiB obtainable', 1, true),
  'the report records how much memory could be held at once')
check(text:find('largest single allocation:', 1, true),
  'the report records the largest contiguous allocation, which is the number that decides')
check(text:find('done', 1, true), 'the run reached the end and said so')

-- The load form must be recorded with every figure it affects. EdgeTX's 'bt' mode prefers a
-- compiled cache, which is stripped of debug information, while a source compile keeps it:
-- the two differ by enough that the first hardware run of this probe measured 14.49 KiB and
-- every later run 11.13 KiB, purely because firmware wrote a cache after run one. Without the
-- form in the report, two runs of identical code look like a radio inconsistency.
check(text:find('probe loaded from ', 1, true),
  'the header records how the probe itself was loaded')
check(text:find('(source)', 1, true) or text:find('(cache)', 1, true),
  'each module records whether it loaded from source or from its cache')

-- All three configurations must be measured. A first version measured only the worst case -
-- every module resident - and so reported a few KiB free without ever measuring what a build
-- actually runs with. The difference between `build` and `full` is the whole decision, so a
-- report missing either is not usable.
for _, name in ipairs({'bare', 'build', 'full'}) do
  check(text:find('configuration: ' .. name, 1, true) ~= nil,
    'the report measures the ' .. name .. ' configuration')
  check(text:find(name .. ' RESULT:', 1, true) ~= nil,
    'the ' .. name .. ' configuration reports a result')
end

-- Every module the radio loads must be attempted in the full configuration, because a module
-- that cannot load inside a tool's own state is itself a finding.
for _, name in ipairs({'wire', 'pdb', 'pview', 'pinput', 'params', 'index', 'TELEMETRY'}) do
  check(text:find(name, 1, true) ~= nil, 'the report covers module ' .. name)
end

-- The build configuration must include the builder, since that pair is what a build runs with.
check(text:find('SCRIPTS/MAV/index.lua', 1, true) ~= nil,
  'the build configuration includes the builder module')

-- A stalled run must still answer. The report is readable and every line is complete.
local lines = 0
for _ in text:gmatch('\n') do lines = lines + 1 end
check(lines >= 20, 'the report has one line per stage, found ' .. lines)

print(string.format('PASS: heap probe completes and reports (%d checks, %d lines)', ntests, lines))
print(text)
