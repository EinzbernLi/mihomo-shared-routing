@{
    # Copy this file to SteamRoutingWatcher.config.psd1, then set your own paths.
    Profiles = @(
        'C:\path\to\profiles\SubscriptionA.yaml'
        'C:\path\to\profiles\SubscriptionB.yaml'
    )

    # Leave empty to update files only. When true, a currently running client
    # is restarted after a route change so the new rules take effect at once.
    ClashExecutable = 'C:\path\to\clash-verge.exe'
    RestartRunningClient = $true

    # The watcher checks every three seconds and requires two matching samples.
    PollSeconds = 3
    StableSamples = 2

    # Watt's acceleration engine is recognised only while this process owns one
    # of these local HTTP/HTTPS listening ports.
    WattProcessName = 'Steam++.Accelerator'
    WattProxyPorts = @(80, 443)

    # Steamcommunity_302 is ready only when its CLI/Caddy process owns one of
    # these local ports. The default covers its standard HTTP/HTTPS listeners.
    Steam302ProxyPorts = @(80, 443)

    # When an accelerator is ready, set dns.use-system-hosts in the Clash Verge
    # Rev override so Mihomo resolves the accelerator's Windows hosts entries.
    EnsureSystemHosts = $true

    # Optional. Leave empty to write SteamRoutingWatcher.log next to the script.
    LogPath = ''
}
