-- SPDX-License-Identifier: GPL-3.0-or-later
-- Category navigation, on-demand value reads, and guarded editing controls.
return function(s, actions)
  local begin, cancel = actions.begin, actions.cancel
  local failure, request, ready = actions.failure, actions.request, actions.ready
  local clearGroup = actions.clearGroup
  local database = actions.database

  local function editable(p)
    if p.kind == 9 then return true end
    return p.kind >= 1 and p.kind <= 6 and p.value % 1 == 0 and math.abs(p.value) <= 16777216
  end

  local function change(delta)
    local v = s.edited + s.steps[s.stepIndex] * delta
    local lo, hi = -1e20, 1e20
    if s.current.kind ~= 9 then
      local limits = {{0,255}, {-128,127}, {0,65535}, {-32768,32767},
        {0,16777216}, {-16777216,16777216}}
      lo, hi = limits[s.current.kind][1], limits[s.current.kind][2]
    end
    if v >= lo and v <= hi then s.edited = string.unpack('<f', string.pack('<f', v)) end
  end

  local function categories()
    clearGroup()
    s.state = 'categories'
  end

  local function input(action, now)
    if s.state == 'prompt' then
      if action == 'enter' then begin(now)
      elseif action == 'exit' then return true end
    elseif s.state == 'connect' or s.state == 'identity' or s.state == 'database' then
      if action == 'exit' then cancel() end
    elseif s.state == 'categories' then
      if action == 'exit' then
        if not database(4) then return true end
      elseif action == 'menu' then
        if not database(4) then cancel() end
      elseif action == 'next' and #s.categoryRows > 0 then
        if s.categorySelected < #s.categoryRows then s.categorySelected = s.categorySelected + 1
        elseif s.categoryPageStart + #s.categoryRows <= s.categoryTotal then
          database(2, s.categoryPageStart + 8, false)
        else database(2, 1, false)
        end
      elseif action == 'prev' and #s.categoryRows > 0 then
        if s.categorySelected > 1 then s.categorySelected = s.categorySelected - 1
        elseif s.categoryPageStart > 1 then
          database(2, math.max(1, s.categoryPageStart - 8), true)
        else database(2, s.categoryTotal, true)
        end
      elseif action == 'enter' then database(3) end
    elseif s.state == 'categoryLoading' then
      if action == 'exit' and not database(4) then cancel() end
    elseif s.state == 'groupLoading' then
      if action == 'exit' then categories() end
    elseif s.state == 'list' then
      if action == 'exit' or action == 'menu' then categories()
      elseif action == 'next' and #s.rows > 0 then
        if s.selected < #s.rows then s.selected = s.selected + 1
        elseif s.pageStart + #s.rows <= s.groupTotal then database(1, s.pageStart + 8, false)
        else database(1, 1, false) end
      elseif action == 'prev' and #s.rows > 0 then
        if s.selected > 1 then s.selected = s.selected - 1
        elseif s.pageStart > 1 then database(1, math.max(1, s.pageStart - 8), true)
        else database(1, s.groupTotal, true) end
      elseif action == 'enter' and s.rows[s.selected] then
        s.current = {name=s.rows[s.selected].name}
        s.state = 'reading'
        request('edit', s.current.name)
      end
    elseif s.state == 'edit' then
      if not editable(s.current) then failure('Unsupported value type')
      elseif action == 'next' or action == 'prev' then change(action == 'next' and 1 or -1)
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
        else s.state = 'checking' request('check', s.current.name) end
      end
    elseif s.state == 'error' or s.state == 'saved' then
      if action == 'enter' or action == 'exit' then
        if s.database then
          if s.group then s.state = 'list' else s.state = 'categories' end
        else s.state = 'prompt' end
      end
    elseif s.state == 'reading' or s.state == 'checking' then
      if action == 'exit' then s.pending, s.state = nil, 'list' end
    end
  end

  local function leave()
    if s.state == 'saving' then return false end
    if s.state == 'connect' or s.state == 'identity' or s.state == 'database'
      or s.state == 'categoryLoading' or s.state == 'groupLoading' then cancel()
    elseif s.state == 'reading' or s.state == 'checking' then
      s.pending, s.state = nil, 'list'
    elseif s.state == 'edit' or s.state == 'confirm' then s.state = 'list' end
    if s.state == 'list' then categories() end
    return true
  end

  return {input=input, leave=leave}
end
