-- Widget adapter contract, including failed loads, zone ownership and touch.
local draws, runs, backgrounds, inits = {}, {}, 0, 0
EVT_TOUCH_TAP, EVT_TOUCH_SLIDE = 20, 21
EVT_VIRTUAL_ENTER, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV = 30, 31, 32
local fail = false
local app = {
  init = function() inits = inits + 1 end,
  background = function() backgrounds = backgrounds + 1 end,
  run = function(event, zone) runs[#runs + 1] = {event, zone} end,
}
loadScript = function(path, mode)
  assert(path == "/SCRIPTS/TELEMETRY/MAV" and mode == "bt", "extension-neutral loader")
  if fail then return nil, "not enough memory" end
  return function() return app end
end
lcd = {drawText = function(x, y, text) draws[#draws + 1] = {x, y, text} end}
local widget = assert(loadfile("src/WIDGETS/MAV/main.lua"))()
local zone = {x = 10, y = 20, w = 320, h = 240}
local instance = widget.create(zone, {})
assert(inits == 1)
widget.background(instance)
assert(backgrounds == 1)
widget.refresh(instance, nil)
assert(runs[#runs][1] == nil and runs[#runs][2] == zone, "zone refresh stays in widget")
widget.refresh(instance, 0)
assert(runs[#runs][1] == 0 and runs[#runs][2] == nil, "full-screen refresh")
widget.refresh(instance, EVT_TOUCH_TAP, {x = 100, y = 100})
assert(runs[#runs][1] == EVT_VIRTUAL_ENTER)
widget.refresh(instance, EVT_TOUCH_SLIDE, {swipeUp = true})
assert(runs[#runs][1] == EVT_VIRTUAL_NEXT)
widget.refresh(instance, EVT_TOUCH_SLIDE, {swipeDown = true})
assert(runs[#runs][1] == EVT_VIRTUAL_PREV)
widget.update(instance, {})
fail = true
local broken = widget.create(zone, {})
widget.background(broken)
widget.refresh(broken)
assert(backgrounds == 1 and draws[1][3] == "MAV load failed", "load failure stays reviewable")
print("PASS: color widget loader, zone/full-screen callbacks, touch, failure handling")
