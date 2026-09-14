-- SPDX-License-Identifier: GPL-3.0-or-later
-- Bounded database operations: name/category page, open/back, then page reads.
return function(s, failure, clearGroup)
  return function(operation, value, backwards)
    if operation == 1 then
      if not s.group then return end
      local total = s.group.count
      value = math.max(1, math.min(value, math.floor((total - 1) / 8) * 8 + 1))
      s.pageStart, s.selectLast, s.state = value, backwards or nil, 'groupLoading'
    elseif operation == 2 then
      value = math.max(1, math.min(value,
        math.floor((s.categoryTotal - 1) / 8) * 8 + 1))
      s.categoryPageStart, s.categorySelectLast, s.state =
        value, backwards or nil, 'categoryLoading'
    elseif operation == 3 then
      local row = s.categoryRows[s.categorySelected]
      if not row then failure('Database index error') return end
      if row.count < 0 then
        s.parentPageStart, s.parentSelected = s.categoryPageStart, s.categorySelected
        s.folderName, s.categoryIndexOffset, s.categoryTotal = row.name, row.offset, -row.count
        s.categoryPageStart, s.categorySelected, s.state = 1, 1, 'categoryLoading'
        return
      end
      clearGroup()
      s.group, s.groupName, s.groupTotal = row, row.name, row.count
      s.pageStart, s.selectLast, s.state = 1, nil, 'groupLoading'
    elseif operation == 4 then
      if not s.folderName then return false end
      s.folderName, s.categoryIndexOffset, s.categoryTotal = nil, 0, s.database[4]
      local first, selected = s.parentPageStart or 1, s.parentSelected or 1
      s.parentPageStart, s.parentSelected = nil, nil
      value = math.max(1, math.min(first,
        math.floor((s.categoryTotal - 1) / 8) * 8 + 1))
      s.categoryPageStart, s.categorySelectLast, s.state = value, nil, 'categoryLoading'
      s.categoryRestoreSelected = selected
      return true
    elseif operation == 5 then
      local file = io.open(s.database[3], 'r')
      if not file then failure('DB open failed') return end
      local offset = s.group.offset + (s.pageStart - 1) * 16
      local count = math.min(8, s.groupTotal - s.pageStart + 1)
      local positioned = io.seek(file, offset) == 0
      local data = positioned and io.read(file, count * 16)
      io.close(file)
      if not data or #data ~= count * 16 then failure('DB read failed') return end
      local rows = s.rows
      for i = 1, count do
        local name = string.match(string.sub(data, (i - 1) * 16 + 1, i * 16), '^[^%z]+')
        if not name then failure('DB record error') return end
        local row = rows[i] or {}
        row.name, rows[i] = name, row
      end
      for i = #rows, count + 1, -1 do rows[i] = nil end
      s.selected = s.selectLast and #rows or 1
      s.selectLast, s.state = nil, 'list'
    else
      local file = io.open(s.database[3], 'r')
      if not file then failure('DB open failed') return end
      local count = math.min(8, s.categoryTotal - s.categoryPageStart + 1)
      local offset = s.categoryIndexOffset + (s.categoryPageStart - 1) * 22
      local positioned = io.seek(file, offset) == 0
      local data = positioned and io.read(file, count * 22)
      io.close(file)
      if not data or #data ~= count * 22 then failure('DB index failed') return end
      local rows = s.categoryRows
      for i = 1, count do
        local start = (i - 1) * 22 + 1
        local name = string.match(string.sub(data, start, start + 15), '^[^%z]+')
        local target, total = string.unpack('<I4I2', data, start + 16)
        if total >= 32768 then total = 32768 - total end
        if not name or total == 0 then failure('DB index error') return end
        local row = rows[i] or {}
        row.name, row.offset, row.count = name, target, total
        rows[i] = row
      end
      for i = #rows, count + 1, -1 do rows[i] = nil end
      s.categorySelected = s.categoryRestoreSelected or (s.categorySelectLast and #rows or 1)
      s.categoryRestoreSelected = nil
      s.categorySelectLast, s.state = nil, 'categories'
    end
  end
end
