-- Bounded live-page loader with delayed, reordered and duplicate replies.
local root = arg[1] or 'src'
local saved = arg
arg = {root, 'fixture'}
local fixture = dofile('tests/test_params.lua')
arg = saved

local function simulate(options)
  options = options or {}
  local f = fixture(options.count or 160)
  f.interval = 2
  local wire = assert(loadfile(root .. '/SCRIPTS/MAV/wire.lua'))()
  local queue, attempts, inflight = {}, {}, {}
  local sentAt, deliverAt, maximum, reordered, prior = -100, 0, 0, false, -1
  local sends = 0
  f.env.crossfireTelemetryPush = function(command, packet)
    assert(command == 0xAA)
    local id, payload = wire.decode(packet)
    if id == 4 then return true end
    assert(id == 20, 'live browsing must not send SET')
    local index = string.unpack('<i2', payload)
    attempts[index] = (attempts[index] or 0) + 1
    sends = sends + 1
    assert(f.now - sentAt >= 4, 'indexed reads remain capped at 25/s')
    sentAt = f.now
    if options.loss and index == 3 and attempts[index] == 1 then return true end
    if options.busy and index == 5 and attempts[index] == 1 then return false end
    inflight[index] = true
    local n = 0 for _ in pairs(inflight) do n = n + 1 end
    maximum = math.max(maximum, n)
    assert(n <= 4, 'at most four reads are outstanding')
    local delay = options.reorder and index % 4 == 0 and 28 or 10
    queue[#queue + 1] = {index=index, due=f.now + delay}
    return true
  end
  f.action('enter')
  local done
  for _ = 1, 3000 do
    f.tick()
    if f.now >= deliverAt then
      local chosen
      for j, p in ipairs(queue) do
        if p.due <= f.now and (not chosen or p.due < queue[chosen].due) then chosen = j end
      end
      if chosen then
        local p = table.remove(queue, chosen)
        if p.index < prior then reordered = true end
        prior, inflight[p.index], deliverAt = p.index, nil, f.now + 4
        f.reply(p.index)
        if options.duplicates then f.reply(p.index) end
      end
    end
    if f.draw():find('All parameters', 1, true) then done = f.now break end
  end
  assert(done, 'first live page did not finish: ' .. f.draw())
  assert(sends <= 12, 'opening retains a bounded page instead of downloading the list')
  assert(f.draw():find('P_0000', 1, true) and f.draw():find('1/160', 1, true))
  if options.reorder then assert(reordered, 'test actually reordered replies') end
  if options.loss then assert(attempts[3] == 2, 'only the lost request is retried') end
  if options.busy then assert(attempts[5] == 2, 'rejected queue submission is retried') end
  return done / 100, maximum, sends
end

local elapsed, window, sends = simulate()
assert(window >= 2, 'requests overlap')
assert(elapsed < 4, 'eight-row page should open quickly')
print(string.format('Live-page simulation: %.2fs / 8 visible params, peak %d outstanding, %d reads',
  elapsed, window, sends))
simulate({reorder=true, duplicates=true, loss=true, busy=true})

-- Failed queue submissions never authorize unsolicited replies; a late reply
-- to an earlier accepted attempt remains valid after a rejected retry.
local fetch = assert(loadfile(root .. '/SCRIPTS/MAV/fetch.lua'))()
local wireStub = {read=function(_, _, index) return index end}
local attempts = 0
local function busy() attempts = attempts + 1 return false end
local p = {index=0,count=1,name='TEST',kind=9,value=1}
fetch.reset(0, 0, 0)
for now = 0, 600, 200 do
  local record, err = fetch.tick(now, 17, 1, wireStub, busy)
  assert(not record and not err)
  fetch.receive(p, now + 1)
end
local record, err = fetch.tick(800, 17, 1, wireStub, busy)
assert(not record and err == 'No reply; paused' and attempts == 4, 'busy queue terminates after bounded attempts')
fetch.reset(0, 0, 0)
fetch.tick(0, 17, 1, wireStub, function() return true end)
fetch.tick(130, 17, 1, wireStub, busy)
fetch.receive(p, 132)
assert(fetch.tick(132, 17, 1, wireStub, busy) == p, 'late accepted reply survives a rejected retry')
fetch.reset(0, 4, 0)
fetch.tick(0, 17, 1, wireStub, function() return true end)
assert(fetch.receive(p, 10) == 'List changed: reload', 'changed parameter count is rejected')
fetch.clear()
assert(fetch.receive(p, 20) == nil and fetch.tick(20, 17, 1, wireStub, busy) == nil, 'clear ignores late replies')
print('PASS: bounded live page, overlap, reordering, duplicates, loss and backpressure')
