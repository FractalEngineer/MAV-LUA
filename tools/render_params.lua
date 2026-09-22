-- Exercise the real parameter controller; export its native-font draw calls.
local options = arg
arg = {'src', 'fixture'}
local fixture = dofile('tests/test_params.lua')
arg = options
local f = fixture()
f.values.AUTO_OPTIONS = 1
local stage, width, height = arg[1], tonumber(arg[2]), tonumber(arg[3])
if stage ~= 'parameters-load' then
  f.load()
  -- Categories are the ones this vehicle reported, so the group page is reached by name
  -- rather than by a fixed number of scrolls.
  if stage == 'parameters-groups' then
    for _ = 1, 4 do f.action('next') f.tick() f.draw() end
  else
    local guard = 0
    while not f.draw():find('@AUTO', 1, true) do
      f.action('next')
      f.tick()
      guard = guard + 1
      assert(guard < 40, 'AUTO category not reachable')
    end
    f.open()
  end
  if stage == 'parameters-edit' or stage == 'parameters-save' then
    f.edit() f.action('next')
    if stage == 'parameters-save' then f.action('enter') f.action('next') end
  end
end
local advances = {}
for i = 32,126 do advances[i] = tonumber(arg[4]:sub(i-31,i-31)) end
local function measure(s)
  local pixels = 0
  for i = 1,#s do pixels = pixels + (advances[s:byte(i)] or 6) end
  return pixels
end
local function fit(s, space)
  while #s > 0 and measure(s) > space do s = s:sub(1,-2) end
  return s
end
local function text(x,y,s,inverse,maxWidth)
  if y+8 > height then return end
  s=fit(s,math.min(maxWidth or width-x,width-x))
  print(string.format('T\t%d\t%d\t%d\t%s',x,y,inverse and 2 or 0,s))
end
local function right(y,s,left)
  s=fit(s,width-(left or 0))
  text(width-measure(s),y,s)
end
f.app.draw(text,right,width,height,9)
f.close()
