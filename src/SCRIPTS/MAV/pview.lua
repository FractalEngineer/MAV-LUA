-- SPDX-License-Identifier: GPL-3.0-or-later
-- Separate source chunk to bound the parser peak on small radio heaps.
local function fmt(v)
  local value = string.format('%.7g', v)
  return tonumber(value) == v and value or string.format('%.9g', v)
end

return function(s, text, right, width, height, step)
  local reserve = step > 9 and 80 or 36
  text(0, 0, 'PARAMETERS', true, width - reserve)
  local position = '3/3'
  if s.state == 'categories' and s.categoryTotal then
    position = math.min(s.categoryTotal, s.categoryPageStart + s.categorySelected - 1)
      .. '/' .. s.categoryTotal
  elseif s.groupTotal then
    position = math.min(s.groupTotal, s.pageStart + s.selected - 1) .. '/' .. s.groupTotal
  end
  right(0, position, width - reserve)
  local function row(n, value, inverse) text(0, n * step, value, inverse) end

  if s.state == 'prompt' then
    row(2, 'Load parameter DB')
    row(3, 'Reads firmware ID')
    row(5, '> LOAD <', true)
  elseif s.state == 'connect' then
    row(2, 'Connecting...')
    row(3, 'Waiting for autopilot')
    row(5, 'EXIT: cancel')
  elseif s.state == 'identity' then
    row(2, 'Reading firmware...')
    row(3, 'Selecting database')
    row(5, 'EXIT: cancel')
  elseif s.state == 'database' then
    row(2, 'Opening database...')
    row(3, s.firmware or '')
  elseif s.state == 'categoryLoading' then
    row(2, 'Opening categories...')
    row(3, 'Local SD database')
  elseif s.state == 'groupLoading' then
    row(2, 'Opening ' .. (s.groupName or '') .. '...')
    row(3, 'Local SD database')
    row(5, 'EXIT: categories')
  elseif s.state == 'categories' then
    row(1, s.folderName and (s.folderName .. ' groups')
      or s.firmware or 'ArduPilot')
    local visible = math.max(1, math.floor(height / step) - 3)
    local first = math.max(1, s.categorySelected - visible + 1)
    for i = first, math.min(#s.categoryRows, first + visible - 1) do
      local group = s.categoryRows[i]
      row(i - first + 2, group.name .. (group.count < 0 and ' >' or ''),
        i == s.categorySelected)
    end
    local group = s.categoryRows[s.categorySelected]
    text(0, height - step, group and ((group.count < 0 and -group.count or group.count)
      .. (group.count < 0 and ' groups' or ' parameter names')) or 'No categories')
  elseif s.state == 'list' then
    row(1, s.groupName or '')
    local visible = math.max(1, math.floor(height / step) - 3)
    local first = math.max(1, s.selected - visible + 1)
    for i = first, math.min(#s.rows, first + visible - 1) do
      row(i - first + 2, s.rows[i].name, i == s.selected)
    end
    text(0, height - step, 'ENTER: read value')
  elseif s.state == 'edit' or s.state == 'confirm' then
    row(1, s.current.name)
    row(2, 'Was: ' .. fmt(s.current.value))
    row(3, 'Now: ' .. fmt(s.edited))
    row(4, 'Step: ' .. fmt(s.steps[s.stepIndex]))
    if s.state == 'edit' then
      row(5, 'ENTER: review')
      row(6, 'EXIT: discard')
    else row(5, s.choice == 0 and '> Back    Save' or '  Back  > Save', true) end
  elseif s.state == 'saved' then
    row(2, 'Saved and verified')
    row(3, s.current.name)
    row(4, '= ' .. fmt(s.current.value))
    row(5, 'ENTER: browse')
  elseif s.state == 'error' then
    row(2, s.errorText)
    if s.errorText == 'No parameter bridge' then row(3, 'ELRS bridge required')
    elseif string.sub(s.errorText or '', 1, 6) == 'No DB:' then row(3, 'Install matching DB') end
    row(5, 'ENTER: back')
  else
    row(2, s.state == 'saving' and 'Saving / verifying...' or 'Reading current value...')
  end
end
