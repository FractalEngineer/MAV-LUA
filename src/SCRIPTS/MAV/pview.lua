-- SPDX-License-Identifier: GPL-3.0-or-later
-- Separate source chunk to bound the parser peak on small radio heaps.
local function fmt(v)
  local value = string.format('%.7g', v)
  return tonumber(value) == v and value or string.format('%.9g', v)
end
return function(s, text, right, width, height, step)
  local reserve = step > 9 and 80 or 36
  text(0, 0, 'PARAMETERS', true, width - reserve)
  local position = s.total > 0 and tostring((s.rows[s.selected] and s.rows[s.selected].index or s.pageStart) + 1) .. '/' .. s.total or '3/3'
  right(0, position, width - reserve)
  local function row(n, value, inverse) text(0, n * step, value, inverse) end
  if s.state == 'prompt' then
    row(2, 'Load parameters')
    row(3, 'Uses telemetry link')
    row(5, '> LOAD <', true)
  elseif s.state == 'preparing' then
    row(2, 'Preparing...') row(5, 'EXIT: cancel')
  elseif s.state == 'connect' then
    row(2, 'Connecting...') row(3, 'Waiting for autopilot') row(5, 'EXIT: cancel')
  elseif s.state == 'loading' then
    row(2, 'Loading...')
    row(3, (s.pageStart + #s.rows + 1) .. ' / ' .. (s.total > 0 and s.total or '?'))
    row(5, 'EXIT: cancel')
  elseif s.state == 'list' then
    row(1, 'All parameters')
    local visible = math.max(1, math.floor(height / step) - 3)
    local first = math.max(1, s.selected - visible + 1)
    for i = first, math.min(#s.rows, first + visible - 1) do
      row(i - first + 2, s.rows[i].name, i == s.selected)
    end
    text(0, height - step, s.rows[s.selected] and ('= ' .. fmt(s.rows[s.selected].value)) or 'No parameters')
  elseif s.state == 'edit' or s.state == 'confirm' then
    row(1, s.current.name)
    row(2, 'Was: ' .. fmt(s.current.value))
    row(3, 'Now: ' .. fmt(s.edited))
    row(4, 'Step: ' .. fmt(s.steps[s.stepIndex]))
    if s.state == 'edit' then row(5, 'ENTER: review') row(6, 'EXIT: discard')
    else row(5, s.choice == 0 and '> Back    Save' or '  Back  > Save', true) end
  elseif s.state == 'saved' then
    row(2, 'Saved and verified') row(3, s.current.name) row(4, '= ' .. fmt(s.current.value)) row(5, 'ENTER: browse')
  elseif s.state == 'error' then
    row(2, s.errorText)
    if s.errorText == 'No parameter bridge' then row(3, 'ELRS bridge required') end
    row(5, 'ENTER: back')
  else row(2, s.state == 'saving' and 'Saving / verifying...' or 'Reading current value...') end
end
