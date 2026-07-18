-- claude-voice / Hammerspoon floating control panel
--
-- Cmd+Ctrl+G toggles a glassy floating panel with:
--   * on/off toggle, stop button
--   * speed / volume sliders, voice picker
--   * play/pause + seek bar for the current message (drag the ball to jump
--     back to any point of the speech)
--   * clickable history of past spoken messages (click any to replay)
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
local KOKORO_VOICES = {
    "af_heart", "af_nova", "af_alloy", "af_sky",
    "am_adam", "am_fenrir", "am_michael", "am_onyx",
    "bm_george", "bm_daniel", "bf_emma", "bf_isabella",
}

local cvPanel = nil
local cvTimer = nil

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

local function cvBuildHtml()
    local cfg = hs.json.read(CV_CONFIG) or {}
    local enabled  = cfg.enabled ~= false
    local speed    = cfg.speed or 1.0
    local volume   = math.floor((cfg.volume or 1.0) * 100 + 0.5)
    local provider = cfg.provider or "kokoro"
    local voice    = (cfg.voices or {})[provider] or ""

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
        table.insert(histRows, string.format(
            '<div class="msg" onclick="send({action:\'replay\',index:\'%d\'})">' ..
            '<span class="t">%s</span>%s</div>', i, when, snippet))
    end
    if #histRows == 0 then
        histRows = { '<div class="empty">no spoken messages yet</div>' }
    end

    return [[<!doctype html><html><head><meta charset="utf-8"><style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      html, body { background: transparent; }
      body {
        font: 13px/1.4 -apple-system, "SF Pro Text", sans-serif;
        color: rgba(235,238,250,0.92);
        padding: 40px 14px 14px;
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
              min-height: 0; margin-bottom: 0; }
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
      .val { width: 46px; text-align: right; font-size: 12px; font-weight: 600;
             color: #8ab6ff; font-variant-numeric: tabular-nums; }
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
      button {
        background: rgba(255,255,255,0.07); color: rgba(235,238,250,0.85);
        border: 1px solid rgba(255,255,255,0.12); border-radius: 999px;
        padding: 6px 16px; font-size: 12.5px; font-weight: 500; cursor: pointer;
        transition: background 0.15s, transform 0.1s;
      }
      button:hover { background: rgba(255,255,255,0.13); }
      button:active { transform: scale(0.96); }
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
      h2 { font-size: 10.5px; font-weight: 600; color: rgba(235,238,250,0.4);
           text-transform: uppercase; letter-spacing: 1.2px; margin: 2px 2px 8px; }
      .hist { flex: 1; min-height: 0; overflow-y: auto; margin: 0 -4px; padding: 0 4px; }
      .hist::-webkit-scrollbar { width: 5px; }
      .hist::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15);
                                       border-radius: 3px; }
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
      .msg .t { color: rgba(138,182,255,0.65); font-size: 10.5px; font-weight: 600;
                margin-right: 8px; font-variant-numeric: tabular-nums; }
      .empty { color: rgba(235,238,250,0.3); padding: 10px; font-size: 12px; }
    </style></head><body>
      <div class="card">
        <div class="row" style="margin-bottom:2px">
          <button id="power" class="]] .. (enabled and "on" or "off") .. [["
            onclick="send({action:'power'})">]] .. (enabled and "● On" or "○ Off") .. [[</button>
          <button onclick="send({action:'stop'})">◼ Stop</button>
          <button onclick="send({action:'refresh'})" style="margin-left:auto">↻</button>
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
        <h2>History — click to replay</h2>
        <div class="hist">]] .. table.concat(histRows) .. [[</div>
      </div>
      <script>
        function send(m) { webkit.messageHandlers.cv.postMessage(m); }
        let drag = false;
        function fmt(s) {
          s = Math.max(0, Math.floor(s));
          return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
        }
        function updPlay(pos, dur, playing) {
          if (dur <= 0) return;
          const sk = document.getElementById('seek');
          if (!drag) { sk.max = dur; sk.value = pos; }
          document.getElementById('pt').textContent =
            fmt(drag ? sk.value : pos) + ' / ' + fmt(dur);
          document.getElementById('pp').textContent = playing ? '⏸' : '▶';
        }
      </script>
    </body></html>]]
end

local function cvRefresh()
    if cvPanel then cvPanel:html(cvBuildHtml()) end
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
    end
end)

-- Auto-refresh the open panel when a new message lands in the history file.
local cvRefreshPending = nil
local cvWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.cache/claude-voice/",
    function(files)
        for _, f in ipairs(files) do
            if f:find("history%.jsonl$") then
                if cvRefreshPending then cvRefreshPending:stop() end
                cvRefreshPending = hs.timer.doAfter(0.5, function()
                    cvRefreshPending = nil
                    if cvPanel and cvPanel:hswindow() then cvRefresh() end
                end)
                return
            end
        end
    end):start()

hs.hotkey.bind({ "cmd", "ctrl" }, "g", function()
    if cvPanel and cvPanel:hswindow() then
        if cvTimer then cvTimer:stop(); cvTimer = nil end
        cvPanel:delete()
        cvPanel = nil
        return
    end
    local sf = hs.screen.mainScreen():frame()
    cvPanel = hs.webview.new(
        { x = sf.x + sf.w - 380, y = sf.y + 40, w = 360, h = 560 },
        {}, cvBridge)
        :windowStyle({ "titled", "closable", "utility", "fullSizeContentView" })
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
