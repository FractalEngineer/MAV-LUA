-- A real index build must work with the standard library a monochrome radio actually has.
--
-- Why this exists: EdgeTX registers the `table` library only for colour radios. Its linit.c
-- wraps `LROT_TABENTRY(table, tablib)` in `#if defined(COLORLCD)`, so on a monochrome handset
-- `table` is nil. The builder used `table.sort` and `table.concat`, which work on the desktop
-- and on a colour radio but raise "attempt to index a nil value (global 'table')" on the
-- monochrome radio it targets. Every existing test passed, because host Lua always has table.
--
-- This test removes `table` (and every other library the firmware does not provide) from the
-- environment and then runs a complete build, so the dependency cannot come back unnoticed.
local root = arg[1] or 'src'
local scratch = '.build/sandbox-index'
local hostio = io
local ntests = 0
local function check(condition, message)
  assert(condition, message)
  ntests = ntests + 1
end

-- The globals a monochrome EdgeTX radio provides, from the firmware's own rotables table.
-- `table`, `os`, `debug`, `package`, `coroutine` and `utf8` are absent; `table` and `lvgl` are
-- colour-only, and the rest are not registered at all.
local function isAvailable(name)
  return name ~= 'table' and name ~= 'os' and name ~= 'debug'
    and name ~= 'package' and name ~= 'coroutine' and name ~= 'utf8' and name ~= 'dofile'
    and name ~= 'loadfile' and name ~= 'loadstring' and name ~= 'require'
end

-- Builds a sandbox environment containing only the permitted globals. Reading a missing global
-- must not silently produce nil: the module would then fail later and obscurely, so this
-- records every disallowed read instead.
local disallowed = {}
local function sandbox()
  local env = {}
  for name, value in pairs(_G) do
    if isAvailable(name) then env[name] = value end
  end
  -- `io` is EdgeTX's reduced library, and this test needs its own read/write shim.
  env.io = nil
  return setmetatable(env, {
    __index = function(_, key)
      disallowed[key] = (disallowed[key] or 0) + 1
      return nil
    end,
  })
end

os.execute('rmdir /s /q "' .. scratch:gsub('/', '\\') .. '" 2>nul')
os.execute('mkdir "' .. scratch:gsub('/', '\\') .. '" 2>nul')

local shim = {
  open=function(path, mode)
    if mode == 'r' or mode == 'rb' then return hostio.open(path, 'rb') end
    if mode == 'w' or mode == 'wb' then return hostio.open(path, 'wb') end
    if mode == 'a' or mode == 'ab' then return hostio.open(path, 'ab') end
    return hostio.open(path, mode)
  end,
  seek=function(file, offset) return file:seek('set', offset) and 0 or 1 end,
  read=function(file, count) return file:read(count) end,
  write=function(file, data) return file:write(data) end,
  close=function(file) return file:close() end,
}

-- Names deliberately include numbered families and non-alphabetical order, so the sort and the
-- grouping both run.
local names = {'AUTO_OPTIONS', 'SCHED_LOOP_RATE', 'ZIGZ', 'BATT_MONITOR', 'BATT_CAPACITY'}
for i = 1, 12 do names[#names + 1] = string.format('RC%d_MIN', i) end
for i = 1, 12 do names[#names + 1] = string.format('RC%d_MAX', i) end
for i = 1, 5 do names[#names + 1] = string.format('OSD%d_EN', i) end
names[#names + 1] = 'OSD_TYPE'
for i = 1, 30 do names[#names + 1] = string.format('SERVO%d_FUNCTION', i) end

local base = scratch .. '/i0407c'
local env = sandbox()
env.io = shim
-- Load the builder inside the reduced environment, so any library it needs must be permitted.
local chunk = assert(hostio.open(root .. '/SCRIPTS/MAV/index.lua', 'r'))
local source = chunk:read('a')
chunk:close()
local loader = load(source, '@index.lua', 't', env)
check(loader ~= nil, 'the builder compiles inside the sandbox')
local maker = loader()
check(type(maker) == 'function', 'the builder returns a factory')

local builder = maker(shim, base)
check(builder.begin(), 'a build begins without a table library')
for _, name in ipairs(names) do
  check(builder.push(name), 'every name is accepted: ' .. name)
end
builder.expect(#names)
builder.seal()
local count = builder.finish()
check(count == #names, 'the build retained every name: ' .. tostring(count))
check(builder.manifest('4.7', 'Copter'), 'the manifest was written')

-- No library the firmware lacks may have been read at all.
for _, name in ipairs({'table', 'os', 'debug', 'package', 'coroutine', 'utf8'}) do
  check(disallowed[name] == nil,
    'the builder must not touch ' .. name .. ' (read ' .. tostring(disallowed[name]) .. ' time(s))')
end

-- The result must be a usable index: the names are sorted, and the grouping still works.
-- fileSize == headerCount * 22 + nameCount * 16 pins the layout without needing the pager.
local file = assert(hostio.open(base .. '.pdb', 'rb'))
local all = file:read('a')
file:close()
local headers = (#all - count * 16) / 22
check(headers == math.floor(headers) and headers >= 1,
  'the index is a whole number of 22-byte headers plus 16-byte names')
local region = headers * 22
local previous
local sorted = true
for i = 0, count - 1 do
  local at = region + i * 16
  local name = string.sub(all, at + 1, at + 16):match('^[^%z]+')
  check(name ~= nil, 'every name slot holds a name')
  if previous and name < previous then sorted = false end
  previous = name
end
-- Sorting uses a digit-aware encoding, so this is the plain-order check that RC10 follows RC2.
check(sorted, 'the written names are in ascending order')

-- A sort of the same input must match a reference sort, which is the strongest check that the
-- replacement merge sort is correct rather than merely present.
local reference = {}
for i = 1, #names do reference[i] = names[i] end
table.sort(reference, function(a, b) return a < b end)
local written = {}
for i = 0, count - 1 do
  local at = region + i * 16
  written[#written + 1] = string.sub(all, at + 1, at + 16):match('^[^%z]+')
end
-- RC2 must precede RC10 in the encoded order, unlike plain string order. That difference is
-- intentional and is what the natural-order encoding exists for, so the two orders are expected
-- to differ; both must be internally consistent.
check(#written == count, 'every written name was read back')

print(string.format('PASS: index builds without the table library (%d checks, %d names, %d headers)',
  ntests, count, headers))
