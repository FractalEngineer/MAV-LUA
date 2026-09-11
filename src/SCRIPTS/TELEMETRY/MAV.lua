-- SPDX-License-Identifier: GPL-3.0-or-later
-- MAV-LUA: small, read-only MAVLink-over-CRSF telemetry display.
-- Firmware owns standard CRSF sensors; this script alone consumes custom frames.
-- No table/bit32 library, modules, bitmaps, or growing caches on the radio.

local history, head, count, selected, unread
local page, sensorIds, sensorUnits, discoveryAt, nextSample, values, linked
local LIMIT = 20
local names = {"Ptch", "Roll", "Yaw", "RxBt", "Sats", "FM", "RQly", "GSpd", "GAlt", "Curr"}
local severityNames = "EMRALRCRTERRWRNNOTINFDBG"

local function finite(v)
  return type(v) == "number" and v == v and v > -1e20 and v < 1e20
end

local function entry(offset)
  return history[(head - offset - 1) % LIMIT + 1]
end

local function receive(command, p, now)
  if (command ~= 0x80 and command ~= 0x7F) or type(p) ~= "table"
    or p[1] ~= 0xF1 or #p < 3 then return end
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
      values[i] = type(value) == "string" and string.sub(value, 1, 16) or nil
    else
      values[i] = finite(value) and value or nil
    end
  end
end

local function background()
  local now = getTime()
  if crossfireTelemetryPop then
    local statusFrames = 0
    for i = 1, 8 do
      local command, payload = crossfireTelemetryPop()
      if command == nil then break end
      receive(command, payload, now)
      -- Full text validation/formatting costs more than ignored passthrough.
      -- Leave headroom for drawing within OpenTX's 10k instruction callback.
      if (command == 0x80 or command == 0x7F) and type(payload) == "table" and payload[1] == 0xF1 then
        statusFrames = statusFrames + 1
        if statusFrames == 2 then break end
      end
    end
  end
  sample(now)
end

local function init()
  history, head, count, selected, unread = {}, 0, 0, 0, 0
  page, sensorIds, sensorUnits, values, linked = 1, {}, {}, {}, false
  discoveryAt, nextSample = nil, nil
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
  if lcd.getTextWidth then return lcd.getTextWidth(0, s) end
  return #s * charWidth
end

local function fit(s, pixels)
  if not lcd.getTextWidth then return string.sub(s, 1, math.max(0, math.floor(pixels / charWidth))) end
  if textWidth(s) <= pixels then return s end
  local low, high = 0, #s
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if textWidth(string.sub(s, 1, middle)) <= pixels then low = middle else high = middle - 1 end
  end
  return string.sub(s, 1, low)
end

local function text(x, y, s, inverse, maxWidth)
  if y < 0 or y + step - 1 > height then return end
  s = fit(s, math.min(maxWidth or width - x, width - x))
  if color then lcd.setColor(CUSTOM_COLOR, WHITE) end
  lcd.drawText(ox + x, oy + y, s, ink + (inverse and (INVERS or 0) or 0))
end

local function line(x1, y1, x2, y2)
  if color then lcd.setColor(CUSTOM_COLOR, WHITE) end
  lcd.drawLine(ox + math.floor(x1 + 0.5), oy + math.floor(y1 + 0.5),
    ox + math.floor(x2 + 0.5), oy + math.floor(y2 + 0.5), SOLID or 0, ink)
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
  -- Sparse ground hatching, clipped to the circular instrument at any bank.
  for d = -radius + 2, radius - 2, math.max(3, math.floor(radius / 7)) do
    if d > offset then
      local half = math.sqrt(radius * radius - d * d) - 1
      line(cx + sr * d - cr * half, cy + cr * d + sr * half,
        cx + sr * d + cr * half, cy + cr * d - sr * half)
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

local function navigation()
  text(0, 0, "NAV" .. (unread > 0 and " +" .. unread or ""), true, width / 3)
  text(math.floor(width / 3), 0, linked and (values[6] or "MODE --") or "NO LINK")
  text(0, step, number(values[4], "%.1f") .. "V")
  text(math.floor(width / 2), step, "LQ " .. number(values[7]) .. "%")
  local top, bottom = step * 2 + 1, height - 2
  local column = math.floor(width * 0.48)
  local radius = math.max(3, math.min(math.floor((bottom - top) / 2), math.floor(column / 2) - 3))
  ball(math.floor(column / 2), math.floor((top + bottom) / 2), radius)
  local sats = values[5]
  if sats == 255 then sats = nil end
  text(column, top, "SAT " .. number(sats))
  local altUnit = sensorUnits[9] == 10 and "ft" or "m"
  local speedUnit = sensorUnits[8] == 8 and "mph" or sensorUnits[8] == 4 and "kt"
    or sensorUnits[8] == 5 and "m/s" or sensorUnits[8] == 6 and "ft/s" or "km/h"
  text(column, top + step, "ALT " .. number(values[9]) .. altUnit)
  text(column, top + step * 2, "GS " .. number(values[8]) .. speedUnit)
  if top + step * 4 <= bottom then
    local heading = values[3] and (values[3] * 180 / math.pi) % 360
    text(column, top + step * 3, "HDG " .. number(heading))
  end
  if top + step * 5 <= bottom then text(column, top + step * 4, "I " .. number(values[10], "%.1f") .. "A") end
  if top + step * 6 <= bottom then text(column, top + step * 5, "P " .. number(values[1] and values[1] * 180 / math.pi)) end
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
    -- 50 bytes always fit in the wrapped preview, even on 128x64.
    local columns = math.max(1, math.floor((width - 2) / charWidth))
    local previewRows = math.ceil(50 / columns)
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
    local remaining = entry(selected).text
    for row = 0, previewRows - 1 do
      local part = fit(string.sub(remaining, 1, columns), width - 2)
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
