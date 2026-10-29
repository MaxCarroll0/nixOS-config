-- Meow-style window editing over a layout backend: selection, cut and paste, rotate, undo.

local model = require("wm.model")
local undo = require("wm.undo")

local wm = {
    backend = require("wm.strip"),
    selection = {},
    clipboard = nil,
    marks = { back = {}, forward = {} },
    saved = {},
    widths = { 0.333, 0.5, 0.667, 1.0 },
    min_width = 0.05,
    scroll_ms = 120,
}
_G.wm = wm

local function workspace()
    return hl.get_active_workspace().id
end

local function set_of(list)
    local set = {}
    for _, address in ipairs(list) do set[address] = true end
    return set
end

local function centre(window)
    return window.at.x + window.size.x / 2, window.at.y + window.size.y / 2
end

local function focus(window)
    if window then hl.dispatch(hl.dsp.focus({ window = window })) end
end

local function apply(ws, m)
    wm.backend.apply(ws, m)
    wm.publish()
end

function wm.run(target)
    if type(target) == "function" then target() else hl.dispatch(target) end
end

local function json(value)
    local kind = type(value)
    if kind == "table" then
        if #value > 0 or next(value) == nil then
            local items = {}
            for _, item in ipairs(value) do items[#items + 1] = json(item) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local items = {}
        for k, item in pairs(value) do items[#items + 1] = json(tostring(k)) .. ":" .. json(item) end
        return "{" .. table.concat(items, ",") .. "}"
    elseif kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    end
    return tostring(value)
end

function wm.selected(ws)
    local live = model.live(ws or workspace())
    local list = {}
    for address in pairs(wm.selection) do
        if live[address] then list[#list + 1] = address end
    end
    return list, live
end

function wm.publish()
    local list = {}
    for address in pairs(wm.selection) do list[#list + 1] = address end
    local state = { selection = list, mode = hl.get_current_submap(), ace = wm.ace_labels or {} }
    hl.dispatch(hl.dsp.event("wm>>" .. json(state)))
end

local function paint(address, on)
    local window = hl.get_window("address:" .. address)
    if not window then return end
    hl.dispatch(hl.dsp.window.set_prop({ prop = "border_size", value = on and "0" or "unset", window = window }))
    hl.dispatch(hl.dsp.window.tag({ tag = (on and "+" or "-") .. "wmsel", window = window }))
end

local function set_selected(address, on)
    if not address or (wm.selection[address] or false) == on then return end
    wm.selection[address] = on or nil
    paint(address, on)
end

function wm.clear_selection()
    for address in pairs(wm.selection) do set_selected(address, false) end
    wm.publish()
end

local function targets(m)
    local list = {}
    for address in pairs(wm.selection) do
        if model.find(m, address) then list[#list + 1] = address end
    end
    if #list == 0 and m.focus then list = { m.focus } end
    return list
end

local function block_of(m, set)
    local block, top, first = {}, math.huge, nil
    for c, column in ipairs(m.columns) do
        local picked, row = {}, nil
        for r, address in ipairs(column.windows) do
            if set[address] then
                picked[#picked + 1] = address
                row = row or r
            end
        end
        if #picked > 0 then
            first = first or c
            block[#block + 1] = { windows = picked, width = column.width, row = row, col = c - first }
            top = math.min(top, row)
        end
    end
    for _, b in ipairs(block) do b.row = b.row - top end
    return block
end

local function side_of(live, address)
    local window = live[address]
    local monitor = window and window.monitor or hl.get_active_monitor()
    if not window then return "r" end
    local x = centre(window)
    return x < monitor.x + monitor.width / 2 and "l" or "r"
end

local function neighbour(m, gone)
    local fc, fr = model.find(m, m.focus)
    if not fc then return nil end
    for distance = 0, #m.columns do
        for _, c in ipairs({ fc - distance, fc + distance }) do
            local column = m.columns[c]
            if column then
                local best, gap = nil, math.huge
                for r, address in ipairs(column.windows) do
                    if not gone[address] and math.abs(r - fr) < gap then best, gap = address, math.abs(r - fr) end
                end
                if best then return best end
            end
        end
    end
end

local function place_at_edges(m, left, right)
    for i, b in ipairs(left) do
        table.insert(m.columns, i, { windows = b.windows, width = b.width })
    end
    for _, b in ipairs(right) do
        m.columns[#m.columns + 1] = { windows = b.windows, width = b.width }
    end
end

local function evict_from(m, list, live)
    local left, right = {}, {}
    for _, address in ipairs(list) do
        (side_of(live, address) == "l" and left or right)[address] = true
    end
    local leftb, rightb = block_of(m, left), block_of(m, right)
    model.remove(m, set_of(list))
    model.prune(m)
    place_at_edges(m, leftb, rightb)
end

local function evict(remember)
    local ws = workspace()
    local m = model.read(ws)
    local list = targets(m)
    if #list == 0 then return end
    local gone = set_of(list)
    if remember then wm.clipboard = { block = block_of(m, gone), ws = ws } end
    local after = neighbour(m, gone)
    evict_from(m, list, model.live(ws))
    m.focus = after or m.focus
    for _, address in ipairs(list) do set_selected(address, false) end
    apply(ws, m)
end

function wm.evict() evict(false) end

function wm.cut() evict(true) end

function wm.cut_window(window)
    if not window or window.floating then return end
    focus(window)
    local saved = wm.selection
    wm.selection = {}
    evict(true)
    wm.selection = saved
end

local function paste(replace)
    local clip = wm.clipboard
    if not clip then return end
    local ws = workspace()
    for _, b in ipairs(clip.block) do
        for _, address in ipairs(b.windows) do
            local window = hl.get_window("address:" .. address)
            if window and window.workspace and window.workspace.id ~= ws then
                hl.dispatch(hl.dsp.window.move({ workspace = ws, follow = false, window = window }))
            end
        end
    end
    local m = model.read(ws)
    local live = model.live(ws)
    local incoming = {}
    for _, b in ipairs(clip.block) do
        for _, address in ipairs(b.windows) do
            if live[address] and address ~= m.focus then incoming[address] = true end
        end
    end
    if not next(incoming) then return end
    model.remove(m, incoming)
    model.prune(m)
    local fc, fr = model.find(m, m.focus)
    local first
    if not fc then
        fc, fr = #m.columns + 1, 0
        m.columns[fc] = { windows = {}, width = clip.block[1].width }
    end
    local replaced
    local at = fr + 1
    if replace and m.focus then
        replaced = m.focus
        table.remove(m.columns[fc].windows, fr)
        at = fr
    end
    for _, b in ipairs(clip.block) do
        local windows = {}
        for _, address in ipairs(b.windows) do
            if incoming[address] then windows[#windows + 1] = address end
        end
        first = first or windows[1]
        local c = fc + b.col
        if c > #m.columns then
            m.columns[#m.columns + 1] = { windows = windows, width = b.width }
        else
            local column = m.columns[c]
            local pos = math.min(at + b.row, #column.windows + 1)
            for i, address in ipairs(windows) do table.insert(column.windows, pos + i - 1, address) end
        end
    end
    model.prune(m)
    if replaced then
        local side = side_of(live, replaced)
        local edge = { { windows = { replaced }, width = m.columns[1] and m.columns[1].width or 0.5 } }
        if side == "l" then place_at_edges(m, edge, {}) else place_at_edges(m, {}, edge) end
    end
    m.focus = first or m.focus
    wm.clipboard = nil
    apply(ws, m)
end

function wm.paste() paste(false) end

function wm.replace() paste(true) end

local function enter_select()
    hl.dispatch(hl.dsp.submap("select"))
    wm.publish()
end

function wm.select_mode()
    if hl.get_current_submap() == "select" then
        hl.dispatch(hl.dsp.submap("normal"))
        wm.publish()
    else
        enter_select()
    end
end

function wm.leave_select(to)
    wm.clear_selection()
    hl.dispatch(hl.dsp.submap(to or "normal"))
    wm.publish()
end

function wm.toggle_select()
    local window = hl.get_active_window()
    if not window then return end
    set_selected(window.address, not wm.selection[window.address])
    wm.publish()
end

local function logical(m, address)
    local c, r = model.find(m, address)
    local x = 0
    for i = 1, c - 1 do x = x + m.columns[i].width end
    local column = m.columns[c]
    return x + column.width / 2, (r - 0.5) / #column.windows, column
end

local function on_screen(window)
    local monitor = window.monitor or hl.get_active_monitor()
    return window.at.x < monitor.x + monitor.width and window.at.x + window.size.x > monitor.x
end

function wm.select_row()
    local ws = workspace()
    local m = model.read(ws)
    if not m.focus then return end
    local _, y = logical(m, m.focus)
    for _, column in ipairs(m.columns) do
        local r = math.min(#column.windows, math.floor(y * #column.windows) + 1)
        set_selected(column.windows[r], true)
    end
    enter_select()
end

function wm.select_column()
    local m = model.read(workspace())
    local c = model.find(m, m.focus)
    if not c then return end
    for _, address in ipairs(m.columns[c].windows) do set_selected(address, true) end
    enter_select()
end

function wm.rotate(clockwise)
    local ws = workspace()
    local m = model.read(ws)
    local live = model.live(ws)
    local scope = wm.selected(ws)
    if #scope < 2 then
        scope = {}
        for address, window in pairs(live) do
            if on_screen(window) then scope[#scope + 1] = address end
        end
    end
    if #scope < 2 then return end
    local position, cx, cy = {}, 0, 0
    for _, address in ipairs(scope) do
        local x, y = logical(m, address)
        position[address] = { x = x, y = y }
        cx, cy = cx + x / #scope, cy + y / #scope
    end
    for _, p in pairs(position) do p.angle = math.atan(p.y - cy, p.x - cx) end
    table.sort(scope, function(a, b)
        local p, q = position[a], position[b]
        if math.abs(p.angle - q.angle) > 1e-6 then return p.angle < q.angle end
        if p.x ~= q.x then return p.x > q.x end
        return p.y < q.y
    end)
    local slots = {}
    for i, address in ipairs(scope) do
        local c, r = model.find(m, address)
        slots[i] = { c = c, r = r }
    end
    local n = #scope
    local result = model.copy(m)
    for i, address in ipairs(scope) do
        local slot = slots[(clockwise and i or i - 2) % n + 1]
        result.columns[slot.c].windows[slot.r] = address
    end
    apply(ws, result)
end

local function move_vertical(m, set, down)
    for _, column in ipairs(m.columns) do
        local w = column.windows
        if down then
            for r = #w - 1, 1, -1 do
                if set[w[r]] and not set[w[r + 1]] then w[r], w[r + 1] = w[r + 1], w[r] end
            end
        else
            for r = 2, #w do
                if set[w[r]] and not set[w[r - 1]] then w[r], w[r - 1] = w[r - 1], w[r] end
            end
        end
    end
end

local function move_horizontal(m, set, step)
    local n = #m.columns
    local slots, moving = {}, {}
    for s = 0, 2 * n + 2 do slots[s] = { windows = {}, width = 0 } end
    for c, column in ipairs(m.columns) do slots[2 * c].width = column.width end
    for c, column in ipairs(m.columns) do
        local shared, moves = false, false
        for _, address in ipairs(column.windows) do
            if set[address] then moves = true else shared = true end
        end
        local dest = 2 * c
        if moves and shared then
            dest = 2 * c + step
            slots[dest].width = column.width
        elseif moves and c + step >= 1 and c + step <= n then
            dest = 2 * (c + step)
        end
        for r, address in ipairs(column.windows) do
            if set[address] then
                moving[#moving + 1] = { address = address, dest = dest, row = r }
            else
                table.insert(slots[2 * c].windows, address)
            end
        end
    end
    table.sort(moving, function(a, b) return a.row < b.row end)
    for _, entry in ipairs(moving) do
        local column = slots[entry.dest].windows
        table.insert(column, math.min(entry.row, #column + 1), entry.address)
    end
    local columns = {}
    for s = 0, 2 * n + 2 do
        if #slots[s].windows > 0 then columns[#columns + 1] = slots[s] end
    end
    m.columns = columns
end

function wm.move(direction)
    local ws = workspace()
    local m = model.read(ws)
    local set = set_of(targets(m))
    if not next(set) then return end
    if direction == "u" or direction == "d" then
        move_vertical(m, set, direction == "d")
    else
        move_horizontal(m, set, direction == "r" and 1 or -1)
    end
    apply(ws, m)
end

local function nearest(from, candidates, direction)
    local fx, fy = centre(from)
    local best, score = nil, math.huge
    for _, window in ipairs(candidates) do
        local x, y = centre(window)
        local along, across
        if direction == "l" then along, across = fx - x, y - fy
        elseif direction == "r" then along, across = x - fx, y - fy
        elseif direction == "u" then along, across = fy - y, x - fx
        else along, across = y - fy, x - fx end
        if along > 1 then
            local s = along + 2 * math.abs(across)
            if s < score then best, score = window, s end
        end
    end
    return best
end

function wm.focus_within(direction)
    local active = hl.get_active_window()
    if not active then return end
    local list, live = wm.selected()
    local candidates = {}
    for _, address in ipairs(list) do
        if address ~= active.address then candidates[#candidates + 1] = live[address] end
    end
    focus(nearest(active, candidates, direction))
end

local function step_focus(direction)
    if hl.get_current_submap() == "select" then
        wm.focus_within(direction)
    else
        hl.dispatch(hl.dsp.focus({ direction = direction }))
    end
end

function wm.align_left()
    local window = hl.get_active_window()
    if not window or window.floating then return end
    local monitor = hl.get_active_monitor()
    local edge = monitor.x + monitor.reserved.left + hl.get_config("general.gaps_out").left
        + hl.get_config("general.gaps_in").left + hl.get_config("general.border_size")
    local offset = math.floor(window.at.x - edge + 0.5)
    if offset == 0 then return end
    hl.dispatch(hl.dsp.layout(string.format("move %d", -offset)))
    focus(window)
end

local function shift_view(pixels)
    if pixels == 0 then return end
    local active = hl.get_active_window()
    local follow = hl.get_config("scrolling.follow_focus")
    hl.config({ scrolling = { follow_focus = false } })
    hl.dispatch(hl.dsp.layout(string.format("move %d", -pixels)))
    focus(active)
    hl.config({ scrolling = { follow_focus = follow } })
end

wm.pan_fraction = 0.1

function wm.pan(direction)
    shift_view(direction * math.floor(hl.get_active_monitor().width * wm.pan_fraction))
end

local scrolling = false
function wm.scroll(direction)
    if scrolling then return end
    scrolling = true
    hl.timer(function() scrolling = false end, { timeout = wm.scroll_ms, type = "oneshot" })
    step_focus(direction)
end

local function saved_for(address)
    wm.saved[address] = wm.saved[address] or {}
    return wm.saved[address]
end

local function toggle_width(m, address)
    local c = model.find(m, address)
    local column = m.columns[c]
    local saved = saved_for(address)
    if column.width > 0.99 and saved.width then
        column.width, saved.width = saved.width, nil
    else
        saved.width, column.width = column.width, 1.0
    end
end

local function promote(m, address)
    local c, r = model.find(m, address)
    local column = m.columns[c]
    if #column.windows < 2 then return false end
    local saved = saved_for(address)
    saved.beside = column.windows[r == 1 and 2 or r - 1]
    saved.row = r
    table.remove(column.windows, r)
    table.insert(m.columns, c + 1, { windows = { address }, width = column.width })
    return true
end

local function demote(m, address)
    local saved = saved_for(address)
    local c = model.find(m, address)
    local home = saved.beside and model.find(m, saved.beside)
    saved.beside = nil
    if not home or home == c or #m.columns[c].windows > 1 then return false end
    table.remove(m.columns, c)
    if home > c then home = home - 1 end
    local windows = m.columns[home].windows
    table.insert(windows, math.min(saved.row or #windows + 1, #windows + 1), address)
    return true
end

local function each_target(edit)
    local ws = workspace()
    local m = model.read(ws)
    for _, address in ipairs(targets(m)) do edit(m, address) end
    apply(ws, m)
end

function wm.fill_row()
    each_target(toggle_width)
end

function wm.fill_column()
    each_target(function(m, address)
        if not demote(m, address) then promote(m, address) end
    end)
end

function wm.fill()
    each_target(function(m, address)
        local c = model.find(m, address)
        local saved = saved_for(address)
        if m.columns[c].width > 0.99 and #m.columns[c].windows == 1 and (saved.beside or saved.width) then
            local width = saved.width
            saved.width = nil
            if not demote(m, address) and width then m.columns[c].width = width end
        else
            promote(m, address)
            c = model.find(m, address)
            saved.width, m.columns[c].width = m.columns[c].width, 1.0
        end
    end)
end

local function column_windows(ws)
    local m = model.read(ws)
    local live = model.live(ws)
    local seen, list = {}, {}
    for _, address in ipairs(targets(m)) do
        local c = model.find(m, address)
        if not seen[c] then
            seen[c] = true
            list[#list + 1] = live[address]
        end
    end
    return list, live[m.focus]
end

local function next_preset(width, grow)
    if grow then
        for _, preset in ipairs(wm.widths) do
            if preset > width + 0.01 then return preset end
        end
        return 1.0
    end
    for i = #wm.widths, 1, -1 do
        if wm.widths[i] < width - 0.01 then return wm.widths[i] end
    end
    return nil
end

function wm.resize_column(delta)
    local list, active = column_windows(workspace())
    local exhausted = false
    for _, window in ipairs(list) do
        local width = model.slot(window).width
        local target
        if delta == "+" or delta == "-" then
            target = next_preset(width, delta == "+")
        else
            target = width + delta
            if target < wm.min_width then target = nil end
        end
        if target then
            focus(window)
            hl.dispatch(hl.dsp.layout(string.format("colresize %.4f", math.min(target, wm.backend.max_width or 1.0))))
        else
            exhausted = true
        end
    end
    focus(active)
    if exhausted and #list == 1 then step_focus("r") end
end

function wm.resize_row(fraction)
    local list, active = column_windows(workspace())
    if wm.backend.resize_row then
        for _, window in ipairs(list) do wm.backend.resize_row(workspace(), window.address, fraction) end
        hl.dispatch(hl.dsp.layout("recalc"))
        return
    end
    local monitor = hl.get_active_monitor()
    for _, window in ipairs(list) do
        focus(window)
        hl.dispatch(hl.dsp.window.resize({ x = 0, y = math.floor(fraction * monitor.height), relative = true }))
    end
    focus(active)
end

function wm.close()
    local ws = workspace()
    local m = model.read(ws)
    local live = model.live(ws)
    local list = targets(m)
    for _, address in ipairs(list) do
        focus(live[address])
        hl.dispatch(hl.dsp.window.close())
        set_selected(address, false)
    end
    if #list == 0 then hl.dispatch(hl.dsp.window.close()) end
end

local ace_letters = "asdfghjklqwertyuipzxcvbnm"
local ace = nil

local function on_screen(window, monitor)
    return window.mapped and not window.hidden
        and window.at.x < monitor.x + monitor.width and window.at.x + window.size.x > monitor.x
        and window.at.y < monitor.y + monitor.height and window.at.y + window.size.y > monitor.y
end

local function emacs_splits()
    local pipe = io.popen("timeout 0.3 emacsclient --eval '(wm-ace-layout)' 2>/dev/null")
    if not pipe then return {} end
    local text = pipe:read("a") or ""
    pipe:close()
    local frames = {}
    for address, index, x, y in text:gmatch("(0x%x+) (%d+) (%-?%d+) (%-?%d+)") do
        frames[address] = frames[address] or {}
        table.insert(frames[address], { index = tonumber(index), x = tonumber(x), y = tonumber(y) })
    end
    return frames
end

local function visible_corner(x, y, monitor)
    return math.max(x, monitor.x), math.max(y, monitor.y)
end

local function ace_targets()
    local windows = {}
    local monitors = {}
    local emacs = false
    for _, monitor in ipairs(hl.get_monitors()) do
        if monitor.active_workspace then
            for _, window in ipairs(hl.get_workspace_windows(monitor.active_workspace.id)) do
                if on_screen(window, monitor) then
                    windows[#windows + 1] = window
                    monitors[window.address] = monitor
                    emacs = emacs or window.class:lower() == "emacs"
                end
            end
        end
    end
    table.sort(windows, function(a, b)
        if a.at.x ~= b.at.x then return a.at.x < b.at.x end
        return a.at.y < b.at.y
    end)
    local splits = emacs and emacs_splits() or {}
    local targets = {}
    for _, window in ipairs(windows) do
        local monitor = monitors[window.address]
        local inner = splits[window.address]
        if inner and #inner > 1 then
            for _, split in ipairs(inner) do
                local x, y = visible_corner(window.at.x + split.x, window.at.y + split.y, monitor)
                targets[#targets + 1] = { address = window.address, split = split.index, x = x, y = y }
            end
        else
            local x, y = visible_corner(window.at.x, window.at.y, monitor)
            targets[#targets + 1] = { address = window.address, x = x, y = y }
        end
    end
    return targets
end

local function ace_finish(to)
    ace = nil
    wm.ace_labels = nil
    hl.dispatch(hl.dsp.submap(to))
    wm.publish()
end

function wm.ace(mode)
    local targets = ace_targets()
    if #targets == 0 then return end
    local by_key, labels = {}, {}
    for i, target in ipairs(targets) do
        local key = ace_letters:sub(i, i)
        if key == "" then break end
        by_key[key] = target
        labels[#labels + 1] = { key = key, x = target.x, y = target.y }
    end
    local from = hl.get_current_submap()
    ace = { mode = mode, targets = by_key, from = from ~= "" and from or "reset" }
    wm.ace_labels = labels
    hl.dispatch(hl.dsp.submap("ace"))
    wm.publish()
end

function wm.ace_key(key)
    if not ace then return end
    local target = ace.targets[key]
    if not target then return end
    local window = hl.get_window("address:" .. target.address)
    if not window then return ace_finish(ace.from) end
    if ace.mode == "select" then
        set_selected(target.address, not wm.selection[target.address])
        return ace_finish("select")
    end
    local from = ace.from
    focus(window)
    if target.split then
        hl.dispatch(hl.dsp.exec_cmd(string.format("emacsclient --eval '(wm-ace-select \"%s\" %d)'",
            target.address, target.split)))
    end
    ace_finish(from)
end

function wm.ace_cancel()
    if ace then ace_finish(ace.from) end
end

hl.define_submap("ace", function()
    for key in ace_letters:gmatch(".") do
        hl.bind(key, function() wm.ace_key(key) end, { description = "ace " .. key })
    end
    hl.bind("escape", function() wm.ace_cancel() end, { description = "cancel ace" })
    hl.bind("o", function() wm.ace_cancel() end, { description = "cancel ace" })
end)

local windowed_layout, before_fullscreen = {}, {}

local function remember_layout()
    local ws = workspace()
    local live = model.live(ws)
    local xs = {}
    for address, window in pairs(live) do
        if window.fullscreen ~= 0 then return end
        xs[address] = window.at.x
    end
    windowed_layout[ws] = { ws = ws, model = model.read(ws), x = xs }
end

function wm.checkpoint()
    if wm.backend.applying then return end
    undo.checkpoint()
    remember_layout()
end

function wm.undo()
    undo.undo(wm.backend)
    wm.publish()
end

local function mapped_window(address)
    for _, window in ipairs(hl.get_windows()) do
        if window.address == address and window.mapped then return window end
    end
end

function wm.mark_push()
    local here = hl.get_active_window()
    if not here then return end
    local back = wm.marks.back
    if back[#back] ~= here.address then back[#back + 1] = here.address end
    wm.marks.forward = {}
end

local function step_mark(from, to, elisp)
    local here = hl.get_active_window()
    while #from > 0 do
        local address = table.remove(from)
        local target = (not here or address ~= here.address) and mapped_window(address)
        if target then
            if here then to[#to + 1] = here.address end
            focus(target)
            return
        end
    end
    if here and here.class == "emacs" then
        hl.dispatch(hl.dsp.exec_cmd("timeout 1 emacsclient --eval '(" .. elisp .. ")'"))
    end
end

function wm.mark_pop() step_mark(wm.marks.back, wm.marks.forward, "wm-mark-pop") end

function wm.mark_unpop() step_mark(wm.marks.forward, wm.marks.back, "wm-mark-unpop") end

hl.on("window.open", function(window)
    undo.claim(window, wm.backend)
end)

hl.on("window.minimize", function(window, minimized)
    if minimized ~= false and minimized ~= 0 then
        wm.checkpoint()
        wm.cut_window(window)
    end
end)

hl.timer(remember_layout, { timeout = 500, type = "repeat" })

local function release_scroll() hl.dispatch(hl.dsp.layout("inhibit_scroll 0")) end

local function hold_scroll()
    hl.dispatch(hl.dsp.layout("inhibit_scroll 1"))
    hl.timer(release_scroll, { timeout = 500, type = "oneshot" })
end

release_scroll()
hl.on("workspace.active", release_scroll)

local function after_layout(fn)
    hl.timer(fn, { timeout = 50, type = "oneshot" })
end

hl.on("window.fullscreen", function(window)
    if not window or wm.backend.applying then return end
    if window.fullscreen ~= 0 then
        if before_fullscreen[window.address] then return end
        for _, saved in pairs(windowed_layout) do
            if saved.x[window.address] then before_fullscreen[window.address] = saved end
        end
        return
    end
    local saved = before_fullscreen[window.address]
    before_fullscreen[window.address] = nil
    if not saved then return end
    after_layout(function()
        local target = model.copy(saved.model)
        target.focus = window.address
        wm.backend.apply(saved.ws, target)
        after_layout(function()
            local now = model.live(saved.ws)[window.address]
            if now and now.fullscreen == 0 then shift_view(math.floor(now.at.x - saved.x[window.address] + 0.5)) end
            hold_scroll()
        end)
    end)
end)

local recent, closing = {}, {}

local function forget(address)
    for i = #recent, 1, -1 do
        if recent[i] == address then table.remove(recent, i) end
    end
end

hl.on("window.active", function(window)
    if not window or not window.address or closing[window.address] then return end
    forget(window.address)
    table.insert(recent, 1, window.address)
    while #recent > 32 do table.remove(recent) end
end)

local function refocus_after_close(window)
    if not window or not window.address or closing[window.address] then return end
    local was_active = recent[1] == window.address or recent[2] == window.address
    closing[window.address] = true
    local after = {}
    local seen = false
    for _, address in ipairs(recent) do
        if seen then table.insert(after, address) end
        if address == window.address then seen = true end
    end
    forget(window.address)
    if not was_active then return end
    hl.timer(function()
        closing[window.address] = nil
        for _, address in ipairs(after) do
            local candidate = hl.get_window("address:" .. address)
            if candidate and candidate.workspace and window.workspace
                and candidate.workspace.id == window.workspace.id then
                focus(candidate)
                return
            end
        end
    end, { timeout = 30, type = "oneshot" })
end

hl.on("window.close", refocus_after_close)

hl.on("window.destroy", function(window)
    refocus_after_close(window)
    if window and window.address then before_fullscreen[window.address] = nil end
    if window and window.address and wm.selection[window.address] then wm.selection[window.address] = nil end
end)

return wm
