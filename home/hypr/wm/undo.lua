-- Undo ring: snapshots of every workspace model, relaunching windows that have gone.

local model = require("wm.model")

local M = { stack = {}, cursor = nil, commands = {}, pending = {}, limit = 64 }

local function quote(arg)
    return "'" .. arg:gsub("'", "'\\''") .. "'"
end

local function command_of(window)
    if window.class == "emacs" then return "emacsclient -c -n" end
    local cached = M.commands[window.address]
    if cached then return cached end
    local file = io.open("/proc/" .. window.pid .. "/cmdline", "rb")
    if not file then return nil end
    local raw = file:read("a")
    file:close()
    local args = {}
    for arg in raw:gmatch("([^%z]*)%z") do args[#args + 1] = quote(arg) end
    if #args == 0 then return nil end
    M.commands[window.address] = table.concat(args, " ")
    return M.commands[window.address]
end

local function windows_by_address()
    local by = {}
    for _, window in ipairs(hl.get_windows()) do
        if window.mapped and window.workspace then by[window.address] = window end
    end
    return by
end

local function key_of(s)
    local ids, addresses = {}, {}
    for id in pairs(s.workspaces) do ids[#ids + 1] = id end
    for address in pairs(s.windows) do addresses[#addresses + 1] = address end
    table.sort(ids)
    table.sort(addresses)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = id .. "=" .. model.key(s.workspaces[id]) end
    for _, address in ipairs(addresses) do
        local info = s.windows[address]
        parts[#parts + 1] = address .. ":" .. info.ws .. (info.floating and "f" or "t")
    end
    return table.concat(parts, ";")
end

function M.snapshot()
    local s = { workspaces = {}, windows = {}, active = hl.get_active_workspace().id }
    local focused = hl.get_active_window()
    s.focus = focused and focused.address
    for address, window in pairs(windows_by_address()) do
        local ws = window.workspace.id
        s.windows[address] = { ws = ws, floating = window.floating, class = window.class, command = command_of(window) }
        if not s.workspaces[ws] then s.workspaces[ws] = model.read(ws) end
    end
    s.key = key_of(s)
    return s
end

local function record(s)
    local top = M.stack[#M.stack]
    if top and top.key == s.key then return end
    M.stack[#M.stack + 1] = s
    if #M.stack > M.limit then
        table.remove(M.stack, 1)
        if M.cursor then M.cursor = M.cursor - 1 end
    end
end

function M.checkpoint()
    M.cursor = nil
    record(M.snapshot())
end

local function rename(old, new)
    for _, s in ipairs(M.stack) do
        for _, m in pairs(s.workspaces) do model.rename(m, old, new) end
        s.windows[new], s.windows[old] = s.windows[old], nil
        if s.focus == old then s.focus = new end
    end
    for _, p in ipairs(M.pending) do
        for _, m in pairs(p.snapshot.workspaces) do model.rename(m, old, new) end
    end
end

local function focus(address)
    local window = windows_by_address()[address]
    if window then hl.dispatch(hl.dsp.focus({ window = window })) end
end

local function restore(s, backend)
    local live = windows_by_address()
    for address, info in pairs(s.windows) do
        local window = live[address]
        if window then
            if window.workspace.id ~= info.ws then
                hl.dispatch(hl.dsp.window.move({ workspace = info.ws, follow = false, window = window }))
            end
            if window.floating ~= info.floating then
                hl.dispatch(hl.dsp.focus({ window = window }))
                hl.dispatch(hl.dsp.window.float())
            end
        elseif info.command then
            M.pending[#M.pending + 1] = {
                address = address,
                class = info.class,
                ws = info.ws,
                snapshot = s,
                deadline = os.time() + 10,
            }
            hl.dispatch(hl.dsp.exec_cmd(info.command))
        end
    end
    for id, m in pairs(s.workspaces) do
        if id ~= s.active then backend.apply(id, m) end
    end
    if s.workspaces[s.active] then backend.apply(s.active, s.workspaces[s.active]) end
    if s.focus then focus(s.focus) end
end

function M.undo(backend)
    local now = M.snapshot()
    M.cursor = M.cursor or #M.stack + 1
    record(now)
    local i = M.cursor - 1
    while i >= 1 and M.stack[i].key == now.key do i = i - 1 end
    if i < 1 then return end
    M.cursor = i
    restore(M.stack[i], backend)
end

function M.claim(window, backend)
    for i, p in ipairs(M.pending) do
        if os.time() > p.deadline then
            table.remove(M.pending, i)
            return M.claim(window, backend)
        end
        if window.class == p.class then
            local address = window.address
            rename(p.address, address)
            table.remove(M.pending, i)
            hl.timer(function()
                local live = windows_by_address()[address]
                if not live then return end
                if live.workspace.id ~= p.ws then
                    hl.dispatch(hl.dsp.window.move({ workspace = p.ws, follow = false, window = live }))
                end
                backend.apply(p.ws, p.snapshot.workspaces[p.ws] or { columns = {} })
            end, { timeout = 80, type = "oneshot" })
            return true
        end
    end
end

return M
