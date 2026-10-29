-- Workspace layout model: ordered columns of window addresses with widths.

local M = {}

local function tiled(window)
    return window.mapped and not window.floating and type(window.layout) == "table" and window.layout.column
end

function M.live(ws)
    local by = {}
    for _, window in ipairs(hl.get_workspace_windows(ws)) do
        if tiled(window) then by[window.address] = window end
    end
    return by
end

function M.read(ws)
    local columns, order = {}, {}
    for _, window in pairs(M.live(ws)) do
        local index = window.layout.column.index
        if not columns[index] then
            columns[index] = { rows = {}, width = window.layout.column.width }
            order[#order + 1] = index
        end
        table.insert(columns[index].rows, { row = window.layout.index_in_column, address = window.address })
    end
    table.sort(order)
    local m = { columns = {} }
    for _, index in ipairs(order) do
        local column = columns[index]
        table.sort(column.rows, function(a, b) return a.row < b.row end)
        local windows = {}
        for _, entry in ipairs(column.rows) do windows[#windows + 1] = entry.address end
        m.columns[#m.columns + 1] = { windows = windows, width = column.width }
    end
    local active = hl.get_active_window()
    if active and M.find(m, active.address) then m.focus = active.address end
    return m
end

function M.find(m, address)
    for c, column in ipairs(m.columns) do
        for r, candidate in ipairs(column.windows) do
            if candidate == address then return c, r end
        end
    end
end

function M.copy(m)
    local columns = {}
    for c, column in ipairs(m.columns) do
        columns[c] = { windows = { table.unpack(column.windows) }, width = column.width }
    end
    return { columns = columns, focus = m.focus }
end

function M.remove(m, set)
    for _, column in ipairs(m.columns) do
        for r = #column.windows, 1, -1 do
            if set[column.windows[r]] then table.remove(column.windows, r) end
        end
    end
end

function M.prune(m)
    for c = #m.columns, 1, -1 do
        if #m.columns[c].windows == 0 then table.remove(m.columns, c) end
    end
    return m
end

function M.keep(m, present)
    for _, column in ipairs(m.columns) do
        for r = #column.windows, 1, -1 do
            if not present[column.windows[r]] then table.remove(column.windows, r) end
        end
    end
    if m.focus and not present[m.focus] then m.focus = nil end
    return M.prune(m)
end

function M.flat(m)
    local list = {}
    for _, column in ipairs(m.columns) do
        for _, address in ipairs(column.windows) do list[#list + 1] = address end
    end
    return list
end

function M.shape(m)
    local parts = {}
    for _, column in ipairs(m.columns) do parts[#parts + 1] = table.concat(column.windows, ",") end
    return table.concat(parts, "|")
end

function M.key(m)
    local parts = {}
    for _, column in ipairs(m.columns) do
        parts[#parts + 1] = table.concat(column.windows, ",") .. string.format("@%.3f", column.width)
    end
    return table.concat(parts, "|")
end

function M.rename(m, old, new)
    for _, column in ipairs(m.columns) do
        for r, address in ipairs(column.windows) do
            if address == old then column.windows[r] = new end
        end
    end
    if m.focus == old then m.focus = new end
end

return M
