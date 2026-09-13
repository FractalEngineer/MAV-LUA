-- SPDX-License-Identifier: GPL-3.0-or-later
-- Four indexed reads, with bounded reordering for a small live page.
-- Time is EdgeTX getTime() ticks (10 ms). Writes use the separate editor path.
local slots, first, total, nextAt, gap, successes, timeout, lastTick
local function reset(index, count, now)
  slots, first, total, nextAt = {}, index, count, now
  gap, successes, timeout = 5, 0, 120
  lastTick = now
end
local function clear() slots = nil end
local function receive(p, now)
  if not slots then return end
  local s = slots[p.index % 4 + 1]
  if not s or s.index ~= p.index or not s.sent or s.value then return end
  if total > 0 and p.count ~= total then return 'List changed: reload' end
  total, s.value = p.count, p
  if s.tries == 1 and now >= s.at then
    -- Smoothed timeout, bounded for both fast links and long round trips.
    timeout = math.max(60, math.min(240, (timeout * 3 + (now - s.at) * 4) / 4))
    successes = successes + 1
    if successes >= 16 then gap, successes = math.max(4, gap - 1), 0 end
  end
end
local function tick(now, sys, comp, wire, push)
  if not slots then return end
  if now < lastTick then nextAt = now end
  lastTick = now
  local last = total > 0 and math.min(first + 3, total - 1) or first
  local candidate, retry
  for index = first, last do
    local key = index % 4 + 1
    local s = slots[key]
    if not s then s = {index=index, tries=0} slots[key] = s end
    if not s.value then
      local expired = s.at and (now < s.at or now - s.at >= timeout)
      if expired then
        if s.tries >= 4 then return nil, 'No reply; paused' end
        if not retry then candidate, retry = s, true end
      elseif not s.at and not candidate then candidate = s end
    end
  end
  if candidate and now >= nextAt then
    if retry then gap, successes = math.min(20, gap * 2), 0 end
    local accepted = push(0xAA, wire.read(sys, comp, candidate.index))
    candidate.at, candidate.tries = now, candidate.tries + 1
    -- A rejected retransmission must not invalidate a previously queued read.
    candidate.sent = candidate.sent or accepted == true
    if not accepted then gap, successes = math.min(20, gap * 2), 0 end
    nextAt = now + gap
  end
  -- Return at most one record per tick. A missing first record holds the window;
  -- the other three replies can never grow into an unbounded RAM cache.
  local key = first % 4 + 1
  local s = slots[key]
  if s and s.value then
    slots[key], first = nil, first + 1
    return s.value
  end
end
return {reset=reset, clear=clear, receive=receive, tick=tick}
