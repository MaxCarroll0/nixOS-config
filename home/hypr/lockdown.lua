-- Lockdown enforcement: pins focus to the engaged profile's own workspace and keeps only allowlisted windows on it.

local M = { source = nil, active = nil, kb_options = nil, opened = {} }

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

local function allowed(window)
    for _, rule in ipairs(M.active.allow) do
        if matches(rule, window) then return true end
    end
    return false
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

local function free_workspace()
    local used = {}
    for _, window in ipairs(hl.get_windows()) do
        if window.workspace and window.workspace.id then used[window.workspace.id] = true end
    end
    local id = 1
    while used[id] do id = id + 1 end
    return id
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
    elseif here then
        M.opened[window.address] = true
        move(window, stash)
    end
end

local function enforce()
    if not M.active then return end
    for _, window in ipairs(hl.get_windows()) do settle(window) end
    local special = hl.get_active_special_workspace()
    if special and special.name == stash then
        hl.dispatch(hl.dsp.workspace.toggle_special("lockdown"))
    end
    local current = hl.get_active_workspace()
    if not (current and current.name == M.active.workspace) then
        hl.dispatch(hl.dsp.focus({ workspace = home() }))
    end
    if hl.get_current_submap() ~= "lockdown" then hl.dispatch(hl.dsp.submap("lockdown")) end
end

local function engage()
    if M.kb_options == nil then
        M.kb_options = hl.get_config("input.kb_options") or ""
        local opts = M.kb_options == "" and "srvrkeys:none" or (M.kb_options .. ",srvrkeys:none")
        hl.config({ ["input.kb_options"] = opts })
    end
    enforce()
end

local function release()
    local target = nil
    for _, window in ipairs(hl.get_windows()) do
        if on(window, stash) then
            target = target or free_workspace()
            move(window, target)
        end
    end
    M.opened = {}
    if M.kb_options ~= nil then
        hl.config({ ["input.kb_options"] = M.kb_options })
        M.kb_options = nil
    end
    if hl.get_current_submap() == "lockdown" then hl.dispatch(hl.dsp.submap("reset")) end
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
    if active then engage() elseif was then release() end
end

hl.on("window.open", function(window)
    if not M.active then return end
    M.opened[window.address] = true
    hl.timer(function() settle(window) end, { timeout = 50, type = "oneshot" })
end)

hl.on("window.close", function(window)
    M.opened[window.address] = nil
end)

hl.on("keybinds.submap", function()
    if M.active and hl.get_current_submap() ~= "lockdown" then
        hl.timer(function()
            if M.active and hl.get_current_submap() ~= "lockdown" then hl.dispatch(hl.dsp.submap("lockdown")) end
        end, { timeout = 10, type = "oneshot" })
    end
end)

hl.timer(poll, { timeout = 1000, type = "repeat" })
hl.on("hyprland.start", poll)

return M
