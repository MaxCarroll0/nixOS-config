-- Lockdown enforcement: hides windows outside the engaged profile's allowlist and pins the lockdown submap.

local M = { source = nil, active = nil, origin = {}, kb_options = nil }

local runtime = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/lockdown/active.lua"
local hidden = "special:lockdown"

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

local function workspace_name(window)
    return window.workspace and window.workspace.name or nil
end

local function hide(window)
    local ws = workspace_name(window)
    if ws == hidden then return end
    M.origin[window.address] = window.workspace.id
    hl.dispatch(hl.dsp.window.move({ workspace = hidden, follow = false, window = window }))
end

local function reveal(window)
    if workspace_name(window) ~= hidden then return end
    local target = M.origin[window.address] or hl.get_active_workspace().id
    M.origin[window.address] = nil
    hl.dispatch(hl.dsp.window.move({ workspace = target, follow = false, window = window }))
    return target
end

local function enforce_window(window)
    if not (M.active and window and window.mapped and window.workspace) then return end
    if allowed(window) then
        local target = reveal(window)
        if target then
            hl.dispatch(hl.dsp.focus({ workspace = target }))
            hl.dispatch(hl.dsp.focus({ window = window }))
        end
    else
        hide(window)
    end
end

local function enforce()
    if not M.active then return end
    for _, window in ipairs(hl.get_windows()) do enforce_window(window) end
    local special = hl.get_active_special_workspace()
    if special and special.name == hidden then
        hl.dispatch(hl.dsp.workspace.toggle_special("lockdown"))
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
    for _, window in ipairs(hl.get_windows()) do
        if window.workspace and workspace_name(window) == hidden then reveal(window) end
    end
    M.origin = {}
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
    if M.active then hl.timer(function() enforce_window(window) end, { timeout = 50, type = "oneshot" }) end
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
