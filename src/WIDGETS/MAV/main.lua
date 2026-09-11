-- SPDX-License-Identifier: GPL-3.0-or-later
-- Color-radio adapter. One MAV widget per model; the telemetry queue is shared.
local function create(zone, options)
  local chunk, err = loadScript("/SCRIPTS/TELEMETRY/MAV", "bt")
  local widget = {zone = zone, error = err}
  if chunk then widget.app = chunk() widget.app.init() end
  return widget
end

local function refresh(widget, event, touch)
  if not widget.app then
    lcd.drawText(widget.zone.x, widget.zone.y, "MAV load failed", 0)
    return
  end
  if touch then
    if event == EVT_TOUCH_TAP then
      event = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK
    elseif event == EVT_TOUCH_SLIDE then
      if touch.swipeUp then event = EVT_VIRTUAL_NEXT
      elseif touch.swipeDown then event = EVT_VIRTUAL_PREV end
    end
  end
  widget.app.run(event, event == nil and widget.zone or nil)
end

local function background(widget)
  if widget.app then widget.app.background() end
end

return {name = "MAV", options = {}, create = create, refresh = refresh,
  background = background, update = function() end}
