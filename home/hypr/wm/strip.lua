-- Strip layout: a Lua layout provider that owns the column model, with the backend interface.

local model = require("wm.model")

local M = {
    name = "strip",
    default_width = 0.5,
    max_width = 2.0,
    min_height = 0.05,
    applying = false,
}

local states = {}

local function state(ws)
    states[ws] = states[ws] or { columns = {}, offset = 0, weights = {} }
    return states[ws]
end

local function uses_strip(window)
    return type(window.layout) == "table" and window.layout.name == "lua:" .. M.name
end

local function workspace_of(ctx)
    for _, target in ipairs(ctx.targets) do
        if target.window then return target.window.workspace.id end
    end
end

local function reconcile(ctx, s)
    local by = {}
    for _, target in ipairs(ctx.targets) do
        if target.window then by[target.window.address] = target end
    end
    model.keep(s, by)
    local active = hl.get_active_window()
    if active and by[active.address] then s.focus = active.address end
    for _, target in ipairs(ctx.targets) do
        local address = target.window and target.window.address
        if address and not model.find(s, address) then
            local after = s.focus and model.find(s, s.focus) or #s.columns
            table.insert(s.columns, after + 1, { windows = { address }, width = M.default_width })
        end
    end
    return by
end

local function lefts(s, width)
    local list, x = {}, 0
    for c, column in ipairs(s.columns) do
        list[c] = x
        x = x + column.width * width
    end
    return list, x
end

local function follow(s, area)
    local starts = lefts(s, area.w)
    local c = s.focus and model.find(s, s.focus)
    if not c then return end
    local left = starts[c]
    local right = left + s.columns[c].width * area.w
    if left < s.offset then
        s.offset = left
    elseif right > s.offset + area.w then
        s.offset = math.min(left, right - area.w)
    end
end

local function weight(s, address)
    return s.weights[address] or 1
end

local function place(ctx, s, by)
    local area = ctx.area
    s.offset = math.max(0, s.offset)
    local starts = lefts(s, area.w)
    for c, column in ipairs(s.columns) do
        local total = 0
        for _, address in ipairs(column.windows) do total = total + weight(s, address) end
        local y = area.y
        for _, address in ipairs(column.windows) do
            local h = area.h * weight(s, address) / total
            by[address]:place({ x = area.x + starts[c] - s.offset, y = y, w = column.width * area.w, h = h })
            y = y + h
        end
    end
end

local function recalculate(ctx)
    local ws = workspace_of(ctx)
    if not ws then return end
    local s = state(ws)
    local by = reconcile(ctx, s)
    follow(s, ctx.area)
    place(ctx, s, by)
end

local function focused_column(s)
    local c = s.focus and model.find(s, s.focus)
    return c and s.columns[c], c
end

local function resize_height(s, column, address, delta)
    local others = 0
    for _, other in ipairs(column.windows) do
        if other ~= address then others = others + weight(s, other) end
    end
    if others == 0 then return end
    local share = weight(s, address) / (others + weight(s, address))
    share = math.min(1 - M.min_height, math.max(M.min_height, share + delta))
    s.weights[address] = share * others / (1 - share)
end

local function fit_visible(s, area)
    local starts = lefts(s, area.w)
    local visible, total = {}, 0
    for c, column in ipairs(s.columns) do
        local left = starts[c] - s.offset
        if left + column.width * area.w > 1 and left < area.w - 1 then
            visible[#visible + 1] = column
            total = total + column.width
        end
    end
    for _, column in ipairs(visible) do column.width = column.width / total end
end

local messages = {
    recalc = function() end,
    colresize = function(s, area, arg)
        local column = focused_column(s)
        if not column then return end
        local sign, value = arg:match("^([+-]?)([%d.]+)$")
        value = tonumber(value)
        if not value then return end
        if sign == "+" then value = column.width + value elseif sign == "-" then value = column.width - value end
        column.width = math.min(M.max_width, math.max(0.05, value))
    end,
    rowresize = function(s, area, arg)
        local column = focused_column(s)
        if column and tonumber(arg) then resize_height(s, column, s.focus, tonumber(arg)) end
    end,
    move = function(s, area, arg)
        if tonumber(arg) then s.offset = s.offset - tonumber(arg) end
        return true
    end,
    fit = function(s, area, arg)
        if arg == "active" then
            local column, c = focused_column(s)
            if not column then return end
            column.width = 1.0
            s.offset = lefts(s, area.w)[c]
            return true
        elseif arg == "visible" then
            fit_visible(s, area)
        end
    end,
}

local function layout_msg(ctx, msg)
    local verb, arg = msg:match("^(%S+)%s*(.-)$")
    local handler = messages[verb]
    if not handler then return false end
    local ws = workspace_of(ctx)
    if not ws then return true end
    local s = state(ws)
    local by = reconcile(ctx, s)
    local pinned = handler(s, ctx.area, arg)
    if not pinned then follow(s, ctx.area) end
    place(ctx, s, by)
    return true
end

M.state = state
M.provider = { recalculate = recalculate, layout_msg = layout_msg }
hl.layout.register(M.name, M.provider)

hl.on("window.active", function(window)
    if window and not window.floating and uses_strip(window) and not M.applying then
        hl.dispatch(hl.dsp.layout("recalc"))
    end
end)

local default_slot = model.slot
function model.slot(window)
    if not uses_strip(window) then return default_slot(window) end
    local s = states[window.workspace.id]
    if not s then return nil end
    local c, r = model.find(s, window.address)
    if not c then return nil end
    return { column = c, row = r, width = s.columns[c].width }
end

function M.resize_row(ws, address, fraction)
    local s = state(ws)
    local c = model.find(s, address)
    if c then resize_height(s, s.columns[c], address, fraction) end
end

function M.apply(ws, target)
    local s = state(ws)
    local live = model.live(ws)
    local m = model.keep(model.copy(target), live)
    for address in pairs(live) do
        if not model.find(m, address) then
            m.columns[#m.columns + 1] = { windows = { address }, width = M.default_width }
        end
    end
    s.columns = m.columns
    if m.focus then s.focus = m.focus end
    M.applying = true
    local window = s.focus and live[s.focus]
    if window then hl.dispatch(hl.dsp.focus({ window = window })) end
    M.applying = false
    if hl.get_active_workspace().id == ws then hl.dispatch(hl.dsp.layout("recalc")) end
end

return M
