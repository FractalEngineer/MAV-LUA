-- SPDX-License-Identifier: GPL-3.0-or-later
-- MAV-LUA: small, read-only MAVLink-over-CRSF telemetry display.
-- Firmware owns standard CRSF sensors; this script alone consumes custom frames.
-- No table/bit32 library, modules, bitmaps, or growing caches on the radio.

local history, head, count, selected, unread
local page, sensorIds, sensorUnits, discoveryAt, nextSample, values, linked
local ap
local LIMIT = 20
local names = {"Ptch", "Roll", "Yaw", "RxBt", "Sats", "FM", "RQly", "GSpd", "GAlt", "Curr"}
local severityNames = "EMRALRCRTERRWRNNOTINFDBG"

local function finite(v)
  return type(v) == "number" and v == v and v > -1e20 and v < 1e20
end

local function entry(offset)
  return history[(head - offset - 1) % LIMIT + 1]
end

local function fresh(time, now, age)
  return time ~= nil and now >= time and now - time <= age
end

-- ArduPilot passthrough: packed 16-bit ID / 32-bit value, little endian.
local function passthrough(p, now)
  local first, last = 2, 7
  if p[1] == 0xF2 then
    if not finite(p[2]) or p[2] < 1 or p[2] > 9 or p[2] % 1 ~= 0 then return end
    first, last = 3, 2 + p[2] * 6
  end
  if #p ~= last then return end
  for i = first, last do
    local b = p[i]
    if not finite(b) or b < 0 or b > 255 or b % 1 ~= 0 then return end
  end
  for i = first, last, 6 do
    local id = p[i] + p[i + 1] * 256
    -- Decode separate byte fields: Lua 5.3 on EdgeTX uses int32/float32,
    -- so assembling an unsigned uint32 would overflow or lose its low bits.
    local low, high = p[i + 2] + p[i + 3] * 256, p[i + 5]
    if id == 0x5001 then
      local armed = p[i + 3] % 2 == 1
      if ap.armed ~= armed then ap.readyTime = nil end
      ap.armed, ap.mode, ap.statusTime = armed, (low % 32 - 1) % 32, now
    elseif id == 0x5007 and high == 1 then
      ap.vehicle = low + p[i + 4] * 65536
    elseif id == 0x5004 then
      ap.distance = math.floor(low / 4) % 1024 * 10 ^ (low % 4)
      -- Wire bearing points TO home; this north-up dial locates the craft FROM home.
      local bearing = math.floor(high / 2) * 3
      ap.bearing = bearing < 360 and (bearing + 180) % 360 or nil
      -- Zero distance is ambiguous when ELRS has not received HOME_POSITION.
      ap.homeTime = ap.distance > 0 and now or nil
    end
  end
end

local function receive(command, p, now)
  if (command ~= 0x80 and command ~= 0x7F) or type(p) ~= "table"
    then return end
  if p[1] == 0xF0 or p[1] == 0xF2 then passthrough(p, now) return end
  if p[1] ~= 0xF1 or #p < 3 then return end
  local severity = p[2]
  if not finite(severity) or severity < 0 or severity > 255 or severity % 1 ~= 0 then return end
  local last = math.min(#p, 52)
  for i = 3, last do
    local b = p[i]
    if b == 0 then last = i - 1 break end
    if not finite(b) or b < 0 or b > 255 or b % 1 ~= 0 then return end
  end
  if last < 3 then return end
  local text = ""
  for i = 3, last do
    local b = p[i]
    text = text .. string.char(b >= 32 and b <= 126 and b or 32)
  end
  if not string.find(text, "[^ ]") then return end
  if string.sub(text, 1, 7) == "PreArm:" then
    ap.ready, ap.readyTime = false, now
  elseif text == "Ready to arm" then
    ap.ready, ap.readyTime = true, now
  end
  local latest = count > 0 and entry(0)
  if latest and latest.text == text and latest.severity == severity
    and now >= latest.time and now - latest.time <= 300 then
    latest.time = now
    latest.repeats = math.min(latest.repeats + 1, 999)
    return
  end
  head = head % LIMIT + 1
  local item = history[head] or {}
  item.text, item.severity, item.time, item.repeats = text, severity, now, 1
  history[head] = item
  count = math.min(count + 1, LIMIT)
  -- Preserve the item being read as newer messages arrive (until eviction).
  if page == 2 and selected > 0 then selected = math.min(selected + 1, count - 1) end
  if page == 1 or selected > 0 then unread = math.min(unread + 1, LIMIT) end
end

local function sample(now)
  if nextSample and now >= nextSample and now - nextSample < 10 then return end
  nextSample = now
  if not discoveryAt or now < discoveryAt or now - discoveryAt >= 100 then
    discoveryAt = now
    if getFieldInfo then
      for i = 1, #names do
        if not sensorIds[i] then
          local info = getFieldInfo(names[i])
          if not info and i == 4 then info = getFieldInfo("BtRx") end
          if not info and i == 9 then info = getFieldInfo("Alt") end
          if info then sensorIds[i], sensorUnits[i] = info.id, info.unit end
        end
      end
    end
  end
  linked = getRSSI ~= nil and (getRSSI() or 0) > 0
  if not linked then
    ap.statusTime, ap.homeTime, ap.readyTime, ap.vehicle = nil, nil, nil, nil
  end
  for i = 1, #names do
    local value, valid
    if linked and sensorIds[i] then
      if getSourceValue then
        value, valid = getSourceValue(sensorIds[i])
      elseif getValue then
        value = getValue(sensorIds[i])
      end
    end
    if valid == false then value = nil end
    if i == 6 then
      values[i] = type(value) == "string" and string.find(value, "[^ ]") and string.sub(value, 1, 16) or nil
    else
      values[i] = finite(value) and value or nil
    end
  end
end

local function background()
  local now = getTime()
  if crossfireTelemetryPop then
    for i = 1, 8 do
      local command, payload = crossfireTelemetryPop()
      if command == nil then break end
      receive(command, payload, now)
      -- One custom candidate leaves room for grey fill and proportional wrapping
      -- inside the permanent-script 10k instruction budget, including bad packets.
      if command == 0x80 or command == 0x7F then break end
    end
  end
  sample(now)
end

local function init()
  history, head, count, selected, unread = {}, 0, 0, 0, 0
  page, sensorIds, sensorUnits, values, linked = 1, {}, {}, {}, false
  discoveryAt, nextSample = nil, nil
  ap = {}
end

local function controls(event)
  if not event or event == 0 then return end
  if event == EVT_VIRTUAL_ENTER or event == EVT_ENTER_BREAK or event == EVT_ROT_BREAK then
    page = page == 1 and 2 or 1
    selected, unread = 0, 0
  elseif event == EVT_VIRTUAL_EXIT or event == EVT_EXIT_BREAK then
    page, selected = 1, 0
  elseif page == 2 then
    if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_NEXT_REPT
      or event == EVT_ROT_RIGHT or event == EVT_PLUS_FIRST or event == EVT_PLUS_REPT
      or event == EVT_DOWN_FIRST or event == EVT_DOWN_REPT then
      selected = math.min(selected + 1, math.max(0, count - 1))
    elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_PREV_REPT
      or event == EVT_ROT_LEFT or event == EVT_MINUS_FIRST or event == EVT_MINUS_REPT
      or event == EVT_UP_FIRST or event == EVT_UP_REPT then
      selected = math.max(selected - 1, 0)
    end
    if selected == 0 then unread = 0 end
  end
end

-- Drawing accepts a zone for color widgets; telemetry scripts use the whole LCD.
-- All text is bounded before drawing, including unknown flight-mode strings.
local ox, oy, width, height, step, charWidth, ink, color
local function textWidth(s)
  local measured
  if lcd.getTextWidth then
    measured = lcd.getTextWidth(0, s)
  elseif not color and lcd.getLastRightPos then
    -- FreedomTX has proportional glyphs but no Lua getTextWidth. Drawing below
    -- the physical LCD advances its cursor without touching visible pixels.
    lcd.drawText(0, LCD_H + 1, s, 0)
    measured = lcd.getLastRightPos()
  end
  -- FreedomTX 1.40 loses the return from a no-argument C tail call. Keep
  -- CALL + RETURN here; never use `return lcd.getLastRightPos()`.
  return measured or #s * charWidth
end

local function fit(s, pixels)
  if not lcd.getTextWidth and not lcd.getLastRightPos then
    return string.sub(s, 1, math.max(0, math.floor(pixels / charWidth)))
  end
  if textWidth(s) <= pixels then return s end
  local low, high = 0, #s
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if textWidth(string.sub(s, 1, middle)) <= pixels then low = middle else high = middle - 1 end
  end
  return string.sub(s, 1, low)
end

local function drawText(x, y, s, inverse)
  if y < 0 or y + step - 1 > height then return end
  if color then lcd.setColor(CUSTOM_COLOR, WHITE) end
  lcd.drawText(ox + x, oy + y, s, ink + (inverse and (INVERS or 0) or 0))
end

local function text(x, y, s, inverse, maxWidth)
  drawText(x, y, fit(s, math.min(maxWidth or width - x, width - x)), inverse)
end

local function line(x1, y1, x2, y2)
  if color then lcd.setColor(CUSTOM_COLOR, WHITE) end
  local flags = ink + (not color and (FORCE or 0) or 0)
  lcd.drawLine(ox + math.floor(x1 + 0.5), oy + math.floor(y1 + 0.5),
    ox + math.floor(x2 + 0.5), oy + math.floor(y2 + 0.5), SOLID or 0, flags)
end

local function number(v, fmt)
  return v ~= nil and string.format(fmt or "%.0f", v) or "--"
end

local function ball(cx, cy, radius)
  local px, py = cx + radius, cy
  for i = 1, 24 do
    local a = i * math.pi / 12
    local x, y = cx + radius * math.cos(a), cy + radius * math.sin(a)
    line(px, py, x, y)
    px, py = x, y
  end
  local pitch, roll = values[1], values[2]
  if not pitch or not roll then
    line(cx - radius * 0.6, cy - radius * 0.6, cx + radius * 0.6, cy + radius * 0.6)
    line(cx - radius * 0.6, cy + radius * 0.6, cx + radius * 0.6, cy - radius * 0.6)
    return
  end
  -- CRSF attitude is radians. ArduPilot/ELRS positive pitch is nose up.
  local sr, cr = math.sin(roll), math.cos(roll)
  local offset = pitch * radius / (math.pi / 4)
  -- Solid grey ground on Tango; spaced scanlines on one-bit LCDs.
  local greyType = type(GREY)
  local shade = (greyType == "function" or greyType == "lightfunction") and GREY(8) or nil
  local stride = color and 2 or shade and 1 or 3
  local groundInk = ink + (not color and (FORCE or 0) or 0)
  if shade then groundInk = groundInk + shade end
  if color then lcd.setColor(CUSTOM_COLOR, lcd.RGB(100, 100, 100)) end
  for y = -radius + 1, radius - 1, stride do
    local half = math.sqrt(radius * radius - y * y) - 1
    local left, right = -half, half
    if math.abs(sr) < 0.001 then
      if cr * y <= offset then right = left - 1 end
    elseif sr > 0 then
      left = math.max(left, (offset - cr * y) / sr)
    else
      right = math.min(right, (offset - cr * y) / sr)
    end
    if left <= right then
      local x1, x2 = math.floor(cx + left + 0.5), math.floor(cx + right + 0.5)
      if color then
        lcd.drawFilledRectangle(ox + x1, oy + cy + y, x2 - x1 + 1, 2, groundInk)
      else
        lcd.drawLine(ox + x1, oy + cy + y, ox + x2, oy + cy + y, SOLID or 0, groundInk)
      end
    end
  end
  -- Horizon plus +/- 10 and 20 degree pitch ladder, no off-screen primitives.
  for mark = -2, 2 do
    local d = offset - mark * math.pi / 18 * radius / (math.pi / 4)
    if math.abs(d) < radius - 1 then
      local half = math.sqrt(radius * radius - d * d) - 1
      if mark ~= 0 then half = math.min(half, radius * 0.32) end
      line(cx + sr * d - cr * half, cy + cr * d + sr * half,
        cx + sr * d + cr * half, cy + cr * d - sr * half)
    end
  end
  -- Fixed aircraft reference and top index stay independent of attitude.
  line(cx - radius * 0.55, cy, cx - radius * 0.15, cy)
  line(cx + radius * 0.15, cy, cx + radius * 0.55, cy)
  line(cx - radius * 0.15, cy, cx, cy + 3)
  line(cx, cy + 3, cx + radius * 0.15, cy)
  line(cx, cy - radius, cx, cy - radius + 3)
end

local function flightMode(now)
  if values[6] then return values[6] end
  if not fresh(ap.statusTime, now, 300) then return "MODE --" end
  local v, modes = ap.vehicle
  -- Four-character slots keep the lookup small; blanks are unknown mode IDs.
  if v == 1 or (v and v >= 19 and v <= 25) then
    modes = "MANUCIRCSTABTRANACROFBWAFBWBCRUSATUN    AUTORTL LOITTKOFAVOIGUIDINITQSTBQHOVQLOTQLNDQRTLQATNQACOTHMLL2QL"
  elseif v == 2 or v == 3 or v == 4 or v == 13 or v == 14 or v == 15 or v == 29 or v == 35 then
    modes = "STABACROALTHAUTOGUIDLOITRTL CIRC    LAND    DRIF    SPRTFLIPATUNPHLDBRAKTHRWAVOIGNGPSRTLFHLDFOLLZIGZSYSIAROTARTLTRTL"
  elseif v == 10 or v == 11 then
    modes = "MANUACRO    STERHOLDLOITFOLLSMPLDOCK    AUTORTL SRTL        GUIDINIT"
  end
  local label = modes and string.sub(modes, ap.mode * 4 + 1, ap.mode * 4 + 4)
  return label and string.find(label, "[^ ]") and label or "M" .. ap.mode
end

local function rightText(y, s, left)
  s = fit(s, width - (left or 0))
  drawText(width - textWidth(s), y, s)
end

local function navValue(x, y, label, value)
  drawText(x, y, label)
  rightText(y, value, x + textWidth(label) + 2)
end

local function navigation()
  local now, state = getTime(), "ARM?"
  if linked and fresh(ap.statusTime, now, 300) then
    state = ap.armed and "ARMD" or "RDY?"
    if not ap.armed and fresh(ap.readyTime, now, 1000) then state = ap.ready and "RDY" or "!RDY" end
  end
  text(0, 0, linked and flightMode(now) or "NO LINK", true, width - textWidth(state) - 3)
  rightText(0, state)
  text(0, step, number(values[4], "%.1f") .. "V")
  rightText(step, "LQ " .. number(values[7]) .. "%", math.floor(width / 2))
  local top, bottom = step * 2 + 1, height - step - 2
  local column = math.floor(width * 0.50)
  local cx, cy = math.floor(column / 2), math.floor((top + bottom) / 2)
  local margin = height >= step * 9 and step or 0
  local radius = math.max(3, math.min(40, math.floor((bottom - top - margin * 2) / 2), math.floor(column / 2) - charWidth - 3))
  ball(cx, cy, radius)
  text(cx - math.floor(textWidth("N") / 2), cy - radius - margin, "N")
  text(cx - math.floor(textWidth("S") / 2), cy + radius + 1 - step + margin, "S")
  text(cx - radius - textWidth("W") - 2, cy - math.floor(step / 2), "W")
  text(cx + radius + 2, cy - math.floor(step / 2), "E")
  local distance = linked and fresh(ap.homeTime, now, 300) and ap.distance or nil
  if distance and distance >= 2 and ap.bearing then
    local a = ap.bearing * math.pi / 180
    local dx, dy = math.sin(a), -math.cos(a)
    local x, y = cx + dx * radius, cy + dy * radius
    -- Inward chevron, independent of aircraft yaw and the attitude horizon.
    line(x, y, x - dx * 5 + dy * 3, y - dy * 5 - dx * 3)
    line(x, y, x - dx * 5 - dy * 3, y - dy * 5 + dx * 3)
  end
  local home = distance and (distance >= 1000 and number(distance / 1000, "%.1f") .. "k" or number(distance) .. "m") or "--m"
  -- Distance sits above the fixed aircraft reference, leaving the wings visible.
  local overlay = fit(home, radius * 2 - 2)
  text(cx - math.floor(textWidth(overlay) / 2), cy - step, overlay, true)
  local sats = values[5]
  if sats == 255 then sats = nil end
  navValue(column, top, "SAT", number(sats))
  local altUnit = sensorUnits[9] == 10 and "ft" or "m"
  local speedUnit = sensorUnits[8] == 8 and "mph" or sensorUnits[8] == 4 and "kt"
    or sensorUnits[8] == 5 and "m/s" or sensorUnits[8] == 6 and "ft/s" or "km/h"
  navValue(column, top + step, "ALT", number(values[9]) .. altUnit)
  navValue(column, top + step * 2, "HOM", home)
  if top + step * 4 <= bottom then
    navValue(column, top + step * 3, "GS", number(values[8]) .. speedUnit)
  end
  if top + step * 5 <= bottom then
    local heading = values[3] and (values[3] * 180 / math.pi) % 360
    navValue(column, top + step * 4, "HDG", number(heading))
  end
  if top + step * 6 <= bottom then navValue(column, top + step * 5, "I", number(values[10], "%.1f") .. "A") end
  line(0, height - step - 1, width - 1, height - step - 1)
  text(0, height - step, count > 0 and entry(0).text or "No messages")
end

local function messages()
  local position = (count > 0 and selected + 1 or 0) .. "/" .. count
    .. (unread > 0 and " +" .. unread or "")
  local positionX = width - textWidth(position)
  text(0, 0, "MESSAGES", true, positionX - charWidth)
  text(positionX, 0, position)
  if count == 0 then
    text(0, step * 2, "No messages")
    text(0, step * 3, crossfireTelemetryPop and "Waiting for status" or "CRSF API missing")
  else
    -- Measure actual selected text: Tango's proportional font often saves a row.
    local remaining, previewRows = entry(selected).text, 0
    while #remaining > 0 do
      local part = fit(remaining, width)
      remaining = string.sub(remaining, math.max(1, #part) + 1)
      previewRows = previewRows + 1
    end
    local rows = math.max(1, math.floor(height / step) - previewRows - 1)
    local first = math.max(0, selected - rows + 1)
    for row = 0, math.min(rows, count - first) - 1 do
      local offset = first + row
      local item = entry(offset)
      local sev = item.severity <= 7 and string.sub(severityNames, item.severity * 3 + 1, item.severity * 3 + 3) or "UNK"
      local label = (item.severity <= 3 and "!" or " ") .. sev
      if item.repeats > 1 then label = label .. "x" .. item.repeats end
      text(0, (row + 1) * step, label .. " " .. item.text, offset == selected)
    end
    local y = (rows + 1) * step
    line(0, y - 1, width - 1, y - 1)
    remaining = entry(selected).text
    for row = 0, previewRows - 1 do
      local part = fit(remaining, width)
      text(0, y + row * step, part)
      remaining = string.sub(remaining, #part + 1)
    end
  end
end

local function run(event, zone)
  background()
  controls(event)
  ox, oy = zone and zone.x or 0, zone and zone.y or 0
  width, height = zone and zone.w or LCD_W, zone and zone.h or LCD_H
  color = LCD_W >= 480 or (lcd.RGB ~= nil and CUSTOM_COLOR ~= nil)
  -- Bound visible color rows as screens grow, leaving CPU for telemetry bursts.
  step = color and math.max(20, math.ceil(height / 16)) or 9
  charWidth, ink = color and 16 or 6, color and CUSTOM_COLOR or 0
  if color then
    lcd.setColor(CUSTOM_COLOR, BLACK)
    lcd.drawFilledRectangle(ox, oy, width, height, CUSTOM_COLOR)
  else
    lcd.clear()
  end
  if width < (color and 256 or 128) or height < (color and 160 or 64) then
    text(0, 0, "MAV: full screen")
  elseif page == 1 then navigation() else messages() end
  return 0
end

return {init = init, background = background, run = run}
