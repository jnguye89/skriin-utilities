namespace WifiSetupService;

/// <summary>
/// Main state machine. Runs as a hosted background service for the whole
/// lifetime of the machine — not just once at first boot.
///
/// Cycle:
///   1. Check if already connected -> report Connected.
///   2. Show the on-screen network picker (KioskStatusServer's launcher page)
///      and wait for the customer to pick a network and enter a password
///      there, or for a retry request.
///   3. Join the target network.
///   4. Verify internet, persist the profile, report Connected.
///
/// After a cycle finishes, the service keeps watching: if connectivity is
/// lost later (new router, changed password, moved kiosk) or the kiosk asks
/// for a retry (e.g. via a "WiFi settings" button), it runs the cycle again
/// automatically rather than requiring a service restart or reboot.
///
/// There is deliberately no hotspot/QR step here anymore - see WifiHelper's
/// class comment for why that approach was dropped. Onboarding now happens
/// entirely on the kiosk screen itself, driven by whatever the customer can
/// point and click with (remote, game controller, or a keyboard).
/// </summary>
public class SetupOrchestrator : BackgroundService
{
    private const string StateFile = @"C:\ProgramData\Skriin\wifi_state.json";
    private const string KioskSignalFile = @"C:\ProgramData\Skriin\wifi_ready.flag"; // kept for debugging; the kiosk page reads /status instead

    // How often to re-check connectivity once provisioned.
    private static readonly TimeSpan ConnectivityCheckInterval = TimeSpan.FromMinutes(2);

    // How long to give Windows' own WiFi auto-reconnect a chance to finish
    // before concluding the network is really gone and showing the picker.
    // A cold boot can take well longer than one ping's timeout for the
    // driver to init and DHCP to hand out a lease - without this grace
    // period, the service would win that race, decide there's no network,
    // and re-show the picker even though the saved profile (connectionMode
    // = auto) would have reconnected on its own moments later.
    private static readonly TimeSpan BootGracePeriod = TimeSpan.FromSeconds(45);

    private readonly WifiHelper _wifi;
    private readonly ILogger<SetupOrchestrator> _logger;
    private readonly KioskStatusServer _status;

    private (string Ssid, string Password)? _pendingCredentials;
    private volatile bool _retryRequested;

    public SetupOrchestrator(WifiHelper wifi, ILogger<SetupOrchestrator> logger, IConfiguration config)
    {
        _wifi = wifi;
        _logger = logger;
        var redirectUrl = config["Kiosk:RedirectUrl"] ?? "https://skriin.com/";
        _status = new KioskStatusServer(logger, _wifi, redirectUrl: redirectUrl);
        _status.RetryRequested += () => _retryRequested = true;
        _status.ConnectRequested += (ssid, password) => _pendingCredentials = (ssid, password);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(@"C:\ProgramData\Skriin");
        _status.Start();

        try
        {
            while (!ct.IsCancellationRequested)
            {
                await RunOneCycleAsync(ct);
                await IdleUntilNextCycleAsync(ct);
            }
        }
        finally
        {
            _status.Stop();
        }
    }

    private async Task RunOneCycleAsync(CancellationToken ct)
    {
        try
        {
            _retryRequested = false;
            _pendingCredentials = null;

            // ── 1. Already connected (or about to reconnect on its own)? ──
            _status.SetState(KioskWifiState.CheckingConnection, message: "Checking connection...");
            if (await WaitForInternetAsync(BootGracePeriod, ct))
            {
                _logger.LogInformation("Internet available");
                _status.SetState(KioskWifiState.Connected);
                SignalKiosk(connected: true);
                return;
            }

            // ── 2. Show the on-screen picker and wait for a choice ────────
            _status.SetState(KioskWifiState.NeedsNetwork, message: "Pick a WiFi network to continue.");
            _logger.LogInformation("Waiting for a network to be chosen on the kiosk screen...");

            while (!_pendingCredentials.HasValue && !_retryRequested && !ct.IsCancellationRequested)
                await Task.Delay(500, ct);

            if (ct.IsCancellationRequested) return;

            if (_retryRequested || !_pendingCredentials.HasValue)
            {
                _logger.LogInformation("Setup cycle cancelled/retried before a network was chosen");
                return; // outer loop starts a fresh cycle immediately
            }

            var (targetSsid, targetPassword) = _pendingCredentials.Value;
            _pendingCredentials = null;

            // ── 3. Join target network ──────────────────────────────────
            _status.SetState(KioskWifiState.Connecting, ssid: targetSsid);
            _logger.LogInformation("Joining {Ssid}...", targetSsid);
            _wifi.JoinNetwork(targetSsid, targetPassword);

            bool connected = _wifi.WaitForConnection(targetSsid, timeoutSeconds: 30);
            if (!connected)
            {
                _logger.LogError("Failed to connect to {Ssid} within timeout", targetSsid);
                _status.SetState(KioskWifiState.Failed, ssid: targetSsid,
                    message: "Could not join that network - check the password and try again.");
                SignalKiosk(connected: false);
                return;
            }

            // ── 4. Verify internet + persist ──────────────────────────────
            bool internet = _wifi.HasInternetAccess();
            _logger.LogInformation("Internet check: {Ok}", internet);

            if (internet)
            {
                SaveState(targetSsid);
                _status.SetState(KioskWifiState.Connected, ssid: targetSsid);
            }
            else
            {
                _status.SetState(KioskWifiState.Failed, ssid: targetSsid,
                    message: "Connected to the network, but there's no internet access.");
            }
            SignalKiosk(connected: internet);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "SetupOrchestrator cycle failed");
            _status.SetState(KioskWifiState.Failed, message: "Unexpected error during WiFi setup.");
            SignalKiosk(connected: false);
        }
    }

    /// <summary>
    /// Polls HasInternetAccess() until it succeeds or the timeout expires -
    /// gives Windows' own saved-profile auto-reconnect a bounded window to
    /// finish (see BootGracePeriod) instead of a single point-in-time check.
    /// </summary>
    private async Task<bool> WaitForInternetAsync(TimeSpan timeout, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!ct.IsCancellationRequested)
        {
            if (_wifi.HasInternetAccess()) return true;
            if (DateTime.UtcNow >= deadline) return false;
            try { await Task.Delay(2000, ct); }
            catch (TaskCanceledException) { return false; }
        }
        return false;
    }

    /// <summary>
    /// Waits until either the kiosk asks for a retry, or (once provisioned)
    /// connectivity drops and needs re-provisioning. Polls on an interval
    /// rather than blocking forever so a dropped connection is noticed
    /// within one interval, not just at the next reboot.
    /// </summary>
    private async Task IdleUntilNextCycleAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (_retryRequested) return;

            if (!_wifi.HasInternetAccess())
            {
                _logger.LogInformation("Connectivity lost — re-entering setup");
                return;
            }

            try { await Task.Delay(ConnectivityCheckInterval, ct); }
            catch (TaskCanceledException) { return; }
        }
    }

    private void SaveState(string ssid)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(new { ssid, connectedAt = DateTime.UtcNow });
        File.WriteAllText(StateFile, json);
    }

    private void SignalKiosk(bool connected)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(new { connected, timestamp = DateTime.UtcNow });
        File.WriteAllText(KioskSignalFile, json);
    }
}
