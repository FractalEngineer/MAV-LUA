-- Category browsing is local; selected-name traffic retains bounded retries.
local root = arg[1] or 'src'
local saved = arg
arg = {root, 'fixture'}
local fixture = dofile('tests/test_params.lua')
arg = saved

local function waitFor(f, text, limit)
  for _ = 1, limit or 1000 do
    if f.draw():find(text, 1, true) then return end
    f.tick()
  end
  error('timeout waiting for ' .. text .. ':\n' .. f.draw())
end

local f = fixture()
f.interval = 2
f.action('enter')
waitFor(f, 'parameter names')
local identityTraffic = f.sent
for _ = 1, 79 do f.action('next') f.tick() end
f.action('enter') waitFor(f, 'OSD groups')
f.action('next') -- OSD1, 201 local names.
f.open()
local maximum = 0
for _ = 1, 200 do
  local instructions = 0
  debug.sethook(function() instructions = instructions + 100 end, '', 100)
  f.action('next')
  f.tick()
  debug.sethook()
  maximum = math.max(maximum, instructions)
end
assert(f.draw():find('201/201', 1, true), f.draw())
assert(#f.reads == 0, 'scrolling 200 OSD1 names must not request an autopilot parameter')
assert(maximum < 10000, 'local page crossing exceeds callback budget: ' .. maximum)

-- Queue backpressure consumes a bounded attempt and then recovers without
-- changing the selected exact name.
f = fixture()
f.load() f.open()
f.busy = true
f.action('enter')
for _ = 1, 26 do f.tick() end
assert(#f.reads == 0, 'rejected submissions cannot authorize replies')
f.busy = false
waitFor(f, 'Step:')
assert(#f.reads == 1 and f.reads[1] == 'AUTO_OPTIONS', 'retry keeps exact selected name')

-- Accepted reads stop after four missing replies and stay read-only.
f = fixture()
f.load() f.open()
f.drop = true
local before = f.sent
f.action('enter')
waitFor(f, 'Parameter unavailable', 700)
assert(#f.reads == 4 and f.sent - before >= 4 and f.sets == 0,
  'missing exact read has four bounded attempts and no SET')

print(string.format('PASS: 200-name OSD1 local browse, max ~%d instructions; exact-read retry/backpressure', maximum))
