-- SPDX-License-Identifier: GPL-3.0-or-later
-- CRSF 0xAA / unsigned MAVLink 1 and 2, including bounded multi-chunk replies.
local xor, band, shift = bit32.bxor, bit32.band, bit32.rshift
local extras = {[0]=50, [4]=237, [20]=214, [21]=159, [22]=220, [23]=168, [76]=152, [148]=178}
local lengths = {[0]=9, [4]=14, [20]=20, [21]=2, [22]=25, [23]=23, [76]=33, [148]=78}
local minimum = {[148]=60}
local sequence = 0
local chunkData, chunkNext, chunkLast
local function accumulate(crc, byte)
  local t = xor(byte, band(crc, 255))
  t = xor(t, band(t * 16, 255))
  return xor(shift(crc, 8), t * 256, t * 8, shift(t, 4))
end
local function checksum(s, extra)
  local crc = 65535
  for i = 1, #s do crc = accumulate(crc, string.byte(s, i)) end
  return accumulate(crc, extra)
end
local function encode(id, payload)
  if not extras[id] or #payload ~= lengths[id] then return end
  -- MAVLink v1 avoids trimming ambiguity; all messages here fit one CRSF frame.
  local s = string.char(#payload, sequence, 254, 190, id) .. payload
  sequence = (sequence + 1) % 256
  s = string.char(254) .. s .. string.pack('<I2', checksum(s, extras[id]))
  local frame = {0, #s}
  for i = 1, #s do frame[i + 2] = string.byte(s, i) end
  return frame
end
local function packet(frame)
  if type(frame) ~= 'table' or #frame < 3 or #frame > 60 or frame[2] ~= #frame - 2 then return end
  local marker, current = frame[1], frame[1] % 16
  local last = math.floor(marker / 16)
  if current > last then return end
  local s = ''
  for i = 3, #frame do
    local b = frame[i]
    if type(b) ~= 'number' or b < 0 or b > 255 or b % 1 ~= 0 then return end
    s = s .. string.char(b)
  end
  if last == 0 then
    chunkData, chunkNext, chunkLast = nil, nil, nil
    return current == 0 and s or nil
  end
  if current == 0 then
    chunkData, chunkNext, chunkLast = s, 1, last
  elseif not chunkData or current ~= chunkNext or last ~= chunkLast then
    chunkData, chunkNext, chunkLast = nil, nil, nil
  else
    chunkData, chunkNext = chunkData .. s, current + 1
  end
  if chunkData and current == last then
    s, chunkData, chunkNext, chunkLast = chunkData, nil, nil, nil
    return s
  end
end
local function decode(frame)
  local s = packet(frame)
  if not s or #s < 8 then return end
  local magic, n = string.byte(s, 1, 2)
  local header, id, sys, comp
  if magic == 254 then
    header, sys, comp, id = 6, string.byte(s, 4, 6)
  elseif magic == 253 and #s >= 12 and string.byte(s, 3) == 0 then
    header, sys, comp = 10, string.byte(s, 6, 7)
    id = string.byte(s, 8) + string.byte(s, 9) * 256 + string.byte(s, 10) * 65536
  else return end
  if not extras[id] or n > lengths[id] or n < (minimum[id] or 0)
    or #s ~= header + n + 2 or (magic == 254 and n ~= lengths[id]) then return end
  local crc = string.unpack('<I2', s, header + n + 1)
  if checksum(string.sub(s, 2, header + n), extras[id]) ~= crc then return end
  local payload = string.sub(s, header + 1, header + n)
    .. string.rep('\0', lengths[id] - n)
  return id, payload, sys, comp
end
local function parameter(payload)
  local value, count, index, name, kind = string.unpack('<fI2I2c16B', payload)
  name = string.match(name, '^[^%z]*')
  if name == '' or string.find(name, '[^A-Za-z0-9_]') or count < 1 or count > 8192
    or index ~= 65535 and index >= count
    or value ~= value or value <= -1e30 or value >= 1e30 then return end
  return {value=value, count=count, index=index, name=name, kind=kind}
end
local function read(sys, comp, index)
  local result = encode(20, string.pack('<i2BBc16', index, sys, comp, ''))
  return result
end
local function readName(sys, comp, name)
  return encode(20, string.pack('<i2BBc16', -1, sys, comp, name))
end
-- Asks the autopilot to stream its own parameter list. The TX bridge must be in its bounded
-- list session for these to be forwarded.
local function requestList(sys, comp)
  return encode(21, string.pack('<BB', sys, comp))
end
local function versionRequest(sys, comp)
  return encode(76, string.pack('<fffffffI2BBB', 148, 0, 0, 0, 0, 0, 0, 512, sys, comp, 0))
end
local function version(payload)
  -- flight_sw_version is the third wire field (payload bytes 17..20).
  return string.byte(payload, 20), string.byte(payload, 19), string.byte(payload, 18)
end
local function write(sys, comp, p, value)
  local result = encode(23, string.pack('<fBBc16B', value, sys, comp, p.name, p.kind))
  return result
end
local function ping()
  local result = encode(4, string.rep('\0', 14))
  return result
end
return {decode=decode, encode=encode, parameter=parameter, read=read, readName=readName,
  requestList=requestList, write=write, ping=ping, versionRequest=versionRequest, version=version}
