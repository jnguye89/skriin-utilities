using System.Diagnostics;
using System.Text.RegularExpressions;

namespace WifiSetupService;

/// <summary>
/// Wraps netsh wlan client-mode commands: scanning, joining, and checking
/// connectivity. All methods throw on non-zero exit codes.
///
/// Deliberately does NOT include a "host a temporary WiFi hotspot" method.
/// Both ways Windows can do that - the legacy Hosted Network feature
/// (netsh wlan start hostednetwork) and the modern Mobile Hotspot API
/// (NetworkOperatorTetheringManager) - were tried against this fleet's
/// actual hardware and don't work for a zero-connectivity first boot: this
/// adapter's driver doesn't support Hosted Network at all, and Mobile
/// Hotspot fundamentally requires an existing connection to share, which by
/// definition doesn't exist yet on a brand-new kiosk. Client-mode scan/join
/// is a different capability from hosting an access point and works fine on
/// this hardware regardless of that limitation - see
/// KioskStatusServer's on-screen network picker, which is what actually
/// drives onboarding now instead of a temporary hotspot + phone.
/// </summary>
public class WifiHelper
{
    private readonly ILogger<WifiHelper> _logger;

    public WifiHelper(ILogger<WifiHelper> logger) => _logger = logger;

    // -- Network scanning ---------------------------------------------------

    public List<string> ScanNetworks()
    {
        try { RunNetsh("wlan scan"); } // triggers a refresh; results appear ~2 s later
        catch (Exception ex) { _logger.LogWarning(ex, "wlan scan failed; listing cached results"); }
        Thread.Sleep(2500);

        string output;
        try { output = RunNetsh("wlan show networks mode=bssid"); }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "wlan show networks failed");
            return new List<string>();
        }

        var networks = new List<string>();
        foreach (Match m in Regex.Matches(output, @"SSID\s+\d+\s*:\s*(.+)"))
        {
            var ssid = m.Groups[1].Value.Trim();
            if (!string.IsNullOrEmpty(ssid))
                networks.Add(ssid);
        }
        return networks.Distinct().ToList();
    }

    // -- Joining a network ----------------------------------------------------

    public void JoinNetwork(string ssid, string password)
    {
        // Write a temporary profile XML and connect with it
        var profileXml = BuildProfileXml(ssid, password);
        var profilePath = Path.Combine(Path.GetTempPath(), "skriin_wifi_profile.xml");
        File.WriteAllText(profilePath, profileXml);

        try
        {
            // Get the first wireless interface name
            var iface = GetWirelessInterface();
            RunNetsh($"wlan add profile filename=\"{profilePath}\" interface=\"{iface}\"");
            RunNetsh($"wlan connect name=\"{ssid}\" interface=\"{iface}\"");
            _logger.LogInformation("Connecting to {Ssid}", ssid);
        }
        finally
        {
            File.Delete(profilePath);
        }
    }

    public bool WaitForConnection(string ssid, int timeoutSeconds = 30)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            string output;
            try { output = RunNetsh("wlan show interfaces"); }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "wlan show interfaces failed while waiting for connection");
                Thread.Sleep(1000);
                continue;
            }

            if (output.Contains($"SSID                   : {ssid}") &&
                output.Contains("State                  : connected"))
                return true;
            Thread.Sleep(1000);
        }
        return false;
    }

    public bool HasInternetAccess()
    {
        try
        {
            using var ping = new System.Net.NetworkInformation.Ping();
            var reply = ping.Send("8.8.8.8", 3000);
            return reply.Status == System.Net.NetworkInformation.IPStatus.Success;
        }
        catch { return false; }
    }

    // -- Saved profiles -------------------------------------------------------

    public void DeleteProfile(string ssid)
    {
        try { RunNetsh($"wlan delete profile name=\"{ssid}\""); }
        catch { /* profile may not exist */ }
    }

    // -- Internals --------------------------------------------------------------

    private string GetWirelessInterface()
    {
        var output = RunNetsh("wlan show interfaces");
        var m = Regex.Match(output, @"Name\s+:\s+(.+)");
        if (!m.Success) throw new InvalidOperationException("No wireless interface found");
        return m.Groups[1].Value.Trim();
    }

    private string RunNetsh(string args)
    {
        var psi = new ProcessStartInfo("netsh", args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi)!;
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        if (proc.ExitCode != 0)
        {
            _logger.LogWarning("netsh {Args} exited {Code}: {Err}", args, proc.ExitCode, stderr);
            throw new InvalidOperationException($"netsh {args} failed (exit {proc.ExitCode}): {stderr}");
        }
        return stdout;
    }

    private static string BuildProfileXml(string ssid, string password)
    {
        // WPA2-Personal profile. Swap authEncryption for open networks.
        return $"""
            <?xml version="1.0"?>
            <WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
              <name>{EscapeXml(ssid)}</name>
              <SSIDConfig>
                <SSID><name>{EscapeXml(ssid)}</name></SSID>
              </SSIDConfig>
              <connectionType>ESS</connectionType>
              <connectionMode>auto</connectionMode>
              <MSM>
                <security>
                  <authEncryption>
                    <authentication>WPA2PSK</authentication>
                    <encryption>AES</encryption>
                    <useOneX>false</useOneX>
                  </authEncryption>
                  <sharedKey>
                    <keyType>passPhrase</keyType>
                    <protected>false</protected>
                    <keyMaterial>{EscapeXml(password)}</keyMaterial>
                  </sharedKey>
                </security>
              </MSM>
            </WLANProfile>
            """;
    }

    private static string EscapeXml(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
         .Replace("\"", "&quot;").Replace("'", "&apos;");
}
