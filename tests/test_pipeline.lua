-- SPDX-License-Identifier: GPL-3.0-or-later
-- Local paging cost and bounded exact-read retries.
--
-- The index is built from the vehicle, so this test builds one large group from a synthetic
-- parameter stream, then proves paging it locally costs no vehicle traffic and stays inside
-- the permanent-script callback budget.
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

-- One 201-name group, plus a small category so the first page is not the large group.
local stream = {'AUTO_OPTIONS', 'ZIGZ'}
for i = 1, 201 do stream[#stream + 1] = string.format('BIGP_%03d', i) end

-- Opens a named top-level category, however many pages of categories precede it.
local function openCategory(f, name)
  local guard = 0
  while not f.draw():find('@' .. name, 1, true) do
    f.action('next')
    f.tick()
    guard = guard + 1
    assert(guard < 60, 'category ' .. name .. ' not reachable')
  end
  f.open()
end

local f = fixture({stream = stream})
f.interval = 2
f.load()
openCategory(f, 'BIGP')
-- Page the whole group locally, measuring every callback. Exactly 200 presses lands on the
-- final row: the list wraps, so a longer loop would cycle back to the start.
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
assert(#f.reads == 0, 'scrolling 201 names must not request an autopilot parameter')
assert(maximum < 10000, 'local page crossing exceeds callback budget: ' .. maximum)

-- Queue backpressure consumes a bounded attempt and then recovers without changing the
-- selected exact name.
f = fixture()
f.load()
openCategory(f, 'AUTO')
f.busy = true
f.action('enter')
for _ = 1, 26 do f.tick() end
assert(#f.reads == 0, 'rejected submissions cannot authorize replies')
f.busy = false
waitFor(f, 'Step:')
assert(#f.reads == 1 and f.reads[1] == 'AUTO_OPTIONS', 'retry keeps exact selected name')

-- Accepted reads stop after four missing replies and stay read-only.
f = fixture()
f.load()
openCategory(f, 'AUTO')
f.drop = true
local before = f.sent
f.action('enter')
waitFor(f, 'Parameter unavailable', 700)
assert(#f.reads == 4 and f.sent - before >= 4 and f.sets == 0,
  'missing exact read has four bounded attempts and no SET')

print(string.format('PASS: 201-name group browse, max ~%d instructions; exact-read retry/backpressure', maximum))
