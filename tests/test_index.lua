-- Run with Lua 5.3: .build/lua53 tests/test_index.lua [package-root]
-- Builds the discovered parameter index from an ArduPilot-shaped stream, then browses
-- it with the real pdb.lua pager and checks that every name is reachable exactly once.
local root = arg[1] or 'src'
local ntests = 0
local function check(condition, message) assert(condition, message) ntests = ntests + 1 end

local builder = assert(loadfile(root .. '/SCRIPTS/MAV/index.lua'))()

-- The builder writes into `.build`, which the test toolchain already creates. Using a
-- unique prefix instead of a subdirectory avoids cmd.exe's forward-slash handling in
-- os.execute while io still gets the separator it expects.
local base = '.build/index-test-a48p'
local function cleanup()
  for _, suffix in ipairs({'.nam', '.run', '.pdb', '.lua'}) do os.remove(base .. suffix) end
end
cleanup()

-- EdgeTX's io library is not the host's: every call takes the file first, there is no
-- file-handle method table, and io.write is not the standard output writer. Shim the
-- host io to those exact semantics so the builder is exercised as it runs on radio.
-- Binary mode is essential: FatFs writes bytes verbatim, whereas the host would translate
-- 0x0A in a packed record header into CRLF and corrupt the file.
local hostio = io
local function binaryMode(mode)
  if mode == 'r' then return 'rb' end
  if mode == 'w' then return 'wb' end
  if mode == 'a' then return 'ab' end
  return mode
end
local shim = {
  open = function(path, mode) return hostio.open(path, binaryMode(mode)) end,
  seek = function(file, offset) return file:seek('set', offset) and 0 or 1 end,
  read = function(file, count) return file:read(count) end,
  write = function(file, data) return file:write(data) end,
  close = function(file) return file:close() end,
}
-- The pager calls io.open/io.seek/io.read/io.close as globals. Standard Lua has no io.seek
-- at all (it is an EdgeTX addition), so the module must run against the same shim.
io = shim
-- The builder only needs open/read/write/seek/close, matching EdgeTX exactly.
check(shim.open and shim.seek and shim.read and shim.write and shim.close,
  'shim exposes only the EdgeTX io surface')

-- ---------------------------------------------------------------- input stream
-- ArduPilot streams PARAM_REQUEST_LIST in index order, which is NOT alphabetical and
-- NOT grouped. Build a list with families, singletons, and deliberately awkward names.
local names, seen = {}, {}
local function add(name)
  assert(#name <= 16 and not seen[name], 'bad fixture name ' .. name)
  seen[name] = true
  names[#names + 1] = name
end
-- A large GENERAL block of one-off names, unsorted by prefix.
for i = 1, 40 do add(string.format('ARMING_CHECK_%02d', i)) end
for _, name in ipairs({'FORMAT_VERSION', 'SCHED_LOOP_RATE', 'BATT_MONITOR', 'BATT_CAPACITY',
    'INS_GYRO_FILTER', 'INS_ACCEL_FILTER', 'ATC_RAT_RLL_P', 'ATC_RAT_RLL_I',
    'ATC_RAT_PIT_P', 'ATC_RAT_YAW_P', 'MOT_THST_HOVER', 'WPNAV_SPEED', 'RTL_ALT'}) do
  add(name)
end
-- RC with a numbered family plus the unnumbered base, in index order 1,2,...,12.
add('RC_OPTIONS'); add('RC_PROTOCOLS'); add('RC_SPEED')
for i = 1, 12 do add(string.format('RC%d_MIN', i)) end
for i = 1, 12 do add(string.format('RC%d_MAX', i)) end
for i = 12, 1, -1 do add(string.format('RC%d_TRIM', i)) end
-- A family that must sort RC2 before RC10.
for i = 1, 10 do add(string.format('SERIAL%d_BAUD', i)) end
-- OSD1..OSD5, exercising the RC/RC1..RCn nesting used by the packaged layout.
add('OSD_TYPE')
for i = 1, 5 do add(string.format('OSD%d_EN', i)) end
-- A two-member family, and a one-member numbered label that must fall back to GENERAL.
for i = 1, 2 do add(string.format('CAM%d_TRIGG', i)) end
add('SR0_RATE')
-- Fill out to a realistic vehicle size with indexed sensor families.
for i = 1, 4 do
  for j = 1, 30 do add(string.format('BATT%d_VOLT_%02d', i, j)) end
end
local total = #names
check(total > 200, 'fixture is large enough to be realistic (' .. total .. ' names)')
-- The stream is in index order, so it is not already sorted.
local sorted = {}
for i = 1, total do sorted[i] = names[i] end
table.sort(sorted)
local isSorted = true
for i = 1, total do if sorted[i] ~= names[i] then isSorted = false break end end
check(not isSorted, 'fixture stream is deliberately unsorted like a real vehicle')

-- ---------------------------------------------------------------------- build
local built = builder(shim, base)
check(built.begin(), 'build begins')
local pushed = 0
for i = 1, total do
  if built.push(names[i]) then pushed = pushed + 1 end
end
check(pushed == total, 'every valid name is accepted')
-- The vehicle's reported count is authoritative, so the build only advances once the
-- expected number of names has arrived. Seal explicitly here; the app seals on the count.
built.expect(total)
built.seal()
-- A malformed name must be refused rather than corrupting the index.
check(not built.push('bad-name'), 'lowercase/hyphen name refused')
check(not built.push(''), 'empty name refused')
check(not built.push(string.rep('A', 17)), 'over-long name refused')
local count, topCount = built.finish()
check(count == total, 'index reports every parameter (' .. tostring(count) .. ')')
check(topCount and topCount > 1, 'index has several top-level categories')
check(built.complete, 'build marked complete')
check(built.manifest('4.8', 'Plane'), 'manifest written')

-- The stored file must be exactly headers plus one 16-byte record per name.
local pdb = assert(hostio.open(base .. '.pdb', 'rb'))
local size = pdb:seek('end')
pdb:close()
check(size >= total * 16, 'index is at least one record per name')

-- The manifest is the same four-field table the loader expects.
local manifest = assert(loadfile(base .. '.lua'))()
check(type(manifest) == 'table' and manifest[1] == '4.8' and manifest[2] == 'Plane'
  and manifest[3] == base .. '.pdb' and manifest[4] == topCount, 'manifest shape')

-- Determinism: a second identical build must produce identical bytes.
local firstFile = assert(hostio.open(base .. '.pdb', 'rb'))
local first = firstFile:read('a')
firstFile:close()
local rebuild = builder(shim, base)
check(rebuild.begin(), 'rebuild begins')
for i = 1, total do assert(rebuild.push(names[i])) end
rebuild.expect(total)
rebuild.seal()
check(rebuild.finish() == total, 'rebuild reports the same count')
local secondFile = assert(hostio.open(base .. '.pdb', 'rb'))
local second = secondFile:read('a')
secondFile:close()
check(first == second, 'rebuild is byte-identical')

-- The resumable build must support abort at any point and restart cleanly, because the
-- pilot can abandon a build and the partial files must never be mistaken for an index.
local aborted = builder(shim, base)
check(aborted.begin(), 'aborted build begins')
for i = 1, 40 do assert(aborted.push(names[i])) end
-- One step while the stream is incomplete must not advance past the names phase.
check(aborted.step() == 'names', 'build waits for the stream to finish')
check(aborted.abort(), 'abort succeeds mid-build')
check(aborted.phase == 'idle', 'abort returns the builder to idle')
-- A fresh build over the same base must still be correct.
local restarted = builder(shim, base)
check(restarted.begin(), 'restart after abort begins')
for i = 1, total do assert(restarted.push(names[i])) end
restarted.expect(total)
restarted.seal()
check(restarted.finish() == total, 'restart after abort rebuilds fully')
local thirdFile = assert(hostio.open(base .. '.pdb', 'rb'))
local third = thirdFile:read('a')
thirdFile:close()
check(third == first, 'restart after abort is byte-identical')

-- --------------------------------------------------------------------- browse
-- Drive the real pager exactly as params.lua does. pdb.lua returns a factory, so the
-- chunk must be called once with no arguments before it is given the state table.
local failureCalled
local function fail(message) failureCalled = message error('pager failure: ' .. message, 0) end
local s = {rows = {}, categoryRows = {}}
local pager = assert(loadfile(root .. '/SCRIPTS/MAV/pdb.lua'))()
local database = pager(s, fail, function()
  for i = #s.rows, 1, -1 do s.rows[i] = nil end
  s.group, s.groupName, s.groupTotal = nil, nil, nil
end)
check(type(database) == 'function', 'pager factory produced an operation function')

-- op 2 only stages the page start; op 6 performs the read. Both are required, which is
-- exactly the pair params.lua drives when its state machine is 'categoryLoading'.
local function loadCategoryPage(page)
  database(2, page, false)
  database(6)
end
local function openDatabase()
  s.database, s.categoryTotal, s.categoryIndexOffset = manifest, manifest[4], 0
  s.categoryPageStart, s.categorySelected, s.folderName = 1, 1, nil
  loadCategoryPage(1)
end
-- Reads every name page of the currently open group.
local browsed = {}
local function readGroup()
  local pageStart = 1
  while pageStart <= s.groupTotal do
    s.pageStart = pageStart
    database(5) -- op 5: read a name page
    for i = 1, #s.rows do browsed[#browsed + 1] = s.rows[i].name end
    pageStart = pageStart + 8
  end
end

-- Browsing must expose every stored name exactly once, through the real pager.
local function browseAll()
  openDatabase()
  check(s.categoryTotal == topCount, 'top-level count matches the manifest')
  for index = 1, s.categoryTotal do
    local page = math.floor((index - 1) / 8) * 8 + 1
    loadCategoryPage(page)
    s.categorySelected = index - page + 1
    local row = s.categoryRows[s.categorySelected]
    check(row ~= nil, 'top-level row exists at ' .. index)
    database(3) -- op 3: open the category, or enter the family folder
    if row.count < 0 then
      -- A family folder: its children are categories, laid out contiguously, so they are
      -- paged with the same op-2/op-6 pair using the folder's own index offset.
      check(s.folderName == row.name, 'folder entered: ' .. row.name)
      local children = s.categoryTotal
      check(children == -row.count, 'folder child count matches its record')
      for childPage = 1, children, 8 do
        loadCategoryPage(childPage)
        for k = 1, #s.categoryRows do
          s.categorySelected = k
          local childRow = s.categoryRows[k]
          check(childRow.count > 0, 'folder child is a category: ' .. tostring(childRow.name))
          database(3)
          check(s.group ~= nil, 'folder child opened a group: ' .. childRow.name)
          check(s.group.count == childRow.count, 'child group total matches its record')
          readGroup()
        end
      end
      openDatabase() -- return to the top level for the next index
    else
      check(s.group ~= nil, 'category opened a group: ' .. tostring(row.name))
      check(s.groupTotal == row.count, 'group total matches its record')
      readGroup()
      openDatabase()
    end
  end
end

browseAll()
check(#browsed == total, 'browsing exposed exactly the stored names ('
  .. #browsed .. ' of ' .. total .. ')')
local counts = {}
for i = 1, #browsed do
  check(not counts[browsed[i]], 'name appears only once: ' .. browsed[i])
  counts[browsed[i]] = true
end
for i = 1, total do
  check(counts[names[i]], 'name is reachable: ' .. names[i])
end
check(failureCalled == nil, 'pager reported no failure')

-- Short final pages must be read exactly, and paging past either end must wrap.
openDatabase()
for index = 1, s.categoryTotal do
  local page = math.floor((index - 1) / 8) * 8 + 1
  loadCategoryPage(page)
  s.categorySelected = index - page + 1
  local row = s.categoryRows[s.categorySelected]
  if row.count < 0 then
    -- Enter the folder: categoryTotal then reflects the child records, and the first
    -- child page is loaded in the same step.
    local expectedChildren = -row.count
    database(3)
    check(s.folderName == row.name, 'folder entered: ' .. row.name)
    check(s.categoryTotal == expectedChildren, 'folder exposes its children')
    check(#s.categoryRows > 0, 'folder page is non-empty')
    -- A short final child page must also read exactly.
    local lastChildPage = math.floor((expectedChildren - 1) / 8) * 8 + 1
    loadCategoryPage(lastChildPage)
    check(#s.categoryRows == expectedChildren - lastChildPage + 1,
      'final child page is correctly short')
    openDatabase()
  elseif row.count > 0 then
    database(3)
    check(s.groupTotal == row.count, 'group total equals its category count')
    -- Last page of this category, which is usually a short page.
    local lastPage = math.floor((s.groupTotal - 1) / 8) * 8 + 1
    database(1, lastPage, false)
    database(5)
    check(#s.rows == s.groupTotal - lastPage + 1, 'final page is correctly short')
    -- Selecting the end and wrapping back to the start must both resolve.
    database(1, s.groupTotal, true)
    database(5)
    check(s.selected == #s.rows, 'wrapping to the end selects the final row')
    database(1, 1, false)
    database(5)
    check(s.selected == 1, 'wrapping to the start selects the first row')
    openDatabase()
  else
    openDatabase()
  end
end

-- A first-level category count of zero must never be stored.
check(topCount >= 1, 'top-level count is usable by the loader')

cleanup()
print(string.format('PASS: discovered index build and browse (%d names, %d categories, %d checks)',
  total, topCount, ntests))
