-- Realises a target model on Hyprland's scrolling layout with its own layout messages.

local model = require("wm.model")

local M = {}

local function focus(ws, address)
    local window = model.live(ws)[address]
    if window then hl.dispatch(hl.dsp.focus({ window = window })) end
    return window
end

local function resize(ws, m)
    for _, column in ipairs(m.columns) do
        local window = focus(ws, column.windows[1])
        if window and math.abs(window.layout.column.width - column.width) > 0.001 then
            hl.dispatch(hl.dsp.layout(string.format("colresize %.4f", column.width)))
        end
    end
end

local function unmaximise(ws)
    for address, window in pairs(model.live(ws)) do
        if window.fullscreen ~= 0 then
            focus(ws, address)
            hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 0 }))
        end
    end
end

local function restructure(ws, current, target)
    for _, column in ipairs(current.columns) do
        for i = 1, #column.windows - 1 do
            focus(ws, column.windows[i])
            hl.dispatch(hl.dsp.layout("promote"))
        end
    end
    for i, address in ipairs(model.flat(target)) do
        local window = focus(ws, address)
        if window then
            for _ = 1, window.layout.column.index - (i - 1) do
                hl.dispatch(hl.dsp.layout("swapcol l"))
            end
        end
    end
    for _, column in ipairs(target.columns) do
        for j = 2, #column.windows do
            focus(ws, column.windows[j])
            hl.dispatch(hl.dsp.window.move({ direction = "l" }))
        end
    end
end

local function normalise(ws, target)
    local live = model.live(ws)
    local m = model.keep(model.copy(target), live)
    for address in pairs(live) do
        if not model.find(m, address) then
            m.columns[#m.columns + 1] = { windows = { address }, width = live[address].layout.column.width }
        end
    end
    return m
end

M.applying = false

function M.apply(ws, target)
    local m = normalise(ws, target)
    local current = model.read(ws)
    local focus_after = m.focus or current.focus
    if model.key(current) ~= model.key(m) then
        local animated = hl.get_config("animations.enabled")
        M.applying = true
        hl.config({ ["animations.enabled"] = false })
        local ok, err = pcall(function()
            unmaximise(ws)
            if model.shape(current) ~= model.shape(m) then restructure(ws, model.read(ws), m) end
            resize(ws, m)
        end)
        hl.config({ ["animations.enabled"] = animated })
        M.applying = false
        if not ok then hl.notification.create({ text = "wm: " .. tostring(err), timeout = 5000 }) end
    end
    if focus_after then focus(ws, focus_after) end
end

return M
