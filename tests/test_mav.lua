-- Run: .build/lua tests/test_mav.lua [source-or-unstripped-bytecode]
local source = arg[1] or "src/SCRIPTS/TELEMETRY/MAV.lua"
local concat = table.concat
local tests = 0
local function check(condition, message)
  assert(condition, message)
  tests = tests + 1
end

local function up(fn, name)
  for i = 1, 100 do
    local key, value = debug.getupvalue(fn, i)
    if key == name then return value end
    if not key then break end
  end
  error("No upvalue " .. name)
end

local function fixture(w, h, modern)
  local f = {now = 0, rssi = 0, queue = {}, reads = 0, calls = {}, sensors = {}, probes = 0}
  local env = {LCD_W = w or 128, LCD_H = h or 96, SOLID = 0, INVERS = 1,
    math = math, string = string, type = type, FORCE = 2, ERASE = 4}
  -- Deliberately omit table, bit32, CENTERED, loadScript, and every optional event.
  env.EVT_PAGE_BREAK, env.EVT_EXIT_BREAK = 10, 11
  env.EVT_VIRTUAL_NEXT, env.EVT_VIRTUAL_PREV = 12, 13
  env.getTime = function() return f.now end
  env.getRSSI = function() return f.rssi end
  env.getFieldInfo = function(name)
    f.probes = f.probes + 1
    local sensor = f.sensors[name]
    return sensor and {id = name, unit = sensor.unit}
  end
  env.getValue = function(id) return f.sensors[id].value end
  if modern then
    env.getSourceValue = function(id) return f.sensors[id].value, f.sensors[id].valid end
  end
  env.crossfireTelemetryPop = function()
    f.reads = f.reads + 1
    local frame = f.queue[1]
    for i = 2, #f.queue do f.queue[i - 1] = f.queue[i] end
    f.queue[#f.queue] = nil
    if frame then return frame[1], frame[2] end
  end
  local function record(kind, ...)
    if f.quiet then return end
    f.calls[#f.calls + 1] = {kind, ...}
  end
  env.lcd = {
    clear = function() f.calls = {} end,
    drawText = function(x, y, s, flags) record("text", x, y, s, flags) end,
    drawLine = function(x1, y1, x2, y2, pattern, flags) record("line", x1, y1, x2, y2, flags) end,
  }
  function f.nativeFont()
    -- Proportional firmware cursor API, intentionally without getTextWidth.
    local right = 0
    f.measure = function(s)
      local _, narrow = s:gsub("[ ilI%.:,!'r]", "")
      return #s * 6 - narrow * 3
    end
    env.lcd.drawText = function(x, y, s, flags)
      right = x + f.measure(s)
      if y <= env.LCD_H then record("text", x, y, s, flags) else
        assert(x == 0 and y == env.LCD_H + 1 and flags == 0, "font probe must be below physical LCD")
      end
    end
    env.lcd.getLastRightPos = function() return right end
    env.GREY = function(n) return n * 65536 end
    env.type = function(value)
      if value == env.GREY then return "lightfunction" end
      return type(value)
    end
  end
  if env.LCD_W >= 320 then
    env.CUSTOM_COLOR, env.WHITE, env.BLACK = 256, 65535, 0
    env.lcd.RGB = function() return 0 end
    env.lcd.setColor = function() end
    env.lcd.getTextWidth = function(_, text) return #text * 16 end
    env.lcd.drawFilledRectangle = function(x, y, width, height)
      if width > 100 then f.calls = {} end
      record("fill", x, y, width, height)
    end
  end
  f.env = env
  local chunk = assert(loadfile(source, "bt", env))
  f.app = chunk()
  f.app.init()
  f.receive = up(f.app.background, "receive")
  f.control = up(f.app.run, "controls")
  function f.state(name) return up(f.receive, name) end
  function f.rows()
    local result = {}
    for _, call in ipairs(f.calls) do
      if call[1] == "text" then result[#result + 1] = call[4] end
    end
    return concat(result, "\n")
  end
  function f.render(event, zone)
    f.now = f.now + 10
    f.app.run(event or 0, zone)
    return f.rows()
  end
  function f.push(text, severity, command)
    local payload = {0xF1, severity or 6}
    for i = 1, #text do payload[#payload + 1] = string.byte(text, i) end
    f.queue[#f.queue + 1] = {command or 0x80, payload}
  end
  function f.data(id, v, more)
    local p = more or {0xF0}
    p[#p + 1], p[#p + 2] = id % 256, math.floor(id / 256)
    for i = 1, 4 do local byte = v % 256 p[#p + 1] = byte v = (v - byte) / 256 end
    if not more then f.queue[#f.queue + 1] = {0x80, p} end
    return p
  end
  function f.status(present, enabled, healthy)
    local p = {}
    for i = 1, 12 do p[i] = 0 end
    if present then p[1] = 16 end
    if enabled then p[5] = 16 end
    if healthy then p[9] = 16 end
    f.queue[#f.queue + 1] = {0xAC, p}
  end
  return f
end

local f = fixture()
check(f.render():find("NO LINK", 1, true), "empty navigation indicates missing link")
check(f.render(10):find("No messages", 1, true), "empty history")
check(up(f.control, "page") == 2, "PAGE changes page")
f.app.run(nil)
check(up(f.control, "page") == 2, "nil event must not equal missing constants")
f.push("PreArm: GPS", 4)
f.app.background()
check(f.state("count") == 1, "background collects while hidden")
check(f.render():find("WRN", 1, true), "severity label")
f.now = f.state("history")[f.state("head")].time + 300
f.push("PreArm: GPS", 4, 0x7F)
f.app.background()
local latest = f.state("history")[f.state("head")]
check(latest.repeats == 2, "legacy command and inclusive 3-second dedup")
f.now = f.now + 301
f.push("PreArm: GPS", 4)
f.app.background()
check(f.state("count") == 2, "outside dedup window inserts")
f.push("PreArm: GPS", 3)
f.app.background()
check(f.state("count") == 3, "severity distinguishes duplicates")
check(f.render():find("!ERR", 1, true), "critical marker")
check(f.render():find("x2", 1, true), "repeat count visible")

local initial = f.state("count")
local bad = {
  {0x80, nil}, {0x80, "bad"}, {0x21, {0xF1, 4, 65}},
  {0x80, {0xF0, 4, 65}}, {0x80, {0xF1, -1, 65}},
  {0x80, {0xF1, 256, 65}}, {0x80, {0xF1, 1.1, 65}},
  {0x80, {0xF1, 0/0, 65}}, {0x80, {0xF1, 4, -1}},
  {0x80, {0xF1, 4, 256}}, {0x80, {0xF1, 4, 65, "x"}},
  {0x80, {0xF1, 4, 65, 1.2}}, {0x80, {0xF1, 4, 0}},
  {0x80, {0xF1, 4}}, {0x80, {0xF1, 4, 32}},
}
for _, frame in ipairs(bad) do
  f.queue = {frame}
  f.app.background()
end
check(f.state("count") == initial, "malformed frames cannot create history")
f.push("A\0ignored", 255)
check(f.render():find("UNK A", 1, true), "NUL termination and unknown severity")
f.push("\1hi\255", 6)
f.render()
check(f.state("history")[f.state("head")].text == " hi ", "nonprintable bytes sanitized")
f.push(string.rep("W", 60), 6)
f.app.background()
check(#f.state("history")[f.state("head")].text == 50, "50-byte transport cap")
f.now = 0 -- reset/wrap must not fold an older message into a newer timestamp
f.push(string.rep("W", 60), 6)
f.app.background()
check(f.state("history")[f.state("head")].repeats == 1, "clock rollback resets dedup")

f = fixture()
for i = 1, 30 do f.queue[i] = {0x29, {}} end
f.app.background()
check(f.reads == 8 and #f.queue == 22, "eight-frame callback budget")
f.queue = {}
for i = 1, 30 do f.push("Message " .. i) end
f.reads = 0
f.app.background()
check(f.reads == 1 and #f.queue == 29, "custom callback budget leaves packets queued")
while #f.queue > 0 do f.app.background() end
for i = 1, 8 do f.status(true, true, i % 2 == 0) end
f.reads = 0
f.app.background()
check(f.reads == 1 and #f.queue == 7, "system-status callback budget leaves packets queued")
while #f.queue > 0 do f.app.background() end
check(f.state("count") == 20 and #f.state("history") == 20, "bounded history")
check(f.state("history")[f.state("head")].text == "Message 30", "newest entry")
f.render(10)
for i = 1, 25 do f.render(12) end
check(up(f.control, "selected") == 19, "scroll lower bound")
check(f.rows():find("Message 11", 1, true), "oldest retained entry readable")
for i = 1, 30 do f.render(13) end
check(up(f.control, "selected") == 0, "scroll upper bound")
f.render(12)
local chosen = up(f.control, "selected")
f.push("New arrival")
f.render()
check(up(f.control, "selected") == chosen + 1, "new arrival preserves selected message")
check(f.state("unread") == 1, "unread while browsing older history")
f.render(11)
check(up(f.control, "page") == 1, "Exit returns Navigation")
f.render(10)
check(up(f.control, "selected") == 0 and f.state("unread") == 0, "reopen starts at latest")
for _, eventName in ipairs({"EVT_ROT_RIGHT", "EVT_PLUS_FIRST", "EVT_PLUS_REPT", "EVT_DOWN_FIRST",
  "EVT_DOWN_REPT", "EVT_VIRTUAL_NEXT_REPT"}) do
  f.env[eventName] = 30
  f.render(30)
  check(up(f.control, "selected") == 1, eventName)
  f.render(13)
  f.env[eventName] = nil
end
for _, eventName in ipairs({"EVT_ROT_LEFT", "EVT_MINUS_FIRST", "EVT_MINUS_REPT", "EVT_UP_FIRST",
  "EVT_UP_REPT", "EVT_VIRTUAL_PREV_REPT"}) do
  f.render(12)
  f.env[eventName] = 31
  f.render(31)
  check(up(f.control, "selected") == 0, eventName)
  f.env[eventName] = nil
end

local function telemetry(f)
  f.rssi = 99
  f.sensors = {
    Ptch = {value = 0.15, unit = 21, valid = true}, Roll = {value = 0.25, unit = 21, valid = true},
    Yaw = {value = -1, unit = 21, valid = true}, RxBt = {value = 16.4, unit = 1, valid = true},
    Sats = {value = 14, valid = true}, FM = {value = "STAB*", valid = true},
    RQly = {value = 98, valid = true}, GSpd = {value = 42, unit = 7, valid = true},
    GAlt = {value = 123, unit = 9, valid = true}, Curr = {value = 3.2, unit = 2, valid = true},
  }
end

f = fixture(128, 96, true)
telemetry(f)
local screen = f.render()
check(screen:find("16.4V", 1, true) and screen:find("STAB*", 1, true), "battery and unmodified mode")
check(screen:find("SAT\n14", 1, true) and screen:find("HDG\n303", 1, true), "satellites and normalized heading")
f.sensors.Ptch.valid, f.sensors.RxBt.valid = false, false
screen = f.render()
check(screen:find("--V", 1, true), "stale sensor suppressed on modern firmware")
local sample = up(f.app.background, "sample")
check(up(sample, "values")[1] == nil, "stale attitude does not draw level horizon")
f.rssi = 0
check(f.render():find("NO LINK", 1, true) and up(sample, "values")[6] == nil, "link loss clears all readings")
f.rssi = 99
f.sensors.Ptch.valid, f.sensors.RxBt.valid = true, true
check(f.render():find("16.4V", 1, true), "link recovery")
f.sensors.Sats.value = 255
check(f.render():find("SAT\n--", 1, true), "unknown satellite sentinel")
f.sensors.Ptch.value = 0/0
f.render()
check(up(sample, "values")[1] == nil, "nonfinite telemetry suppressed")

f = fixture()
f.render()
local probes = f.probes
f.render()
check(f.probes == probes, "missing sensors not scanned every redraw")
telemetry(f)
f.sensors.BtRx, f.sensors.RxBt = f.sensors.RxBt, nil
f.sensors.Alt, f.sensors.GAlt = f.sensors.GAlt, nil
f.sensors.Alt.unit, f.sensors.GSpd.unit = 10, 8
f.now = 200
screen = f.render()
check(screen:find("16.4V", 1, true), "late discovery and BtRx alias")
check(screen:find("123ft", 1, true) and screen:find("42mph", 1, true), "imperial sensor units")
f.env.crossfireTelemetryPop = nil
check(f.render(10):find("CRSF API missing", 1, true), "missing optional raw API")

local function bounds(f, zone)
  local w, h = zone and zone.w or f.env.LCD_W, zone and zone.h or f.env.LCD_H
  local x0, y0 = zone and zone.x or 0, zone and zone.y or 0
  for _, c in ipairs(f.calls) do
    if c[1] == "text" then
      local cw, ch = f.env.CUSTOM_COLOR and 16 or 6, f.env.CUSTOM_COLOR and 19 or 8
      assert(c[2] >= x0 and c[3] >= y0 and c[2] + (f.measure and f.measure(c[4]) or #c[4] * cw) <= x0 + w
        and c[3] + ch <= y0 + h, "text outside screen: " .. c[4])
    elseif c[1] == "line" then
      assert(c[2] >= x0 and c[2] < x0 + w and c[4] >= x0 and c[4] < x0 + w
        and c[3] >= y0 and c[3] < y0 + h and c[5] >= y0 and c[5] < y0 + h, "line outside screen")
    end
  end
end

for _, size in ipairs({{128,64}, {128,96}, {212,64}, {320,240}, {480,272}, {800,480}}) do
  f = fixture(size[1], size[2])
  telemetry(f)
  for _, attitude in ipairs({{0,0}, {0.5,0.7}, {-0.7,-0.9}, {1.57,3.14}, {-1.57,-3.14}}) do
    f.sensors.Ptch.value, f.sensors.Roll.value = attitude[1], attitude[2]
    f.render()
    bounds(f)
  end
  f.push(string.rep("W", 50), 2)
  f.render(10)
  bounds(f)
  local preview = ""
  for _, c in ipairs(f.calls) do
    if c[1] == "text" and c[4]:match("^W+$") then preview = preview .. c[4] end
  end
  check(#preview == 50, "full 50-byte preview at " .. size[1] .. "x" .. size[2])
  if size[1] >= 320 then
    local zone = {x = 10, y = 12, w = 160, h = 80}
    f.render(0, zone)
    bounds(f, zone)
    check(f.rows():find("MAV:", 1, true), "small widget full-screen prompt")
  end
end

-- Passthrough removes the dependency on FreedomTX's missing/renamed FM sensor.
f = fixture()
telemetry(f)
f.sensors.FM = nil
f.nativeFont()
local p = f.data(0x5007, 16777216 + 1, {0xF2, 2}) -- plane
f.data(0x5001, 6 + 256, p) -- FBWA, armed
f.queue = {{0x80, p}}
screen = f.render()
check(screen:find("FBWA", 1, true) and screen:find("ARMED", 1, true), "F2 mode family and explicit armed bit")
f.data(0x5004, 123 * 4 + 90 * 33554432) -- 123 m; home west => craft east
screen = f.render()
local ap = up(up(f.receive, "passthrough"), "ap")
check(ap.distance == 123 and ap.bearing == 90, "home bearing reversed to craft FROM home")
check(not screen:find("HOM", 1, true), "home distance is not duplicated in data list")
bounds(f)
local atRight, armedInverse, grey, overlay, eastMarker = false, false, false, false, false
local markerLight, markerDark = false, false
for _, c in ipairs(f.calls) do
  if c[1] == "text" and c[4] == "123m" and c[2] < 64 then overlay = true end
  if c[1] == "text" and c[4] == "ARMED" and c[2] + f.measure(c[4]) == 128 then
    atRight, armedInverse = true, c[5] == 1
  end
  if c[1] == "line" and c[6] == 8 * 65536 + 2 then grey = true end
  if c[1] == "line" and c[2] == 55 and c[3] == 52 and c[4] == 55 and c[5] == 52 then eastMarker = true end
  if c[1] == 'line' and c[2] == c[4] and c[2] >= 50 and c[2] <= 55 then
    if c[6] == 2 then markerLight = true elseif c[6] == 4 then markerDark = true end
  end
end
check(atRight and armedInverse and overlay and grey and eastMarker and markerLight and markerDark,
  "native width, inverted ARMED, grey fill, distance overlay and contrast-filled east marker")
f.sensors.Yaw.value = 1.5
f.render()
check(ap.bearing == 90, "home dial does not rotate with heading")
for _, case in ipairs({{0,180}, {30,270}, {60,0}, {90,90}}) do
  f.data(0x5004, 400 + case[1] * 33554432)
  f.render()
  check(ap.bearing == case[2], "cardinal FROM-home bearing " .. case[2])
end
f.data(0x5004, 321 * 4 + 2)
f.render()
check(ap.distance == 32100, "home decimal exponent")
f.data(0x5004, 0)
check(f.render():find("--m", 1, true), "zero home distance is not invented home lock")
f.data(0x5001, 6)
check(f.render():find("READY?", 1, true), "disarmed state without SYS_STATUS keeps readiness unknown")
f.status(true, true, false)
check(f.render():find("NOT READY", 1, true), "enabled failing MAVLink pre-arm check is not ready")
local notReadyNormal = false
for _, c in ipairs(f.calls) do
  if c[1] == 'text' and c[4] == 'NOT READY' then notReadyNormal = c[5] == 0 end
end
check(notReadyNormal, 'NOT READY is not inverted')
f.push("PreArm: GPS", 4)
check(f.render():find("NOT READY", 1, true), "prearm warning does not replace live readiness")
check(f.calls[#f.calls][1] == "text" and f.calls[#f.calls][3] == 87
  and f.calls[#f.calls][4] == "PreArm: GPS", "latest message occupies bottom nav line")
f.push("Ready to arm", 6)
check(f.render():find("NOT READY", 1, true), "ready message does not override failing SYS_STATUS")
f.status(true, true, true)
check(f.render():find("READY", 1, true), "healthy enabled MAVLink pre-arm check is ready")
local readyInverse = false
for _, c in ipairs(f.calls) do
  if c[1] == 'text' and c[4] == 'READY' then readyInverse = c[5] == 1 end
end
check(readyInverse, 'READY is inverted')
f.status(true, false, false)
check(f.render():find("READY", 1, true), "disabled arming checks follow Mission Planner readiness semantics")
f.status(false, false, false)
check(f.render():find("READY?", 1, true), "missing pre-arm capability is distinguishable")
f.status(true, true, false)
f.render()
local readyTime = ap.readyTime
f.queue = {{0xAC, {16,0,0,0,16,0,0,0,16,0,0,"bad"}}}
f.app.background()
check(ap.ready == false and ap.readyTime == readyTime, "malformed system status cannot change readiness")
f.queue = {{0xAC, {16,0,0,0,16,0,0,0,16,0,0,0,0}}}
f.app.background()
check(ap.ready == false and ap.readyTime == readyTime, "overlong system status cannot change readiness")
f.now = f.now + 301
f.data(0x5001, 6)
check(f.render():find("READY?", 1, true), "stale readiness stays unknown despite fresh disarmed state")
f.data(0x5001, 262)
f.render()
f.push('PreArm: GPS', 4)
check(f.render():find('ARMED', 1, true), 'warning text cannot override confirmed armed state')
f.data(0x5001, 6)
f.status(true, true, true)
check(f.render():find("READY", 1, true), "arm/disarm transition returns to current readiness")
f.now = f.now + 301
screen = f.render()
check(screen:find("READY?", 1, true) and screen:find("MODE --", 1, true), "AP and readiness freshness expire independently of link")
f.data(0x5007, 16777216 + 2)
f.app.background()
f.data(0x5001, 6)
check(f.render():find("LOIT", 1, true), "copter mode family")
f.data(0x5007, 16777216 + 0)
check(f.render():find("M5", 1, true), "unknown vehicle keeps numeric mode instead of guessing plane")
f.data(0x5001, 0)
check(f.render():find("M31", 1, true), "five-bit mode offset wraps at mode 31")
f.data(0x5007, 16777216 + 10)
f.app.background()
f.data(0x5001, 4)
check(f.render():find("STER", 1, true), "rover steering mode family")
local previous = ap.mode
p = f.data(0x5001, 11, {0xF2, 2})
f.data(0x5004, 999, p)
p[#p] = "bad"
f.queue = {{0x80, p}}
f.app.background()
check(ap.mode == previous, "malformed F2 is rejected before any tuple mutates state")
for _, invalid in ipairs({{0xF2, 10}, {0xF2, 0}, {0xF2, 1.5}, {0xF2, 0/0}, {0xF0, 1, 80, 1, 0, 0},
  {0xF0, 1, 80, 1, 0, 0, 256}, {0xF2, 1, 1, 80, 1, 0, 0, 0, 0}}) do
  f.queue = {{0x80, invalid}}
  f.app.background()
end
check(ap.mode == previous, "truncated, oversized and invalid-byte passthrough rejected")
-- ELRS's earlier sizeof(frame) instead of sizeof(frame.p) adds four bytes.
p = f.data(0x5007, 16777217, {0xF2,2})
f.data(0x5001, 262, p)
for _,b in ipairs({0,123,200,42}) do p[#p+1]=b end
f.queue={{0x80,p}}
check(f.render():find('ARMED',1,true), 'legacy padded ELRS F2 restores arm state')
f.now = f.now + 301
p = f.data(0x5001, 6, {0xF0})
for _,b in ipairs({0,123,200,42}) do p[#p+1]=b end
f.queue={{0x80,p}}
check(f.render():find('READY?',1,true), 'legacy padded ELRS F0 follows disarm without inventing readiness')
p[#p]='bad'
f.queue={{0x80,p}}
f.app.background()
check(ap.armed==false, 'non-byte legacy padding remains invalid')
f.rssi = 0
f.render()
f.rssi = 99
check(f.render():find("READY?", 1, true) and ap.vehicle == nil, "reconnect requires fresh state and vehicle type")

-- Real font measurement uses the full width and shrinks previews only when safe.
f = fixture()
f.nativeFont()
f.push(string.rep("iW", 25))
f.render(10)
local preview, previewLines, maxRight = "", 0, 0
for _, c in ipairs(f.calls) do
  if c[1] == "text" and c[4]:match("^[iW]+$") then
    preview, previewLines = preview .. c[4], previewLines + 1
    maxRight = math.max(maxRight, c[2] + f.measure(c[4]))
  end
end
check(#preview == 50 and previewLines == 2 and maxRight >= 123, "50-byte proportional preview fills width in two lines")
bounds(f)
f.push(string.rep("W", 50))
f.render()
preview, previewLines = "", 0
for _, c in ipairs(f.calls) do
  if c[1] == "text" and c[4]:match("^W+$") then preview, previewLines = preview .. c[4], previewLines + 1 end
end
check(#preview == 50 and previewLines == 3, "wide glyphs keep three preview rows without dropping text")

-- Retained heap must plateau under sustained traffic, including navigation.
f = fixture()
telemetry(f)
f.quiet = true
local function soak(cycles)
  for i = 1, cycles do
    f.push("Soak " .. i .. string.rep("!", 35), i % 8)
    f.render(i % 17 == 0 and 10 or 12)
  end
  for i = 1, 4 do collectgarbage("collect") end
  return collectgarbage("count")
end
soak(500)
local before = soak(5000)
local after = soak(20000)
check(after - before < 3, "retained heap plateau (<3 KiB growth)")
check(f.state("count") == 20, "soak retains only twenty entries")
f = fixture()
for i = 1, 1100 do f.push("Repeated warning", 4) f.app.background() end
check(f.state("count") == 1 and f.state("history")[1].repeats == 999, "duplicate count saturates")

-- Geometric attitude semantics: level, nose up, and right bank.
f = fixture()
telemetry(f)
f.sensors.Ptch.value, f.sensors.Roll.value = 0, 0
f.render()
local nav = up(f.app.run, "navigation")
local ball = up(nav, "ball")
local function hasLine(x1, y1, x2, y2)
  for _, c in ipairs(f.calls) do
    if c[1] == "line" and c[2] == x1 and c[3] == y1 and c[4] == x2 and c[5] == y2 then return true end
  end
end
f.calls = {}
ball(30, 45, 20)
check(hasLine(11, 45, 49, 45), "level horizon crosses instrument center")
f.sensors.Ptch.value = math.pi / 8
f.render()
f.calls = {}
ball(30, 45, 20)
check(hasLine(14, 55, 46, 55), "positive pitch moves horizon down")
f.sensors.Ptch.value, f.sensors.Roll.value = 0, math.pi / 2
f.render()
f.calls = {}
ball(30, 45, 20)
check(hasLine(30, 64, 30, 26), "right bank rotates horizon counterclockwise")
f = fixture()
telemetry(f)
f.quiet = true
for i = 1, 8 do f.push(string.rep("W", 49) .. i, 4) end
local instructions = 0
debug.sethook(function() instructions = instructions + 100 end, "", 100)
f.app.run(0)
debug.sethook()
print("Worst-case queued burst: ~" .. instructions .. " instructions")
check(instructions < 9000 and #f.queue == 7, "burst plus drawing fits permanent-script instruction limit")
-- Full history and extreme instrument attitudes must also respect the budget.
for _, size in ipairs({{128,64}, {128,96}, {212,64}, {320,240}, {480,272}, {800,480}}) do
  f = fixture(size[1], size[2])
  telemetry(f)
  f.sensors.Ptch.value, f.sensors.Roll.value = -math.pi / 2, math.pi / 2
  f.quiet = true
  for i = 1, 20 do f.push(string.rep("W", 48) .. i, 4) f.app.background() end
  for page = 1, 2 do
    f.queue = {}
    for i = 1, 8 do f.push(string.rep("W", 49) .. i, 4) end
    instructions = 0
    debug.sethook(function() instructions = instructions + 100 end, "", 100)
    f.app.run(page == 2 and 10 or 0)
    debug.sethook()
    check(instructions < 10000, "callback budget at " .. size[1] .. "x" .. size[2] .. " page " .. page .. ": " .. instructions)
  end
end
-- Tango cursor-only font API + solid grey, live home, and maximum F2 packet.
f = fixture()
telemetry(f)
f.sensors.FM = nil
f.nativeFont()
f.quiet = true
f.data(0x5007, 16777217)
f.app.background()
f.data(0x5001, 262)
f.app.background()
f.data(0x5004, 492 + 90 * 33554432)
f.app.background()
for i = 1, 20 do f.push(string.rep("W", 49) .. i, 4) f.app.background() end
local tangoMax = 0
for _, attitude in ipairs({{0,0}, {0.5,0.7}, {-1.57,0}, {-1.57,1.57}}) do
  f.sensors.Ptch.value, f.sensors.Roll.value = attitude[1], attitude[2]
  for page = 1, 2 do
    for _, kind in ipairs({"text", "multi"}) do
      f.queue = {}
      if kind == "text" then f.push(string.rep("W", 50), 4) else
        local p = {0xF2, 9}
        for i = 1, 9 do f.data(0x5004, 492 + 90 * 33554432, p) end
        f.queue = {{0x80, p}}
      end
      f.now = f.now + 10
      f.control(11)
      if page == 2 then f.control(10) end
      instructions = 0
      -- Firmware APIs are C functions. Exclude Lua mock internals here so the
      -- cursor/font simulator is not charged to the radio script's budget.
      debug.sethook(function()
        if debug.getinfo(2, "S").source == "@" .. source then instructions = instructions + 1 end
      end, "", 1)
      f.app.run(0)
      debug.sethook()
      tangoMax = math.max(tangoMax, instructions)
      check(instructions < 10000, "Tango grey/cursor budget " .. page .. " " .. kind .. ": " .. instructions)
    end
  end
end
f = fixture()
telemetry(f)
f.nativeFont()
f.quiet = true
f.sensors.Ptch.value, f.sensors.Roll.value = -1.57, 0
f.push(string.rep("W", 50), 4)
instructions = 0
debug.sethook(function()
  if debug.getinfo(2, "S").source == "@" .. source then instructions = instructions + 1 end
end, "", 1)
f.app.run(0)
debug.sethook()
check(instructions < 10000, "first Tango callback with sensor discovery and grey fill: " .. instructions)
tangoMax = math.max(tangoMax, instructions)
print("Tango grey/cursor worst callback: ~" .. tangoMax .. " instructions")
print(string.format("PASS: %d assertions; 25,500-cycle soak heap delta %.2f KiB", tests, after - before))
