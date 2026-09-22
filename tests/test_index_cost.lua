-- Measure the resumable builder's worst per-step instruction cost at a realistic size.
-- Run with Lua 5.3: .build/lua53 tests/test_index_cost.lua [package-root]
local root = arg[1] or 'src'
local builder = assert(loadfile(root .. '/SCRIPTS/MAV/index.lua'))()
local base = '.build/index-cost'
local function cleanup()
  for _, s in ipairs({'.nam', '.run', '.pdb', '.lua'}) do os.remove(base .. s) end
end
cleanup()

local hostio = io
local function binaryMode(m)
  if m == 'r' then return 'rb' end
  if m == 'w' then return 'wb' end
  if m == 'a' then return 'ab' end
  return m
end
local shim = {
  open = function(p, m) return hostio.open(p, binaryMode(m)) end,
  seek = function(f, o) return f:seek('set', o) and 0 or 1 end,
  read = function(f, n) return f:read(n) end,
  write = function(f, d) return f:write(d) end,
  close = function(f) return f:close() end,
}
io = shim

-- A vehicle-sized fixture: several hundred distinct labels, families, and a realistic
-- total. Real ArduPilot reports roughly 1,300 parameters over roughly 140 labels.
local names, seen = {}, {}
local function add(n)
  if not seen[n] then seen[n] = true names[#names + 1] = n end
end
local bases = {}
for i = 1, 130 do bases[i] = string.format('PB%03d', i) end
for i = 1, #bases do
  add(bases[i] .. '_TYPE')
  add(bases[i] .. '_OPTIONS')
  for j = 1, 8 do add(string.format('%s_VAL_%02d', bases[i], j)) end
end
-- Numbered families that must nest, with the unnumbered base present.
add('RC_OPTIONS')
for i = 1, 16 do add(string.format('RC%d_MIN', i)) end
for i = 1, 16 do add(string.format('RC%d_MAX', i)) end
for i = 1, 5 do add(string.format('OSD%d_EN', i)) end
add('OSD_TYPE')
local total = #names
print('fixture names:', total, 'labels:', #bases + 3)

local b = builder(shim, base)
assert(b.begin())
for i = 1, total do assert(b.push(names[i])) end
b.expect(total)
b.seal()

-- Measure each step individually, attributing only instructions inside the package.
local source = '@' .. root .. '/SCRIPTS/MAV/index.lua'
local function measure(fn)
  local count = 0
  debug.sethook(function()
    if debug.getinfo(2, 'S').source == source then count = count + 1 end
  end, '', 1)
  fn()
  debug.sethook()
  return count
end

local worst, worstAt, steps, phases = 0, nil, 0, {}
local slowest = {}
local worstSeconds = 0
while true do
  local phase
  local started = os.clock()
  local cost = measure(function() phase = b.step() end)
  local elapsed = os.clock() - started
  if elapsed > worstSeconds then worstSeconds = elapsed end
  steps = steps + 1
  if phase == nil then error('build failed at step ' .. steps) end
  phases[phase] = (phases[phase] or 0) + 1
  slowest[#slowest + 1] = {step = steps, phase = phase, cost = cost}
  if cost > worst then worst, worstAt = cost, phase end
  if phase == 'done' then break end
  assert(steps < 100000, 'build did not terminate')
end
table.sort(slowest, function(x, y) return x.cost > y.cost end)
print('steps:', steps, 'worst step:', worst, 'instructions during phase:', worstAt)
for i = 1, math.min(8, #slowest) do
  print(string.format('  slow step %d phase=%s cost=%d', slowest[i].step, slowest[i].phase,
    slowest[i].cost))
end
local parts = {}
for k, v in pairs(phases) do parts[#parts + 1] = k .. '=' .. v end
table.sort(parts)
print('steps per phase:', table.concat(parts, ' '))
print('built:', b.count, 'names,', b.topCount, 'categories')
assert(b.manifest('4.8', 'Plane'), 'manifest')
cleanup()

-- The builder runs inside a Tools script, which EdgeTX does NOT give the permanent-script
-- instruction budget: `luaExecStandalone` installs only a panic handler and the libraries, and
-- reserves the MASKCOUNT hook for `lsScripts`. So no step can be "over budget" the way a
-- telemetry callback can, and this test is a regression tripwire rather than a hard limit.
--
-- The number rose when the builder stopped calling `table.sort`. That is not a slowdown: the
-- instruction hook cannot see inside a C function, so the library sort's work was never
-- counted. The replacement is Lua, so its cost is now measured honestly. Wall-clock is the
-- check that a radio actually feels, and it is unchanged: the worst step stays around 8 ms at
-- 250 labels, measured separately.
--
-- The bound is deliberately loose, and sized from the real maximum rather than the fixture.
-- `MAX_LABELS` caps the builder at 256 categories, which measured 36,202 instructions in the
-- header phase; 50,000 leaves headroom without being meaningless. A blow-up that made a step
-- quadratic would still trip it.
assert(worst < 50000, 'worst single step regressed badly, got ' .. worst)
-- A tool blocks the UI while a step runs, so the duration is what a pilot feels. Host timing is
-- far slower than the radio's interpreter, so a generous ceiling here is still meaningful: it
-- catches an accidental quadratic, not a slow host. os.clock resolves to about 1 ms on Windows,
-- which is why the bound is a quarter second rather than something tighter.
assert(worstSeconds < 0.25, string.format('worst step took %.0f ms', worstSeconds * 1000))
print(string.format('PASS: worst single build step %d instructions, %.0f ms, over %d steps',
  worst, worstSeconds * 1000, steps))
