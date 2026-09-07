-- claude-voice / Hammerspoon floating control panel
--
-- Cmd+Ctrl+G toggles a glassy floating panel with:
--   * on/off toggle, stop button
--   * speed / volume sliders, voice picker
--   * play/pause + seek bar for the current message (drag the ball to jump
--     back to any point of the speech)
--   * clickable history of past spoken messages: agent name, then the
--     message. Click any to read the full text in a scrollable popup
--     (headings, lists, tables rendered). Buttons: Previous / Next
--     (same list), Replay, Open (that agent's Terminal), Close
--   * five most recent agent-to-agent messages (agent name, then the
--     message). Click to read the whole note in the same formatted popup
--   * side column of every registered agent: Live (green = Claude is
--     still running in that Terminal) on top, Idle underneath. A window
--     whose title still says claude after the process has exited is Idle.
--     Click Open (or a name) to bring that agent's Terminal to the front
--     and minimize this panel. If a Terminal with that agent name is
--     already open, reuse it — do not open a second window with the same
--     title. The Terminal is enlarged so it is readable — never a 33×5
--     thumbnail.
--     Cmd+Ctrl+G brings this panel back.
--   * "Arrange live" opens a card grid of running agents (A–Z, live only)
--     beside this panel so you can see both. Click a card to read messages.
--     Close on a card types exit in that Claude, then closes its Terminal.
--     Open (or a new agent Terminal appearing) minimizes this panel so the
--     Terminal is in front. Click it in the Dock, or press Cmd+Ctrl+G, to
--     bring the panel back.
--   * "Show messages" draws a moving network of who wrote to whom.
--     Click a line to read the last note between those two agents.
--   * "Close all" types exit in every running Claude, then closes
--     all Terminal windows (asks first).
--   * "Save" stores every Terminal where Claude is still running (not
--     windows where you already typed exit). "Clock" lists those save
--     times; click one after a restart to reopen them one by one
--     (named after each agent) and continue Claude in each folder.
--   * "Make smaller" shrinks the panel to a compact card on the right edge
--
-- Requires claude-voice >= 0.2 with the history/replay/seek/playpause
-- commands (this repo). The panel shells out to the CLI for everything.
--
-- Install
-- -------
-- 1. Install Hammerspoon: `brew install --cask hammerspoon`, then grant it
--    Accessibility permissions in System Settings -> Privacy & Security.
-- 2. In ~/.hammerspoon/init.lua, either paste this file or:
--      dofile(os.getenv("HOME") .. "/code/claude-voice/integrations/hammerspoon-panel.lua")
-- 3. Edit CLAUDE_VOICE_BIN below if your install lives somewhere else.
-- 4. Open Hammerspoon and click "Reload Config" (menu bar icon).

local CLAUDE_VOICE_BIN = os.getenv("HOME") .. "/.local/bin/claude-voice"
local PYTHON_BIN = "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"
local CLAUDE_VOICE_PY = os.getenv("HOME") .. "/code/claude-voice/claude_voice.py"
local CV_CONFIG  = os.getenv("HOME") .. "/.config/claude-voice/config.json"
local CV_HISTORY = os.getenv("HOME") .. "/.cache/claude-voice/history.jsonl"
local CV_SNAPS   = os.getenv("HOME") .. "/.config/claude-voice/snapshots.json"
local ORCH_MSGS  = os.getenv("HOME") .. "/.claude/orchestration/messages"
local ORCH_REG   = os.getenv("HOME") .. "/.claude/orchestration/registry.json"
local KOKORO_VOICES = {
    "af_heart", "af_nova", "af_alloy", "af_sky",
    "am_adam", "am_fenrir", "am_michael", "am_onyx",
    "bm_george", "bm_daniel", "bf_emma", "bf_isabella",
}

-- Mirror of THEMES in claude_voice.py (accent / near, as "r,g,b" for CSS vars):
-- the panel follows whatever `claude-voice theme <name>` is active.
local CV_THEMES = {
    aurora = { accent = "120,200,255", near = "80,150,210" },
    ember  = { accent = "255,170,90",  near = "205,120,60" },
    violet = { accent = "195,145,255", near = "140,100,205" },
    mint   = { accent = "110,235,185", near = "70,175,140" },
    mono   = { accent = "235,235,235", near = "170,170,170" },
}

local cvPanel = nil
local cvTimer = nil
local cvCompact = false
local cvBoard = false
local cvNet = false
local cvShowSnaps = false
local cvRefresh
local cvLastFullFrame = nil
local cvArranging = false
local cvHidden = false
local cvScanReady = false
local cvRestoreBusy = false
local cvLaunchErrShown = false
local FULL = { w = 560, h = 920 }
local MINI = { w = 300, h = 128 }

-- Prefer the installed `claude-voice` command; if it is missing, run the
-- Python file in this repo the same way ~/.hammerspoon/init.lua already does.
local function cvSpawn(args, callback)
    local bin, taskArgs
    if hs.fs.attributes(CLAUDE_VOICE_BIN) then
        bin, taskArgs = CLAUDE_VOICE_BIN, args
    else
        bin = (hs.fs.attributes(PYTHON_BIN) and PYTHON_BIN) or "/usr/bin/python3"
        taskArgs = { CLAUDE_VOICE_PY }
        for i = 1, #args do taskArgs[#taskArgs + 1] = args[i] end
    end
    local t = hs.task.new(bin, callback or function() end, taskArgs)
    t:start()
    return t
end

local function cvRun(args, andThen)
    cvSpawn(args, function()
        if andThen then andThen() end
    end)
end

local function htmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
             :gsub('"', "&quot;"):gsub("'", "&#39;"))
end

-- Strip a trailing slash so "/foo" and "/foo/" count as the same folder.
local function cvNormPath(p)
    if type(p) ~= "string" or p == "" then return "" end
    return (p:gsub("/+$", ""))
end

local function cvFolderName(path)
    return cvNormPath(path):match("([^/]+)$") or ""
end

-- One-line preview of a message for the history list.
local function cvPlainSnippet(text, maxLen)
    local s = tostring(text or "")
        :gsub("\r\n", "\n")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("\n+", " ")
        :gsub("%s+", " ")
    s = htmlEscape(s)
    if #s > maxLen then s = s:sub(1, maxLen) .. "…" end
    return s
end

-- Map a folder name (cwd) or stored label to the registry agent name.
-- Rebuilt once per panel refresh so we do not re-read registry.json 20 times.
local cvAliasCache = nil
local cvMsgIndex = nil
local function cvAgentAliasIndex()
    if cvAliasCache then return cvAliasCache.byKey, cvAliasCache.names end
    local byKey, names = {}, {}
    local seen = {}
    local function add(label, canon)
        if type(label) ~= "string" or label == "" then return end
        byKey[label] = canon or label
        if not seen[label] then
            seen[label] = true
            names[#names + 1] = label
        end
    end
    local reg = hs.json.read(ORCH_REG) or {}
    for path, entry in pairs(reg) do
        if type(entry) == "table" and entry.name then
            add(entry.name, entry.name)
            add(cvFolderName(path), entry.name)
        end
    end
    table.sort(names, function(a, b) return #a > #b end)
    cvAliasCache = { byKey = byKey, names = names }
    return byKey, names
end

local function cvResolveAgent(label)
    if type(label) ~= "string" or label == "" then return nil end
    local byKey = cvAgentAliasIndex()
    return byKey[label] or label
end

-- Every name this agent might appear under (registry name, folder, aliases).
local function cvNameKeys(name, path)
    local keys = {}
    local function add(s)
        if type(s) == "string" and s ~= "" then keys[s:lower()] = true end
    end
    add(name)
    add(cvFolderName(path or ""))
    local byKey = cvAgentAliasIndex()
    for label, canon in pairs(byKey) do
        if label == name or canon == name then
            add(label)
            add(canon)
        end
    end
    return keys
end

-- Spoken history used to mash "kpi_analysis. the message" into one string.
-- Pull the agent name off the front so the list can show them separately.
local function cvSplitSpoken(entry)
    local spoken = entry.text or ""
    local display = entry.display or spoken
    local stored = entry.agent
    local byKey, names = cvAgentAliasIndex()
    local function stripPrefix(src, name)
        local p = name .. ". "
        if src:sub(1, #p) == p then return src:sub(#p + 1) end
        p = name .. ": "
        if src:sub(1, #p) == p then return src:sub(#p + 1) end
        return nil
    end
    if type(stored) == "string" and stored ~= "" then
        local snippet = spoken
        local stripped = stripPrefix(snippet, stored)
            or stripPrefix(snippet, cvFolderName(stored) or "")
        if not stripped then
            for _, n in ipairs(names) do
                if byKey[n] == stored or n == stored then
                    stripped = stripPrefix(snippet, n)
                    if stripped then break end
                end
            end
        end
        return cvResolveAgent(stored), stripped or snippet, display
    end
    for _, n in ipairs(names) do
        local rest = stripPrefix(spoken, n)
        if rest then
            return cvResolveAgent(n), rest, display
        end
    end
    local n, rest = spoken:match("^([%w_%-]+)%.%s+(.*)$")
    if n and rest then return n, rest, display end
    return nil, spoken, display
end

-- One clickable row: time + agent name on the first line, message under it.
local function cvMsgRow(opts)
    local who = ""
    if opts.who and opts.who ~= "" then
        who = '<span class="who">' .. htmlEscape(opts.who) .. '</span>'
    end
    local idx = ""
    if opts.index then
        idx = ' data-index="' .. tostring(opts.index) .. '"'
    end
    local path = ""
    if opts.path and opts.path ~= "" then
        path = ' data-path="' .. htmlEscape(opts.path) .. '"'
    end
    local name = ""
    if opts.name and opts.name ~= "" then
        name = ' data-name="' .. htmlEscape(opts.name) .. '"'
    end
    return '<div class="msg" tabindex="0" role="button"' .. idx .. path .. name ..
        ' data-route="' .. htmlEscape(opts.route or opts.who or "") ..
        '" data-meta="' .. htmlEscape(opts.meta or "") ..
        '" onclick="openMsg(this)"' ..
        ' onkeydown="if(event.key===\'Enter\'||event.key===\' \'){event.preventDefault();openMsg(this)}">' ..
        '<div class="msg-head"><span class="t">' .. htmlEscape(opts.when or "") ..
        '</span>' .. who .. '</div>' ..
        '<div class="snip">' .. (opts.snippet or "") .. '</div>' ..
        '<div class="full">' .. htmlEscape(opts.full or "") .. '</div></div>'
end

local function cvReadHistory(maxItems)
    local items = {}
    local f = io.open(CV_HISTORY, "r")
    if not f then return items end
    for line in f:lines() do
        local ok, e = pcall(hs.json.decode, line)
        if ok and e and e.text then table.insert(items, e) end
    end
    f:close()
    -- newest first
    local rev = {}
    for i = #items, 1, -1 do table.insert(rev, items[i]) end
    local out = {}
    for i = 1, math.min(maxItems, #rev) do out[i] = rev[i] end
    return out
end

-- Walk inbox + archive for the newest unique agent-to-agent notes.
local function cvWalkMd(dir, acc)
    local attr = hs.fs.attributes(dir)
    if not attr or attr.mode ~= "directory" then return end
    for name in hs.fs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. "/" .. name
            local a = hs.fs.attributes(p)
            if a and a.mode == "directory" then
                cvWalkMd(p, acc)
            elseif name:sub(-3) == ".md" then
                acc[#acc + 1] = p
            end
        end
    end
end

local function cvParseOrchMsg(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    if not text then return nil end
    local fm, body = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n?(.*)$")
    if not fm then return nil end
    local msg = { body = body or "", path = path }
    for line in fm:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+):%s*(.*)$")
        if k then msg[k] = v end
    end
    if not msg.from or not msg.to then return nil end
    msg.body = msg.body:gsub("^%s+", ""):gsub("%s+$", "")
    msg.re = msg.re or ""
    msg.date = msg.date or ""
    local stamp = path:match("(%d%d%d%d%-%d%d%-%d%d%-%d%d%d%d)") or ""
    msg.sort = ((msg.date ~= "" and msg.date) or stamp) .. " " .. stamp
    return msg
end

local function cvReadOrchMessages(maxItems)
    local ok, result = pcall(function()
        local paths = {}
        cvWalkMd(ORCH_MSGS .. "/inbox", paths)
        cvWalkMd(ORCH_MSGS .. "/archive", paths)
        local seen = {}
        for _, p in ipairs(paths) do
            local m = cvParseOrchMsg(p)
            if m then
                local key = m.from .. "\0" .. m.to .. "\0" .. m.date .. "\0" .. m.re
                local prev = seen[key]
                if not prev or #m.body > #prev.body then
                    seen[key] = m
                end
            end
        end
        local items = {}
        for _, m in pairs(seen) do items[#items + 1] = m end
        table.sort(items, function(a, b) return a.sort > b.sort end)
        local out = {}
        for i = 1, math.min(maxItems, #items) do out[i] = items[i] end
        return out
    end)
    if ok and type(result) == "table" then return result end
    return {}
end

local function cvAsQuote(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function cvPanelIsMinimized()
    if not cvPanel then return true end
    if cvHidden then return true end
    local hw = cvPanel:hswindow()
    if not hw then return true end
    return hw:isMinimized() == true
end

-- This panel floats above Terminal. Drop that so macOS can park it in
-- the Dock (minimize), instead of hiding/closing it. Cmd+Ctrl+G or the
-- Dock thumbnail brings it back.
local function cvMinimizePanel()
    if not cvPanel then return end
    cvHidden = true
    pcall(function()
        cvPanel:level(hs.drawing.windowLevels.normal)
    end)
    local hw = cvPanel:hswindow()
    if hw then
        hw:minimize()
    end
end

local function cvRestorePanel()
    if not cvPanel then return end
    cvHidden = false
    pcall(function()
        cvPanel:level(hs.drawing.windowLevels.floating)
    end)
    cvPanel:show()
    local hw = cvPanel:hswindow()
    if hw then
        pcall(function() hw:unminimize() end)
        hw:raise()
        hw:focus()
    end
    if cvRefresh then cvRefresh() end
end

-- Readable Terminal size. Stay off the left Dock / app icons, and leave a
-- strip on the right only while this panel is still visible.
local function cvDockEdge()
    local ok, edge = hs.osascript.applescript(
        'tell application "System Events" to tell dock preferences to get screen edge as text')
    edge = tostring(edge or ""):lower()
    if ok and edge:find("left", 1, true) then return "left" end
    if ok and edge:find("right", 1, true) then return "right" end
    return "bottom"
end

local function cvStandardTermFrame()
    local screen = hs.screen.mainScreen()
    local sf = screen:frame()
    local ff = screen:fullFrame()
    local gutter = 24
    if cvPanel and not cvPanelIsMinimized() then
        local pf = cvPanel:frame()
        if pf and pf.x > sf.x + sf.w * 0.45 then
            gutter = (sf.x + sf.w) - pf.x + 16
        else
            gutter = FULL.w + 28
        end
    end
    -- Keep left-side Dock icons visible (including auto-hide).
    local leftPad = 28
    if cvDockEdge() == "left" then
        local reserved = math.max(0, sf.x - ff.x)
        if reserved < 40 then
            leftPad = 120
        else
            leftPad = 24
        end
    end
    local w = math.min(1040, math.max(720, sf.w - gutter - leftPad - 24))
    local h = math.min(720, math.max(480, sf.h - 96))
    return { x = sf.x + leftPad, y = sf.y + 48, w = w, h = h }
end

-- Bring one Terminal window to the current Space, enlarge it, and
-- put it in front. If `win` is omitted, uses Terminal's focused window.
local function cvResizeFocusedTerminal(win)
    local app = hs.application.get("Terminal")
    if not app then return end
    app:activate()
    local w = win or app:focusedWindow()
    if not w then return end
    pcall(function()
        local space = hs.spaces.focusedSpace()
        if space then hs.spaces.moveWindowToSpace(w, space) end
    end)
    pcall(function() w:unminimize() end)
    w:setFrame(cvStandardTermFrame())
    w:raise()
    w:focus()
end

-- Terminal.app titles look like:
--   "iNotes — ✳ some task — node ◂ claude -c — 33×5"   (Claude still running)
--   "iNotes — -zsh — 128×30"                           (idle shell)
-- Live / green = a process named "claude" is running in that Terminal.
-- A leftover title after Claude has exited is Idle, not green.
-- Click matches the folder name at the start of the title, then enlarges
-- that window so it is readable.
local cvTermByPath = {}
local cvTermSig = ""
local cvLiveTitles = {}

-- AppleScript fragment: given window `w`, sets nm + isLive.
-- isLive is true only while a process named "claude" is running.
local function cvLiveClaudeSnippet()
    return [[
      set nm to name of w as text
      set procClaude to false
      repeat with tb in tabs of w
        try
          set procs to processes of tb
          repeat with p in procs
            if (p as text) is "claude" then set procClaude to true
          end repeat
        end try
      end repeat
      set isLive to procClaude
    ]]
end

local function cvIndexRegistry()
    local byKey = {}
    local reg = hs.json.read(ORCH_REG) or {}
    for path, entry in pairs(reg) do
        if type(entry) == "table" and entry.name then
            local p = cvNormPath(path)
            local rec = {
                name = entry.name,
                path = p,
                last_active = entry.last_active or "",
            }
            local folder = cvFolderName(p)
            if folder ~= "" then byKey[folder] = rec end
            byKey[entry.name] = rec
        end
    end
    return byKey
end

local function cvScanSessions(andThen)
    local script = [[
set out to ""
tell application "Terminal"
  repeat with w in windows
    try
]] .. cvLiveClaudeSnippet() .. [[
      set live to "0"
      if isLive then set live to "1"
      set AppleScript's text item delimiters to " — "
      set prefix to text item 1 of nm
      set AppleScript's text item delimiters to ""
      -- Do not use AppleScript `tab` here: inside `tell Terminal` it means
      -- a tab object, so the line becomes "1tabVAD..." and Lua cannot parse it.
      set out to out & live & "::" & prefix & linefeed
    end try
  end repeat
end tell
return out
]]
    local t = hs.task.new("/usr/bin/osascript", function(_, stdout)
        local byKey = cvIndexRegistry()
        local byPath, sig, liveTitles = {}, {}, {}
        for line in (stdout or ""):gmatch("[^\n]+") do
            local live, prefix = line:match("^([01])::(.*)$")
            if prefix and prefix ~= "" then
                prefix = prefix:gsub("%s+$", "")
                local rec = byKey[prefix]
                local path = rec and rec.path or ("__win__/" .. prefix)
                local isCloud = live == "1"
                local prev = byPath[path]
                if not prev or (isCloud and not prev.cloud) then
                    byPath[path] = {
                        prefix = prefix,
                        cloud = isCloud,
                        name = rec and rec.name or prefix,
                        last_active = rec and rec.last_active or "",
                    }
                end
                if isCloud then liveTitles[prefix] = true end
                sig[#sig + 1] = live .. prefix
            end
        end
        table.sort(sig)
        local s = table.concat(sig, ";")
        local changed = s ~= cvTermSig
        local prevLive = cvLiveTitles
        cvTermSig = s
        cvTermByPath = byPath
        cvLiveTitles = liveTitles
        -- A new Claude Terminal appeared: get this panel out of the way.
        if cvScanReady then
            for prefix, _ in pairs(liveTitles) do
                if not prevLive[prefix] then
                    if cvPanel and not cvPanelIsMinimized() then
                        cvMinimizePanel()
                    end
                    break
                end
            end
        end
        cvScanReady = true
        if andThen then andThen(changed) end
    end)
    t:setInput(script)
    t:start()
end

-- Live = Claude is still running in that Terminal (busy tab).
-- Idle = registered agent with no running Claude process.
local function cvAgentLists()
    local ok, result = pcall(function()
        local byPath = {}
        local reg = hs.json.read(ORCH_REG) or {}
        for path, entry in pairs(reg) do
            if type(entry) == "table" and entry.name then
                local p = cvNormPath(path)
                local term = cvTermByPath[p]
                byPath[p] = {
                    name = entry.name,
                    path = p,
                    last_active = entry.last_active or "",
                    cloud = term and term.cloud or false,
                    live = term and term.cloud or false,
                }
            end
        end
        for p, term in pairs(cvTermByPath) do
            if not byPath[p] and term.cloud then
                byPath[p] = {
                    name = term.name or cvFolderName(p),
                    path = p,
                    last_active = "",
                    cloud = true,
                    live = true,
                }
            end
        end
        local live, idle = {}, {}
        for _, a in pairs(byPath) do
            if a.live then live[#live + 1] = a else idle[#idle + 1] = a end
        end
        table.sort(live, function(a, b)
            return a.name:lower() < b.name:lower()
        end)
        table.sort(idle, function(a, b)
            if a.last_active ~= b.last_active then
                return a.last_active > b.last_active
            end
            return a.name:lower() < b.name:lower()
        end)
        return { live = live, idle = idle }
    end)
    if ok and type(result) == "table" then return result end
    return { live = {}, idle = {} }
end

-- Who-talked-to-whom: one node per agent, one line per pair, last note on the line.
local function cvCommGraph()
    local lists = cvAgentLists()
    local live, paths = {}, {}
    local function mark(a)
        if not a or not a.name then return end
        if a.live then live[a.name] = true end
        if a.path and a.path ~= "" then paths[a.name] = a.path end
    end
    for _, a in ipairs(lists.live) do mark(a) end
    for _, a in ipairs(lists.idle) do mark(a) end
    local nodesBy = {}
    local function ensure(raw)
        if type(raw) ~= "string" or raw == "" then return nil end
        local id = cvResolveAgent(raw) or raw
        if not nodesBy[id] then
            nodesBy[id] = {
                id = id,
                live = live[id] and true or false,
                path = paths[id] or "",
            }
        elseif live[id] then
            nodesBy[id].live = true
        end
        return id
    end
    local edges = {}
    for _, e in ipairs(cvReadOrchMessages(150)) do
        local a, b = ensure(e.from), ensure(e.to)
        if a and b and a ~= b then
            local lo, hi = a, b
            if lo:lower() > hi:lower() then lo, hi = hi, lo end
            local k = lo .. "\0" .. hi
            local prev = edges[k]
            if not prev then
                local text = e.body or ""
                if #text > 20000 then text = text:sub(1, 20000) .. "\n…" end
                edges[k] = {
                    source = lo,
                    target = hi,
                    from = a,
                    to = b,
                    n = 1,
                    when = e.date or "",
                    route = (e.from or "?") .. " → " .. (e.to or "?"),
                    text = text,
                }
            else
                prev.n = prev.n + 1
            end
        end
    end
    local nodeList, edgeList = {}, {}
    for _, n in pairs(nodesBy) do nodeList[#nodeList + 1] = n end
    table.sort(nodeList, function(x, y) return x.id:lower() < y.id:lower() end)
    for _, e in pairs(edges) do edgeList[#edgeList + 1] = e end
    return { nodes = nodeList, edges = edgeList }
end

local function cvAgentButton(a)
    local cls = a.live and "agent live" or "agent"
    local dot = a.live
        and '<span class="dot" aria-hidden="true"></span>'
        or '<span class="dot off" aria-hidden="true"></span>'
    local tip = a.path
    if a.live then
        tip = a.name .. " — Claude is running (click to open at full size)"
    elseif a.last_active ~= "" then
        tip = a.name .. " — last active " .. a.last_active
    end
    return '<button type="button" class="' .. cls ..
        '" data-path="' .. htmlEscape(a.path) ..
        '" data-name="' .. htmlEscape((a.name or ""):lower()) ..
        '" title="' .. htmlEscape(tip) ..
        '" onclick="send({action:\'goto\',path:this.dataset.path})">' ..
        dot .. '<span class="an">' .. htmlEscape(a.name) .. '</span></button>'
end

local function cvPrefixesFor(path)
    local prefs, seen = {}, {}
    local function add(s)
        if s and s ~= "" and not seen[s] then
            seen[s] = true
            prefs[#prefs + 1] = s
        end
    end
    add(cvFolderName(path))
    local term = cvTermByPath[cvNormPath(path)]
    if term then add(term.prefix) add(term.name) end
    local byKey = cvIndexRegistry()
    for _, rec in pairs(byKey) do
        if rec.path == cvNormPath(path) then add(rec.name) end
    end
    table.sort(prefs, function(a, b) return #a > #b end)
    return prefs
end

local function cvAgentDisplayName(path)
    path = cvNormPath(path or "")
    if path == "" then return "" end
    local term = cvTermByPath[path]
    if term and term.name and term.name ~= "" then return term.name end
    local folder = cvFolderName(path)
    local byKey = cvIndexRegistry()
    local rec = byKey[folder] or byKey[path]
    if rec and rec.name and rec.name ~= "" then return rec.name end
    for _, r in pairs(byKey) do
        if r.path == path and r.name and r.name ~= "" then return r.name end
    end
    return folder
end

local function cvTitleTabsScript(title)
    title = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then return "" end
    return [[
  repeat with tb in tabs of target
    try
      set custom title of tb to ]] .. cvAsQuote(title) .. [[
    end try
  end repeat
]]
end

local function cvSetFrontTerminalTitle(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    hs.osascript.applescript([[
tell application "Terminal"
  if (count of windows) is 0 then return
  try
    set target to front window
]] .. cvTitleTabsScript(name) .. [[
  end try
end tell
]])
end

-- First chunk of a Terminal title bar ("ADR — ✳ task — claude — 116×30").
local function cvTitleHead(title)
    title = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return (title:match("^(.-) [—–-]") or title):gsub("%s+$", "")
end

local function cvTitleBelongsTo(title, prefixes)
    local head = cvTitleHead(title):lower()
    if head == "" then return false end
    for _, p in ipairs(prefixes or {}) do
        if type(p) == "string" and p ~= "" and head == p:lower() then
            return true
        end
    end
    return false
end

-- Already-open Terminal whose title starts with this agent name.
-- Prefers a window that still has Claude running.
local function cvFindTerminalWindow(prefixes)
    local app = hs.application.get("Terminal")
    if not app then return nil end
    local idle
    for _, win in ipairs(app:allWindows()) do
        local t = win:title() or ""
        if cvTitleBelongsTo(t, prefixes) then
            if t:lower():find("claude", 1, true) then
                return win
            elseif not idle then
                idle = win
            end
        end
    end
    return idle
end

-- AppleScript fallback: sees minimized windows / other Spaces that
-- hs.window can miss. Matches by title only (no process walk).
local function cvFocusTerminalById(prefixes)
    local quoted = {}
    for _, p in ipairs(prefixes or {}) do
        if type(p) == "string" and p ~= "" then
            quoted[#quoted + 1] = cvAsQuote(p)
        end
    end
    if #quoted == 0 then return false end
    local script = [[
set prefs to {]] .. table.concat(quoted, ", ") .. [[}
set foundId to missing value
set liveId to missing value
tell application "Terminal"
  if (count of windows) is 0 then return "MISS"
  repeat with w in windows
    try
      set nm to name of w as text
      set head to nm
      if nm contains " — " then
        set AppleScript's text item delimiters to " — "
        set head to text item 1 of nm
        set AppleScript's text item delimiters to ""
      end if
      ignoring case
        repeat with p in prefs
          if head is (p as text) then
            if nm contains "claude" then
              set liveId to id of w
            else if foundId is missing value then
              set foundId to id of w
            end if
          end if
        end repeat
      end ignoring
    end try
  end repeat
  if liveId is not missing value then set foundId to liveId
  if foundId is missing value then return "MISS"
  try
    set target to first window whose id is foundId
    set miniaturized of target to false
    set index of target to 1
  end try
  activate
  return "OK"
end tell
]]
    local ok, out = hs.osascript.applescript(script)
    return ok and out == "OK"
end

-- Reuse a Terminal that already has this agent's name. Never open a second
-- window with the same title.
local function cvFocusTerminal(prefixes)
    local win = cvFindTerminalWindow(prefixes)
    if win then
        cvResizeFocusedTerminal(win)
        return true
    end
    if cvFocusTerminalById(prefixes) then
        hs.timer.doAfter(0.05, cvResizeFocusedTerminal)
        return true
    end
    return false
end

local function cvGotoAgent(path)
    if type(path) ~= "string" or path == "" then return end
    local prefixes = cvPrefixesFor(path)
    local name = cvAgentDisplayName(path)
    local seen = {}
    for _, p in ipairs(prefixes) do seen[p:lower()] = true end
    if name ~= "" and not seen[name:lower()] then
        table.insert(prefixes, 1, name)
    end
    -- Get this panel out of the way, then put the agent's Terminal on top.
    cvMinimizePanel()
    if cvFocusTerminal(prefixes) then
        return
    end
    -- No existing window with this name: open one in that folder.
    local folder = path
    if folder:sub(1, 8) == "__win__/" then return end
    hs.task.new("/usr/bin/open", function()
        hs.timer.doAfter(0.55, function()
            cvSetFrontTerminalTitle(name)
            cvResizeFocusedTerminal()
        end)
    end, { "-a", "Terminal", folder }):start()
end

local function cvReadSnaps()
    local data = hs.json.read(CV_SNAPS)
    if type(data) ~= "table" then return {} end
    if data.ts or data.agents then return { data } end
    local out = {}
    for _, s in ipairs(data) do
        if type(s) == "table" and type(s.agents) == "table" then
            out[#out + 1] = s
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.ts) or 0) > (tonumber(b.ts) or 0)
    end)
    return out
end

local function cvWriteSnaps(list)
    hs.fs.mkdir(os.getenv("HOME") .. "/.config/claude-voice")
    local ok = pcall(hs.json.write, list, CV_SNAPS, true, true)
    if ok then return end
    local f = io.open(CV_SNAPS, "w")
    if not f then return end
    f:write(hs.json.encode(list) or "[]")
    f:close()
end

-- Start Claude in a folder, continuing the last chat (`claude -c`).
-- Uses `open -a Terminal` (same as clicking Open) because a background
-- osascript process is not allowed to create Terminal windows.
local function cvLaunchClaude(path, name, andThen)
    path = cvNormPath(path)
    local finished = false
    local function done()
        if finished then return end
        finished = true
        if andThen then andThen() end
    end
    if path == "" or path:sub(1, 8) == "__win__/" then
        done()
        return false
    end
    if not hs.fs.attributes(path) then
        done()
        return false
    end
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = cvAgentDisplayName(path) end
    local t = hs.task.new("/usr/bin/open", function(exitCode)
        if exitCode ~= 0 and not cvLaunchErrShown then
            cvLaunchErrShown = true
            hs.alert.show("Could not open Terminal in that folder", 3)
        end
        hs.timer.doAfter(0.65, function()
            cvSetFrontTerminalTitle(name)
            local typed = hs.osascript.applescript([[
tell application "Terminal" to activate
delay 0.1
tell application "System Events"
  keystroke "claude -c"
  keystroke return
end tell
]])
            if typed == false and not cvLaunchErrShown then
                cvLaunchErrShown = true
                hs.alert.show("Could not type claude -c — grant Hammerspoon Accessibility", 3.5)
            end
            done()
        end)
    end, { "-a", "Terminal", path })
    if not t:start() then
        if not cvLaunchErrShown then
            cvLaunchErrShown = true
            hs.alert.show("Could not run Open", 3)
        end
        done()
        return false
    end
    hs.timer.doAfter(12, done)
    return true
end

-- Type "exit" in every tab where Claude is running, then close Terminal windows.
local function cvCloseAll()
    local script = [[
set liveIds to {}
tell application "Terminal"
  if (count of windows) is 0 then return "NONE"
  repeat with w in windows
    set hasClaude to false
    try
      repeat with tb in tabs of w
        try
          repeat with p in processes of tb
            if (p as text) is "claude" then set hasClaude to true
          end repeat
        end try
      end repeat
    end try
    if hasClaude then set end of liveIds to id of w
  end repeat
end tell
repeat with wid in liveIds
  tell application "Terminal"
    try
      set w to first window whose id is wid
      set index of w to 1
      activate
    end try
  end tell
  delay 0.15
  tell application "System Events"
    keystroke "exit"
    keystroke return
  end tell
  delay 0.35
end repeat
delay 0.8
tell application "Terminal"
  try
    close every window saving no
  end try
end tell
return "OK"
]]
    hs.alert.show("Exiting Claude and closing Terminal…", 2.5)
    -- Run inside Hammerspoon so Accessibility can type into Terminal.
    hs.timer.doAfter(0.05, function()
        local ok = hs.osascript.applescript(script)
        if ok == false then
            hs.alert.show("Could not close Terminal — grant Hammerspoon Accessibility", 3.5)
        end
        cvScanSessions(function()
            if cvPanel then cvRefresh() end
        end)
    end)
end

-- Type exit in this agent's Claude (if it is running), then close only
-- that Terminal window. Other agents stay open.
local function cvCloseAgent(path, name)
    path = tostring(path or "")
    name = tostring(name or "")
    if path == "" then return end
    local prefixes = cvPrefixesFor(path)
    local list = {}
    for _, p in ipairs(prefixes or {}) do list[#list + 1] = cvAsQuote(p) end
    if #list == 0 then
        hs.alert.show("No Terminal found for " .. (name ~= "" and name or "this agent"), 2.5)
        return
    end
    local label = name ~= "" and name or "agent"
    local script = [[
set prefs to {]] .. table.concat(list, ", ") .. [[}
set cloudId to missing value
set anyId to missing value
tell application "Terminal"
  if (count of windows) is 0 then return "MISS"
  repeat with w in windows
    try
]] .. cvLiveClaudeSnippet() .. [[
      repeat with p in prefs
        set pref to p as text
        if nm is pref or nm starts with (pref & " —") then
          if isLive then
            set cloudId to id of w
          else if anyId is missing value then
            set anyId to id of w
          end if
        end if
      end repeat
    end try
  end repeat
end tell
set wid to cloudId
set wasLive to true
if wid is missing value then
  set wid to anyId
  set wasLive to false
end if
if wid is missing value then return "MISS"
if wasLive then
  tell application "Terminal"
    try
      set w to first window whose id is wid
      set miniaturized of w to false
      set index of w to 1
      activate
      repeat with tb in tabs of w
        try
          set procs to processes of tb
          repeat with p in procs
            if (p as text) is "claude" then set selected of tb to true
          end repeat
        end try
      end repeat
    end try
  end tell
  delay 0.15
  tell application "System Events"
    keystroke "exit"
    keystroke return
  end tell
  delay 0.8
end if
tell application "Terminal"
  try
    close (first window whose id is wid) saving no
  end try
end tell
return "OK"
]]
    hs.alert.show("Closing " .. label .. "…", 1.8)
    hs.timer.doAfter(0.05, function()
        local ok, out = hs.osascript.applescript(script)
        if ok == false then
            hs.alert.show("Could not close Terminal — grant Hammerspoon Accessibility", 3.5)
        elseif out == "MISS" then
            hs.alert.show("No Terminal found for " .. label, 2.5)
        end
        cvRestorePanel()
        cvScanSessions(function()
            if cvPanel then cvRefresh() end
        end)
    end)
end

-- Only Terminals where Claude is still running (logged in), not idle
-- shells after exit.
local function cvOpenAgents()
    local seen, agents = {}, {}
    local function add(name, path)
        path = cvNormPath(path or "")
        if path == "" or path:sub(1, 8) == "__win__/" then return end
        if seen[path] then return end
        seen[path] = true
        agents[#agents + 1] = { name = name or cvFolderName(path), path = path }
    end
    local lists = cvAgentLists()
    for _, a in ipairs(lists.live) do add(a.name, a.path) end
    for p, term in pairs(cvTermByPath) do
        if term.cloud then
            add(term.name or cvFolderName(p), p)
        end
    end
    table.sort(agents, function(a, b) return a.name:lower() < b.name:lower() end)
    return agents
end

local function cvSaveSnapshot()
    cvScanSessions(function()
        local agents = cvOpenAgents()
        if #agents == 0 then
            hs.alert.show("No running Claude sessions to save", 2.5)
            return
        end
        local now = os.time()
        local snap = {
            ts = now,
            label = os.date("%a %d %b  %H:%M", now),
            agents = agents,
        }
        local snaps = cvReadSnaps()
        table.insert(snaps, 1, snap)
        while #snaps > 20 do snaps[#snaps] = nil end
        cvWriteSnaps(snaps)
        cvShowSnaps = true
        hs.alert.show("Saved " .. #agents .. " agents  ·  " .. snap.label, 2.5)
        if cvPanel then cvRefresh() end
    end)
end

local function cvRestoreSnapshot(ts)
    ts = tonumber(ts)
    local snap
    for _, s in ipairs(cvReadSnaps()) do
        if tonumber(s.ts) == ts then snap = s; break end
    end
    if not snap or not snap.agents or #snap.agents == 0 then
        hs.alert.show("That snapshot is empty", 2)
        return
    end
    if cvRestoreBusy then
        hs.alert.show("Already reopening terminals…", 2)
        return
    end
    cvShowSnaps = false
    if cvPanel then
        cvPanel:evaluateJavaScript("if(window.closeSnaps)closeSnaps()")
    end
    cvScanSessions(function()
        local toOpen = {}
        for _, a in ipairs(snap.agents) do
            local p = cvNormPath(a.path or "")
            if p ~= "" and hs.fs.attributes(p) then
                local term = cvTermByPath[p]
                if not (term and term.cloud) then
                    toOpen[#toOpen + 1] = a
                end
            end
        end
        if #toOpen == 0 then
            hs.alert.show("Those agents are already open", 2.5)
            return
        end
        cvLaunchErrShown = false
        -- Get this panel out of the way so new windows are visible.
        cvMinimizePanel()
        hs.osascript.applescript('tell application "Terminal" to activate')
        cvRestoreBusy = true
        local i, n = 0, #toOpen
        local function nextOne()
            i = i + 1
            if i > n then
                cvRestoreBusy = false
                hs.alert.show("Reopened " .. n .. " terminals", 2.5)
                cvScanSessions(function()
                    if cvPanel then cvRefresh() end
                end)
                return
            end
            local a = toOpen[i]
            if i == 1 or i % 5 == 0 or i == n then
                hs.alert.show("Opening " .. i .. " / " .. n .. "  ·  " ..
                    tostring(a.name or ""), 1.4)
            end
            local p = cvNormPath(a.path or "")
            local term = cvTermByPath[p]
            if term and term.cloud then
                hs.timer.doAfter(0.05, nextOne)
                return
            end
            -- Always start a new window. Do not "find" an existing one —
            -- that was skipping launches and looking like nothing happened.
            cvLaunchClaude(a.path, a.name, function()
                hs.timer.doAfter(0.22, nextOne)
            end)
        end
        nextOne()
    end)
end

local function cvDeleteSnapshot(ts)
    ts = tonumber(ts)
    local kept = {}
    for _, s in ipairs(cvReadSnaps()) do
        if tonumber(s.ts) ~= ts then kept[#kept + 1] = s end
    end
    cvWriteSnaps(kept)
    cvShowSnaps = true
    if cvPanel then cvRefresh() end
end

local function cvSnapRows()
    local snaps = cvReadSnaps()
    if #snaps == 0 then
        return '<div class="empty">No snapshots yet. Click Save while your agents are open.</div>'
    end
    local rows = {}
    for _, s in ipairs(snaps) do
        local names = {}
        local agents = s.agents or {}
        for i, a in ipairs(agents) do
            if i > 8 then
                names[#names + 1] = "…"
                break
            end
            names[#names + 1] = a.name or cvFolderName(a.path or "")
        end
        rows[#rows + 1] =
            '<div class="snap" role="button" tabindex="0" data-ts="' ..
            htmlEscape(tostring(s.ts)) ..
            '" onclick="if(!event.target.closest(\'.snap-del\'))send({action:\'restore\',ts:this.dataset.ts})"' ..
            ' onkeydown="if(event.key===\'Enter\'||event.key===\' \'){event.preventDefault();send({action:\'restore\',ts:this.dataset.ts})}">' ..
            '<div class="snap-head"><span class="t">' .. htmlEscape(s.label or "") ..
            '</span><span class="n">' .. tostring(#agents) .. ' agents</span>' ..
            '<button type="button" class="snap-del" title="Delete this save"' ..
            ' onclick="send({action:\'snapdel\',ts:this.closest(\'.snap\').dataset.ts})">✕</button>' ..
            '</div><div class="snip">' .. htmlEscape(table.concat(names, ", ")) ..
            '</div></div>'
    end
    return table.concat(rows)
end

-- Choose columns/rows so every window fits on screen, with cells a bit
-- wider than tall (terminal text reads better that way).
local function cvGridDims(n, areaW, areaH)
    if n <= 1 then return 1, 1 end
    local bestCols, bestScore = 1, -math.huge
    for cols = 1, n do
        local rows = math.ceil(n / cols)
        local tw = areaW / cols
        local th = areaH / rows
        local aspect = tw / math.max(th, 1)
        local aspectScore = -math.abs(math.log(aspect / 1.55))
        local emptyPenalty = (cols * rows - n) * 0.06
        local score = aspectScore - emptyPenalty
        if score > bestScore then
            bestCols, bestScore = cols, score
        end
    end
    return bestCols, math.ceil(n / bestCols)
end

-- Terminal.app has no "hide title bar" switch. Hide the tab bar so the
-- grid cells keep a little more room for the actual session.
local function cvHideTerminalTabBar()
    hs.osascript.applescript([[
tell application "System Events"
  tell process "Terminal"
    try
      click menu item "Hide Tab Bar" of menu "View" of menu bar 1
    end try
  end tell
end tell
]])
end

-- Leave a strip on the right for this floating panel so the grid
-- of agent windows does not cover the controls.
local function cvGutterRight()
    local sf = hs.screen.mainScreen():frame()
    if cvPanel then
        local pf = cvPanel:frame()
        if pf and pf.x > sf.x + sf.w * 0.45 then
            return (sf.x + sf.w) - pf.x + 10
        end
    end
    return FULL.w + 28
end

local function cvWindowAgentName(win)
    local t = win:title() or ""
    local prefix = t:match("^(.-) —") or t
    for _, term in pairs(cvTermByPath) do
        if term.cloud and (term.prefix == prefix or term.name == prefix) then
            return (term.name or prefix):lower()
        end
    end
    return prefix:lower()
end

local function cvTileWindows(wins)
    local n = #wins
    if n == 0 then
        hs.alert.show("No live agents to arrange", 2)
        return
    end
    table.sort(wins, function(a, b)
        return cvWindowAgentName(a) < cvWindowAgentName(b)
    end)
    cvHideTerminalTabBar()
    -- Usable screen (below the menu bar, above the Dock), minus the panel.
    local sf = hs.screen.mainScreen():frame()
    local pad = 2
    local area = {
        x = sf.x + pad,
        y = sf.y + pad,
        w = sf.w - cvGutterRight() - pad * 2,
        h = sf.h - pad * 2,
    }
    local cols, rows = cvGridDims(n, area.w, area.h)
    local tw = math.floor(area.w / cols)
    local th = math.floor(area.h / rows)
    local space = nil
    pcall(function() space = hs.spaces.focusedSpace() end)
    local screen = hs.screen.mainScreen()
    for i, win in ipairs(wins) do
        local c = (i - 1) % cols
        local r = math.floor((i - 1) / cols)
        if space then pcall(hs.spaces.moveWindowToSpace, win, space) end
        pcall(function() win:moveToScreen(screen) end)
        win:unminimize()
        -- Instant resize so 30+ windows land together instead of animating.
        win:setFrame({
            x = area.x + c * tw,
            y = area.y + r * th,
            w = tw - pad,
            h = th - pad,
        }, 0)
        win:raise()
    end
    if cvPanel then
        local hw = cvPanel:hswindow()
        if hw then hw:raise() end
    end
end

local function cvCloudTerminalWindows()
    local wins = {}
    local app = hs.application.get("Terminal")
    if not app then return wins end
    local livePrefixes = {}
    for _, term in pairs(cvTermByPath) do
        if term.cloud and term.prefix then livePrefixes[term.prefix] = true end
    end
    for p, _ in pairs(cvLiveTitles) do livePrefixes[p] = true end
    for _, w in ipairs(app:allWindows()) do
        local t = w:title() or ""
        local prefix = t:match("^(.-) —") or t
        if livePrefixes[prefix] then
            wins[#wins + 1] = w
        end
    end
    return wins
end

-- Scan spoken history + agent notes once, then look up by any alias.
local function cvGetMsgIndex()
    if cvMsgIndex then return cvMsgIndex end
    local byWho = {}
    local function add(who, item)
        if type(who) ~= "string" or who == "" then return end
        local k = who:lower()
        byWho[k] = byWho[k] or {}
        byWho[k][#byWho[k] + 1] = item
    end
    local byKey = cvAgentAliasIndex()
    for i, e in ipairs(cvReadHistory(400)) do
        local who, _, full = cvSplitSpoken(e)
        if who then
            local item = {
                sort = string.format("%013.0f", tonumber(e.ts) or 0),
                when = os.date("%Y-%m-%d %H:%M", math.floor(e.ts or 0)),
                text = full or e.text or "",
                index = i,
                kind = "spoken",
            }
            add(who, item)
            local canon = byKey[who]
            if canon then add(canon, item) end
        end
    end
    for _, e in ipairs(cvReadOrchMessages(80)) do
        local item = {
            sort = e.sort or e.date or "",
            when = e.date or "",
            text = e.body or "",
            kind = "note",
            route = (e.from or "?") .. " → " .. (e.to or "?"),
        }
        add(e.from, item)
        add(e.to, item)
        if e.from and byKey[e.from] then add(byKey[e.from], item) end
        if e.to and byKey[e.to] then add(byKey[e.to], item) end
    end
    cvMsgIndex = byWho
    return cvMsgIndex
end

-- Newest-first spoken + agent-to-agent notes for one agent.
local function cvMessagesForAgent(name, path)
    local keys = cvNameKeys(name, path)
    local index = cvGetMsgIndex()
    local seen, items = {}, {}
    for k in pairs(keys) do
        local list = index[k]
        if list then
            for _, item in ipairs(list) do
                if not seen[item] then
                    seen[item] = true
                    items[#items + 1] = item
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.sort > b.sort end)
    return items
end

local function cvBoardAgents()
    local lists = cvAgentLists()
    local seen, cards = {}, {}
    local function add(a, needMsgs)
        local k = cvNormPath(a.path)
        if k == "" then k = a.name end
        if seen[k] then
            if a.live then cards[seen[k]].live = true end
            return
        end
        local msgs = cvMessagesForAgent(a.name, a.path)
        if needMsgs and #msgs == 0 then return end
        local last = msgs[1]
        local slice = {}
        for i = 1, math.min(10, #msgs) do slice[i] = msgs[i] end
        cards[#cards + 1] = {
            name = a.name,
            path = a.path,
            live = a.live and true or false,
            msgs = slice,
            lastIndex = last and last.index or nil,
            lastWhen = last and last.when or "",
            hasMsgs = #msgs > 0,
        }
        seen[k] = #cards
    end
    for _, a in ipairs(lists.live) do add(a, false) end
    table.sort(cards, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return cards
end

local function cvBoardCard(a)
    local flag = a.live
        and '<span class="flag on">working</span>'
        or '<span class="flag">idle</span>'
    local idx = a.lastIndex and tostring(a.lastIndex) or ""
    local readDis = a.hasMsgs and "" or " disabled"
    local allDis = a.hasMsgs and "" or " disabled"
    local rows = {}
    for _, m in ipairs(a.msgs or {}) do
        local full = m.text or ""
        if #full > 20000 then full = full:sub(1, 20000) .. "\n…" end
        rows[#rows + 1] = cvMsgRow({
            when = m.when,
            route = a.name,
            meta = m.when or "",
            snippet = cvPlainSnippet(m.text, 180),
            full = full,
            index = m.index,
            path = a.path,
            name = a.name,
        })
    end
    if #rows == 0 then
        rows = { '<div class="empty">No messages yet</div>' }
    end
    local closeJs = "if(confirm('Exit Claude and close this Terminal?'))" ..
        "send({action:'closeagent',path:this.closest('.tile').dataset.path," ..
        "name:this.closest('.tile').dataset.name})"
    return '<article class="tile' .. (a.live and " working" or "") ..
        '" data-path="' .. htmlEscape(a.path) ..
        '" data-name="' .. htmlEscape(a.name) ..
        '" data-index="' .. idx .. '">' ..
        '<header class="tile-head"><span class="tile-name">' .. htmlEscape(a.name) ..
        '</span>' .. flag ..
        '<button type="button" class="tile-x" title="Exit Claude and close this Terminal" ' ..
        'onclick="' .. closeJs .. '">×</button></header>' ..
        '<div class="tile-msgs">' .. table.concat(rows) .. '</div>' ..
        '<div class="tile-actions">' ..
        '<button type="button" onclick="send({action:\'goto\',path:this.closest(\'.tile\').dataset.path})">Open</button>' ..
        '<button type="button"' .. readDis ..
        ' onclick="send({action:\'readlast\',path:this.closest(\'.tile\').dataset.path,name:this.closest(\'.tile\').dataset.name,index:this.closest(\'.tile\').dataset.index})">Read last</button>' ..
        '<button type="button"' .. allDis ..
        ' onclick="send({action:\'allmsgs\',path:this.closest(\'.tile\').dataset.path,name:this.closest(\'.tile\').dataset.name})">All messages</button>' ..
        '<button type="button" class="danger" title="Exit Claude and close this Terminal" ' ..
        'onclick="' .. closeJs .. '">Close</button>' ..
        '</div></article>'
end

local function cvBoardFrame()
    local sf = hs.screen.mainScreen():frame()
    return { x = sf.x + 10, y = sf.y + 10, w = sf.w - 20, h = sf.h - 20 }
end

local function cvFullFrame()
    local sf = hs.screen.mainScreen():frame()
    if cvLastFullFrame then return cvLastFullFrame end
    -- Stay on-screen: leave a little air above the Dock and below the menu bar.
    local topGap, botGap = 28, 20
    local h = math.min(FULL.h, sf.h - topGap - botGap)
    local y = sf.y + topGap
    if y + h > sf.y + sf.h - botGap then
        y = sf.y + sf.h - botGap - h
    end
    return { x = sf.x + sf.w - FULL.w - 20, y = y, w = FULL.w, h = h }
end

local function cvMiniFrame()
    -- Dock a small card against the right edge, keeping the current height
    -- on screen so the window does not jump to the top when shrinking.
    local sf = hs.screen.mainScreen():frame()
    local cur = (cvPanel and cvPanel:frame()) or cvFullFrame()
    local y = cur.y
    if y < sf.y + 8 then y = sf.y + 8 end
    if y + MINI.h > sf.y + sf.h - 8 then y = sf.y + sf.h - MINI.h - 8 end
    return { x = sf.x + sf.w - MINI.w - 12, y = y, w = MINI.w, h = MINI.h }
end

local function cvSharedCss(th)
    return [[
      :root {
        --ac: ]] .. th.accent .. [[;
        --nr: ]] .. th.near .. [[;
        --mono: "SF Mono", ui-monospace, Menlo, monospace;
      }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { background: transparent; }
      button {
        background: rgba(255,255,255,0.07); color: rgba(235,238,250,0.85);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 999px;
        padding: 4px 9px; font-size: 11px; font-weight: 500; cursor: pointer;
        white-space: nowrap;
        transition: background 0.15s, border-color 0.15s, transform 0.1s;
      }
      button:hover {
        background: rgba(var(--ac),0.13);
        border-color: rgba(var(--ac),0.32);
      }
      button:active { transform: scale(0.96); }
      button:focus-visible {
        outline: 2px solid rgba(var(--ac),0.85); outline-offset: 2px;
      }
      button:disabled {
        opacity: 0.35; cursor: default; pointer-events: none;
      }
      button.on {
        color: #eafff0;
        background: linear-gradient(135deg, rgba(88,214,141,0.35), rgba(64,186,140,0.25));
        border-color: rgba(88,214,141,0.45);
        box-shadow: 0 0 14px rgba(88,214,141,0.25);
      }
      button.off {
        color: #ffecec;
        background: linear-gradient(135deg, rgba(235,110,110,0.32), rgba(200,80,90,0.22));
        border-color: rgba(235,110,110,0.4);
      }
      .val { text-align: right; font-size: 11.5px; font-weight: 500;
             color: rgb(var(--ac)); font-family: var(--mono);
             font-variant-numeric: tabular-nums; }
      .eq { display: flex; align-items: flex-end; gap: 2.5px;
            height: 14px; flex-shrink: 0; }
      .eq i { width: 3px; height: 3px; border-radius: 2px;
              background: rgb(var(--ac)); opacity: 0.4;
              transition: height 0.3s, opacity 0.3s; }
      .eq.live i { opacity: 1; animation: eqb 1.1s ease-in-out infinite; }
      .eq.live i:nth-child(1) { animation-delay: 0s; }
      .eq.live i:nth-child(2) { animation-delay: -0.9s; }
      .eq.live i:nth-child(3) { animation-delay: -0.35s; }
      .eq.live i:nth-child(4) { animation-delay: -0.7s; }
      .eq.live i:nth-child(5) { animation-delay: -0.15s; }
      @keyframes eqb { 0%, 100% { height: 4px; } 50% { height: 14px; } }
      @media (prefers-reduced-motion: reduce) {
        .eq.live i { animation: none; height: 10px; }
      }
    ]]
end

local function cvPlayScript()
    return [=[
      <script>
        function send(m) { webkit.messageHandlers.cv.postMessage(m); }
        let drag = false;
        let openIndex = null;
        let openEl = null;
        let openPath = '';
        function esc(s) {
          return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }
        function inlineMd(s) {
          s = esc(s);
          s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
          s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
          s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
          s = s.replace(/(^|[^\*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
          s = s.replace(/(^|[^_])_([^_\n]+)_/g, '$1<em>$2</em>');
          s = s.replace(/~~([^~]+)~~/g, '<del>$1</del>');
          s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<span class="md-link">$1</span>');
          return s;
        }
        function splitCells(line) {
          line = String(line).trim();
          if (line.charAt(0) === '|') line = line.slice(1);
          if (line.charAt(line.length - 1) === '|') line = line.slice(0, -1);
          return line.split('|').map(function(c) { return c.trim(); });
        }
        function isTableSep(line) {
          return /^\s*\|?(\s*:?-{2,}:?\s*\|)+\s*:?-{2,}:?\s*\|?\s*$/.test(line);
        }
        function mdToHtml(src) {
          src = String(src || '').replace(/\r\n/g, '\n');
          if (!src.trim()) return '';
          const lines = src.split('\n');
          const out = [];
          let i = 0;
          while (i < lines.length) {
            const line = lines[i];
            if (/^```/.test(line)) {
              const buf = [];
              i += 1;
              while (i < lines.length && !/^```/.test(lines[i])) {
                buf.push(lines[i]);
                i += 1;
              }
              if (i < lines.length) i += 1;
              out.push('<pre class="md-code"><code>' + esc(buf.join('\n')) + '</code></pre>');
              continue;
            }
            if (/^\s*\|/.test(line) && i + 1 < lines.length && isTableSep(lines[i + 1])) {
              const heads = splitCells(line);
              i += 2;
              const rows = [];
              while (i < lines.length && /^\s*\|/.test(lines[i]) && !isTableSep(lines[i])) {
                rows.push(splitCells(lines[i]));
                i += 1;
              }
              let html = '<div class="md-table-wrap"><table class="md-table"><thead><tr>';
              for (let h = 0; h < heads.length; h += 1) {
                html += '<th>' + inlineMd(heads[h]) + '</th>';
              }
              html += '</tr></thead><tbody>';
              for (let r = 0; r < rows.length; r += 1) {
                html += '<tr>';
                for (let c = 0; c < heads.length; c += 1) {
                  html += '<td>' + inlineMd(rows[r][c] || '') + '</td>';
                }
                html += '</tr>';
              }
              html += '</tbody></table></div>';
              out.push(html);
              continue;
            }
            const hm = line.match(/^(#{1,6})\s+(.*)$/);
            if (hm) {
              const n = hm[1].length;
              out.push('<h' + n + ' class="md-h">' + inlineMd(hm[2]) + '</h' + n + '>');
              i += 1;
              continue;
            }
            if (/^\s*[-*_ ]{3,}\s*$/.test(line) && /[-*_]/.test(line)) {
              out.push('<hr class="md-hr">');
              i += 1;
              continue;
            }
            if (/^\s*>\s?/.test(line)) {
              const buf = [];
              while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
                buf.push(lines[i].replace(/^\s*>\s?/, ''));
                i += 1;
              }
              out.push('<blockquote class="md-quote">' + mdToHtml(buf.join('\n')) + '</blockquote>');
              continue;
            }
            if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
              const ordered = /^\s*\d+\.\s+/.test(line);
              const items = [];
              while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
                items.push(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, ''));
                i += 1;
              }
              const tag = ordered ? 'ol' : 'ul';
              let html = '<' + tag + ' class="md-list">';
              for (let n = 0; n < items.length; n += 1) {
                html += '<li>' + inlineMd(items[n]) + '</li>';
              }
              html += '</' + tag + '>';
              out.push(html);
              continue;
            }
            if (!line.trim()) { i += 1; continue; }
            const buf = [line];
            i += 1;
            while (i < lines.length && lines[i].trim() &&
                   !/^(#{1,6}\s|```|\s*([-*+]|\d+\.)\s|\s*>|\s*\|)/.test(lines[i])) {
              buf.push(lines[i]);
              i += 1;
            }
            out.push('<p>' + inlineMd(buf.join(' ')) + '</p>');
          }
          return out.join('');
        }
        function msgSiblings(el) {
          if (!el || !el.parentElement) return [];
          return Array.from(el.parentElement.children).filter(function(n) {
            return n.classList && n.classList.contains('msg');
          });
        }
        function msgPath(el) {
          if (!el) return openPath || '';
          const tile = el.closest ? el.closest('.tile') : null;
          return el.dataset.path || (tile && tile.dataset.path) || openPath || '';
        }
        function syncReaderBtns() {
          const replayBtn = document.getElementById('replayBtn');
          const prevBtn = document.getElementById('prevBtn');
          const nextBtn = document.getElementById('nextBtn');
          const openBtn = document.getElementById('openBtn');
          const sibs = msgSiblings(openEl);
          const i = openEl ? sibs.indexOf(openEl) : -1;
          if (prevBtn) {
            prevBtn.hidden = !openEl;
            prevBtn.disabled = i <= 0;
          }
          if (nextBtn) {
            nextBtn.hidden = !openEl;
            nextBtn.disabled = i < 0 || i >= sibs.length - 1;
          }
          if (replayBtn) replayBtn.hidden = !openIndex;
          const path = msgPath(openEl);
          if (openBtn) openBtn.hidden = !path;
        }
        function openMsg(el) {
          openEl = el;
          openIndex = el.dataset.index || null;
          openPath = msgPath(el);
          const timeEl = document.getElementById('readerTime');
          const routeEl = document.getElementById('readerRoute');
          const body = document.getElementById('readerBody');
          const reader = document.getElementById('reader');
          if (!reader || !body) return;
          const route = el.dataset.route || '';
          if (routeEl) {
            routeEl.textContent = route;
            routeEl.hidden = !route;
          }
          if (timeEl) {
            const t = el.querySelector('.t');
            timeEl.textContent = el.dataset.meta || (t ? t.textContent : '');
          }
          const full = el.querySelector('.full');
          const raw = full ? full.textContent : '';
          const html = mdToHtml(raw);
          body.innerHTML = html || ('<p>' + esc(raw) + '</p>');
          body.scrollTop = 0;
          reader.hidden = false;
          syncReaderBtns();
          body.focus();
        }
        function openPlainMsg(route, meta, raw) {
          openEl = null;
          openIndex = null;
          openPath = '';
          const timeEl = document.getElementById('readerTime');
          const routeEl = document.getElementById('readerRoute');
          const body = document.getElementById('readerBody');
          const reader = document.getElementById('reader');
          if (!reader || !body) return;
          if (routeEl) {
            routeEl.textContent = route || '';
            routeEl.hidden = !route;
          }
          if (timeEl) timeEl.textContent = meta || '';
          const html = mdToHtml(raw || '');
          body.innerHTML = html || ('<p>' + esc(raw || '') + '</p>');
          body.scrollTop = 0;
          reader.hidden = false;
          syncReaderBtns();
          body.focus();
        }
        function openAgentMsgs(title, items, path) {
          openEl = null;
          openIndex = null;
          openPath = path || '';
          const timeEl = document.getElementById('readerTime');
          const routeEl = document.getElementById('readerRoute');
          const body = document.getElementById('readerBody');
          const reader = document.getElementById('reader');
          if (!reader || !body) return;
          if (routeEl) {
            routeEl.textContent = title || '';
            routeEl.hidden = !title;
          }
          if (timeEl) {
            const n = (items && items.length) || 0;
            timeEl.textContent = n ? (n + ' message' + (n === 1 ? '' : 's')) : '';
          }
          let html = '';
          (items || []).forEach(function(it) {
            const bits = [];
            if (it.when) bits.push(it.when);
            if (it.route) bits.push(it.route);
            else if (it.kind === 'spoken') bits.push('spoken');
            html += '<section class="msg-block"><div class="msg-block-meta">'
              + esc(bits.join(' · ')) + '</div>'
              + (mdToHtml(it.text) || ('<p>' + esc(it.text || '') + '</p>'))
              + '</section>';
          });
          body.innerHTML = html || '<p>No messages</p>';
          body.scrollTop = 0;
          reader.hidden = false;
          syncReaderBtns();
          body.focus();
        }
        function closeMsg() {
          const reader = document.getElementById('reader');
          if (reader) reader.hidden = true;
          openIndex = null;
          openEl = null;
          openPath = '';
        }
        function stepMsg(dir) {
          const sibs = msgSiblings(openEl);
          const i = sibs.indexOf(openEl);
          const next = sibs[i + dir];
          if (next) openMsg(next);
        }
        function openAgent() {
          const path = msgPath(openEl);
          if (path) send({action:'goto', path: path});
        }
        function replayOpen() {
          if (openIndex) send({action:'replay', index: String(openIndex)});
        }
        function filterAgents(q) {
          q = (q || '').toLowerCase().trim();
          document.querySelectorAll('.agent').forEach(function(el) {
            const name = el.dataset.name || '';
            el.hidden = !!(q && name.indexOf(q) === -1);
          });
        }
        function filterTiles(q) {
          q = (q || '').toLowerCase().trim();
          document.querySelectorAll('.tile').forEach(function(el) {
            const name = el.dataset.name || '';
            el.hidden = !!(q && name.indexOf(q) === -1);
          });
        }
        let netRAF = 0, netState = null, netMoved = false;
        function netCssRgb() {
          const raw = (getComputedStyle(document.documentElement)
            .getPropertyValue('--ac') || '120,200,255').trim();
          return raw || '120,200,255';
        }
        function netResize() {
          const canvas = document.getElementById('netCanvas');
          const wrap = document.getElementById('net');
          if (!canvas || !wrap || wrap.hidden) return;
          const bar = wrap.querySelector('.net-bar');
          const dpr = window.devicePixelRatio || 1;
          const w = wrap.clientWidth;
          const h = Math.max(80, wrap.clientHeight - (bar ? bar.offsetHeight : 56));
          canvas.style.width = w + 'px';
          canvas.style.height = h + 'px';
          canvas.width = Math.floor(w * dpr);
          canvas.height = Math.floor(h * dpr);
          const ctx = canvas.getContext('2d');
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          if (netState) { netState.w = w; netState.h = h; }
        }
        function netHit(st, x, y) {
          for (let i = st.nodes.length - 1; i >= 0; i -= 1) {
            const n = st.nodes[i];
            if (Math.hypot(x - n.x, y - n.y) <= n.r + 6) return { kind: 'node', item: n };
          }
          let best = null, bestD = 10;
          st.edges.forEach(function(e) {
            const a = e.a, b = e.b;
            const dx = b.x - a.x, dy = b.y - a.y;
            const l2 = dx * dx + dy * dy;
            let t = 0;
            if (l2 > 1) t = Math.max(0, Math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / l2));
            const px = a.x + t * dx, py = a.y + t * dy;
            const d = Math.hypot(x - px, y - py);
            if (d < bestD) { bestD = d; best = e; }
          });
          if (best) return { kind: 'edge', item: best };
          return null;
        }
        function closeNet() {
          if (netRAF) cancelAnimationFrame(netRAF);
          netRAF = 0;
          netState = null;
          window.removeEventListener('resize', netResize);
          const el = document.getElementById('net');
          const tip = document.getElementById('netTip');
          if (el) el.hidden = true;
          if (tip) tip.hidden = true;
          send({action:'netclose'});
        }
        function openNet(data) {
          const el = document.getElementById('net');
          const canvas = document.getElementById('netCanvas');
          const empty = document.getElementById('netEmpty');
          const count = document.getElementById('netCount');
          const tip = document.getElementById('netTip');
          if (!el || !canvas) return;
          el.hidden = false;
          data = data || {};
          const rawN = data.nodes || [];
          const rawE = data.edges || [];
          if (count) count.textContent = rawE.length + ' link' + (rawE.length === 1 ? '' : 's');
          if (empty) empty.hidden = rawN.length > 0;
          const byId = {};
          const nodes = rawN.map(function(n, i) {
            const node = {
              id: n.id, live: !!n.live, path: n.path || '',
              x: 0, y: 0, vx: 0, vy: 0, r: 16, pin: false
            };
            byId[n.id] = node;
            node._i = i;
            return node;
          });
          const edges = [];
          rawE.forEach(function(e) {
            const a = byId[e.from] || byId[e.source];
            const b = byId[e.to] || byId[e.target];
            if (!a || !b) return;
            a.deg = (a.deg || 0) + 1;
            b.deg = (b.deg || 0) + 1;
            edges.push({
              a: a, b: b, n: e.n || 1,
              when: e.when || '', route: e.route || (e.from + ' → ' + e.to),
              text: e.text || ''
            });
          });
          nodes.forEach(function(n) {
            n.r = 14 + Math.min(10, (n.deg || 1) * 1.6);
          });
          netState = { nodes: nodes, edges: edges, w: 800, h: 600, drag: null, hover: null };
          netResize();
          const cx = netState.w / 2, cy = netState.h / 2;
          const rad = Math.min(cx, cy) * 0.62;
          nodes.forEach(function(n, i) {
            const ang = (Math.PI * 2 * i) / Math.max(nodes.length, 1) - Math.PI / 2;
            n.x = cx + Math.cos(ang) * rad * (0.72 + Math.random() * 0.28);
            n.y = cy + Math.sin(ang) * rad * (0.72 + Math.random() * 0.28);
            n.vx = (Math.random() - 0.5) * 1.4;
            n.vy = (Math.random() - 0.5) * 1.4;
          });
          if (netRAF) cancelAnimationFrame(netRAF);
          window.removeEventListener('resize', netResize);
          window.addEventListener('resize', netResize);
          const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
          function tick(t) {
            const st = netState;
            if (!st) return;
            const w = st.w, h = st.h;
            const nN = st.nodes.length;
            const rest = Math.max(90, Math.min(170, 520 / Math.sqrt(Math.max(nN, 1))));
            const damp = reduce ? 0.78 : 0.88;
            for (let i = 0; i < nN; i += 1) {
              const a = st.nodes[i];
              if (a.pin) continue;
              for (let j = i + 1; j < nN; j += 1) {
                const b = st.nodes[j];
                let dx = a.x - b.x, dy = a.y - b.y;
                let d2 = dx * dx + dy * dy;
                if (d2 < 16) { dx = (Math.random() - 0.5); dy = (Math.random() - 0.5); d2 = 16; }
                const d = Math.sqrt(d2);
                const force = 1400 / d2;
                const fx = (dx / d) * force, fy = (dy / d) * force;
                if (!b.pin) { b.vx -= fx; b.vy -= fy; }
                a.vx += fx; a.vy += fy;
              }
              a.vx += (w / 2 - a.x) * 0.012;
              a.vy += (h / 2 - a.y) * 0.012;
              if (!reduce) {
                a.vx += Math.sin(t * 0.0008 + a._i) * 0.05;
                a.vy += Math.cos(t * 0.0011 + a._i * 1.7) * 0.05;
              }
            }
            st.edges.forEach(function(e) {
              const a = e.a, b = e.b;
              const dx = b.x - a.x, dy = b.y - a.y;
              const d = Math.hypot(dx, dy) || 1;
              const pull = (d - rest) * 0.018;
              const fx = (dx / d) * pull, fy = (dy / d) * pull;
              if (!a.pin) { a.vx += fx; a.vy += fy; }
              if (!b.pin) { b.vx -= fx; b.vy -= fy; }
            });
            st.nodes.forEach(function(n) {
              if (n.pin) { n.vx = 0; n.vy = 0; return; }
              n.vx *= damp; n.vy *= damp;
              n.x += n.vx; n.y += n.vy;
              const m = n.r + 8;
              if (n.x < m) { n.x = m; n.vx *= -0.4; }
              if (n.y < m) { n.y = m; n.vy *= -0.4; }
              if (n.x > w - m) { n.x = w - m; n.vx *= -0.4; }
              if (n.y > h - m) { n.y = h - m; n.vy *= -0.4; }
            });
            const ctx = canvas.getContext('2d');
            ctx.clearRect(0, 0, w, h);
            const ac = netCssRgb();
            const hoverE = st.hover && st.hover.kind === 'edge' ? st.hover.item : null;
            const hoverN = st.hover && st.hover.kind === 'node' ? st.hover.item : null;
            st.edges.forEach(function(e) {
              const hot = e === hoverE || (hoverN && (e.a === hoverN || e.b === hoverN));
              ctx.strokeStyle = hot ? 'rgba(' + ac + ',0.95)' : 'rgba(' + ac + ',0.38)';
              ctx.lineWidth = (hot ? 2.4 : 1.1) + Math.min(4, Math.log(e.n + 1));
              ctx.beginPath();
              ctx.moveTo(e.a.x, e.a.y);
              ctx.lineTo(e.b.x, e.b.y);
              ctx.stroke();
              const dx = e.b.x - e.a.x, dy = e.b.y - e.a.y;
              const len = Math.hypot(dx, dy) || 1;
              const ux = dx / len, uy = dy / len;
              const ex = e.b.x - ux * (e.b.r + 3);
              const ey = e.b.y - uy * (e.b.r + 3);
              ctx.fillStyle = ctx.strokeStyle;
              ctx.beginPath();
              ctx.moveTo(ex, ey);
              ctx.lineTo(ex - ux * 9 + uy * 4.5, ey - uy * 9 - ux * 4.5);
              ctx.lineTo(ex - ux * 9 - uy * 4.5, ey - uy * 9 + ux * 4.5);
              ctx.closePath();
              ctx.fill();
            });
            st.nodes.forEach(function(n) {
              const hot = n === hoverN;
              const pulse = n.live && !reduce ? 0.55 + 0.45 * Math.sin(t * 0.004) : 1;
              ctx.beginPath();
              ctx.arc(n.x, n.y, n.r + (hot ? 3 : 0), 0, Math.PI * 2);
              ctx.fillStyle = n.live
                ? 'rgba(94,224,154,' + (0.22 * pulse) + ')'
                : 'rgba(255,255,255,0.08)';
              ctx.fill();
              ctx.lineWidth = n.live ? 2 : 1.2;
              ctx.strokeStyle = n.live
                ? 'rgba(94,224,154,' + (0.55 + 0.35 * pulse) + ')'
                : (hot ? 'rgba(' + ac + ',0.95)' : 'rgba(' + ac + ',0.55)');
              ctx.stroke();
              ctx.fillStyle = 'rgba(235,238,250,0.94)';
              ctx.font = '600 11px -apple-system, "SF Pro Text", sans-serif';
              ctx.textAlign = 'center';
              ctx.textBaseline = 'top';
              const label = n.id.length > 22 ? n.id.slice(0, 21) + '…' : n.id;
              ctx.fillText(label, n.x, n.y + n.r + 5);
            });
            netRAF = requestAnimationFrame(tick);
          }
          netRAF = requestAnimationFrame(tick);
          canvas.onpointerdown = function(ev) {
            const r = canvas.getBoundingClientRect();
            const x = ev.clientX - r.left, y = ev.clientY - r.top;
            netMoved = false;
            const hit = netHit(netState, x, y);
            if (hit && hit.kind === 'node') {
              netState.drag = hit.item;
              hit.item.pin = true;
              canvas.setPointerCapture(ev.pointerId);
              canvas.style.cursor = 'grabbing';
            }
          };
          canvas.onpointermove = function(ev) {
            if (!netState) return;
            const r = canvas.getBoundingClientRect();
            const x = ev.clientX - r.left, y = ev.clientY - r.top;
            if (netState.drag) {
              netMoved = true;
              netState.drag.x = x;
              netState.drag.y = y;
              if (tip) tip.hidden = true;
              return;
            }
            const hit = netHit(netState, x, y);
            netState.hover = hit;
            canvas.style.cursor = hit ? (hit.kind === 'node' ? 'grab' : 'pointer') : 'default';
            if (tip) {
              if (hit && hit.kind === 'edge') {
                const snip = String(hit.item.text || '').replace(/\s+/g, ' ').trim().slice(0, 90);
                const nr = el.getBoundingClientRect();
                tip.hidden = false;
                tip.textContent = hit.item.route + (snip ? ' — ' + snip : '');
                tip.style.left = Math.min(nr.width - 24, ev.clientX - nr.left + 14) + 'px';
                tip.style.top = Math.min(nr.height - 24, ev.clientY - nr.top + 14) + 'px';
              } else {
                tip.hidden = true;
              }
            }
          };
          canvas.onpointerup = function(ev) {
            if (!netState) return;
            const r = canvas.getBoundingClientRect();
            const x = ev.clientX - r.left, y = ev.clientY - r.top;
            if (netState.drag) {
              netState.drag.pin = false;
              netState.drag = null;
              canvas.style.cursor = 'grab';
            }
            if (netMoved) return;
            const hit = netHit(netState, x, y);
            if (hit && hit.kind === 'edge') {
              openPlainMsg(hit.item.route, hit.item.when || '', hit.item.text || '');
            } else if (hit && hit.kind === 'node' && hit.item.path) {
              send({action:'goto', path: hit.item.path});
            }
          };
          canvas.onpointerleave = function() {
            if (netState) netState.hover = null;
            if (tip) tip.hidden = true;
          };
        }
        function closeSnaps() {
          const el = document.getElementById('snaps');
          if (el) el.hidden = true;
          send({action:'snapclose'});
        }
        function toggleSnaps() {
          const el = document.getElementById('snaps');
          if (!el) return;
          if (el.hidden) el.hidden = false;
          else closeSnaps();
        }
        document.addEventListener('keydown', function(e) {
          const reader = document.getElementById('reader');
          if (reader && !reader.hidden) {
            if (e.key === 'Escape') { closeMsg(); return; }
            if (e.key === 'ArrowLeft') { e.preventDefault(); stepMsg(-1); return; }
            if (e.key === 'ArrowRight') { e.preventDefault(); stepMsg(1); return; }
          }
          if (e.key !== 'Escape') return;
          const snaps = document.getElementById('snaps');
          if (snaps && !snaps.hidden) { closeSnaps(); return; }
          const net = document.getElementById('net');
          if (net && !net.hidden) { closeNet(); return; }
          const board = document.getElementById('board');
          if (board && !board.hidden) send({action:'boardclose'});
        });
        function fmt(s) {
          s = Math.max(0, Math.floor(s));
          return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
        }
        function updPlay(pos, dur, playing) {
          const eq = document.getElementById('eq');
          if (eq) eq.classList.toggle('live', !!playing);
          if (dur <= 0) return;
          const sk = document.getElementById('seek');
          if (sk && !drag) { sk.max = dur; sk.value = pos; }
          const pt = document.getElementById('pt');
          if (pt) {
            const shown = drag && sk ? sk.value : pos;
            pt.textContent = pt.dataset.short
              ? fmt(shown)
              : fmt(shown) + ' / ' + fmt(dur);
          }
          const pp = document.getElementById('pp');
          if (pp) pp.textContent = playing ? '⏸' : '▶';
        }
      </script>
    ]=]
end

local function cvBuildHtml()
    cvAliasCache = nil
    cvMsgIndex = nil
    local cfg = hs.json.read(CV_CONFIG) or {}
    local enabled  = cfg.enabled ~= false
    local speed    = cfg.speed or 1.0
    local volume   = math.floor((cfg.volume or 1.0) * 100 + 0.5)
    local provider = cfg.provider or "kokoro"
    local voice    = (cfg.voices or {})[provider] or ""
    local powerCls = enabled and "on" or "off"
    local powerLbl = enabled and "● On" or "○ Off"
    local th = CV_THEMES[cfg.theme or "aurora"] or CV_THEMES.aurora

    if cvCompact then
        return [[<!doctype html><html><head><meta charset="utf-8"><style>
      ]] .. cvSharedCss(th) .. [[
      body {
        font: 13px/1.3 -apple-system, "SF Pro Text", sans-serif;
        color: rgba(235,238,250,0.92);
        padding: 36px 10px 10px;
        user-select: none;
        background:
          radial-gradient(140% 80% at 50% 0%, rgba(var(--ac),0.16), transparent 60%),
          rgba(14,15,22,0.74);
        height: 100vh;
        overflow: hidden;
      }
      .mini {
        display: flex; align-items: center; gap: 6px;
        height: calc(100% - 0px);
      }
      .mini button { padding: 5px 10px; font-size: 12px; white-space: nowrap; }
      .mini #pp { padding: 5px 11px; }
      .mini .val { width: auto; min-width: 34px; font-size: 10.5px; }
      .grow { margin-left: auto; }
    </style></head><body>
      <div class="mini">
        <button id="power" class="]] .. powerCls .. [["
          onclick="send({action:'power'})">]] .. powerLbl .. [[</button>
        <button onclick="send({action:'stop'})" title="Stop speaking">◼</button>
        <button id="pp" onclick="this.textContent=this.textContent==='⏸'?'▶':'⏸';send({action:'playpause'})">▶</button>
        <span class="val" id="pt" data-short="1">–:––</span>
        <div class="eq" id="eq" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>
        <button class="grow" onclick="send({action:'expand'})"
          title="Restore the full panel">Make bigger</button>
      </div>
      <input type="range" id="seek" min="0" max="1" step="0.1" value="0"
        style="position:absolute;width:0;height:0;opacity:0;pointer-events:none">
      ]] .. cvPlayScript() .. [[
    </body></html>]]
    end

    local voiceOpts = {}
    for _, v in ipairs(KOKORO_VOICES) do
        table.insert(voiceOpts, string.format('<option value="%s"%s>%s</option>',
            v, v == voice and " selected" or "", v))
    end

    local byReg = cvIndexRegistry()
    local histRows = {}
    for i, e in ipairs(cvReadHistory(20)) do
        local when = os.date("%H:%M", math.floor(e.ts or 0))
        local who, snippetText, full = cvSplitSpoken(e)
        local rec = who and (byReg[who] or byReg[cvFolderName(who)])
        -- Concatenate (don't string.format) so a "%" in the spoken text
        -- cannot break Lua format specifiers.
        table.insert(histRows, cvMsgRow({
            index = i,
            when = when,
            who = who,
            snippet = cvPlainSnippet(snippetText, 160),
            full = full,
            route = who or "",
            meta = when,
            path = rec and rec.path or "",
            name = who,
        }))
    end
    if #histRows == 0 then
        histRows = { '<div class="empty">no spoken messages yet</div>' }
    end

    local orchRows = {}
    for _, e in ipairs(cvReadOrchMessages(5)) do
        local when = (e.date or ""):match("(%d%d:%d%d)") or ""
        local who = e.from or "?"
        local route = who
        if e.to and e.to ~= "" and e.to ~= who then
            route = who .. " → " .. e.to
        end
        local meta = e.date or ""
        if e.re ~= "" then
            meta = (meta ~= "" and (meta .. "  ·  " .. e.re)) or e.re
        end
        local snippetSrc = e.body or ""
        if snippetSrc == "" and e.re ~= "" then snippetSrc = e.re end
        local rec = byReg[who]
        table.insert(orchRows, cvMsgRow({
            when = when,
            who = who,
            snippet = cvPlainSnippet(snippetSrc, 160),
            full = e.body or "",
            route = route,
            meta = meta,
            path = rec and rec.path or "",
            name = who,
        }))
    end
    if #orchRows == 0 then
        orchRows = { '<div class="empty">no agent messages yet</div>' }
    end

    -- Side column: live agents first, idle agents under a divider.
    local lists = cvAgentLists()
    local liveRows, idleRows = {}, {}
    for _, a in ipairs(lists.live) do liveRows[#liveRows + 1] = cvAgentButton(a) end
    for _, a in ipairs(lists.idle) do idleRows[#idleRows + 1] = cvAgentButton(a) end
    if #liveRows == 0 then
        liveRows = { '<div class="empty">none running</div>' }
    end
    if #idleRows == 0 then
        idleRows = { '<div class="empty">none</div>' }
    end

    local boardHtml = '<div id="board" class="board" hidden></div>'
    if cvBoard then
        local cards = cvBoardAgents()
        local tileRows = {}
        for _, a in ipairs(cards) do
            tileRows[#tileRows + 1] = cvBoardCard(a)
        end
        if #tileRows == 0 then
            tileRows = { '<div class="empty">No live agents to show</div>' }
        end
        boardHtml = '<div id="board" class="board">' ..
            '<div class="board-bar">' ..
            '<h1>Live agents</h1>' ..
            '<span class="n">' .. tostring(#cards) .. '</span>' ..
            '<input id="tileFind" type="search" placeholder="Find agent" ' ..
            'oninput="filterTiles(this.value)" aria-label="Find agent">' ..
            '<button type="button" onclick="send({action:\'boardclose\'})">Back</button>' ..
            '</div>' ..
            '<div class="board-grid">' .. table.concat(tileRows) .. '</div></div>'
    end

    return [[<!doctype html><html><head><meta charset="utf-8"><style>
      ]] .. cvSharedCss(th) .. [[
      body {
        font: 13px/1.4 -apple-system, "SF Pro Text", sans-serif;
        color: rgba(235,238,250,0.92);
        padding: 40px 10px 12px;
        user-select: none;
        background:
          radial-gradient(140% 70% at 50% 0%, rgba(var(--ac),0.13), transparent 60%),
          rgba(14,15,22,0.58);
        height: 100vh;
        overflow: hidden;
        display: flex;
        flex-direction: column;
      }
      .shell { flex: 1; min-height: 0; display: flex; gap: 10px; }
      .dock { flex: 1; min-width: 0; min-height: 0; display: flex; gap: 10px; }
      .shell.has-board .dock { flex: 0 0 560px; width: 560px; }
      .main { flex: 1; min-width: 0; min-height: 0; display: flex;
              flex-direction: column; overflow: hidden; }
      .rail {
        width: 176px; flex-shrink: 0; min-height: 0;
        display: flex; flex-direction: column;
        background: linear-gradient(rgba(255,255,255,0.055), rgba(255,255,255,0.03));
        border: 1px solid rgba(255,255,255,0.10);
        border-radius: 14px;
        padding: 10px 8px 8px;
      }
      .arrange {
        width: 100%; border-radius: 10px; padding: 5px 6px;
        font-size: 11px; font-weight: 600; margin-bottom: 6px;
        color: rgba(235,238,250,0.95);
        background: rgba(var(--ac),0.16);
        border-color: rgba(var(--ac),0.32);
      }
      .arrange:hover { background: rgba(var(--ac),0.24); }
      .rail-pair { display: flex; gap: 6px; margin-bottom: 6px; }
      .rail-pair button { flex: 1; min-width: 0; padding: 5px 4px; font-size: 11px; }
      .arrange.danger {
        color: #ffecec;
        background: rgba(235,110,110,0.22);
        border-color: rgba(235,110,110,0.4);
      }
      .arrange.danger:hover { background: rgba(235,110,110,0.32); }
      button.danger {
        color: #ffecec;
        background: rgba(235,110,110,0.22);
        border-color: rgba(235,110,110,0.4);
      }
      button.danger:hover { background: rgba(235,110,110,0.32); }
      #agentFind {
        width: 100%; margin-bottom: 10px;
        background: rgba(0,0,0,0.28); color: rgba(235,238,250,0.9);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 8px;
        padding: 6px 8px; font-size: 12px; outline: none;
      }
      #agentFind:focus { border-color: rgba(var(--ac),0.5); }
      .rail-scroll { flex: 1; min-height: 0; overflow-y: auto; }
      .rail-scroll::-webkit-scrollbar { width: 5px; }
      .rail-scroll::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.15); border-radius: 3px; }
      .rail h2 { display: flex; align-items: baseline; gap: 6px;
                 margin: 2px 2px 6px; }
      .rail h2 .n { font-family: var(--mono); font-size: 10px;
                    color: rgba(var(--ac),0.7); letter-spacing: 0; }
      .agent {
        display: flex; align-items: center; gap: 6px;
        width: 100%; text-align: left;
        border-radius: 8px; padding: 4px 6px; margin-bottom: 2px;
        font-size: 11px; font-weight: 500; line-height: 1.25;
        color: rgba(235,238,250,0.55);
        background: transparent; border: 1px solid transparent;
      }
      .agent:hover {
        background: rgba(var(--ac),0.10);
        border-color: rgba(var(--ac),0.22);
        color: rgba(235,238,250,0.92);
      }
      .agent.live { color: rgba(235,238,250,0.95); }
      .agent .an {
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .dot {
        width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0;
        background: #5ee09a;
        box-shadow: 0 0 8px rgba(94,224,154,0.75);
        animation: livepulse 1.8s ease-in-out infinite;
      }
      .dot.cur {
        background: transparent; border: 1.5px solid rgba(94,224,154,0.75);
        box-shadow: none; animation: none;
      }
      .dot.off {
        background: rgba(235,238,250,0.22); box-shadow: none; animation: none;
      }
      @keyframes livepulse {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.4; }
      }
      @media (prefers-reduced-motion: reduce) {
        .dot { animation: none; }
      }
      .grow { flex: 1; display: flex; flex-direction: column;
              min-height: 0; margin-bottom: 0; overflow-y: auto; }
      .card {
        background: linear-gradient(rgba(255,255,255,0.065), rgba(255,255,255,0.04));
        border: 1px solid rgba(255,255,255,0.10);
        border-top-color: rgba(255,255,255,0.18);
        border-radius: 14px;
        padding: 10px 10px;
        margin-bottom: 10px;
        backdrop-filter: blur(24px) saturate(1.5);
        -webkit-backdrop-filter: blur(24px) saturate(1.5);
        box-shadow: 0 8px 24px rgba(0,0,0,0.25);
      }
      .row { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; margin-bottom: 10px; }
      .row:last-child { margin-bottom: 2px; }
      .row label { width: 50px; font-size: 10.5px; font-weight: 500;
                   color: rgba(235,238,250,0.42); text-transform: uppercase;
                   letter-spacing: 1px; }
      .val { width: 46px; }
      #eq { margin: 0 auto; }
      input[type=range] {
        -webkit-appearance: none; flex: 1; height: 4px; border-radius: 3px;
        background: linear-gradient(90deg, rgba(var(--ac),0.65), rgba(var(--nr),0.4));
        outline: none;
      }
      input[type=range]::-webkit-slider-thumb {
        -webkit-appearance: none; width: 16px; height: 16px; border-radius: 50%;
        background: rgb(var(--ac));
        border: 2px solid rgba(255,255,255,0.85);
        box-shadow: 0 1px 6px rgba(var(--ac),0.5);
        cursor: pointer;
      }
      select {
        flex: 1; -webkit-appearance: none; appearance: none;
        background: rgba(255,255,255,0.07); color: rgba(235,238,250,0.9);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 10px;
        padding: 6px 26px 6px 10px; font-size: 12.5px; cursor: pointer; outline: none;
        background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path d='M1 1l4 4 4-4' fill='none' stroke='%23aab2c8' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/></svg>");
        background-repeat: no-repeat; background-position: right 10px center;
      }
      select:hover { border-color: rgba(var(--ac),0.32); }
      h2 { font-size: 10px; font-weight: 600; color: rgba(235,238,250,0.38);
           text-transform: uppercase; letter-spacing: 1.4px; margin: 2px 2px 8px; }
      h2.sub { margin-top: 14px; }
      .hist { flex: 1; min-height: 140px; overflow-y: auto; margin: 0 -4px; padding: 0 4px; }
      .hist::-webkit-scrollbar, .orch::-webkit-scrollbar { width: 5px; }
      .hist::-webkit-scrollbar-thumb, .orch::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.15); border-radius: 3px; }
      .orch { flex: 0 0 auto; margin: 0 -4px; padding: 0 4px 8px; }
      .orch .msg { padding: 7px 10px; margin-bottom: 4px; font-size: 12px; }
      .msg {
        padding: 8px 11px; border-radius: 12px; margin-bottom: 6px;
        background: rgba(255,255,255,0.045);
        border: 1px solid rgba(255,255,255,0.07);
        cursor: pointer; line-height: 1.4; font-size: 12.5px;
        color: rgba(235,238,250,0.78);
        transition: background 0.15s, border-color 0.15s, transform 0.1s;
      }
      .msg:hover {
        background: rgba(var(--ac),0.10);
        border-color: rgba(var(--ac),0.30);
        transform: translateX(2px);
      }
      .msg:active { transform: scale(0.985); }
      .msg:focus-visible {
        outline: 2px solid rgba(var(--ac),0.85); outline-offset: 1px;
      }
      .msg-head {
        display: flex; align-items: baseline; gap: 8px; margin-bottom: 3px;
      }
      .msg .t { color: rgba(var(--ac),0.7); font-size: 10px; font-weight: 500;
                font-family: var(--mono);
                font-variant-numeric: tabular-nums; flex-shrink: 0; }
      .msg .who {
        font-weight: 650; font-size: 12.5px;
        color: rgb(var(--ac));
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .msg .snip {
        display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2;
        overflow: hidden; color: rgba(235,238,250,0.78); font-weight: 400;
      }
      .msg .full { display: none; }
      .empty { color: rgba(235,238,250,0.3); padding: 10px; font-size: 12px; }
      .board {
        flex: 1; min-width: 0; min-height: 0;
        display: flex; flex-direction: column;
        background:
          radial-gradient(120% 70% at 50% 0%, rgba(var(--ac),0.14), transparent 55%),
          rgba(16,18,26,0.94);
        border: 1px solid rgba(255,255,255,0.10);
        border-radius: 14px;
        padding: 10px 12px 12px;
      }
      .board[hidden] { display: none; }
      .board-bar {
        display: flex; align-items: center; gap: 10px;
        margin-bottom: 14px; flex-shrink: 0;
      }
      .board-bar h1 {
        font-size: 15px; font-weight: 650; letter-spacing: 0;
        text-transform: none; color: rgba(235,238,250,0.95);
        margin: 0 auto 0 0;
      }
      .board-bar .n {
        font-family: var(--mono); font-size: 11px;
        color: rgba(var(--ac),0.75);
      }
      #tileFind {
        width: 200px; background: rgba(0,0,0,0.28);
        color: rgba(235,238,250,0.9);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 8px;
        padding: 6px 8px; font-size: 12px; outline: none;
      }
      #tileFind:focus { border-color: rgba(var(--ac),0.5); }
      .board-grid {
        flex: 1; min-height: 0; overflow: auto;
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
        gap: 12px; align-content: start;
      }
      .board-grid::-webkit-scrollbar { width: 6px; }
      .board-grid::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.18); border-radius: 3px; }
      .tile {
        display: flex; flex-direction: column;
        min-height: 260px; max-height: 380px;
        padding: 13px 14px 12px;
        border-radius: 14px;
        background: rgba(28,30,42,0.96);
        border: 1px solid rgba(255,255,255,0.12);
        transition: border-color 0.15s, background 0.15s;
      }
      .tile:hover {
        background: rgba(34,36,50,0.98);
        border-color: rgba(var(--ac),0.28);
      }
      .tile.working { border-color: rgba(94,224,154,0.42); }
      .tile-head {
        display: flex; align-items: center; gap: 8px; margin-bottom: 4px;
      }
      .tile-name {
        flex: 1; min-width: 0;
        font-weight: 650; font-size: 14px;
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .tile-x {
        flex-shrink: 0;
        width: 24px; height: 24px; padding: 0;
        border-radius: 7px;
        font-size: 16px; font-weight: 500; line-height: 1;
        color: rgba(235,238,250,0.4);
        background: transparent; border: 1px solid transparent;
      }
      .tile-x:hover {
        color: #ffd4d4;
        background: rgba(235,110,110,0.28);
        border-color: rgba(235,110,110,0.45);
      }
      .flag {
        margin-left: auto; flex-shrink: 0;
        font-size: 10px; font-weight: 650; letter-spacing: 0.04em;
        text-transform: uppercase;
        padding: 3px 7px; border-radius: 999px;
        color: rgba(235,238,250,0.45);
        background: rgba(255,255,255,0.06);
      }
      .flag.on {
        color: #c5f6d8;
        background: rgba(94,224,154,0.18);
      }
      .tile-msgs {
        flex: 1; min-height: 0;
        overflow-y: auto;
        margin: 4px -4px 10px;
        padding: 0 4px 2px;
      }
      .tile-msgs::-webkit-scrollbar { width: 5px; }
      .tile-msgs::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.18); border-radius: 3px; }
      .tile-msgs .msg {
        padding: 6px 8px; margin-bottom: 4px; font-size: 12px;
        background: rgba(18,20,30,0.92);
      }
      .tile-msgs .msg:hover { transform: none; }
      .tile-msgs .snip { -webkit-line-clamp: 3; }
      .tile-actions {
        display: flex; flex-wrap: nowrap; gap: 4px; margin-top: auto;
        min-width: 0;
      }
      .tile-actions button {
        padding: 2px 6px; font-size: 10px; border-radius: 999px;
        flex: 0 1 auto; min-width: 0;
      }
      .tile-actions button:disabled { opacity: 0.35; cursor: default; }
      h2.sub { display: flex; align-items: center; gap: 8px; }
      h2 .net-btn {
        margin-left: auto; text-transform: none; letter-spacing: 0;
        font-size: 11px; font-weight: 600; padding: 4px 10px;
      }
      .net {
        position: fixed; inset: 0; z-index: 18;
        display: flex; flex-direction: column;
        background:
          radial-gradient(90% 70% at 50% 40%, rgba(var(--ac),0.10), transparent 58%),
          rgba(10,11,18,0.97);
        padding: 40px 14px 12px;
      }
      .net[hidden] { display: none; }
      .net-bar {
        display: flex; align-items: center; gap: 10px;
        margin-bottom: 8px; flex-shrink: 0;
      }
      .net-bar h1 {
        font-size: 15px; font-weight: 650; letter-spacing: 0;
        text-transform: none; color: rgba(235,238,250,0.95);
        margin: 0;
      }
      .net-bar .n {
        font-family: var(--mono); font-size: 11px;
        color: rgba(var(--ac),0.75);
      }
      .net-hint {
        margin-right: auto;
        font-size: 11.5px; color: rgba(235,238,250,0.42);
      }
      #netCanvas { flex: 1; min-height: 0; width: 100%; display: block; touch-action: none; }
      .net-tip {
        position: absolute; z-index: 2;
        max-width: 320px; pointer-events: none;
        background: rgba(18,20,30,0.94);
        border: 1px solid rgba(var(--ac),0.35);
        border-radius: 10px;
        padding: 7px 10px;
        font-size: 12px; line-height: 1.35;
        color: rgba(235,238,250,0.9);
      }
      #netEmpty {
        position: absolute; left: 50%; top: 50%;
        transform: translate(-50%, -50%);
      }
      .snaps {
        position: fixed; inset: 0; z-index: 19;
        background: rgba(8,9,16,0.58);
        display: flex; padding: 48px 16px 16px;
        justify-content: center; align-items: flex-start;
      }
      .snaps[hidden] { display: none; }
      .snaps-card {
        width: min(420px, 100%); max-height: calc(100% - 12px);
        display: flex; flex-direction: column;
        background: rgba(22,24,36,0.96);
        border: 1px solid rgba(255,255,255,0.14);
        border-radius: 16px;
        overflow: hidden;
      }
      .snaps-bar {
        display: flex; align-items: center; gap: 8px;
        padding: 10px 12px; flex-shrink: 0;
        border-bottom: 1px solid rgba(255,255,255,0.08);
      }
      .snaps-bar h1 {
        font-size: 14px; font-weight: 650; letter-spacing: 0;
        text-transform: none; margin: 0 auto 0 0;
      }
      .snaps-list { flex: 1; min-height: 0; overflow-y: auto; padding: 8px; }
      .snaps-list::-webkit-scrollbar { width: 5px; }
      .snaps-list::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.18); border-radius: 3px; }
      .snap {
        padding: 9px 11px; border-radius: 12px; margin-bottom: 6px;
        background: rgba(255,255,255,0.045);
        border: 1px solid rgba(255,255,255,0.07);
        cursor: pointer;
      }
      .snap:hover {
        background: rgba(var(--ac),0.10);
        border-color: rgba(var(--ac),0.30);
      }
      .snap-head { display: flex; align-items: baseline; gap: 8px; }
      .snap .t {
        font-family: var(--mono); font-size: 12px; font-weight: 650;
        color: rgb(var(--ac));
      }
      .snap .n {
        font-family: var(--mono); font-size: 10px;
        color: rgba(var(--ac),0.7);
      }
      .snap-del {
        margin-left: auto; padding: 2px 8px; font-size: 11px;
      }
      .reader {
        position: fixed; inset: 0; z-index: 20;
        background: rgba(8,9,16,0.58);
        display: flex; padding: 40px 12px 12px;
        animation: readerIn 0.16s ease-out;
      }
      .reader[hidden] { display: none; }
      @keyframes readerIn { from { opacity: 0; } to { opacity: 1; } }
      @media (prefers-reduced-motion: reduce) { .reader { animation: none; } }
      .reader-card {
        flex: 1; min-height: 0; display: flex; flex-direction: column;
        background: rgba(22,24,36,0.94);
        border: 1px solid rgba(255,255,255,0.14);
        border-radius: 16px;
        backdrop-filter: blur(28px) saturate(1.4);
        -webkit-backdrop-filter: blur(28px) saturate(1.4);
        box-shadow: 0 16px 40px rgba(0,0,0,0.45);
        overflow: hidden;
      }
      .reader-bar {
        display: flex; align-items: flex-start; gap: 8px;
        padding: 10px 12px; flex-shrink: 0;
        border-bottom: 1px solid rgba(255,255,255,0.08);
        flex-wrap: wrap;
      }
      .reader-titles { margin-right: auto; min-width: 0; padding-right: 8px; }
      .reader-actions {
        display: flex; flex-wrap: wrap; gap: 6px;
        justify-content: flex-end; align-items: center;
      }
      .reader-route {
        font-size: 13px; font-weight: 600;
        color: rgba(235,238,250,0.95);
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .reader-route[hidden] { display: none; }
      .reader-bar .t {
        color: rgba(var(--ac),0.75);
        font-size: 10.5px; font-weight: 500;
        font-family: var(--mono);
        font-variant-numeric: tabular-nums;
        overflow-wrap: anywhere;
      }
      .reader-body {
        flex: 1; min-height: 0; overflow-y: auto;
        padding: 14px 16px 18px;
        font-size: 15px; line-height: 1.6;
        overflow-wrap: anywhere;
        user-select: text; -webkit-user-select: text;
        color: rgba(235,238,250,0.94);
      }
      .reader-body:focus { outline: none; }
      .reader-body::-webkit-scrollbar { width: 6px; }
      .reader-body::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18);
                                              border-radius: 3px; }
      .reader-body p { margin: 0 0 0.85em; max-width: 72ch; }
      .reader-body p:last-child { margin-bottom: 0; }
      .reader-body .md-h {
        font-weight: 650; line-height: 1.3; color: rgba(235,238,250,0.98);
        margin: 1.1em 0 0.4em;
      }
      .reader-body h1.md-h { font-size: 1.35em; }
      .reader-body h2.md-h { font-size: 1.18em; }
      .reader-body h3.md-h, .reader-body h4.md-h { font-size: 1.05em; }
      .reader-body h5.md-h, .reader-body h6.md-h { font-size: 1em; }
      .reader-body .md-h:first-child { margin-top: 0; }
      .reader-body .md-list { margin: 0 0 0.9em 1.15em; padding: 0; }
      .reader-body .md-list li { margin: 0.22em 0; }
      .reader-body .md-quote {
        margin: 0.55em 0 1em; padding: 8px 12px;
        background: rgba(var(--ac),0.07);
        border-radius: 10px;
        color: rgba(235,238,250,0.82);
      }
      .reader-body .md-hr {
        border: 0; height: 1px; margin: 1em 0;
        background: rgba(255,255,255,0.12);
      }
      .reader-body .md-link { color: rgb(var(--ac)); font-weight: 500; }
      .reader-body code {
        font-family: var(--mono); font-size: 0.88em;
        background: rgba(var(--ac),0.12);
        padding: 1px 5px; border-radius: 4px;
      }
      .reader-body .md-code {
        background: rgba(0,0,0,0.38);
        border: 1px solid rgba(255,255,255,0.08);
        border-radius: 10px;
        padding: 10px 12px; overflow-x: auto;
        font-family: var(--mono); font-size: 12.5px; line-height: 1.45;
        margin: 0.55em 0 1em; white-space: pre-wrap;
      }
      .reader-body .md-code code { background: none; padding: 0; font-size: inherit; }
      .reader-body .md-table-wrap { overflow-x: auto; margin: 0.55em 0 1.05em; }
      .reader-body .md-table {
        width: 100%; border-collapse: collapse;
        font-size: 13px; line-height: 1.4;
      }
      .reader-body .md-table th, .reader-body .md-table td {
        padding: 7px 10px;
        border: 1px solid rgba(255,255,255,0.12);
        text-align: left; vertical-align: top;
      }
      .reader-body .md-table th {
        background: rgba(var(--ac),0.16);
        font-weight: 600; font-size: 11px;
        letter-spacing: 0.03em;
        color: rgba(235,238,250,0.95);
      }
      .reader-body .md-table tbody tr:nth-child(even) td {
        background: rgba(255,255,255,0.035);
      }
      .reader-body .msg-block {
        border: 1px solid rgba(255,255,255,0.08);
        border-radius: 12px;
        padding: 10px 12px;
        margin-bottom: 12px;
        background: rgba(255,255,255,0.03);
      }
      .reader-body .msg-block-meta {
        font-family: var(--mono); font-size: 10px;
        color: rgba(var(--ac),0.75);
        margin-bottom: 8px;
      }
    </style></head><body>
      <div class="shell]] .. (cvBoard and " has-board" or "") .. [[">
      ]] .. boardHtml .. [[
      <div class="dock">
      <aside class="rail" aria-label="Agents">
        <button type="button" class="arrange" onclick="send({action:'arrange'})"
          title="Open a card grid of running agents (A–Z). This panel stays on the right.">Arrange live</button>
        <button type="button" class="arrange" onclick="send({action:'shownet'})"
          title="Moving network of who messaged whom. Click a line to read the last note.">Show messages</button>
        <div class="rail-pair">
          <button type="button" onclick="send({action:'save'})"
            title="Save every Terminal where Claude is still running">Save</button>
          <button type="button" onclick="toggleSnaps()"
            title="Show saved times. Click a time to reopen those terminals.">Clock</button>
        </div>
        <button type="button" class="arrange danger"
          onclick="if(confirm('Exit every running Claude and close all Terminal windows?'))send({action:'closeall'})"
          title="Type exit in each running Claude, then close every Terminal window">Close all</button>
        <input id="agentFind" type="search" placeholder="Find agent"
          oninput="filterAgents(this.value)" aria-label="Find agent">
        <div class="rail-scroll" id="railScroll">
          <h2>Live <span class="n">]] .. tostring(#lists.live) .. [[</span></h2>
          ]] .. table.concat(liveRows) .. [[
          <h2 class="sub">Idle <span class="n">]] .. tostring(#lists.idle) .. [[</span></h2>
          ]] .. table.concat(idleRows) .. [[
        </div>
      </aside>
      <div class="main">
      <div class="card">
        <div class="row" style="margin-bottom:2px">
          <button id="power" class="]] .. powerCls .. [["
            onclick="send({action:'power'})">]] .. powerLbl .. [[</button>
          <button onclick="send({action:'stop'})" title="Stop speaking">◼</button>
          <div class="eq" id="eq" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>
          <button onclick="send({action:'shrink'})"
            title="Shrink to a small card on the side of the screen">Mini</button>
          <button onclick="send({action:'minimize'})"
            title="Minimize this panel">–</button>
          <button onclick="send({action:'refresh'})" title="Refresh">↻</button>
          <button onclick="send({action:'save'})"
            title="Save every Terminal where Claude is still running">Save</button>
          <button onclick="toggleSnaps()"
            title="Show saved times. Click a time to reopen those terminals.">Clock</button>
        </div>
      </div>
      <div class="card">
        <div class="row"><label>speed</label>
          <input type="range" min="0.5" max="2" step="0.05" value="]] .. speed .. [["
            oninput="sv.textContent=this.value+'x'"
            onchange="send({action:'speed',value:this.value})">
          <span class="val" id="sv">]] .. speed .. [[x</span></div>
        <div class="row"><label>volume</label>
          <input type="range" min="0" max="150" step="5" value="]] .. volume .. [["
            oninput="vv.textContent=this.value+'%'"
            onchange="send({action:'volume',value:this.value})">
          <span class="val" id="vv">]] .. volume .. [[%</span></div>
        <div class="row"><label>voice</label>
          <select onchange="send({action:'voice',value:this.value})">
          ]] .. table.concat(voiceOpts) .. [[</select></div>
      </div>
      <div class="card">
        <div class="row" style="margin-bottom:2px">
          <button id="pp" style="padding:3px 8px"
            onclick="this.textContent=this.textContent==='⏸'?'▶':'⏸';send({action:'playpause'})">▶</button>
          <input type="range" id="seek" min="0" max="1" step="0.1" value="0"
            onpointerdown="drag=true"
            oninput="pt.textContent=fmt(this.value)+' / '+fmt(this.max)"
            onchange="drag=false;send({action:'seek',value:this.value})">
          <span class="val" id="pt" style="width:92px">–:–– / –:––</span></div>
      </div>
      <div class="card grow">
        <h2>History — click to read</h2>
        <div class="hist">]] .. table.concat(histRows) .. [[</div>
        <h2 class="sub">Messages — click to read
          <button type="button" class="net-btn" onclick="send({action:'shownet'})"
            title="Moving network of who messaged whom">Show messages</button>
        </h2>
        <div class="orch">]] .. table.concat(orchRows) .. [[</div>
      </div>
      </div>
      </div>
      </div>
      <div id="net" class="net" hidden>
        <div class="net-bar">
          <h1>Messages</h1>
          <span class="n" id="netCount"></span>
          <span class="net-hint">Drag a name · click a line to read</span>
          <button type="button" onclick="closeNet()">Back</button>
        </div>
        <canvas id="netCanvas"></canvas>
        <div id="netTip" class="net-tip" hidden></div>
        <div id="netEmpty" class="empty" hidden>No agent messages yet</div>
      </div>
      <div id="snaps" class="snaps"]] .. (cvShowSnaps and "" or " hidden") .. [[
           role="dialog" aria-modal="true" aria-labelledby="snapsTitle"
           onclick="if(event.target===this)closeSnaps()">
        <div class="snaps-card">
          <div class="snaps-bar">
            <h1 id="snapsTitle">Saved sessions</h1>
            <button type="button" onclick="send({action:'save'})">Save now</button>
            <button type="button" onclick="closeSnaps()" aria-label="Close">✕</button>
          </div>
          <div class="snaps-list">]] .. cvSnapRows() .. [[</div>
        </div>
      </div>
      <div id="reader" class="reader" hidden role="dialog" aria-modal="true"
           aria-labelledby="readerRoute"
           onclick="if(event.target===this)closeMsg()">
        <div class="reader-card">
          <div class="reader-bar">
            <div class="reader-titles">
              <div class="reader-route" id="readerRoute" hidden></div>
              <span class="t" id="readerTime"></span>
            </div>
            <div class="reader-actions">
              <button id="prevBtn" type="button" onclick="stepMsg(-1)" hidden>‹ Previous</button>
              <button id="nextBtn" type="button" onclick="stepMsg(1)" hidden>Next ›</button>
              <button id="replayBtn" type="button" onclick="replayOpen()" hidden>▶ Replay</button>
              <button id="openBtn" type="button" onclick="openAgent()" hidden>Open</button>
              <button type="button" onclick="closeMsg()">Close</button>
            </div>
          </div>
          <div id="readerBody" class="reader-body" tabindex="0"></div>
        </div>
      </div>
      ]] .. cvPlayScript() .. [[
    </body></html>]]
end

function cvRefresh()
    if not cvPanel then return end
    if cvCompact then
        cvPanel:html(cvBuildHtml())
        return
    end
    if cvBoard then
        cvPanel:evaluateJavaScript(
            "(function(){var f=document.getElementById('tileFind');return f?f.value:'';})()",
            function(q)
                if not cvPanel then return end
                cvPanel:html(cvBuildHtml())
                if type(q) == "string" and q ~= "" then
                    cvPanel:evaluateJavaScript(string.format(
                        "(function(){var f=document.getElementById('tileFind');if(f){f.value=%s;if(window.filterTiles)filterTiles(f.value);}})()",
                        string.format("%q", q)))
                end
            end)
        return
    end
    -- Keep the agent-list scroll position and Find box so a refresh
    -- does not jump you back to the top of 150 names.
    cvPanel:evaluateJavaScript(
        "(function(){var r=document.getElementById('railScroll');var f=document.getElementById('agentFind');return JSON.stringify({s:r?r.scrollTop:0,q:f?f.value:''});})()",
        function(raw)
            local s, q = 0, ""
            if type(raw) == "string" then
                local ok, t = pcall(hs.json.decode, raw)
                if ok and type(t) == "table" then
                    s = tonumber(t.s) or 0
                    q = t.q or ""
                end
            end
            if not cvPanel then return end
            cvPanel:html(cvBuildHtml())
            cvPanel:evaluateJavaScript(string.format(
                "(function(){var r=document.getElementById('railScroll');if(r)r.scrollTop=%d;var f=document.getElementById('agentFind');if(f){f.value=%s;if(window.filterAgents)filterAgents(f.value);}})()",
                s, string.format("%q", q)))
        end)
end

local function cvSpeakText(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    local old = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    cvRun({ "clip" }, function()
        if old ~= nil then hs.pasteboard.setContents(old) end
    end)
end

local function cvCloseBoard()
    cvBoard = false
    if not cvPanel then return end
    if cvNet then
        cvPanel:frame(cvBoardFrame())
        return
    end
    cvPanel:frame(cvCompact and cvMiniFrame() or cvFullFrame())
    cvRefresh()
end

local function cvJsonArray(list)
    if not list or #list == 0 then return "[]" end
    local parts = {}
    for i, v in ipairs(list) do
        parts[i] = hs.json.encode(v) or "{}"
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function cvShowNet()
    if not cvPanel then return end
    local graph = cvCommGraph()
    if not cvBoard then
        local f = cvPanel:frame()
        if f and f.w < 720 then cvLastFullFrame = f end
        cvPanel:frame(cvBoardFrame())
    end
    cvNet = true
    local js = "openNet({nodes:" .. cvJsonArray(graph.nodes) ..
        ",edges:" .. cvJsonArray(graph.edges) .. "})"
    hs.timer.doAfter(0.08, function()
        if cvPanel then cvPanel:evaluateJavaScript(js) end
    end)
end

local function cvCloseNet()
    local was = cvNet
    cvNet = false
    if was and cvPanel and not cvBoard then
        cvPanel:frame(cvCompact and cvMiniFrame() or cvFullFrame())
    end
end

local function cvOpenAllMsgs(name, path)
    if not cvPanel then return end
    local msgs = cvMessagesForAgent(name, path)
    if #msgs == 0 then
        hs.alert.show("No messages for " .. (name ~= "" and name or "this agent"), 2)
        return
    end
    local payload = {}
    for i, m in ipairs(msgs) do
        local text = m.text or ""
        if #text > 20000 then text = text:sub(1, 20000) .. "\n…" end
        payload[#payload + 1] = {
            when = m.when or "",
            kind = m.kind or "",
            route = m.route or "",
            text = text,
            index = m.index,
        }
        if i >= 40 then break end
    end
    cvPanel:evaluateJavaScript(
        "openAgentMsgs(" .. hs.json.encode(name or "") .. "," ..
        hs.json.encode(payload) .. "," .. hs.json.encode(path or "") .. ")")
end

-- Open the live-agent card grid beside this panel (A–Z). Click Arrange
-- live again, or Back, to close it. Does not resize Terminal windows.
local function cvArrangeLive()
    cvScanSessions(function()
        if cvCompact then
            cvCompact = false
        end
        if cvBoard then
            cvCloseBoard()
            return
        end
        cvBoard = true
        if cvPanel then
            local f = cvPanel:frame()
            if f and f.w < 720 then cvLastFullFrame = f end
            cvPanel:frame(cvBoardFrame())
        end
        cvRefresh()
    end)
end

local function cvApplyLayout()
    if not cvPanel then return end
    if cvBoard or cvNet then
        cvPanel:frame(cvBoardFrame())
    else
        cvPanel:frame(cvCompact and cvMiniFrame() or cvFullFrame())
    end
    cvPanel:html(cvBuildHtml())
end

local function cvSetCompact(compact)
    if compact and cvPanel and not cvBoard then
        cvLastFullFrame = cvPanel:frame()
    end
    cvBoard = false
    cvNet = false
    cvShowSnaps = false
    cvCompact = compact and true or false
    cvApplyLayout()
end

local cvBridge = hs.webview.usercontent.new("cv"):setCallback(function(msg)
    local m = msg.body or {}
    if m.action == "power" then
        cvRun({ "toggle" }, function() cvRefresh() end)
    elseif m.action == "stop" then
        cvRun({ "stop" })
    elseif m.action == "speed" then
        cvRun({ "speed", tostring(m.value) })
    elseif m.action == "volume" then
        cvRun({ "volume", tostring(m.value) })
    elseif m.action == "voice" then
        cvRun({ "voice", tostring(m.value) })
    elseif m.action == "replay" then
        cvRun({ "replay", tostring(m.index) })
    elseif m.action == "seek" then
        cvRun({ "seek", tostring(m.value) })
    elseif m.action == "playpause" then
        cvRun({ "playpause" })
    elseif m.action == "refresh" then
        cvScanSessions(function() cvRefresh() end)
    elseif m.action == "shrink" then
        cvSetCompact(true)
    elseif m.action == "minimize" then
        cvMinimizePanel()
    elseif m.action == "expand" then
        cvSetCompact(false)
    elseif m.action == "goto" then
        cvGotoAgent(tostring(m.path or ""))
    elseif m.action == "arrange" then
        cvArrangeLive()
    elseif m.action == "boardclose" then
        cvCloseBoard()
    elseif m.action == "save" then
        cvSaveSnapshot()
    elseif m.action == "restore" then
        cvRestoreSnapshot(m.ts)
    elseif m.action == "snapdel" then
        cvDeleteSnapshot(m.ts)
    elseif m.action == "snapclose" then
        cvShowSnaps = false
    elseif m.action == "closeall" then
        cvCloseAll()
    elseif m.action == "closeagent" then
        cvCloseAgent(tostring(m.path or ""), tostring(m.name or ""))
    elseif m.action == "shownet" then
        cvShowNet()
    elseif m.action == "netclose" then
        cvCloseNet()
    elseif m.action == "readlast" then
        local idx = tonumber(m.index)
        if idx and idx >= 1 then
            cvRun({ "replay", tostring(idx) })
        else
            local msgs = cvMessagesForAgent(tostring(m.name or ""), tostring(m.path or ""))
            local last = msgs[1]
            if last and last.text and last.text ~= "" then
                cvSpeakText(last.text)
            else
                hs.alert.show("No message to read", 2)
            end
        end
    elseif m.action == "allmsgs" then
        cvOpenAllMsgs(tostring(m.name or ""), tostring(m.path or ""))
    end
end)

-- Auto-refresh the open panel when spoken history or an agent message changes.
local cvRefreshPending = nil
local function cvScheduleRefresh()
    if cvRefreshPending then cvRefreshPending:stop() end
    cvRefreshPending = hs.timer.doAfter(0.5, function()
        cvRefreshPending = nil
        if cvArranging then return end
        if not (cvPanel and cvPanel:hswindow()) then return end
        -- Don't yank the HTML out from under an open reader popup.
        cvPanel:evaluateJavaScript(
            "(function(){var r=document.getElementById('reader');var n=document.getElementById('net');var s=document.getElementById('snaps');return !!(r&&!r.hidden)||!!(n&&!n.hidden)||!!(s&&!s.hidden);})()",
            function(isOpen)
                if isOpen ~= true then cvRefresh() end
            end)
    end)
end

local cvWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.cache/claude-voice/",
    function(files)
        for _, f in ipairs(files) do
            if f:find("history%.jsonl$") then
                cvScheduleRefresh()
                return
            end
        end
    end):start()

local cvOrchWatcher = hs.pathwatcher.new(ORCH_MSGS, function()
    cvScheduleRefresh()
end):start()

local cvRegWatcher = hs.pathwatcher.new(
    os.getenv("HOME") .. "/.claude/orchestration",
    function(files)
        for _, f in ipairs(files) do
            if f:find("registry%.json") then
                cvScheduleRefresh()
                return
            end
        end
    end):start()

hs.hotkey.bind({ "cmd", "ctrl" }, "g", function()
    if cvPanel then
        local hw = cvPanel:hswindow()
        if cvHidden or (hw and hw:isMinimized()) then
            cvRestorePanel()
            return
        end
        if hw then
            if cvTimer then cvTimer:stop(); cvTimer = nil end
            cvPanel:delete()
            cvPanel = nil
            cvCompact = false
            cvBoard = false
            cvNet = false
            cvShowSnaps = false
            cvHidden = false
            cvLastFullFrame = nil
            return
        end
    end
    cvCompact = false
    cvBoard = false
    cvNet = false
    cvShowSnaps = false
    cvHidden = false
    cvLastFullFrame = nil
    cvPanel = hs.webview.new(cvFullFrame(), {}, cvBridge)
        :windowStyle({ "titled", "closable", "miniaturizable", "resizable", "fullSizeContentView" })
        :windowTitle("claude-voice")
        :level(hs.drawing.windowLevels.floating)
        :allowTextEntry(true)
        :transparent(true)
        :html(cvBuildHtml())
    cvPanel:show()

    -- Seed the terminal-session cache so Live is accurate on first paint.
    cvScanSessions(function(changed)
        if changed then cvScheduleRefresh() end
    end)

    -- Poll playback position so the seek ball tracks the speech; every
    -- fifth tick, rescan claude terminal sessions for the Live list.
    if cvTimer then cvTimer:stop() end
    local tick = 0
    cvTimer = hs.timer.doEvery(1.0, function()
        if not cvPanel then
            if cvTimer then cvTimer:stop(); cvTimer = nil end
            return
        end
        if cvHidden then return end
        tick = tick + 1
        -- Rescan Claude sessions so Live turns off soon after a process exits.
        if tick % 2 == 0 then
            cvScanSessions(function(changed)
                if changed then cvScheduleRefresh() end
            end)
        end
        cvSpawn({ "playinfo" }, function(_, stdout)
            local ok, info = pcall(hs.json.decode, stdout or "")
            if ok and info and cvPanel then
                cvPanel:evaluateJavaScript(string.format("updPlay(%.2f,%.2f,%s)",
                    tonumber(info.pos) or 0, tonumber(info.duration) or 0,
                    info.playing and "true" or "false"))
            end
        end)
    end)
end)
