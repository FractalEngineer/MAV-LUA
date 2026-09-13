-- SPDX-License-Identifier: GPL-3.0-or-later
-- Editing and button actions share the controller state, without copying rows.
return function(s, actions)
  local begin, page, cancel = actions.begin, actions.page, actions.cancel
  local failure, request, ready = actions.failure, actions.request, actions.ready
  local function editable(p)
    if p.kind == 9 then return true end
    return p.kind >= 1 and p.kind <= 6 and p.value % 1 == 0 and math.abs(p.value) <= 16777216
  end
  local function change(delta)
    local v = s.edited + s.steps[s.stepIndex] * delta
    local lo, hi = -1e20, 1e20
    if s.current.kind ~= 9 then
      local limits = {{0,255}, {-128,127}, {0,65535}, {-32768,32767}, {0,16777216}, {-16777216,16777216}}
      lo, hi = limits[s.current.kind][1], limits[s.current.kind][2]
    end
    if v >= lo and v <= hi then s.edited = string.unpack('<f', string.pack('<f', v)) end
  end
  local function input(action, now)
    if s.state == 'prompt' then
      if action == 'enter' then begin(now)
      elseif action == 'exit' then return true end
    elseif s.state == 'preparing' then
      if action == 'exit' then s.state = 'prompt' end
    elseif s.state == 'connect' or s.state == 'loading' then
      if action == 'exit' then cancel() end
    elseif s.state == 'list' then
      if action == 'exit' then return true
      elseif action == 'menu' then s.state = 'prompt'
      elseif action == 'next' and #s.rows > 0 then
        if s.selected < #s.rows then s.selected = s.selected + 1
        elseif s.rows[s.selected].index + 1 < s.total then page(s.rows[s.selected].index + 1, false, now) end
      elseif action == 'prev' and #s.rows > 0 then
        if s.selected > 1 then s.selected = s.selected - 1
        elseif s.pageStart > 0 then page(math.max(0, s.pageStart - 8), true, now) end
      elseif action == 'enter' and s.rows[s.selected] then
        s.current = s.rows[s.selected]
        if not editable(s.current) then failure('Unsupported value type') return end
        s.state = 'reading'
        request('edit', s.current.index)
      end
    elseif s.state == 'edit' then
      if action == 'next' or action == 'prev' then change(action == 'next' and 1 or -1)
      elseif action == 'menu' then
        s.stepIndex = s.stepIndex % #s.steps + 1
        if s.current.kind ~= 9 and s.stepIndex < 7 then s.stepIndex = 7 end
      elseif action == 'exit' then s.state = 'list'
      elseif action == 'enter' then s.state, s.choice = 'confirm', 0 end
    elseif s.state == 'confirm' then
      if action == 'next' or action == 'prev' then s.choice = 1 - s.choice
      elseif action == 'exit' then s.state = 'edit'
      elseif action == 'enter' then
        if s.choice == 0 then s.state = 'edit'
        elseif not ready(now) then failure('Disarm / check link')
        elseif s.edited == s.current.value then s.state = 'list'
        else s.state = 'checking' request('check', s.current.index) end
      end
    elseif s.state == 'error' or s.state == 'saved' then
      if action == 'enter' or action == 'exit' then s.state = #s.rows > 0 and 'list' or 'prompt' end
    elseif s.state == 'reading' or s.state == 'checking' then
      if action == 'exit' then s.pending, s.state = nil, 'list' end
    end
  end
  local function leave()
    if s.state == 'saving' then return false end
    if s.state == 'preparing' then s.state = 'prompt'
    elseif s.state == 'connect' or s.state == 'loading' then cancel() end
    if s.state == 'reading' or s.state == 'checking' then s.pending, s.state = nil, 'list' end
    if s.state == 'edit' or s.state == 'confirm' then s.state = 'list' end
    return true
  end
  return {input=input, leave=leave}
end
