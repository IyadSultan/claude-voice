-- claude-voice / Hammerspoon floating control panel
--
-- Cmd+Ctrl+G toggles a glassy floating panel with:
--   * on/off toggle, stop button
--   * speed / volume sliders, voice picker
--   * play/pause + seek bar for the current message (drag the ball to jump
--     back to any point of the speech)
--   * clickable history of past spoken messages: agent name, then the
--     message. Click any to read the full text in a scrollable popup
--     (headings, lists, tables rendered), with a Replay button
--   * five most recent agent-to-agent messages (agent name, then the
--     message). Click to read the whole note in the same formatted popup
--   * side column of every registered agent: Live (green = a Terminal
--     whose title shows `◂ claude`, i.e. an active cloud agent) on top,
--     Idle underneath. Click a name to bring that agent's Terminal
--     forward at a readable size — never a 33×5 thumbnail.
--   * "Arrange live" tiles every Terminal that currently has a cloud agent
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
local cvLastFullFrame = nil
local cvArranging = false
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
    return '<div class="msg" tabindex="0" role="button"' .. idx ..
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

-- Readable Terminal size on the main screen, leaving a strip for this panel.
local function cvStandardTermFrame()
    local sf = hs.screen.mainScreen():frame()
    local gutter = 24
    if cvPanel then
        local pf = cvPanel:frame()
        if pf and pf.x > sf.x + sf.w * 0.45 then
            gutter = (sf.x + sf.w) - pf.x + 16
        else
            gutter = FULL.w + 28
        end
    end
    local w = math.min(1040, math.max(720, sf.w - gutter - 48))
    local h = math.min(720, math.max(480, sf.h - 96))
    return { x = sf.x + 28, y = sf.y + 48, w = w, h = h }
end

local function cvResizeFocusedTerminal()
    local app = hs.application.get("Terminal")
    if not app then return end
    app:activate()
    local w = app:focusedWindow()
    if not w then return end
    pcall(function()
        local space = hs.spaces.focusedSpace()
        if space then hs.spaces.moveWindowToSpace(w, space) end
    end)
    w:unminimize()
    w:setFrame(cvStandardTermFrame())
    w:raise()
    w:focus()
end

-- Terminal.app titles look like:
--   "iNotes — ✳ some task — node ◂ claude -c — 33×5"   (active cloud agent)
--   "iNotes — -zsh — 128×30"                           (idle shell)
-- Live / green = the title contains "◂ claude". Click matches the folder
-- name at the start of the title, then enlarges that window so it is readable.
local cvTermByPath = {}
local cvTermSig = ""

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
      set nm to name of w as text
      set cloud to "0"
      if nm contains "◂ claude" then set cloud to "1"
      set AppleScript's text item delimiters to " — "
      set prefix to text item 1 of nm
      set AppleScript's text item delimiters to ""
      set out to out & cloud & "::" & prefix & linefeed
    end try
  end repeat
end tell
return out
]]
    local t = hs.task.new("/usr/bin/osascript", function(_, stdout)
        local byKey = cvIndexRegistry()
        local byPath, sig = {}, {}
        for line in (stdout or ""):gmatch("[^\n]+") do
            local cloud, prefix = line:match("^([01])::(.*)$")
            if prefix and prefix ~= "" then
                prefix = prefix:gsub("%s+$", "")
                local rec = byKey[prefix]
                local path = rec and rec.path or ("__win__/" .. prefix)
                local isCloud = cloud == "1"
                local prev = byPath[path]
                if not prev or (isCloud and not prev.cloud) then
                    byPath[path] = {
                        prefix = prefix,
                        cloud = isCloud,
                        name = rec and rec.name or prefix,
                        last_active = rec and rec.last_active or "",
                    }
                end
                sig[#sig + 1] = cloud .. prefix
            end
        end
        table.sort(sig)
        local s = table.concat(sig, ";")
        local changed = s ~= cvTermSig
        cvTermSig = s
        cvTermByPath = byPath
        if andThen then andThen(changed) end
    end)
    t:setInput(script)
    t:start()
end

-- Live = Terminal title contains "◂ claude" (active cloud agent).
-- Idle = registered agent with no such window.
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

local function cvAgentButton(a)
    local cls = a.live and "agent live" or "agent"
    local dot = a.live
        and '<span class="dot" aria-hidden="true"></span>'
        or '<span class="dot off" aria-hidden="true"></span>'
    local tip = a.path
    if a.live then
        tip = a.name .. " — active cloud agent (click to open at full size)"
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

-- Bring the matching Terminal window forward and enlarge it so the
-- conversation is readable. Prefers a window whose title contains "claude".
local function cvFocusTerminal(prefixes)
    local list = {}
    for _, p in ipairs(prefixes or {}) do list[#list + 1] = cvAsQuote(p) end
    if #list == 0 then return false end
    local script = [[
set prefs to {]] .. table.concat(list, ", ") .. [[}
set cloudWin to missing value
set anyWin to missing value
tell application "Terminal"
  repeat with w in windows
    try
      set nm to name of w as text
      repeat with p in prefs
        set pref to p as text
        if nm starts with (pref & " —") then
          if nm contains "◂ claude" then
            set cloudWin to w
          else if anyWin is missing value then
            set anyWin to w
          end if
        end if
      end repeat
    end try
  end repeat
  set target to cloudWin
  if target is missing value then set target to anyWin
  if target is missing value then return "MISS"
  try
    set miniaturized of target to false
  end try
  set index of target to 1
  activate
  return "OK"
end tell
]]
    local ok, out = hs.osascript.applescript(script)
    return ok and out == "OK"
end

local function cvGotoAgent(path)
    if type(path) ~= "string" or path == "" then return end
    local prefixes = cvPrefixesFor(path)
    if cvFocusTerminal(prefixes) then
        hs.timer.doAfter(0.15, cvResizeFocusedTerminal)
        return
    end
    -- No existing window: open a normal-sized Terminal in that folder.
    local folder = path
    if folder:sub(1, 8) == "__win__/" then return end
    hs.task.new("/usr/bin/open", function()
        hs.timer.doAfter(0.55, cvResizeFocusedTerminal)
    end, { "-a", "Terminal", folder }):start()
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

local function cvTileWindows(wins)
    local n = #wins
    if n == 0 then
        hs.alert.show("No live agent windows to arrange", 2)
        return
    end
    local sf = hs.screen.mainScreen():frame()
    local pad = 8
    local area = {
        x = sf.x + pad,
        y = sf.y + pad,
        w = sf.w - cvGutterRight() - pad * 2,
        h = sf.h - pad * 2,
    }
    local cols = 1
    if n >= 2 then cols = 2 end
    if n >= 5 then cols = 3 end
    if n >= 10 then cols = 4 end
    local rows = math.ceil(n / cols)
    local tw = math.floor(area.w / cols)
    local th = math.floor(area.h / rows)
    local space = nil
    pcall(function() space = hs.spaces.focusedSpace() end)
    for i, win in ipairs(wins) do
        local c = (i - 1) % cols
        local r = math.floor((i - 1) / cols)
        if space then pcall(hs.spaces.moveWindowToSpace, win, space) end
        pcall(function() win:moveToScreen(hs.screen.mainScreen()) end)
        win:unminimize()
        win:setFrame({
            x = area.x + c * tw,
            y = area.y + r * th,
            w = tw - pad,
            h = th - pad,
        })
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
    for _, w in ipairs(app:allWindows()) do
        local t = w:title() or ""
        if t:find("◂ claude", 1, true) then
            wins[#wins + 1] = w
        end
    end
    return wins
end

-- Put every active-cloud Terminal on this screen in a tidy grid.
local function cvArrangeLive()
    local wins = cvCloudTerminalWindows()
    if #wins == 0 then
        hs.alert.show("No live cloud agents to arrange", 2.5)
        return
    end
    cvArranging = true
    cvTileWindows(wins)
    hs.timer.doAfter(0.4, function()
        cvArranging = false
    end)
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
        padding: 6px 16px; font-size: 12.5px; font-weight: 500; cursor: pointer;
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
        function openMsg(el) {
          openIndex = el.dataset.index || null;
          const timeEl = document.getElementById('readerTime');
          const routeEl = document.getElementById('readerRoute');
          const body = document.getElementById('readerBody');
          const reader = document.getElementById('reader');
          const replayBtn = document.getElementById('replayBtn');
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
          if (replayBtn) replayBtn.hidden = !openIndex;
          const full = el.querySelector('.full');
          const raw = full ? full.textContent : '';
          const html = mdToHtml(raw);
          body.innerHTML = html || ('<p>' + esc(raw) + '</p>');
          body.scrollTop = 0;
          reader.hidden = false;
          body.focus();
        }
        function closeMsg() {
          const reader = document.getElementById('reader');
          if (reader) reader.hidden = true;
          openIndex = null;
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
        document.addEventListener('keydown', function(e) {
          if (e.key === 'Escape') closeMsg();
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

    local histRows = {}
    for i, e in ipairs(cvReadHistory(20)) do
        local when = os.date("%H:%M", math.floor(e.ts or 0))
        local who, snippetText, full = cvSplitSpoken(e)
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
        table.insert(orchRows, cvMsgRow({
            when = when,
            who = who,
            snippet = cvPlainSnippet(snippetSrc, 160),
            full = e.body or "",
            route = route,
            meta = meta,
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
        liveRows = { '<div class="empty">none open</div>' }
    end
    if #idleRows == 0 then
        idleRows = { '<div class="empty">none</div>' }
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
        width: 100%; border-radius: 10px; padding: 7px 8px;
        font-size: 11.5px; font-weight: 600; margin-bottom: 8px;
        color: rgba(235,238,250,0.95);
        background: rgba(var(--ac),0.16);
        border-color: rgba(var(--ac),0.32);
      }
      .arrange:hover { background: rgba(var(--ac),0.24); }
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
        display: flex; align-items: center; gap: 7px;
        width: 100%; text-align: left;
        border-radius: 9px; padding: 6px 8px; margin-bottom: 3px;
        font-size: 12px; font-weight: 500; line-height: 1.25;
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
        padding: 12px 14px;
        margin-bottom: 12px;
        backdrop-filter: blur(24px) saturate(1.5);
        -webkit-backdrop-filter: blur(24px) saturate(1.5);
        box-shadow: 0 8px 24px rgba(0,0,0,0.25);
      }
      .row { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
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
      }
      .reader-titles { margin-right: auto; min-width: 0; padding-right: 8px; }
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
    </style></head><body>
      <div class="shell">
      <aside class="rail" aria-label="Agents">
        <button type="button" class="arrange" onclick="send({action:'arrange'})"
          title="Put every live agent window on this screen, in a grid">Arrange live</button>
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
          <button onclick="send({action:'stop'})">◼ Stop</button>
          <div class="eq" id="eq" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div>
          <button onclick="send({action:'shrink'})"
            title="Shrink to a small card on the side of the screen">Make smaller</button>
          <button onclick="send({action:'refresh'})" title="Refresh">↻</button>
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
          <button id="pp" style="padding:4px 11px"
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
        <h2 class="sub">Messages — click to read</h2>
        <div class="orch">]] .. table.concat(orchRows) .. [[</div>
      </div>
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
            <button id="replayBtn" onclick="replayOpen()">▶ Replay</button>
            <button onclick="closeMsg()" aria-label="Close">✕</button>
          </div>
          <div id="readerBody" class="reader-body" tabindex="0"></div>
        </div>
      </div>
      ]] .. cvPlayScript() .. [[
    </body></html>]]
end

local function cvRefresh()
    if not cvPanel then return end
    if cvCompact then
        cvPanel:html(cvBuildHtml())
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

local function cvApplyLayout()
    if not cvPanel then return end
    cvPanel:frame(cvCompact and cvMiniFrame() or cvFullFrame())
    cvPanel:html(cvBuildHtml())
end

local function cvSetCompact(compact)
    if compact and cvPanel then
        cvLastFullFrame = cvPanel:frame()
    end
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
        cvRefresh()
    elseif m.action == "shrink" then
        cvSetCompact(true)
    elseif m.action == "expand" then
        cvSetCompact(false)
    elseif m.action == "goto" then
        cvGotoAgent(tostring(m.path or ""))
    elseif m.action == "arrange" then
        cvArrangeLive()
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
            "(function(){var r=document.getElementById('reader');return !!(r&&!r.hidden);})()",
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
    if cvPanel and cvPanel:hswindow() then
        if cvTimer then cvTimer:stop(); cvTimer = nil end
        cvPanel:delete()
        cvPanel = nil
        cvCompact = false
        cvLastFullFrame = nil
        return
    end
    cvCompact = false
    cvLastFullFrame = nil
    cvPanel = hs.webview.new(cvFullFrame(), {}, cvBridge)
        :windowStyle({ "titled", "closable", "resizable", "utility", "fullSizeContentView" })
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
        if not (cvPanel and cvPanel:hswindow()) then
            if cvTimer then cvTimer:stop(); cvTimer = nil end
            return
        end
        tick = tick + 1
        if tick % 5 == 0 then
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
