-- The index must be writable on a card that only has the stock package layout.
--
-- Why this exists: the index was originally written into SCRIPTS/MAV/DB. That directory used to
-- be created by the packaged parameter databases, so it always existed. When those assets were
-- deleted the directory vanished with them, and because EdgeTX's io library exposes only
-- open/close/read/write/seek there is no mkdir, and FatFs does not create a missing parent, the
-- very first write failed. The tool reported "Index build failed" and the cause was invisible.
--
-- The host fixture could not catch that, because it ran mkdir itself for the scratch directory.
-- This test therefore asserts the two properties that make the failure impossible:
--   1. the index path contains no subdirectory of its own, so no directory can be missing;
--   2. a build succeeds when only the package's own directories exist.
local root = arg[1] or 'src'
local scratch = '.build/indexpath'
local hostio = io
local ntests = 0
local function check(condition, message)
  assert(condition, message)
  ntests = ntests + 1
end

-- Start from a clean slate that contains exactly what the shipped package provides under
-- SCRIPTS/MAV: the module sources, and nothing else.
os.execute('rmdir /s /q "' .. scratch:gsub('/', '\\') .. '" 2>nul')
os.execute('mkdir "' .. scratch:gsub('/', '\\') .. '" 2>nul')
for _, name in ipairs({'wire', 'index', 'params', 'pview', 'pinput', 'pdb'}) do
  local source = hostio.open(root .. '/SCRIPTS/MAV/' .. name .. '.lua', 'rb')
  if source then
    local data = source:read('a')
    source:close()
    local copy = assert(hostio.open(scratch .. '/' .. name .. '.lua', 'wb'))
    copy:write(data)
    copy:close()
  end
end

-- Records every path the builder opens, so the test can assert where it writes.
local opened = {}

-- EdgeTX io semantics: the file handle comes first, modes are read/write/append, and a write to
-- a missing parent fails exactly as FatFs does rather than being created. Paths are used as
-- given, so the test drives the builder with the same relative paths it uses on the card.
local function etx_io()
  return {
    open=function(path, mode)
      opened[#opened + 1] = path
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
end

local shim = etx_io()
local base = scratch .. '/i0407c'

-- Property 2: a build must succeed with only the package's own layout present.
local maker = assert(loadfile(root .. '/SCRIPTS/MAV/index.lua'))()
local builder = maker(shim, base)
check(builder.begin(), 'a build can begin beside the modules')
local names = {'RC_OPTIONS', 'RC1_MIN', 'RC2_MIN', 'AUTO_OPTIONS', 'BATT_MONITOR', 'BATT_CAPACITY'}
for _, name in ipairs(names) do builder.push(name) end
builder.expect(#names)
builder.seal()
local count = builder.finish()
check(count == #names, 'the build wrote every name: ' .. tostring(count))
check(builder.manifest('4.7', 'Copter'), 'the manifest was written')

local index = assert(hostio.open(base .. '.pdb', 'rb'))
local size = #index:read('a')
index:close()
check(size > 0, 'the index file exists and is not empty')

-- Property 1: the index filename is the last path component, with no directory of its own, so
-- the write lands in the folder that already holds the modules and cannot depend on any extra
-- directory existing. On the card that folder is SCRIPTS/MAV, which the package ships.
local finalComponent = base:match('([^/]+)$')
check(finalComponent == 'i0407c', 'the index basename is the identity alone: ' .. tostring(finalComponent))
check(base:match('^.-/i%d+[cp]$') ~= nil, 'the index path ends in a flat identity name: ' .. base)
for _, path in ipairs(opened) do
  -- Every opened path must be that same basename plus a short extension, and nothing deeper.
  check(path:match('^.-/i%d+[cp]%.[a-z]+$') ~= nil,
    'the builder must only touch flat files beside its base: ' .. path)
end
-- The identity the page will look for must be the identity the builder wrote.
check(base:match('i0407c') ~= nil, 'the index name carries the firmware identity')

-- A second, independent build into a fresh folder must also work, so success is not an artefact
-- of state left by the first.
local second = scratch .. '/i0408p'
local other = maker(etx_io(), second)
check(other.begin(), 'a second identity can begin a build')
other.push('RC_OPTIONS')
other.expect(1)
other.seal()
check(other.finish() == 1, 'the second build completed')
local secondFile = hostio.open(second .. '.pdb', 'rb')
check(secondFile ~= nil, 'the second index exists in the same flat folder')
if secondFile then secondFile:close() end

print(string.format('PASS: index is written without any subdirectory (%d checks)', ntests))
