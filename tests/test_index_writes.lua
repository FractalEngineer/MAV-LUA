-- Regression: the index builder must never join a run into one string before writing it.
--
-- Why this exists: `stepRuns` used to accumulate a run's padded names with `..` and write the
-- result in a single call. Repeated concatenation allocates every intermediate string, so one
-- run of 64 names cost roughly 33 KiB of garbage for a 1 KiB payload. Lua collects garbage
-- incrementally and its debt threshold scales with live memory, so on a radio those partials
-- pile up before a cycle completes instead of being reclaimed promptly.
--
-- Measured with the host memory runner over a streamed, vehicle-shaped list:
--   runs phase peak, 700 names:  509 KiB (joined)  ->  197 KiB (one write per record)
--   runs phase peak, 1400 names:  scale with runs  ->  stays proportionate
-- The failure therefore appeared at a name count rather than a size, which is exactly the
-- "fails around 700 names" report, and 704 names is 11 runs of 64.
--
-- The error text was the other clue. "not enough memory for buffer allocation" is raised ONLY
-- by `resizebox` in lauxlib.c, i.e. when a `luaL_Buffer` grows past its inline
-- LUAL_BUFFERSIZE. `..` raises the shorter "not enough memory"; `string.rep`, `string.gsub`
-- expansion and `io.read('*a')` grow a luaL_Buffer. `padded` called `string.rep` once per
-- record, so it, not the concatenation, produced the exact wording the pilot saw. Padding now
-- slices a NUL string built once at load, so that call is gone too.
--
-- A capped-allocator test cannot catch this: a tight limit drives the collector continuously
-- and masks the accumulation, which is why the pre-fix builder passed a small-heap check. The
-- assertion here is on the shape of the writes instead, which is what the fix actually changed.
--
-- Run with Lua 5.3: .build/lua53 tests/test_index_writes.lua [package-root]
local root = arg[1] or 'src'
local base = '.build/index-writes'
local hostio = io
local ntests = 0
local function check(condition, message)
  assert(condition, message)
  ntests = ntests + 1
end

-- A shim that records every write, so the test sees the exact call shape the builder used.
-- Writes are attributed to the file being written, because only the run file is the concern:
-- the copy phase deliberately writes a whole 64-record block at a time, which is a single
-- bounded write of a block it just read rather than a string accumulated by concatenation.
local writes, totalBytes = 0, 0
local maxRunWrite, maxAnyWrite, currentPath = 0, 0, nil
local shim = {
  open = function(path, mode)
    local file = hostio.open(path, mode == 'r' and 'rb' or mode == 'w' and 'wb'
      or mode == 'a' and 'ab' or mode)
    if file and (mode == 'w' or mode == 'a') then currentPath = path end
    return file
  end,
  seek = function(file, offset) return file:seek('set', offset) and 0 or 1 end,
  read = function(file, count) return file:read(count) end,
  write = function(file, data)
    writes = writes + 1
    totalBytes = totalBytes + #data
    if #data > maxAnyWrite then maxAnyWrite = #data end
    if currentPath and currentPath:sub(-4) == '.run' and #data > maxRunWrite then
      maxRunWrite = #data
    end
    return file:write(data)
  end,
  close = function(file) currentPath = nil return file:close() end,
}
io = shim

-- A vehicle-shaped list. The size is chosen to exceed ten runs of RUN_NAMES (64), because the
-- defect only became visible once a build spanned many runs.
local names, seen = {}, {}
local function add(name)
  if not seen[name] and #name <= 16 then seen[name] = true names[#names + 1] = name end
end
local label = 1
while #names < 760 do
  local prefix = string.format('WR%03d', label)
  add(prefix .. '_TYPE')
  add(prefix .. '_OPTIONS')
  for j = 1, 9 do add(string.format('%s_VAL_%02d', prefix, j)) end
  label = label + 1
end
local total = #names

local maker = assert(loadfile(root .. '/SCRIPTS/MAV/index.lua'))()
local builder = maker(shim, base)
check(builder.begin(), 'the build begins')
for i = 1, total do assert(builder.push(names[i])) end
builder.expect(total)
builder.seal()
local count = builder.finish()
check(count == total, 'every name was retained: ' .. tostring(count))

-- One run is a 2-byte header plus one 16-byte record per name. The run file must only ever
-- receive a header or a single record, so the largest write to it is 16 bytes. A joined run
-- would be 2 + 64 * 16 = 1026 bytes, which is the shape the fix removed.
check(maxRunWrite <= 16,
  'the run file must receive records individually, saw one write of ' ..
  maxRunWrite .. ' bytes')
-- The name file is written in flushes of FLUSH_NAMES records, so a bounded block there is
-- expected and is not what the fix changed. This pins that the block stays bounded rather than
-- growing into one whole-list payload.
check(maxAnyWrite <= 64 * 16, 'no write may exceed one bounded batch, saw ' ..
  maxAnyWrite .. ' bytes')

-- The writes must also be numerous enough to show the records really were separate. A build of
-- this size writes the name file in flushes, one header and one record per name in the run
-- phase, and one record per name again while merging. Anything near the record count for those
-- passes is expected; a handful would mean whole runs were joined.
check(writes > total, 'records are written one at a time, saw only ' .. writes .. ' writes')
check(totalBytes > total * 16, 'every name reached the file')
print(string.format('PASS: no joined run payload (%d checks, %d names, %d writes, largest run write %d bytes)',
  ntests, count, writes, maxRunWrite))

for _, suffix in ipairs({'.nam', '.run', '.pdb', '.lua'}) do os.remove(base .. suffix) end
