-- claude-voice / Hammerspoon floating control panel
--
-- Cmd+Ctrl+G toggles a glassy floating panel with:
--   * on/off toggle, stop button
--   * speed / volume sliders, voice picker
--   * play/pause + seek bar for the current message (drag the ball to jump
--     back to any point of the speech)
--   * clickable history of past spoken messages (click any to read the
--     full text in a scrollable popup, with a Replay button)
--   * five most recent agent-to-agent messages (agent1 → agent2); click to
--     read the whole message in the same scrollable popup
--   * "Make smaller" shrinks the panel to a compact card on the right edge
--
-- Requires claude-voice >= 0.2 with the history/replay/seek/playpause
-- commands (this repo). The panel shells out to the CLI for everything.
--
-- Install
-- -------
-- 1. Install Hammerspoon: `brew install --cask hammerspoon`, then grant it
--    Accessibility permissions in System Settings -> Privacy & Security.
-- 2. Paste this file into ~/.hammerspoon/init.lua (or `require` it).
-- 3. Edit CLAUDE_VOICE_BIN below to point at your install.
-- 4. Open Hammerspoon and click "Reload Config" (menu bar icon).

local CLAUDE_VOICE_BIN = os.getenv("HOME") .. "/.local/bin/claude-voice"
local CV_CONFIG  = os.getenv("HOME") .. "/.config/claude-voice/config.json"
local CV_HISTORY = os.getenv("HOME") .. "/.cache/claude-voice/history.jsonl"
local ORCH_MSGS  = os.getenv("HOME") .. "/.claude/orchestration/messages"
local KOKORO_VOICES = {
    "af_heart", "af_nova", "af_alloy", "af_sky",
    "am_adam", "am_fenrir", "am_michael", "am_onyx",
    "bm_george", "bm_daniel", "bf_emma", "bf_isabella",
}

local cvPanel = nil
local cvTimer = nil
local cvCompact = false
local cvLastFullFrame = nil
local FULL = { w = 360, h = 920 }
local MINI = { w = 300, h = 128 }

local function cvRun(args, andThen)
    local t = hs.task.new(CLAUDE_VOICE_BIN, function()
        if andThen then andThen() end
    end, args)
    t:start()
end

local function htmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
             :gsub('"', "&quot;"):gsub("'", "&#39;"))
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

local function cvSharedCss()
    return [[
      * { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { background: transparent; }
      button {
        background: rgba(255,255,255,0.07); color: rgba(235,238,250,0.85);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 999px;
        padding: 6px 16px; font-size: 12.5px; font-weight: 500; cursor: pointer;
        transition: background 0.15s, transform 0.1s;
      }
      button:hover { background: rgba(255,255,255,0.13); }
      button:active { transform: scale(0.96); }
      button:focus-visible {
        outline: 2px solid rgba(138,182,255,0.85); outline-offset: 2px;
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
      .val { text-align: right; font-size: 12px; font-weight: 600;
             color: #8ab6ff; font-variant-numeric: tabular-nums; }
    ]]
end

local function cvPlayScript()
    return [[
      <script>
        function send(m) { webkit.messageHandlers.cv.postMessage(m); }
        let drag = false;
        let openIndex = null;
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
          body.textContent = full ? full.textContent : '';
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
        document.addEventListener('keydown', function(e) {
          if (e.key === 'Escape') closeMsg();
        });
        function fmt(s) {
          s = Math.max(0, Math.floor(s));
          return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
        }
        function updPlay(pos, dur, playing) {
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
    ]]
end

local function cvBuildHtml()
    local cfg = hs.json.read(CV_CONFIG) or {}
    local enabled  = cfg.enabled ~= false
    local speed    = cfg.speed or 1.0
    local volume   = math.floor((cfg.volume or 1.0) * 100 + 0.5)
    local provider = cfg.provider or "kokoro"
    local voice    = (cfg.voices or {})[provider] or ""
    local powerCls = enabled and "on" or "off"
    local powerLbl = enabled and "● On" or "○ Off"

    if cvCompact then
        return [[<!doctype html><html><head><meta charset="utf-8"><style>
      ]] .. cvSharedCss() .. [[
      body {
        font: 13px/1.3 -apple-system, "SF Pro Text", sans-serif;
        color: rgba(235,238,250,0.92);
        padding: 36px 10px 10px;
        user-select: none;
        background:
          radial-gradient(120% 90% at 15% 0%, rgba(122,162,255,0.18), transparent 55%),
          radial-gradient(120% 90% at 95% 100%, rgba(180,140,255,0.14), transparent 55%),
          rgba(17,18,28,0.72);
        height: 100vh;
        overflow: hidden;
      }
      .mini {
        display: flex; align-items: center; gap: 6px;
        height: calc(100% - 0px);
      }
      .mini button { padding: 5px 10px; font-size: 12px; white-space: nowrap; }
      .mini #pp { padding: 5px 11px; }
      .mini .val { width: auto; min-width: 34px; font-size: 11px; }
      .grow { margin-left: auto; }
    </style></head><body>
      <div class="mini">
        <button id="power" class="]] .. powerCls .. [["
          onclick="send({action:'power'})">]] .. powerLbl .. [[</button>
        <button onclick="send({action:'stop'})" title="Stop speaking">◼</button>
        <button id="pp" onclick="this.textContent=this.textContent==='⏸'?'▶':'⏸';send({action:'playpause'})">▶</button>
        <span class="val" id="pt" data-short="1">–:––</span>
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
        local snippet = htmlEscape((e.text or ""):gsub("\n", " "))
        if #snippet > 120 then snippet = snippet:sub(1, 120) .. "…" end
        -- Concatenate (don't string.format) so a "%" in the spoken text
        -- cannot break Lua format specifiers.
        table.insert(histRows,
            '<div class="msg" data-index="' .. i .. '" onclick="openMsg(this)">' ..
            '<span class="t">' .. when .. '</span>' .. snippet ..
            '<div class="full">' .. htmlEscape(e.text or "") .. '</div></div>')
    end
    if #histRows == 0 then
        histRows = { '<div class="empty">no spoken messages yet</div>' }
    end

    local orchRows = {}
    for _, e in ipairs(cvReadOrchMessages(5)) do
        local when = (e.date or ""):match("(%d%d:%d%d)") or ""
        local route = (e.from or "?") .. " → " .. (e.to or "?")
        local meta = e.date or ""
        if e.re ~= "" then
            meta = (meta ~= "" and (meta .. "  ·  " .. e.re)) or e.re
        end
        table.insert(orchRows,
            '<div class="msg" tabindex="0" role="button"' ..
            ' data-route="' .. htmlEscape(route) ..
            '" data-meta="' .. htmlEscape(meta) ..
            '" onclick="openMsg(this)"' ..
            ' onkeydown="if(event.key===\'Enter\'||event.key===\' \'){event.preventDefault();openMsg(this)}">' ..
            '<span class="t">' .. htmlEscape(when) .. '</span>' ..
            '<span class="route">' .. htmlEscape(e.from or "?") ..
            '<span class="sep"> → </span>' .. htmlEscape(e.to or "?") .. '</span>' ..
            '<div class="full">' .. htmlEscape(e.body or "") .. '</div></div>')
    end
    if #orchRows == 0 then
        orchRows = { '<div class="empty">no agent messages yet</div>' }
    end

    return [[<!doctype html><html><head><meta charset="utf-8"><style>
      ]] .. cvSharedCss() .. [[
      body {
        font: 13px/1.4 -apple-system, "SF Pro Text", sans-serif;
        color: rgba(235,238,250,0.92);
        padding: 40px 14px 22px;
        user-select: none;
        background:
          radial-gradient(120% 90% at 15% 0%, rgba(122,162,255,0.16), transparent 55%),
          radial-gradient(120% 90% at 95% 100%, rgba(180,140,255,0.13), transparent 55%),
          rgba(17,18,28,0.55);
        height: 100vh;
        overflow: hidden;
        display: flex;
        flex-direction: column;
      }
      .grow { flex: 1; display: flex; flex-direction: column;
              min-height: 0; margin-bottom: 0; overflow-y: auto; }
      .card {
        background: rgba(255,255,255,0.055);
        border: 1px solid rgba(255,255,255,0.10);
        border-top-color: rgba(255,255,255,0.16);
        border-radius: 16px;
        padding: 12px 14px;
        margin-bottom: 12px;
        backdrop-filter: blur(24px) saturate(1.5);
        -webkit-backdrop-filter: blur(24px) saturate(1.5);
        box-shadow: 0 8px 24px rgba(0,0,0,0.25);
      }
      .row { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
      .row:last-child { margin-bottom: 2px; }
      .row label { width: 50px; font-size: 11px; font-weight: 500;
                   color: rgba(235,238,250,0.45); text-transform: uppercase;
                   letter-spacing: 0.8px; }
      .val { width: 46px; }
      input[type=range] {
        -webkit-appearance: none; flex: 1; height: 4px; border-radius: 3px;
        background: linear-gradient(90deg, rgba(138,182,255,0.55), rgba(201,162,255,0.55));
        outline: none;
      }
      input[type=range]::-webkit-slider-thumb {
        -webkit-appearance: none; width: 17px; height: 17px; border-radius: 50%;
        background: linear-gradient(135deg, #a9c7ff, #d4b8ff);
        border: 1px solid rgba(255,255,255,0.5);
        box-shadow: 0 2px 8px rgba(122,162,255,0.45);
        cursor: pointer;
      }
      select {
        flex: 1; -webkit-appearance: none; appearance: none;
        background: rgba(255,255,255,0.07); color: rgba(235,238,250,0.9);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 10px;
        padding: 6px 10px; font-size: 12.5px; cursor: pointer; outline: none;
      }
      h2 { font-size: 10.5px; font-weight: 600; color: rgba(235,238,250,0.4);
           text-transform: uppercase; letter-spacing: 1.2px; margin: 2px 2px 8px; }
      h2.sub { margin-top: 14px; }
      .hist { flex: 1; min-height: 140px; overflow-y: auto; margin: 0 -4px; padding: 0 4px; }
      .hist::-webkit-scrollbar, .orch::-webkit-scrollbar { width: 5px; }
      .hist::-webkit-scrollbar-thumb, .orch::-webkit-scrollbar-thumb {
        background: rgba(255,255,255,0.15); border-radius: 3px; }
      .orch { flex: 0 0 auto; margin: 0 -4px; padding: 0 4px 8px; }
      .orch .msg { padding: 6px 10px; margin-bottom: 4px; font-size: 12px; }
      .msg .route { font-weight: 600; overflow-wrap: anywhere; }
      .msg .sep { color: #8ab6ff; font-weight: 500; }
      .msg {
        padding: 8px 11px; border-radius: 12px; margin-bottom: 6px;
        background: rgba(255,255,255,0.045);
        border: 1px solid rgba(255,255,255,0.07);
        cursor: pointer; line-height: 1.4; font-size: 12.5px;
        color: rgba(235,238,250,0.78);
        transition: background 0.15s, border-color 0.15s, transform 0.1s;
      }
      .msg:hover {
        background: rgba(138,182,255,0.10);
        border-color: rgba(138,182,255,0.30);
        transform: translateX(2px);
      }
      .msg:active { transform: scale(0.985); }
      .msg:focus-visible {
        outline: 2px solid rgba(138,182,255,0.85); outline-offset: 1px;
      }
      .msg .t { color: rgba(138,182,255,0.65); font-size: 10.5px; font-weight: 600;
                margin-right: 8px; font-variant-numeric: tabular-nums; }
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
        color: rgba(180,196,230,0.78);
        font-size: 11px; font-weight: 600;
        font-variant-numeric: tabular-nums;
        overflow-wrap: anywhere;
      }
      .reader-body {
        flex: 1; min-height: 0; overflow-y: auto;
        padding: 14px 16px 18px;
        font-size: 16px; line-height: 1.6;
        white-space: pre-wrap; overflow-wrap: anywhere;
        user-select: text; -webkit-user-select: text;
        color: rgba(235,238,250,0.94);
      }
      .reader-body:focus { outline: none; }
      .reader-body::-webkit-scrollbar { width: 6px; }
      .reader-body::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18);
                                              border-radius: 3px; }
    </style></head><body>
      <div class="card">
        <div class="row" style="margin-bottom:2px">
          <button id="power" class="]] .. powerCls .. [["
            onclick="send({action:'power'})">]] .. powerLbl .. [[</button>
          <button onclick="send({action:'stop'})">◼ Stop</button>
          <button onclick="send({action:'shrink'})" style="margin-left:auto"
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
          <span class="val" id="pt" style="width:82px">–:–– / –:––</span></div>
      </div>
      <div class="card grow">
        <h2>History — click to read</h2>
        <div class="hist">]] .. table.concat(histRows) .. [[</div>
        <h2 class="sub">Messages — click to read</h2>
        <div class="orch">]] .. table.concat(orchRows) .. [[</div>
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
    if cvPanel then cvPanel:html(cvBuildHtml()) end
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
    end
end)

-- Auto-refresh the open panel when spoken history or an agent message changes.
local cvRefreshPending = nil
local function cvScheduleRefresh()
    if cvRefreshPending then cvRefreshPending:stop() end
    cvRefreshPending = hs.timer.doAfter(0.5, function()
        cvRefreshPending = nil
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

    -- Poll playback position so the seek ball tracks the speech.
    if cvTimer then cvTimer:stop() end
    cvTimer = hs.timer.doEvery(1.0, function()
        if not (cvPanel and cvPanel:hswindow()) then
            if cvTimer then cvTimer:stop(); cvTimer = nil end
            return
        end
        hs.task.new(CLAUDE_VOICE_BIN, function(_, stdout)
            local ok, info = pcall(hs.json.decode, stdout or "")
            if ok and info and cvPanel then
                cvPanel:evaluateJavaScript(string.format("updPlay(%.2f,%.2f,%s)",
                    tonumber(info.pos) or 0, tonumber(info.duration) or 0,
                    info.playing and "true" or "false"))
            end
        end, { "playinfo" }):start()
    end)
end)
