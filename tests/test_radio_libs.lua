-- Reproduce two classes of radio failure that the desktop cannot show.
--
-- 1. MISSING LIBRARIES. EdgeTX registers some libraries only for colour radios. From the
--    firmware's linit.c, `table` is inside `#if defined(COLORLCD)`, so on a monochrome radio
--    `table` is nil and any call to it raises "attempt to index a nil value (global 'table')".
--    Host Lua always has every library, so a host test cannot detect this unless it runs the
--    module against a deliberately reduced environment.
--
-- 2. COLON METHOD CALLS. EdgeTX gives strings no metatable `__index`, so `s:find(...)` raises
--    "attempt to index a string value" on the radio while working perfectly on the desktop.
--    Every shipped module calls the library form, `string.find(s, ...)`, and none contains a
--    single colon call. A heap probe added later used `path:find('index')` and crashed on its
--    first module on hardware; the library check could not see it, because the callee of a colon
--    call is a variable rather than a library. This test closes that gap too.
--
-- Run with Lua 5.3: .build/lua53 tests/test_radio_libs.lua [package-root]
local root = arg[1] or 'src'
-- Every file the radio loads. Diagnostics in tools/diag are held to the same rule as shipped
-- code: they are harder to re-test on a radio, so a convention break costs more there, not less.
local modules = {
  {name = 'wire', dir = 'MAV'}, {name = 'pdb', dir = 'MAV'},
  {name = 'pview', dir = 'MAV'}, {name = 'pinput', dir = 'MAV'},
  {name = 'params', dir = 'MAV'},
  {name = 'MAV', dir = 'TELEMETRY'},
  {name = 'MAV', dir = 'TOOLS'},
  -- The widget is the one shipped module outside SCRIPTS, so its path is given in full.
  {path = 'src/WIDGETS/MAV/main.lua'},
  {path = 'tools/diag/MAVHEAP.lua'},
}

-- The globals EdgeTX provides on a monochrome radio, from linit.c's rotables table.
-- `table` and `lvgl` are colour-only; `bit32` is always present in 2.11.
local radioGlobals = {
  assert = true, error = true, ipairs = true, math = true, next = true, pairs = true,
  pcall = true, select = true, string = true, tonumber = true, tostring = true, type = true,
  bit32 = true, io = true, lcd = true, model = true, getValue = true, getFieldInfo = true,
  getTime = true, killEvents = true, loadScript = true, crossfireTelemetryPop = true,
  crossfireTelemetryPush = true, collectgarbage = true, string_pack = true,
}

-- Finds real library references, ignoring comments and string literals. A false positive here
-- would be worse than no probe at all, because it would train the reader to ignore it: comments
-- in these modules deliberately name `table.sort` and `table.concat` to explain why they are
-- avoided, and those must not be reported as uses.
local function codeOnly(source)
  local out, i, n = {}, 1, #source
  while i <= n do
    local c = source:sub(i, i)
    local two = source:sub(i, i + 1)
    if two == '--' then
      -- Line comment, or a long comment delimited by [[ ]].
      local long = source:match('^%-%-%[=*%[', i)
      if long then
        local close = long:gsub('%-%-%[', ']'):gsub('%[', ']')
        local finish = source:find(close, i + #long, true)
        i = finish and finish + #close or n + 1
      else
        local finish = source:find('\n', i, true)
        i = finish and finish + 1 or n + 1
      end
    elseif c == '"' or c == "'" then
      local finish = source:find(c, i + 1, true)
      i = finish and finish + 1 or n + 1
    elseif c == '[' and source:sub(i, i + 1) == '[[' then
      local finish = source:find(']]', i + 2, true)
      i = finish and finish + 2 or n + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Finds identifiers of the form `name.` or `name(` that look like library use.
local function libraryUses(source)
  local code = codeOnly(source)
  local found = {}
  for name in code:gmatch('([A-Za-z_][A-Za-z0-9_]*)%s*[%.:]') do
    found[name] = true
  end
  return found
end

-- Finds colon-method calls, which radio-side code must never use. A Lua label (`::name::`) is
-- excluded by requiring the colon to follow a value rather than another colon.
local function colonCalls(source)
  local code = codeOnly(source)
  local found = {}
  for callee in code:gmatch('[%w_%)%]]%s*:%s*([A-Za-z_][A-Za-z0-9_]*)%s*%(') do
    found[callee] = true
  end
  return found
end

local failures = 0
local checked = 0
for _, module in ipairs(modules) do
  local path = module.path or string.format('%s/SCRIPTS/%s/%s.lua', root, module.dir, module.name)
  local label = module.path or (module.dir .. '/' .. module.name)
  local file = assert(io.open(path, 'r'), 'missing radio-side module: ' .. path)
  local source = file:read('a')
  file:close()
  local used = libraryUses(source)
  checked = checked + 1

  -- A colon call needs a metatable on the value, which EdgeTX does not provide for strings.
  -- No shipped module contains one, so any occurrence is a defect rather than a judgement call.
  for callee in pairs(colonCalls(source)) do
    failures = failures + 1
    print(string.format('UNSAFE %s uses the colon method %s(), which has no metatable on a radio',
      label, callee))
  end

  -- Only these library names matter; a local variable is not a library reference, so a
  -- conservative check is right here: a false positive is a prompt to look, not a verdict.
  for _, lib in ipairs({'table', 'os', 'debug', 'package', 'coroutine', 'utf8'}) do
    if used[lib] and not radioGlobals[lib] then
      failures = failures + 1
      print(string.format('UNSAFE %s uses the %s library, absent on a monochrome radio',
        label, lib))
    end
  end
end

if failures == 0 then
  print(string.format(
    'PASS: no radio-side module uses a missing library or colon call (%d checks)', checked))
else
  error(string.format('%d unsafe radio-side reference(s)', failures))
end
