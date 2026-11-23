-- Lockdown enforcement: pins focus to the engaged profile's own workspace, keeps only allowlisted windows on it and holds the profile's submap.

local M = {
    source = nil,
    active = nil,
    kb_options = nil,
    opened = {},
    before = {},
    submaps = {},
    keep = {},
    spare = {},
    stray_check_ms = 1500,
    stray_kill_ms = 3000,
}

local runtime = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/lockdown/active.lua"
local stash = "special:lockdown"

local function read_active()
    local file = io.open(runtime, "r")
    if not file then return nil, nil end
    local text = file:read("a")
    file:close()
    local chunk = load(text, "lockdown", "t", {})
    if not chunk then return text, nil end
    local ok, value = pcall(chunk)
    return text, ok and value or nil
end

local function matches(rule, window)
    if rule.class and not (window.class or ""):match(rule.class) then return false end
    if rule.title and not (window.title or ""):match(rule.title) then return false end
    return rule.class ~= nil or rule.title ~= nil
end

local function any_match(rules, window)
    for _, rule in ipairs(rules or {}) do
        if matches(rule, window) then return true end
    end
    return false
end

local function allowed(window)
    return any_match(M.active.allow, window)
end

local function submap_name()
    local names = M.submaps[M.active.profile] or {}
    return names[M.active.substate] or "lockdown"
end

local function is_lockdown_submap(name)
    if name == "lockdown" then return true end
    for _, names in pairs(M.submaps) do
        for _, n in pairs(names) do
            if n == name then return true end
        end
    end
    return false
end

local function enter_submap()
    if not M.active then return end
    local want = submap_name()
    local current = hl.get_current_submap()
    if current == want then return end
    if current == nil or current == "" or current == "default" or current == "reset" or is_lockdown_submap(current) then
        hl.dispatch(hl.dsp.submap(want))
    end
end

local function home()
    return "name:" .. M.active.workspace
end

local function on(window, name)
    return window.workspace ~= nil and window.workspace.name == name
end

local function move(window, target)
    hl.dispatch(hl.dsp.window.move({ workspace = target, follow = false, window = window }))
end

local function maximise(window)
    if window.fullscreen == 0 then
        hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 1, client = 0, window = "address:" .. window.address }))
    end
end

local function kept(window)
    return any_match(M.keep[M.active.profile], window) or any_match(M.spare, window)
end

local function command_name(pid)
    local file = io.open("/proc/" .. pid .. "/comm", "r")
    if not file then return "" end
    local name = file:read("l") or ""
    file:close()
    return name
end

local function protected(window)
    if not window.pid or window.pid <= 1 or (window.class or "") == "" or kept(window) then return true end
    if command_name(window.pid):match("^emacs") then return true end
    for _, other in ipairs(hl.get_windows()) do
        if other.pid == window.pid and (M.before[other.address] or kept(other)) then return true end
    end
    return false
end

local function reap(pid, signal, next_signal)
    if not M.active then return end
    hl.dispatch(hl.dsp.exec_cmd(string.format("kill -%s %d", signal, pid)))
    if next_signal then
        hl.timer(function() reap(pid, next_signal, nil) end, { timeout = M.stray_kill_ms, type = "oneshot" })
    end
end

local function free_workspace(taken)
    local used = {}
    for _, window in ipairs(hl.get_windows()) do
        if window.workspace and window.workspace.id then used[window.workspace.id] = true end
    end
    local id = 1
    while used[id] or taken[id] do id = id + 1 end
    taken[id] = true
    return id
end

local function stranded(window)
    local ws = window.workspace
    return window.mapped and ws ~= nil and (ws.name == stash or (ws.id == nil and not ws.special))
end

local function managed(window)
    return any_match(M.keep[M.active.profile], window)
end

local function rehome(only)
    local targets, taken = {}, {}
    local current = hl.get_active_workspace()
    for _, window in ipairs(hl.get_windows()) do
        if stranded(window) and (only == nil or only(window)) then
            local from = window.workspace.name
            targets[from] = targets[from] or free_workspace(taken)
            move(window, targets[from])
        end
    end
    local landing = current and targets[current.name]
    if landing then hl.dispatch(hl.dsp.focus({ workspace = landing })) end
end

local function settle(window)
    if not (M.active and window and window.mapped and window.workspace) then return end
    local here = on(window, M.active.workspace)
    local stashed = on(window, stash)
    if allowed(window) then
        if stashed or (M.opened[window.address] and not here) then
            move(window, home())
            maximise(window)
        elseif here then
            maximise(window)
        end
    elseif stashed and managed(window) then
        move(window, home())
    end
end

local function enforce()
    if not M.active then return end
    for _, window in ipairs(hl.get_windows()) do settle(window) end
    rehome(function(window) return not managed(window) end)
    local special = hl.get_active_special_workspace()
    if special and special.name == stash then
        hl.dispatch(hl.dsp.workspace.toggle_special("lockdown"))
    end
    enter_submap()
end

local function engage()
    M.before = {}
    for _, window in ipairs(hl.get_windows()) do M.before[window.address] = true end
    if M.kb_options == nil then
        M.kb_options = hl.get_config("input.kb_options") or ""
        local opts = M.kb_options == "" and "srvrkeys:none" or (M.kb_options .. ",srvrkeys:none")
        hl.config({ ["input.kb_options"] = opts })
    end
    enforce()
    hl.dispatch(hl.dsp.focus({ workspace = home() }))
end


local function release()
    rehome()
    M.opened = {}
    M.before = {}
    if M.kb_options ~= nil then
        hl.config({ ["input.kb_options"] = M.kb_options })
        M.kb_options = nil
    end
    if is_lockdown_submap(hl.get_current_submap()) then hl.dispatch(hl.dsp.submap("reset")) end
end

local function poll()
    local source, active = read_active()
    if source == M.source and (active == nil) == (M.active == nil) then
        if M.active then enforce() end
        return
    end
    M.source = source
    local was = M.active
    M.active = active
    if active and was then
        enforce()
    elseif active then
        engage()
    elseif was then
        release()
    end
end

hl.on("window.open", function(window)
    if not M.active then return end
    if not allowed(window) then
        local pid = not protected(window) and window.pid
        hl.dispatch(hl.dsp.window.close({ window = "address:" .. window.address }))
        if pid then
            hl.timer(function() reap(pid, "TERM", "KILL") end, { timeout = M.stray_check_ms, type = "oneshot" })
        end
        return
    end
    M.opened[window.address] = true
    hl.timer(function() settle(window) end, { timeout = 50, type = "oneshot" })
end)


hl.on("keybinds.submap", function(name)
    if not M.active or name == submap_name() then return end
    hl.timer(enter_submap, { timeout = 10, type = "oneshot" })
end)

hl.on("window.close", function(window)
    M.opened[window.address] = nil
end)

hl.timer(poll, { timeout = 1000, type = "repeat" })
hl.on("hyprland.start", function()
    poll()
    if not M.active then rehome() end
end)

return M
