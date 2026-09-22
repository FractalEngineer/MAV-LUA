-- The Tools entry must take over the screen and must fail loudly rather than silently.
--
-- Two defects this guards against, both found on hardware:
--   1. A Tools script draws over whatever is already on screen. Without clearing first, the
--      previous menu stayed visible underneath the tool's own text.
--   2. The builder wrote its index into SCRIPTS/MAV/DB, a directory that only existed because
--      the packaged databases created it. When those were deleted the first write failed and
--      the tool reported a bare "Index build failed" with no explanation.
--
-- The screen is checked through a recorder, so the assertions are about what would actually be
-- drawn rather than about the source text.
local root = arg[1] or 'src'
-- The tool reads these as globals, exactly as it does on the radio.
LCD_W, LCD_H, INVERS = 128, 64, 1
BLACK, CUSTOM_COLOR = 0, 1

local ntests = 0
local function check(condition, message)
  assert(condition, message)
  ntests = ntests + 1
end

local drawn, cleared, filled
local function install(colorPresent)
  drawn, cleared, filled = {}, 0, 0
  local view = {
    drawText = function(x, y, value, flags)
      drawn[#drawn + 1] = {x = x, y = y, text = value, flags = flags or 0}
    end,
    drawLine = function() end,
  }
  if colorPresent then
    view.RGB = function() return 0 end
    view.setColor = function() end
    view.drawFilledRectangle = function() filled = filled + 1 end
  else
    -- Only a monochrome screen exposes clear(); a colour one is painted with a fill.
    view.clear = function() cleared = cleared + 1 end
  end
  _G.lcd = view
end

-- A bridge that never answers keeps the tool in its searching phase, which is all the screen
-- test needs. Modules load from source so no shipped cache is required.
getTime = function() return 0 end
crossfireTelemetryPush = function() return true end
crossfireTelemetryPop = function() return nil end
loadScript = function(path)
  -- The tool asks for the compiled cache first, exactly as it does on the radio. A shipped
  -- package has one; this host test does not, so a missing cache must fall back to source.
  if path:sub(-5) == '.luac' then return nil end
  return loadfile(root .. path)
end

local function openTool()
  return assert(loadfile(root .. '/SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua'))()
end

-- Monochrome: clearing is what removes the previous menu.
do
  install(false)
  local tool = openTool()
  tool.init()
  tool.run(0)
  check(cleared > 0, 'a monochrome tool must clear the screen before drawing')
  check(#drawn >= 3, 'the tool draws a title, a detail line and a hint')
  local texts = {}
  for _, item in ipairs(drawn) do
    texts[item.text] = true
    check(item.y >= 0 and item.y < LCD_H, 'every row is inside the screen: ' .. tostring(item.y))
  end
  check(texts['MAV index'], 'the title is drawn')
  check(texts['Searching for vehicle...'], 'the current phase is reported')
  check(texts['EXIT: close'], 'the exit hint is drawn')
end

-- Colour: the screen is filled, because a colour radio has no clear().
do
  LCD_W, LCD_H = 480, 272
  install(true)
  local tool = openTool()
  tool.init()
  tool.run(0)
  check(filled > 0, 'a colour tool must fill the screen before drawing')
  check(#drawn >= 3, 'the colour tool draws the same three lines')
  for _, item in ipairs(drawn) do
    check(item.y >= 0 and item.y < LCD_H, 'every colour row is inside the screen: ' .. item.y)
  end
  LCD_W, LCD_H = 128, 64
end

-- A missing module must be reported, not swallowed, so the pilot sees why nothing happened.
do
  install(false)
  local saved = loadScript
  loadScript = function() return nil end
  local tool = openTool()
  tool.init()
  local phase, reason = tool.status()
  check(phase == 'failed', 'a missing module fails the tool: ' .. tostring(phase))
  check(type(reason) == 'string' and #reason > 0, 'the failure carries a reason')
  loadScript = saved
end

-- The index key must be a flat identity filename in the modules folder, never a subdirectory,
-- because EdgeTX's io cannot create one and FatFs will not create a missing parent.
do
  local file = assert(io.open(root .. '/SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.lua', 'r'))
  local text = file:read('a')
  file:close()
  check(text:find("string.format('i%02d%02d%s'", 1, true) ~= nil,
    'the tool builds a flat identity index name')
  check(text:find('DB/', 1, true) == nil, 'the index key has no subdirectory')
  -- The page must look in exactly the same place, or a build would appear to do nothing.
  local page = assert(io.open(root .. '/SCRIPTS/MAV/params.lua', 'r'))
  local pageText = page:read('a')
  page:close()
  check(pageText:find("string.format('i%02d%02d%s'", 1, true) ~= nil,
    'the page looks for the same flat identity name')
  check(pageText:find('DB/', 1, true) == nil, 'the page has no subdirectory in its index key')
end

print(string.format('PASS: Tools screen clears and reports failure (%d checks)', ntests))
