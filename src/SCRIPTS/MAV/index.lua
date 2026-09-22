-- SPDX-License-Identifier: GPL-3.0-or-later
-- Build a fixed-record parameter index from the names a vehicle reports.
--
-- The on-disk layout matches the pager in pdb.lua, so browsing is unchanged:
--   fixed 22-byte records (name[16], offset I4, count I2) followed by fixed
--   16-byte names. A record whose count has the high bit set is a family folder
--   and its offset points at child records instead of names.
--
-- Why this is not a simple copy:
--   * ArduPilot streams PARAM_REQUEST_LIST in index order, not alphabetical order,
--     so names must be sorted before grouping.
--   * EdgeTX's io library exposes only open/read/write/seek/close, open() is either
--     read-only or write-only, and there is no rename or remove. The build therefore
--     uses separate working files and never seeks a file it is writing.
--   * A radio cannot hold a whole parameter list, so names stream to a file and are
--     sorted in fixed-size runs.
--   * Merging costs one seek per name, and copying must not starve telemetry drawing.
--     No phase therefore runs to completion in one go: call step() from successive
--     telemetry callbacks until it reports 'done'.
--
-- Bounded memory: one run of names, one head record per run, one block being copied,
-- and the category table. A real ArduPilot vehicle reports roughly a hundred categories.

-- Names arrive one per PARAM_VALUE, so this is the only per-record limit needed.
local NAME_SIZE = 16
local RECORD_SIZE = 22
local FOLDER = 0x8000
-- Names held in RAM before one flush to the name file.
local FLUSH_NAMES = 32
-- Names sorted in RAM at a time. The working set is RUN_NAMES * NAME_SIZE bytes.
local RUN_NAMES = 64
-- Names merged per step. Each costs one seek plus one read, so this stays small.
local MERGE_BATCH = 8
-- Records appended to the run file per step. A run is 64 records and each is a separate SD
-- write, so emitting a whole run in one step would stall the UI; spreading them keeps the work
-- per callback comparable to the other phases.
local RUN_WRITE_BATCH = 8
-- Names copied per step while writing the final file.
local COPY_NAMES = 64
-- Names scanned per step while tabulating labels. Reading one record at a time costs a
-- file read per name, which does not fit a single telemetry callback.
local ANALYSE_NAMES = 64
-- Defensive cap on distinct category labels. A real vehicle reports roughly a hundred.
local MAX_LABELS = 256
local GENERAL = 'GENERAL'
-- How often to re-send the list request while no parameter has arrived, in 10 ms ticks, and
-- how many times to try before declaring the link dead. The bridge enforces a 20 ms floor
-- between requests and gives no signal when it refuses one, so the retry must be slower than
-- that gap to be reliable; 50 ticks is 500 ms, comfortably clear of it. At most 9 attempts span
-- about 4.5 seconds, which is long enough for a wake-up but short enough not to strand a pilot.
local LIST_RETRY_MS = 50
local LIST_MAX_TRIES = 9

local function validName(name)
  -- ArduPilot parameter names are letters, digits and underscores, at most 16 bytes.
  return type(name) == 'string' and #name >= 2 and #name <= NAME_SIZE
    and string.match(name, '^[A-Z][A-Z0-9_]*$') ~= nil
end

-- The label is everything before the first underscore. Every name on a real vehicle has
-- one, so GENERAL only appears if a future vehicle reports an unqualified name.
local function labelOf(name)
  local underscore = string.find(name, '_', 1, true)
  return underscore and string.sub(name, 1, underscore - 1) or GENERAL
end

-- One run of NULs, built once at load, so padding never allocates a buffer per record.
-- This matters: string.rep grows a luaL_Buffer, and that is the one call whose failure reads
-- "not enough memory for buffer allocation" (plain `..` says only "not enough memory"). When
-- the run phase exhausted the heap it was this call that reported it, so removing the
-- per-record string.rep removes both the allocation and the confusing message with it.
local NULS = string.rep('\0', NAME_SIZE)

local function padded(name)
  return name .. string.sub(NULS, 1, NAME_SIZE - #name)
end

-- Returns the base of a label ending in digits, so RC12 belongs to the RC family. A single
-- lazy pattern match does this in one C call; scanning the string from Lua costs about
-- 12,000 instructions across a hundred-category vehicle, which alone exceeds a telemetry
-- callback's budget.
local function numberedBase(label)
  local base = string.match(label, '^(.-)%d+$')
  if not base or #base == 0 then return nil end
  return base
end

-- The firmware exposes no `table` library on a monochrome radio. Its linit.c registers
-- `tablib` only inside `#if defined(COLORLCD)`, so `table` is nil there and any call raises
-- "attempt to index a nil value (global 'table')". Host Lua always provides every library, so
-- running the module on the desktop cannot detect this; sorting and joining are therefore
-- implemented here using only base functions plus the string/math/bit32 libraries, which are
-- always present. `tests/test_index_sandbox.lua` executes a real build with `table` removed so
-- this cannot regress.

-- Sorts a list of strings in place, ascending, comparing them exactly as Lua's `<` does.
-- A bottom-up merge sort is O(n log n) and stable, and it calls nothing from a library.
local function sortStrings(items)
  local n = #items
  if n < 2 then return items end
  local buffer = {}
  local width = 1
  while width < n do
    local first = 1
    while first <= n do
      local mid = math.min(first + width - 1, n)
      local last = math.min(first + 2 * width - 1, n)
      local left, right, out = first, mid + 1, first
      while left <= mid and right <= last do
        if items[right] < items[left] then
          buffer[out] = items[right]
          right = right + 1
        else
          buffer[out] = items[left]
          left = left + 1
        end
        out = out + 1
      end
      while left <= mid do
        buffer[out] = items[left]
        left, out = left + 1, out + 1
      end
      while right <= last do
        buffer[out] = items[right]
        right, out = right + 1, out + 1
      end
      first = first + 2 * width
    end
    for i = 1, n do items[i] = buffer[i] end
    width = width * 2
  end
  return items
end

-- Records are written one at a time, never joined into one string first.
--
-- This is not a style choice. Repeated `..` allocates every intermediate result, so building
-- one run of 64 padded names costs about 33 KiB of garbage even though the payload is only
-- 1 KiB, and the collector cannot keep up: a 704-name vehicle reached a 509 KiB peak against a
-- 179 KiB baseline, which is far past any radio heap. The failure lands in the run phase,
-- because that is the first phase that builds a string, and it scales with the number of runs,
-- which is why it appeared suddenly around 700 names. `stepMerge` already appends record by
-- record for the same reason.
--
-- A related trap: writing through `string.rep`, `string.gsub` expansion or `io.read('*a')`
-- instead raises "not enough memory for buffer allocation" from lauxlib.c, because those grow
-- a luaL_Buffer. Plain `..` raises the shorter "not enough memory". Both are heap exhaustion;
-- neither is acceptable here.

-- Digit runs are encoded with a one-byte length prefix, so plain string comparison gives the
-- same order as a digit-aware one (RC2 before RC10). One gsub rewrites every digit run in a
-- single scan; doing this character by character in Lua costs enough instructions to blow a
-- telemetry callback on its own.
local function encode(name)
  return (string.gsub(name, '%d+', function(run) return string.char(#run) .. run end))
end

-- Returns the given labels in natural order.
local function naturalOrder(labels)
  local keys = {}
  for i = 1, #labels do keys[i] = encode(labels[i]) .. '\0' .. labels[i] end
  sortStrings(keys)
  local out = {}
  for i = 1, #keys do out[i] = string.match(keys[i], '\0(.*)$') end
  return out
end

-- Records are fixed width so any page can be read by seeking.
local function record(label, offset, count, folder)
  if #label > NAME_SIZE or count < 1 or count >= FOLDER then return nil end
  return string.pack('<c16I4I2', label, offset, count + (folder and FOLDER or 0))
end

-- Groups naturally-ordered labels into the top-level browse order and, for each numbered
-- family, its members in order.
--
-- Keeps only what the pager actually reads. Earlier shapes also built a per-index base array,
-- a flattened copy of every member, and a label-keyed copy of the name offsets: three extra
-- tables holding the same strings, which is what exhausted the radio heap during the header
-- phase. Members are grouped here once, and the offset shift is added when each record is
-- emitted instead of being stored. Sorting is not repeated per family either, since hundreds
-- of sorts would overflow a telemetry callback.
local function organise(labels, counts)
  -- The numbered base of each label is computed once and reused. Re-deriving it per pass
  -- triples the pattern matches, which alone pushed the first header step past the
  -- permanent-script instruction budget.
  local bases, siblings = {}, {}
  for i = 1, #labels do
    local base = numberedBase(labels[i])
    bases[i] = base
    if base then siblings[base] = (siblings[base] or 0) + 1 end
  end
  -- A base folds its members only when at least two numbered siblings exist, matching the
  -- packaged database generator; a group of one would be a pointless extra level. Labels are
  -- already in natural order, so members need no sorting here.
  local families = {}
  for i = 1, #labels do
    local base = bases[i]
    if base and siblings[base] >= 2 then
      local group = families[base]
      if not group then
        group = {}
        families[base] = group
        -- The unnumbered base group is listed first when it has names of its own.
        if counts[base] then group[1] = base end
      end
      group[#group + 1] = labels[i]
    end
  end

  -- GENERAL first, matching the familiar packaged layout, then the remaining labels in order,
  -- inserting each family folder where its first numbered member appeared.
  local top, placed = {}, {}
  if counts[GENERAL] then
    top[1] = GENERAL
    placed[GENERAL] = true
  end
  for i = 1, #labels do
    local label, base = labels[i], bases[i]
    if base and families[base] then
      if not placed[base] then
        placed[base] = true
        top[#top + 1] = base
      end
    elseif families[label] then
      -- An unnumbered base such as RC is represented by its folder, not as its own row, so it
      -- must not also be added here or the category would appear twice.
      if not placed[label] then
        placed[label] = true
        top[#top + 1] = label
      end
    elseif label ~= GENERAL then
      top[#top + 1] = label
    end
  end
  -- A family whose base has no names of its own still needs a folder entry.
  for base in pairs(families) do
    if not placed[base] then
      placed[base] = true
      top[#top + 1] = base
    end
  end
  return top, families
end

-- Accepts an io library and a file base path, so host tests can inject both.
return function(io, base)
  local self = {names = 0, complete = false, phase = 'idle', expected = nil}
  local pending, pendingCount = {}, 0
  local sealed = false

  -- Resumable-build state. Handles stay open across callbacks; finish() and abort()
  -- both close them.
  local labels, counts, order, starts, total = nil, nil, nil, nil, 0
  local source, runFile, runNumber, mergeTarget
  local runNames, runAt
  local mergeOut, mergeIn, heads, merged
  local analyseIn, analyseAt
  local top, families
  local outFile, headerCursor
  local copyRemaining

  local function closeAll()
    if source then io.close(source) source = nil end
    if runFile then io.close(runFile) runFile = nil end
    if mergeOut then io.close(mergeOut) mergeOut = nil end
    if analyseIn then io.close(analyseIn) analyseIn = nil end
    if mergeIn then io.close(mergeIn) mergeIn = nil end
    if outFile then io.close(outFile) outFile = nil end
  end

  local function writeNew(path, data)
    local file = io.open(path, 'w')
    if not file then return false end
    local ok = true
    if data then ok = io.write(file, data) and true or false end
    io.close(file)
    return ok
  end

  -- Writes the buffered names as fixed 16-byte records in one append.
  local function flush()
    if pendingCount == 0 then return true end
    local file = io.open(base .. '.nam', 'a')
    if not file then return false end
    local ok = true
    for i = 1, pendingCount do
      ok = io.write(file, padded(pending[i])) and true or false
      if not ok then break end
    end
    io.close(file)
    if ok then pendingCount = 0 end
    return ok
  end

  -- Reads the next name of one run, advancing that run's cursor.
  local function mergeHead(i)
    local head = heads[i]
    if not head or head.left <= 0 then return nil end
    if io.seek(mergeIn, head.at) ~= 0 then return nil end
    local raw = io.read(mergeIn, NAME_SIZE)
    if not raw or #raw < NAME_SIZE then return nil end
    head.at = head.at + NAME_SIZE
    head.left = head.left - 1
    return string.match(raw, '^[^%z]+')
  end

  -- Begins a build. 'w' truncates any previous working file.
  function self.begin()
    closeAll()
    pendingCount = 0
    self.names = 0
    self.complete = false
    self.count, self.topCount = nil, nil
    labels, counts, order, starts, total = nil, nil, nil, nil, 0
    top, families, headerCursor = nil, nil, nil
    mergeTarget, merged = 0, 0
    runNames, runAt = nil, nil
    sealed, self.expected = false, nil
    if not writeNew(base .. '.nam', '') then return false end
    self.phase = 'names'
    return true
  end

  -- Tells the builder how many names the vehicle reported. The stream is complete once that
  -- many arrive, which is the handset's job to detect: it knows the count, and the autopilot
  -- always restarts a list from index 0, so a short build could not be resumed.
  function self.expect(count)
    if type(count) == 'number' and count > 0 then self.expected = count end
  end

  -- Marks the input as finished, whatever the reason. Called when the vehicle's reported
  -- count is reached, or when the stream goes idle. The result is assigned before it is
  -- returned: a zero-argument tail call falls through to OP_RETURN on FreedomTX 1.40, which
  -- turns it into a zero-result return.
  function self.seal()
    sealed = true
    local ok = true
    return ok
  end

  -- Adds one parameter name. An invalid name is ignored rather than failing the build,
  -- because the vehicle's list is authoritative.
  function self.push(name)
    if self.phase ~= 'names' or not validName(name) then return false end
    self.names = self.names + 1
    pendingCount = pendingCount + 1
    pending[pendingCount] = name
    if pendingCount >= FLUSH_NAMES then
      -- Assigned rather than tail-called: FreedomTX 1.40 falls through from OP_TAILCALL to
      -- OP_RETURN for a zero-argument call, turning the result into no value at all.
      local flushed = flush()
      return flushed
    end
    return true
  end

  -- Flushes the last names and truncates the run file ready for sorting. Does nothing until
  -- the input is sealed, because a build must never advance with names still in flight.
  local function stepNames()
    if not sealed and (not self.expected or self.names < self.expected) then
      return 'names'
    end
    if not flush() then return nil end
    if self.names == 0 then return nil end
    if not writeNew(base .. '.run', '') then return nil end
    return 'runs'
  end

  -- Reads and sorts one run from the name file, appending it to the run file.
  --
  -- A run is emitted over several steps rather than in one. Each record is its own SD write,
  -- and a run holds RUN_NAMES of them, so writing the whole run at once would leave the UI
  -- stalled for the duration. The pending run is held in `runNames` with `runAt` as the cursor,
  -- which is what makes the phase resumable.
  local function stepRuns()
    if not runNames then
      if not source then
        source = io.open(base .. '.nam', 'r')
        if not source then return nil end
        runFile = io.open(base .. '.run', 'a')
        if not runFile then return nil end
        runNumber = 0
      end
      local block = io.read(source, RUN_NAMES * NAME_SIZE)
      if not block or #block < NAME_SIZE then
        io.close(source) source = nil
        io.close(runFile) runFile = nil
        if runNumber == 0 then return nil end
        mergeTarget = runNumber
        return 'runsDone'
      end
      local names = {}
      local count = math.floor(#block / NAME_SIZE)
      for i = 1, count do
        local name = string.match(
          string.sub(block, (i - 1) * NAME_SIZE + 1, i * NAME_SIZE), '^[^%z]+')
        if name then names[#names + 1] = name end
      end
      -- The names of this run in sorted order. sortStrings is used rather than table.sort for
      -- the reason documented at the top of this file: no table library exists on a monochrome
      -- radio.
      sortStrings(names)
      -- The 2-byte count is the run's header; the records follow it, one write each.
      if not io.write(runFile, string.pack('<I2', #names)) then return nil end
      runNames, runAt = names, 1
    end
    local limit = math.min(runAt + RUN_WRITE_BATCH - 1, #runNames)
    for i = runAt, limit do
      -- Written individually. Building the payload by concatenation would allocate every
      -- partial result and exhaust the heap; the note above the module's string helpers
      -- explains why at length.
      if not io.write(runFile, padded(runNames[i])) then return nil end
    end
    runAt = limit + 1
    if runAt > #runNames then
      runNames, runAt = nil, nil
      runNumber = runNumber + 1
    end
    return 'runs'
  end

  -- Opens the merge and buffers one sorted head per run.
  local function openMerge()
    mergeOut = io.open(base .. '.nam', 'w')
    if not mergeOut then return nil end
    mergeIn = io.open(base .. '.run', 'r')
    if not mergeIn then return nil end
    heads, merged = {}, 0
    -- A run is a 2-byte count then that many fixed records, so the next header is only
    -- reachable by seeking past the whole run.
    local at, index = 0, 0
    while index < mergeTarget do
      if io.seek(mergeIn, at) ~= 0 then return nil end
      local header = io.read(mergeIn, 2)
      if not header or #header < 2 then break end
      local count = string.unpack('<I2', header)
      if count == 0 then break end
      index = index + 1
      heads[index] = {at = at + 2, left = count, name = nil}
      at = at + 2 + count * NAME_SIZE
      merged = merged + count
    end
    if index ~= mergeTarget then return nil end
    for i = 1, #heads do heads[i].name = mergeHead(i) end
    return merged
  end

  -- Emits up to MERGE_BATCH names, always taking the smallest live head.
  local function stepMerge()
    for _ = 1, MERGE_BATCH do
      if merged <= 0 then
        io.close(mergeIn) mergeIn = nil
        io.close(mergeOut) mergeOut = nil
        return 'mergeDone'
      end
      local best
      for i = 1, #heads do
        local name = heads[i].name
        if name and (not best or name < heads[best].name) then best = i end
      end
      if not best then break end
      if not io.write(mergeOut, padded(heads[best].name)) then return nil end
      merged = merged - 1
      heads[best].name = mergeHead(best)
    end
    return 'merge'
  end

  -- Scans the merged file in bounded batches, recording label order and each label's name
  -- count. The merged file is ordered by name, so labels appear in natural order already;
  -- they are collected here and sorted once at the end, because a label's first name decides
  -- where it first appears.
  local function stepAnalyse()
    if not analyseIn then
      analyseIn = io.open(base .. '.nam', 'r')
      if not analyseIn then return nil end
      counts, order, starts = {}, {}, {}
      analyseAt = 0
    end
    local block = io.read(analyseIn, ANALYSE_NAMES * NAME_SIZE)
    if not block or #block < NAME_SIZE then
      io.close(analyseIn) analyseIn = nil
      if total == 0 or #order == 0 then return nil end
      labels = naturalOrder(order)
      return 'headers'
    end
    local count = math.floor(#block / NAME_SIZE)
    for i = 1, count do
      local name = string.match(
        string.sub(block, (i - 1) * NAME_SIZE + 1, i * NAME_SIZE), '^[^%z]+')
      if name then
        local label = labelOf(name)
        if not counts[label] then
          if #order >= MAX_LABELS then return nil end
          counts[label] = 0
          order[#order + 1] = label
          -- Record where this label's names begin. The scan is sequential, so this is the
          -- real file offset and always matches the copy below. Deriving offsets from a
          -- sorted label order instead would break for labels that sort differently as a
          -- label than as a name (OSD1 before OSD_TYPE, but OSD before OSD1).
          starts[label] = analyseAt
        end
        counts[label] = counts[label] + 1
        total = total + 1
        analyseAt = analyseAt + NAME_SIZE
      end
    end
    return 'analyse'
  end

  -- Writes header records one per step: top-level records, then child records.
  local function stepHeaders()
    if not headerCursor then
      -- labels decides the browse order; offsets come from the sequential scan so they always
      -- match the file the copy phase writes. The name region starts after every header
      -- record, so the recorded position is shifted by the header size. That shift is added
      -- when each record is emitted instead of being materialised into a second table keyed
      -- by label, which previously duplicated every category name.
      top, families = organise(labels, counts)
      if #top == 0 then return nil end
      local children = 0
      for i = 1, #top do
        local family = families[top[i]]
        if family then children = children + #family end
      end
      -- Child records occupy the region immediately after the top-level block, so each
      -- parent must point at the start of its own child block within that region.
      local childOffsets, childCursor = {}, #top * RECORD_SIZE
      for i = 1, #top do
        local family = families[top[i]]
        if family then
          childOffsets[top[i]] = childCursor
          childCursor = childCursor + #family * RECORD_SIZE
        end
      end
      outFile = io.open(base .. '.pdb', 'w')
      if not outFile then return nil end
      headerCursor = {index = 1, phase = 'top', childOffsets = childOffsets, childCount = children}
    end

    local h = headerCursor
    local shift = (#top + h.childCount) * RECORD_SIZE
    if h.phase == 'top' then
      if h.index > #top then
        if h.childCount == 0 then
          source = io.open(base .. '.nam', 'r')
          if not source then return nil end
          copyRemaining = total
          return 'copy'
        end
        h.phase, h.index, h.fi, h.mi = 'child', 1, 1, 0
        return 'headers'
      end
      local label = top[h.index]
      -- A family folder points at its child block; a plain category at its names.
      local family = families[label]
      local blob = family and record(label, h.childOffsets[label], #family, true)
        or record(label, shift + starts[label], counts[label])
      if not blob or not io.write(outFile, blob) then return nil end
      h.index = h.index + 1
      return 'headers'
    end
    -- Child phase. Records are emitted in the same order the copy phase writes names, which
    -- is label order across families, matching the original flattened child list. The cursor
    -- advances in constant time: scanning forward for a non-empty family here cost enough
    -- instructions in one callback to exceed the permanent-script budget.
    if h.mi >= (families[top[h.fi]] and #families[top[h.fi]] or 0) then
      repeat
        h.fi, h.mi = h.fi + 1, 0
      until h.fi > #top or families[top[h.fi]]
    end
    if h.fi > #top then
      source = io.open(base .. '.nam', 'r')
      if not source then return nil end
      copyRemaining = total
      return 'copy'
    end
    h.mi = h.mi + 1
    local label = families[top[h.fi]][h.mi]
    local blob = record(label, shift + starts[label], counts[label])
    if not blob or not io.write(outFile, blob) then return nil end
    h.index = h.index + 1
    if h.index > h.childCount then
      source = io.open(base .. '.nam', 'r')
      if not source then return nil end
      copyRemaining = total
      return 'copy'
    end
    return 'headers'
  end

  -- Copies names in bounded batches. The merged file already matches the offsets written
  -- above, so this is a sequential copy with no seeking.
  local function stepCopy()
    local want = math.min(COPY_NAMES, copyRemaining) * NAME_SIZE
    if want <= 0 then
      io.close(source) source = nil
      io.close(outFile) outFile = nil
      self.complete = true
      self.count = total
      self.topCount = #top
      return 'done'
    end
    local block = io.read(source, want)
    if not block or #block == 0 then return nil end
    if not io.write(outFile, block) then return nil end
    copyRemaining = copyRemaining - math.floor(#block / NAME_SIZE)
    return 'copy'
  end

  -- Performs one bounded unit of work. Returns the phase just completed, 'done', or nil
  -- on failure. Call from successive telemetry callbacks so no single one exceeds the
  -- instruction budget: merging alone costs a seek per name.
  function self.step()
    local phase = self.phase
    if phase == 'names' then
      local result = stepNames()
      if not result then return nil end
      if result == 'runs' then self.phase = 'runs' end
      return result
    end
    if phase == 'runs' then
      local result = stepRuns()
      if not result then return nil end
      if result == 'runsDone' then self.phase = 'merge' end
      return result
    end
    if phase == 'merge' then
      if not mergeIn then
        local expected = openMerge()
        if not expected then return nil end
        if expected == 0 then
          self.phase = 'analyse'
          return 'analyse'
        end
        return 'merge'
      end
      local result = stepMerge()
      if not result then return nil end
      if result == 'mergeDone' then self.phase = 'analyse' end
      return result
    end
    if phase == 'analyse' then
      local result = stepAnalyse()
      if not result then return nil end
      if result == 'headers' then self.phase = 'headers' end
      return result
    end
    if phase == 'headers' then
      local result = stepHeaders()
      if not result then return nil end
      if result == 'copy' then self.phase = 'copy' end
      return result
    end
    if phase == 'copy' then
      local result = stepCopy()
      if not result then return nil end
      if result == 'done' then self.phase = 'done' end
      return result
    end
    if phase == 'done' then return 'done' end
    return nil
  end

  -- Runs the build to completion. Convenient for host tests; a radio must drive step()
  -- instead so telemetry drawing keeps its share of each callback.
  function self.finish()
    if self.phase == 'idle' then return nil end
    local guard = 0
    while true do
      guard = guard + 1
      if guard > 100000 then return nil end
      local phase = self.step()
      if not phase then return nil end
      if phase == 'done' then break end
    end
    return self.count, self.topCount
  end

  -- Writes the manifest the loader reads, so identity is known before browsing.
  function self.manifest(version, vehicle)
    local text = '-- SPDX-License-Identifier: GPL-3.0-or-later\n'
      .. '-- Generated from parameters reported by the connected vehicle.\n'
      .. string.format('return {%s,%s,%s,%d}\n',
        string.format('%q', version), string.format('%q', vehicle),
        string.format('%q', base .. '.pdb'), self.topCount or 0)
    return writeNew(base .. '.lua', text)
  end

  -- Ends the build, closing every handle. Any partial file is left for the next begin()
  -- to truncate, so a failed build can never be mistaken for a complete index.
  function self.abort()
    closeAll()
    pendingCount = 0
    sealed = false
    self.complete = false
    -- Drop any half-emitted run, so a later begin() cannot resume into stale names.
    runNames, runAt = nil, nil
    self.phase = 'idle'
    local ok = true
    return ok
  end

  -- Progress wording, in the order the build phases occur.
  local PHASE_TEXT = {
    names = 'Waiting for the vehicle...',
    runs = 'Sorting batches...',
    merge = 'Merging names...',
    analyse = 'Grouping categories...',
    headers = 'Grouping categories...',
    copy = 'Writing index...',
  }

  -- Creates a self-contained build session.
  --
  -- The whole build flow lives here, in the module that loads only when a pilot asks to
  -- build, rather than in the always-loaded browser. Its state machine and screen text
  -- otherwise cost several KiB on every Parameters open, whether or not an index is built.
  --
  -- Arguments are plain values, not callbacks: the caller passes the wire module and the
  -- discovered target, and this module builds its own frames. Passing closures instead would
  -- put that code back in the eager module and defeat the split.
  --
  -- The session owns its own outcome: read session.state ('refresh', 'building', 'done',
  -- 'failed') and session.error afterwards.
  function self.session(wire, system, component, version, vehicle)
    local session = {state = 'refresh', built = 0}
    local builder

    local function send(frame)
      return crossfireTelemetryPush(0xAA, frame)
    end

    local function fail(message)
      if builder then builder.abort() builder = nil end
      session.state, session.error = 'failed', message
      return false
    end

    -- Begins the read: a list request, then the autopilot streams its own parameters.
    --
    -- The request is re-sent until a name actually arrives. send() only reports that the frame
    -- was queued for the handset, not that the bridge accepted it, and the bridge silently
    -- refuses a request that follows another too closely (its READ_GAP_MS floor). A single
    -- fire-and-forget request therefore fails whenever the version reply and this request land
    -- in adjacent ticks, which is exactly what made the first attempt fail and the second work.
    -- Re-sending is safe: the bridge treats a repeated list request as idempotent, and it is
    -- only sent while no names have been seen.
    function session.start(now)
      builder = self
      if not builder.begin() then return fail('Index build failed') end
      session.built, session.total, session.phase = 0, nil, 'names'
      session.streamAt, session.lastPing = now, now
      session.listAt, session.listTries = nil, 0
      if not session.sendList(now) then return fail('Index build failed') end
      session.state = 'building'
      return true
    end

    -- Sends one list request and records when. Returns false only when the frame could not be
    -- queued at all, which the caller treats as fatal.
    function session.sendList(now)
      if not send(wire.requestList(system, component)) then return false end
      session.listAt, session.listTries = now, (session.listTries or 0) + 1
      return true
    end

    -- Accepts one streamed parameter name. The reported count is authoritative, so reaching
    -- it ends the read without waiting for an idle timeout.
    function session.stream(name, count, now)
      if session.state ~= 'building' or not builder then return end
      builder.push(name)
      session.built = builder.names
      -- Remember that a reply arrived at all, which separates "no stream reached us" from
      -- "the stream carried no names" when the build ends with nothing.
      session.seenValue = true
      if count and count > 0 then
        builder.expect(count)
        session.total = count
        if builder.names >= count then builder.seal() end
      end
      session.streamAt = now
    end

    -- Runs one bounded unit of work. Returns true while the session is still building.
    function session.tick(now)
      if session.state ~= 'building' or not builder then
        return session.state == 'building'
      end
      -- Re-send the list request while nothing has arrived yet. The bridge refuses a request
      -- that follows another within its read gap, and there is no signal back to Lua when that
      -- happens, so this repeats at a pace that comfortably clears the gap. It stops the moment
      -- any name arrives, and the attempt count bounds it so a dead link still fails.
      if builder.names == 0 and not session.seenValue then
        if not session.listAt or now < session.listAt
          or now - session.listAt >= LIST_RETRY_MS then
          if not session.sendList(now) then return fail('Index build failed') end
          if session.listTries > LIST_MAX_TRIES then
            -- Nothing ever arrived, so the request never reached an autopilot. On this
            -- hardware that means a TX module built before list-session support, and saying so
            -- is the difference between a reflash and an afternoon spent debugging Lua.
            return fail('No parameter stream: reflash the TX module')
          end
        end
        return true
      end
      -- A stream that has gone quiet: either the autopilot stopped early, or names arrived that
      -- this build could not use. Distinguish the two, because only one of them is the
      -- vehicle's fault.
      if session.streamAt and now >= session.streamAt and now - session.streamAt >= 1500 then
        if builder.names == 0 then return fail('Vehicle reported no parameters') end
        builder.seal()
      end
      local phase = builder.step()
      session.phase = builder.phase or phase
      if not phase then return fail('Index build failed') end
      if phase == 'done' then
        if not builder.manifest(version, vehicle) then return fail('Index write failed') end
        builder, session.phase = nil, nil
        session.state = 'done'
        return false
      end
      -- Keep the bridge lease alive while the build runs; it is a request like any other.
      if now >= session.lastPing and now - session.lastPing >= 300 then
        send(wire.ping())
        session.lastPing = now
      end
      return true
    end

    -- Handles a key. Returns 'build', 'back', 'abort', or nil when the action is ignored.
    function session.input(action, now)
      if session.state == 'refresh' then
        if action == 'enter' then return session.start(now) and 'build' or nil end
        if action == 'exit' or action == 'menu' then return 'back' end
      elseif session.state == 'building' then
        if action == 'exit' then
          if builder then builder.abort() builder = nil end
          session.state, session.phase = 'refresh', nil
          return 'abort'
        end
      elseif session.state == 'failed' then
        if action == 'enter' or action == 'exit' then return 'back' end
      end
      return nil
    end

    -- Text for the current state: title, detail, and a hint.
    function session.screen()
      if session.state == 'building' then
        return 'Reading parameters',
          PHASE_TEXT[session.phase] or 'Waiting for the vehicle...',
          session.built .. ' names found   EXIT: abort'
      end
      return 'No parameter index', 'for this firmware yet',
        '> BUILD <   EXIT: back'
    end

    return session
  end

  return self
end
