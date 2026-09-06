using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WifiSetupService;

public enum KioskWifiState
{
    Idle,
    CheckingConnection,
    NeedsNetwork,
    Connecting,
    Connected,
    Failed
}

/// <summary>
/// Always-on local HTTP server bound to the loopback address only, so it is
/// reachable exclusively from processes on this machine (the kiosk browser),
/// never from the network. Chromium exempts loopback fetches from
/// mixed-content blocking, so this is reachable both from a page loaded via
/// file:// and from the real https://skriin.com/ page once the kiosk is
/// online — no Edge policy changes needed either way.
///
/// Endpoints:
///   GET  /         -> launcher page: on first load the customer picks
///                      "Scan QR Code" (reads their phone's own WiFi-share
///                      QR client-side, no server help needed beyond
///                      /jsqr.js) or "Choose a Network" (on-screen list +
///                      virtual keyboard). Both are dead ends on their own
///                      screen - no fallback link between them - and both
///                      end up POSTing to /connect the same way. Redirects
///                      to the real Skriin site once connected. This is
///                      meant to be the kiosk's actual Edge --kiosk launch
///                      URL, so something always loads even with zero
///                      connectivity.
///   GET  /status   -> { state, ssid, message, timestamp }
///   GET  /networks -> current WiFi scan results, as a JSON array of SSIDs
///   GET  /jsqr.js  -> vendored jsQR library (see JsQrLibrary.cs), served
///                      locally since the QR-scan screen has to work with
///                      zero internet access
///   POST /connect  -> { ssid, password } - requests the orchestrator join
///                      that network, from either path above
///   POST /retry    -> requests the orchestrator show the picker again
///                      (e.g. after a Failed state)
///
/// There's no phone-hosted hotspot, no captive portal: everything the
/// customer needs to get online happens on this screen, driven by whatever
/// they can point and click with (see LauncherHtml for the remote/gamepad
/// navigation and the QR-scan implementation).
/// </summary>
public class KioskStatusServer : IDisposable
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    private readonly HttpListener _listener = new();
    private readonly ILogger _logger;
    private readonly WifiHelper _wifi;
    private readonly string _redirectUrl;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;

    private readonly object _lock = new();
    private KioskWifiState _state = KioskWifiState.Idle;
    private string? _ssid;
    private string? _message;

    public event Action? RetryRequested;
    public event Action<string, string>? ConnectRequested;

    public KioskStatusServer(ILogger logger, WifiHelper wifi, string redirectUrl = "https://skriin.com/", int port = 5757)
    {
        _logger = logger;
        _wifi = wifi;
        _redirectUrl = redirectUrl;
        _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
    }

    public void Start()
    {
        _listener.Start();
        _cts = new CancellationTokenSource();
        _listenTask = Task.Run(() => ListenLoop(_cts.Token));
        _logger.LogInformation("Kiosk status server listening on {Prefix}", string.Join(",", _listener.Prefixes));
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener.Stop(); } catch { /* already stopped */ }
        _listenTask?.Wait(TimeSpan.FromSeconds(3));
    }

    public void SetState(KioskWifiState state, string? ssid = null, string? message = null)
    {
        lock (_lock)
        {
            _state = state;
            _ssid = ssid;
            _message = message;
        }
    }

    private async Task ListenLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch { break; }
            _ = Task.Run(() => HandleRequest(ctx), ct);
        }
    }

    private void HandleRequest(HttpListenerContext ctx)
    {
        try
        {
            // CORS: the launcher page itself is same-origin (served from this
            // server), but the real https://skriin.com/ page also calls
            // /status and /retry directly for the in-app "WiFi settings"
            // affordance, so allow any origin to read these responses.
            ctx.Response.Headers.Add("Access-Control-Allow-Origin", "*");
            ctx.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            ctx.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type");

            var path = ctx.Request.Url?.AbsolutePath ?? "/";

            if (ctx.Request.HttpMethod == "OPTIONS")
            {
                ctx.Response.StatusCode = 204;
                ctx.Response.Close();
                return;
            }

            if ((path == "/" || path == "/index.html") && ctx.Request.HttpMethod == "GET")
            {
                Respond(ctx.Response, LauncherHtml(), "text/html; charset=utf-8");
                return;
            }

            if (path == "/status" && ctx.Request.HttpMethod == "GET")
            {
                KioskWifiState state; string? ssid; string? message;
                lock (_lock) { state = _state; ssid = _ssid; message = _message; }

                var json = JsonSerializer.Serialize(new
                {
                    state = state.ToString(),
                    ssid,
                    message,
                    timestamp = DateTime.UtcNow
                });
                Respond(ctx.Response, json, "application/json");
                return;
            }

            if (path == "/networks" && ctx.Request.HttpMethod == "GET")
            {
                // Blocks for ~2.5s (netsh scan settle time) - fine, this
                // request is handled on its own Task, not the listen loop.
                List<string> networks;
                try { networks = _wifi.ScanNetworks(); }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Network scan failed");
                    networks = new List<string>();
                }
                Respond(ctx.Response, JsonSerializer.Serialize(networks), "application/json");
                return;
            }

            if (path == "/jsqr.js" && ctx.Request.HttpMethod == "GET")
            {
                // Vendored, not CDN-loaded - this page has to work with zero
                // internet, which is exactly the problem it's solving.
                Respond(ctx.Response, JsQrLibrary.Source, "text/javascript; charset=utf-8");
                return;
            }

            if (path == "/connect" && ctx.Request.HttpMethod == "POST")
            {
                string body;
                using (var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding))
                    body = reader.ReadToEnd();

                ConnectRequest? payload;
                try { payload = JsonSerializer.Deserialize<ConnectRequest>(body, JsonOpts); }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Bad /connect payload");
                    ctx.Response.StatusCode = 400;
                    ctx.Response.Close();
                    return;
                }

                if (payload is null || string.IsNullOrWhiteSpace(payload.Ssid))
                {
                    ctx.Response.StatusCode = 400;
                    ctx.Response.Close();
                    return;
                }

                _logger.LogInformation("Connect requested for {Ssid}", payload.Ssid);
                ConnectRequested?.Invoke(payload.Ssid, payload.Password ?? "");
                Respond(ctx.Response, """{"status":"connect-queued"}""", "application/json");
                return;
            }

            if (path == "/retry" && ctx.Request.HttpMethod == "POST")
            {
                RetryRequested?.Invoke();
                Respond(ctx.Response, """{"status":"retry-queued"}""", "application/json");
                return;
            }

            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "KioskStatusServer error handling request");
        }
    }

    private static void Respond(HttpListenerResponse res, string body, string contentType)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        res.ContentType = contentType;
        res.ContentLength64 = bytes.Length;
        res.OutputStream.Write(bytes);
        res.Close();
    }

    private record ConnectRequest(string Ssid, string? Password);

    /// <summary>
    /// The page Edge's --kiosk flag should point at instead of the remote
    /// site directly. It loads unconditionally (it's served locally, so it
    /// works with zero network), shows an on-screen network picker and
    /// virtual keyboard fully navigable with a D-pad/game controller or a
    /// keyboard, and redirects to the real Skriin site once /status reports
    /// Connected.
    /// </summary>
    private string LauncherHtml() => $$"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Skriin</title>
          <script src="/jsqr.js"></script>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body {
              width: 100%; height: 100%; overflow: hidden;
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
              background: #0f0f0f; color: #fff;
            }
            .screen {
              display: none; height: 100vh; width: 100vw;
              flex-direction: column; align-items: center; justify-content: center;
              padding: 48px; text-align: center;
            }
            .screen.active { display: flex; }
            h1 { font-size: 44px; font-weight: 700; margin-bottom: 8px; }
            h1 span { color: #0a84ff; }
            .subtitle { font-size: 20px; color: #8e8e93; margin-bottom: 36px; }

            /* -- Network list -- */
            .net-list {
              width: 640px; max-height: 60vh; overflow-y: auto;
              display: flex; flex-direction: column; gap: 12px;
            }
            .net-item, .kb-key, .action-btn {
              font-family: inherit; font-size: 22px; color: #fff;
              background: #1c1c1e; border: 2px solid #2c2c2e; border-radius: 14px;
              padding: 18px 24px; cursor: pointer; text-align: left;
              display: flex; align-items: center; justify-content: space-between;
              outline: none;
            }
            .net-item.focused, .kb-key.focused, .action-btn.focused {
              border-color: #0a84ff; background: #0a2540; box-shadow: 0 0 0 3px #0a84ff44;
            }
            .net-item .signal { color: #8e8e93; font-size: 16px; }
            .empty-note { color: #8e8e93; font-size: 18px; margin-bottom: 20px; }

            /* -- Password entry / keyboard -- */
            .pw-field {
              width: 640px; font-size: 26px; font-family: 'SF Mono','Fira Code',monospace;
              background: #1c1c1e; border: 2px solid #3a3a3c; border-radius: 12px;
              padding: 16px 20px; margin-bottom: 28px; min-height: 32px; letter-spacing: 1px;
              word-break: break-all;
            }
            .pw-label { font-size: 16px; color: #8e8e93; margin-bottom: 6px; align-self: flex-start;
              margin-left: calc(50vw - 320px); }
            .kb-row { display: flex; gap: 8px; margin-bottom: 8px; justify-content: center; }
            .kb-key { min-width: 52px; justify-content: center; padding: 14px 10px; font-size: 20px; }
            .kb-key.wide { min-width: 96px; }
            .kb-key.space { min-width: 260px; }
            .kb-key.connect { background: #0a84ff; border-color: #0a84ff; }
            .kb-key.connect.focused { background: #3ba0ff; border-color: #fff; }
            .bottom-actions { display: flex; gap: 16px; margin-top: 28px; }
            .action-btn { justify-content: center; }

            /* -- Connecting / connected / failed -- */
            .spinner {
              width: 64px; height: 64px; border-radius: 50%;
              border: 6px solid #2c2c2e; border-top-color: #0a84ff;
              animation: spin 1s linear infinite; margin-bottom: 28px;
            }
            @keyframes spin { to { transform: rotate(360deg); } }
            .checkmark {
              width: 100px; height: 100px; border-radius: 50%; background: #30d158;
              display: flex; align-items: center; justify-content: center; font-size: 56px;
              margin-bottom: 24px;
            }
            .error-icon {
              width: 100px; height: 100px; border-radius: 50%; background: #ff453a;
              display: flex; align-items: center; justify-content: center; font-size: 48px;
              margin-bottom: 24px;
            }
            /* -- Initial choice screen -- */
            .choice-grid { display: flex; gap: 24px; margin-top: 8px; }
            .choice-btn {
              width: 280px; padding: 40px 24px; border-radius: 20px;
              background: #1c1c1e; border: 2px solid #2c2c2e; color: #fff;
              font-family: inherit; cursor: pointer; outline: none;
              display: flex; flex-direction: column; align-items: center; gap: 12px;
            }
            .choice-btn.focused {
              border-color: #0a84ff; background: #0a2540; box-shadow: 0 0 0 3px #0a84ff44;
            }
            .choice-btn .choice-title { font-size: 22px; font-weight: 700; }
            .choice-btn .choice-desc { font-size: 15px; color: #8e8e93; }

            /* -- QR scan screen -- */
            .qr-video-box {
              width: 420px; height: 420px; border-radius: 20px; overflow: hidden;
              background: #000; border: 2px solid #2c2c2e; margin-bottom: 24px;
            }
            .qr-video-box video { width: 100%; height: 100%; object-fit: cover; }
            .qr-status { font-size: 18px; color: #8e8e93; margin-bottom: 8px; min-height: 24px; }

            .hint { position: fixed; bottom: 24px; left: 0; right: 0; text-align: center;
              font-size: 15px; color: #636366; }
          </style>
        </head>
        <body>

        <!-- Initial choice screen -->
        <div class="screen" id="screen-choice">
          <h1>Connect to <span>WiFi</span></h1>
          <div class="subtitle">How would you like to connect?</div>
          <div class="choice-grid">
            <button class="choice-btn" data-focusable data-action="choose-scan">
              <div class="choice-title">Scan QR Code</div>
              <div class="choice-desc">Use your phone's WiFi share QR code</div>
            </button>
            <button class="choice-btn" data-focusable data-action="choose-manual">
              <div class="choice-title">Choose a Network</div>
              <div class="choice-desc">Pick from nearby networks and type the password</div>
            </button>
          </div>
        </div>

        <!-- Network list screen -->
        <div class="screen" id="screen-networks">
          <h1>Connect to <span>WiFi</span></h1>
          <div class="subtitle">Pick a network to get your Skriin device online.</div>
          <div class="net-list" id="netList"></div>
          <div class="bottom-actions">
            <button class="action-btn" data-focusable data-action="back-to-choice">Back</button>
          </div>
        </div>

        <!-- Password entry screen -->
        <div class="screen" id="screen-password">
          <h1 id="pwHeading">Enter Password</h1>
          <div class="pw-label">Password for <span id="pwSsid" style="color:#30d158"></span></div>
          <div class="pw-field" id="pwField">&nbsp;</div>
          <div id="kbContainer"></div>
          <div class="bottom-actions">
            <button class="action-btn" data-focusable data-action="back">Back</button>
            <button class="action-btn connect" data-focusable data-action="connect">Connect</button>
          </div>
        </div>

        <!-- QR scan screen -->
        <div class="screen" id="screen-qrscan">
          <h1>Scan QR Code</h1>
          <div class="subtitle">Hold your phone's WiFi share QR code up to the camera.</div>
          <div class="qr-video-box"><video id="qrVideo" autoplay playsinline muted></video></div>
          <div class="qr-status" id="qrStatus">Starting camera...</div>
          <div class="bottom-actions">
            <button class="action-btn" data-focusable data-action="qr-back">Back</button>
          </div>
        </div>

        <!-- Connecting screen -->
        <div class="screen" id="screen-connecting">
          <div class="spinner"></div>
          <h1 id="connectingHeading">Connecting…</h1>
          <div class="subtitle" id="connectingSub">This can take a few seconds.</div>
        </div>

        <!-- Connected screen -->
        <div class="screen" id="screen-connected">
          <div class="checkmark">✓</div>
          <h1>Connected!</h1>
          <div class="subtitle">Loading Skriin…</div>
        </div>

        <!-- Failed screen -->
        <div class="screen" id="screen-failed">
          <div class="error-icon">!</div>
          <h1>Couldn't Connect</h1>
          <div class="subtitle" id="failedMessage">Please try again.</div>
          <div class="bottom-actions">
            <button class="action-btn" data-focusable data-action="retry-back">Choose a Different Network</button>
          </div>
        </div>

        <div class="hint">Use arrow keys or your remote's D-pad to move · Enter / A to select · B to go back</div>

        <script>
          const REDIRECT_URL = {{JsonSerializer.Serialize(_redirectUrl)}};

          // ---------- Screen management ----------
          const screens = ['choice', 'networks', 'password', 'qrscan', 'connecting', 'connected', 'failed'];
          let currentScreen = null;
          let focused = null;

          function showScreen(name) {
            currentScreen = name;
            for (const s of screens) {
              document.getElementById('screen-' + s).classList.toggle('active', s === name);
            }
            focused = null;
            focusFirst();
          }

          function activeContainer() {
            return document.getElementById('screen-' + currentScreen);
          }

          function getFocusables() {
            const c = activeContainer();
            return c ? Array.from(c.querySelectorAll('[data-focusable]')) : [];
          }

          function setFocus(el) {
            if (focused) focused.classList.remove('focused');
            focused = el;
            if (focused) { focused.classList.add('focused'); focused.focus({ preventScroll: false }); focused.scrollIntoView({ block: 'nearest' }); }
          }

          function focusFirst() {
            const items = getFocusables();
            setFocus(items[0] || null);
          }

          function moveFocus(direction) {
            const items = getFocusables().filter(el => el !== focused);
            if (!focused) { focusFirst(); return; }
            const rect = focused.getBoundingClientRect();
            const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2;
            let best = null, bestScore = Infinity;
            for (const el of items) {
              const r = el.getBoundingClientRect();
              const ex = r.left + r.width / 2, ey = r.top + r.height / 2;
              const dx = ex - cx, dy = ey - cy;
              let primary, secondary;
              if (direction === 'up') { if (dy >= -4) continue; primary = -dy; secondary = Math.abs(dx); }
              else if (direction === 'down') { if (dy <= 4) continue; primary = dy; secondary = Math.abs(dx); }
              else if (direction === 'left') { if (dx >= -4) continue; primary = -dx; secondary = Math.abs(dy); }
              else if (direction === 'right') { if (dx <= 4) continue; primary = dx; secondary = Math.abs(dy); }
              else continue;
              const score = primary * 2.5 + secondary;
              if (score < bestScore) { bestScore = score; best = el; }
            }
            if (best) setFocus(best);
          }

          function activateFocused() {
            if (focused) focused.click();
          }

          function goBack() {
            if (currentScreen === 'password') { showScreen('networks'); }
            else if (currentScreen === 'networks') { showScreen('choice'); }
            else if (currentScreen === 'qrscan') { stopQrScan(); showScreen('choice'); }
            else if (currentScreen === 'failed') { retryAndShowChoice(); }
          }

          // ---------- Keyboard input (arrow keys + Enter, for a USB/BT remote acting as a keyboard) ----------
          document.addEventListener('keydown', (e) => {
            switch (e.key) {
              case 'ArrowUp': e.preventDefault(); moveFocus('up'); break;
              case 'ArrowDown': e.preventDefault(); moveFocus('down'); break;
              case 'ArrowLeft': e.preventDefault(); moveFocus('left'); break;
              case 'ArrowRight': e.preventDefault(); moveFocus('right'); break;
              case 'Enter': e.preventDefault(); activateFocused(); break;
              case 'Backspace': case 'Escape': e.preventDefault(); goBack(); break;
            }
          });

          // ---------- Gamepad input ----------
          let gpPrevPressed = {};
          function pollGamepad() {
            const pads = navigator.getGamepads ? navigator.getGamepads() : [];
            for (const pad of pads) {
              if (!pad) continue;
              const prev = gpPrevPressed[pad.index] || [];
              pad.buttons.forEach((b, i) => {
                if (b.pressed && !prev[i]) onGamepadButton(i);
              });
              gpPrevPressed[pad.index] = pad.buttons.map(b => b.pressed);

              // Left stick as a D-pad fallback, with simple debounce via the same edge logic
              const axisState = gpPrevPressed[pad.index + '_axes'] || {};
              const lx = pad.axes[0] || 0, ly = pad.axes[1] || 0;
              const now = { up: ly < -0.6, down: ly > 0.6, left: lx < -0.6, right: lx > 0.6 };
              for (const dir of ['up', 'down', 'left', 'right']) {
                if (now[dir] && !axisState[dir]) moveFocus(dir);
              }
              gpPrevPressed[pad.index + '_axes'] = now;
            }
            requestAnimationFrame(pollGamepad);
          }
          function onGamepadButton(i) {
            switch (i) {
              case 12: moveFocus('up'); break;
              case 13: moveFocus('down'); break;
              case 14: moveFocus('left'); break;
              case 15: moveFocus('right'); break;
              case 0: activateFocused(); break;   // A / bottom face button
              case 1: goBack(); break;              // B / right face button
            }
          }
          requestAnimationFrame(pollGamepad);

          // ---------- Networks screen ----------
          let chosenSsid = null;

          async function loadNetworks() {
            const list = document.getElementById('netList');
            list.innerHTML = '<div class="empty-note">Scanning for networks…</div>';
            try {
              const r = await fetch('/networks', { cache: 'no-store' });
              const names = await r.json();
              list.innerHTML = '';
              if (!names.length) {
                const note = document.createElement('div');
                note.className = 'empty-note';
                note.textContent = 'No networks found nearby.';
                list.appendChild(note);
              }
              for (const ssid of names) {
                const btn = document.createElement('button');
                btn.className = 'net-item';
                btn.setAttribute('data-focusable', '');
                btn.innerHTML = '<span></span><span class="signal">Wi‑Fi</span>';
                btn.querySelector('span').textContent = ssid;
                btn.onclick = () => selectNetwork(ssid);
                list.appendChild(btn);
              }
              const rescan = document.createElement('button');
              rescan.className = 'net-item';
              rescan.setAttribute('data-focusable', '');
              rescan.innerHTML = '<span>Rescan</span>';
              rescan.onclick = () => loadNetworks();
              list.appendChild(rescan);

              if (currentScreen === 'networks') focusFirst();
            } catch (e) {
              list.innerHTML = '<div class="empty-note">Couldn\'t scan for networks. Retrying…</div>';
              setTimeout(loadNetworks, 3000);
            }
          }

          function selectNetwork(ssid) {
            chosenSsid = ssid;
            document.getElementById('pwSsid').textContent = ssid;
            resetKeyboard();
            showScreen('password');
          }

          // ---------- Virtual keyboard ----------
          let pwValue = '';
          let kbShift = false;
          let kbSymbols = false;

          const LETTER_ROWS = [
            ['q','w','e','r','t','y','u','i','o','p'],
            ['a','s','d','f','g','h','j','k','l'],
            ['shift','z','x','c','v','b','n','m','back']
          ];
          const SYMBOL_ROWS = [
            ['1','2','3','4','5','6','7','8','9','0'],
            ['-','_','@','.',',','!','?',':','/'],
            ['(',')','+','=','*','#','%','&','back']
          ];

          function resetKeyboard() {
            pwValue = ''; kbShift = false; kbSymbols = false;
            renderKeyboard();
            updatePwField();
          }

          function renderKeyboard() {
            const container = document.getElementById('kbContainer');
            container.innerHTML = '';
            const rows = kbSymbols ? SYMBOL_ROWS : LETTER_ROWS;

            for (const row of rows) {
              const rowEl = document.createElement('div');
              rowEl.className = 'kb-row';
              for (const key of row) {
                const keyEl = document.createElement('button');
                keyEl.className = 'kb-key';
                keyEl.setAttribute('data-focusable', '');
                if (key === 'shift') {
                  keyEl.classList.add('wide');
                  keyEl.textContent = kbShift ? 'SHIFT' : 'shift';
                  keyEl.onclick = () => { kbShift = !kbShift; renderKeyboard(); };
                } else if (key === 'back') {
                  keyEl.classList.add('wide');
                  keyEl.textContent = '⌫';
                  keyEl.onclick = () => { pwValue = pwValue.slice(0, -1); updatePwField(); };
                } else {
                  const display = !kbSymbols && kbShift ? key.toUpperCase() : key;
                  keyEl.textContent = display;
                  keyEl.onclick = () => { pwValue += display; updatePwField(); };
                }
                rowEl.appendChild(keyEl);
              }
              container.appendChild(rowEl);
            }

            const modeRow = document.createElement('div');
            modeRow.className = 'kb-row';

            const modeToggle = document.createElement('button');
            modeToggle.className = 'kb-key wide';
            modeToggle.setAttribute('data-focusable', '');
            modeToggle.textContent = kbSymbols ? 'ABC' : '123';
            modeToggle.onclick = () => { kbSymbols = !kbSymbols; kbShift = false; renderKeyboard(); };
            modeRow.appendChild(modeToggle);

            const spaceKey = document.createElement('button');
            spaceKey.className = 'kb-key space';
            spaceKey.setAttribute('data-focusable', '');
            spaceKey.textContent = 'space';
            spaceKey.onclick = () => { pwValue += ' '; updatePwField(); };
            modeRow.appendChild(spaceKey);

            container.appendChild(modeRow);

            if (currentScreen === 'password') focusFirst();
          }

          function updatePwField() {
            document.getElementById('pwField').textContent = pwValue.length ? pwValue : ' ';
          }

          // ---------- Wiring up the static back/connect buttons ----------
          document.querySelector('[data-action="back"]').onclick = () => showScreen('networks');
          document.querySelector('[data-action="connect"]').onclick = () => connect();
          document.querySelector('[data-action="retry-back"]').onclick = () => retryAndShowChoice();
          document.querySelector('[data-action="choose-scan"]').onclick = () => startQrScan();
          document.querySelector('[data-action="choose-manual"]').onclick = () => { showScreen('networks'); loadNetworks(); };
          document.querySelector('[data-action="back-to-choice"]').onclick = () => showScreen('choice');
          document.querySelector('[data-action="qr-back"]').onclick = () => { stopQrScan(); showScreen('choice'); };

          async function connect() {
            showScreen('connecting');
            document.getElementById('connectingHeading').textContent = 'Connecting…';
            document.getElementById('connectingSub').textContent = 'Joining ' + chosenSsid + '…';
            try {
              await fetch('/connect', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ ssid: chosenSsid, password: pwValue })
              });
            } catch (e) { /* orchestrator will surface a Failed state if this doesn't take */ }
            pollUntilSettled();
          }

          async function pollUntilSettled() {
            for (;;) {
              await new Promise(r => setTimeout(r, 1500));
              try {
                const r = await fetch('/status', { cache: 'no-store' });
                if (!r.ok) continue;
                const data = await r.json();
                if (data.state === 'Connected') {
                  showScreen('connected');
                  setTimeout(() => { window.location.replace(REDIRECT_URL); }, 1200);
                  return;
                }
                if (data.state === 'Failed') {
                  document.getElementById('failedMessage').textContent =
                    data.message || 'Could not connect. Please try again.';
                  showScreen('failed');
                  return;
                }
                // still Connecting - keep polling
              } catch (e) { /* transient - keep polling */ }
            }
          }

          async function retryAndShowChoice() {
            try { await fetch('/retry', { method: 'POST' }); } catch (e) {}
            showScreen('choice');
          }

          // ---------- QR scan ----------
          let qrStream = null;
          let qrRafHandle = null;
          const qrCanvas = document.createElement('canvas');
          const qrCtx = qrCanvas.getContext('2d', { willReadFrequently: true });

          async function startQrScan() {
            showScreen('qrscan');
            document.getElementById('qrStatus').textContent = 'Starting camera...';
            try {
              qrStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
            } catch (e) {
              try { qrStream = await navigator.mediaDevices.getUserMedia({ video: true }); }
              catch (e2) {
                document.getElementById('qrStatus').textContent = "Couldn't access the camera.";
                return;
              }
            }
            const video = document.getElementById('qrVideo');
            video.srcObject = qrStream;
            try { await video.play(); } catch (e) { /* likely already playing */ }
            document.getElementById('qrStatus').textContent = "Point your phone's WiFi QR code at the camera.";
            qrScanLoop(video);
          }

          function stopQrScan() {
            if (qrRafHandle) cancelAnimationFrame(qrRafHandle);
            qrRafHandle = null;
            if (qrStream) {
              qrStream.getTracks().forEach(t => t.stop());
              qrStream = null;
            }
          }

          function qrScanLoop(video) {
            if (currentScreen !== 'qrscan') { stopQrScan(); return; }
            if (video.readyState === video.HAVE_ENOUGH_DATA && video.videoWidth > 0) {
              qrCanvas.width = video.videoWidth;
              qrCanvas.height = video.videoHeight;
              qrCtx.drawImage(video, 0, 0, qrCanvas.width, qrCanvas.height);
              const imageData = qrCtx.getImageData(0, 0, qrCanvas.width, qrCanvas.height);
              const code = jsQR(imageData.data, imageData.width, imageData.height, { inversionAttempts: 'dontInvert' });
              if (code && code.data) {
                const parsed = parseWifiQr(code.data);
                if (parsed) {
                  stopQrScan();
                  connectFromQr(parsed.ssid, parsed.password);
                  return;
                }
                document.getElementById('qrStatus').textContent = "That's not a WiFi QR code - try your phone's WiFi share QR.";
              }
            }
            qrRafHandle = requestAnimationFrame(() => qrScanLoop(video));
          }

          // Parses "WIFI:S:name;T:WPA;P:pass;H:false;;" per the standard
          // WiFi QR spec, correctly handling backslash-escaped ';', ':',
          // ',' and '\' inside field values - a naive split(';') would
          // break on a password containing a semicolon or colon.
          function parseWifiQr(text) {
            if (!text || !text.toUpperCase().startsWith('WIFI:')) return null;
            const body = text.slice(text.indexOf(':') + 1);
            const fields = {};
            let key = null, current = '';
            for (let i = 0; i < body.length; i++) {
              const ch = body[i];
              if (ch === '\\' && i + 1 < body.length) { current += body[++i]; continue; }
              if (ch === ':' && key === null) { key = current; current = ''; continue; }
              if (ch === ';') { if (key !== null) fields[key] = current; key = null; current = ''; continue; }
              current += ch;
            }
            if (!fields.S) return null;
            return { ssid: fields.S, password: fields.P || '' };
          }

          async function connectFromQr(ssid, password) {
            chosenSsid = ssid;
            pwValue = password;
            await connect();
          }

          // ---------- Initial load ----------
          // The service gives Windows' own saved-profile auto-reconnect a
          // grace period on startup (BootGracePeriod in SetupOrchestrator)
          // before deciding the network is really gone - during that
          // window /status reports CheckingConnection. Show a "reconnecting"
          // screen instead of flashing the network picker while that's
          // still in progress.
          (async function init() {
            for (;;) {
              try {
                const r = await fetch('/status', { cache: 'no-store' });
                const data = await r.json();

                if (data.state === 'Connected') {
                  showScreen('connected');
                  setTimeout(() => { window.location.replace(REDIRECT_URL); }, 600);
                  return;
                }

                if (data.state === 'CheckingConnection') {
                  showScreen('connecting');
                  document.getElementById('connectingHeading').textContent = 'Reconnecting…';
                  document.getElementById('connectingSub').textContent = 'Checking your saved WiFi network.';
                  await new Promise(res => setTimeout(res, 1500));
                  continue;
                }

                break; // NeedsNetwork, Failed, Idle, or anything else -> show the picker
              } catch (e) {
                await new Promise(res => setTimeout(res, 1000));
              }
            }
            showScreen('choice');
          })();
        </script>
        </body>
        </html>
        """;

    public void Dispose() => Stop();
}
