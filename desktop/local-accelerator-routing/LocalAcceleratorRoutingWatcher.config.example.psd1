@{
    # Copy this file to LocalAcceleratorRoutingWatcher.config.psd1.
    # Keep the copy with your private profile paths; do not commit it.
    Profiles = @(
        @{
            Path = 'C:\Users\your-name\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\SubscriptionA.yaml'
            AcceleratorPolicy = 'DIRECT'
        }
        @{
            Path = 'C:\Users\your-name\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\SubscriptionB.yaml'
            AcceleratorPolicy = 'DIRECT'
        }
    )

    # Optional global Merge profile. Leave empty if you do not use one.
    GlobalMergePath = ''
    # Optional test/development override. Leave empty to use Windows Hosts.
    HostsPath = ''

    # Only the GUI path belongs here. The watcher never targets
    # clash-verge-service.exe or verge-mihomo.exe.
    ClashExecutable = 'C:\Program Files\Clash Verge\clash-verge.exe'
    # Disabled is safest for a shared/TUN environment. Graceful waits for the
    # GUI to close. Fast force-terminates only a verified clash-verge.exe GUI
    # and immediately starts the same path; expect about 1-2 seconds of
    # proxy/TUN interruption. Both modes require the exact GUI path guard.
    ClientRestartMode = 'Disabled' # Disabled | Graceful | Fast
    RestartRunningClient = $false  # legacy fallback when ClientRestartMode is absent
    RestartGraceSeconds = 15
    FastRestartConfirmMilliseconds = 500
    FastRestartSettleMilliseconds = 1000  # 250-3000; wait after GUI exit before relaunch

    # State is private and stores the original dns.use-system-hosts values so
    # the watcher can restore them exactly when both accelerators stop.
    StatePath = '%LOCALAPPDATA%\LocalAcceleratorRoutingWatcher\state.json'
    BackupDirectory = '%LOCALAPPDATA%\LocalAcceleratorRoutingWatcher\backups'

    PollSeconds = 3
    StableSamples = 2

    # Used for process-only connection refresh fallback only when the active
    # mode is Watt; Steamcommunity_302 mode does not select Watt by name.
    WattProcessName = 'Steam++.Accelerator'
    WattProxyPorts = @(80, 443)
    Steam302ProxyPorts = @(80, 443)

    # Optional Mihomo live-connection refresh. Leave disabled unless the
    # runtime YAML path and local controller config are both supplied. The
    # controller secret is read into memory from MihomoControllerConfigPath;
    # never put it in this file or in Git.
    ConnectionRefreshEnabled = $false
    ConnectionRefreshOnRoutingChange = $true
    ConnectionRefreshFlushFakeIp = $false
    ConnectionRefreshTimeoutMilliseconds = 3000 # 500-10000
    ConnectionRefreshMaxConnections = 32 # 1-128; refuses a larger match
    RuntimeConfigPath = ''
    MihomoControllerConfigPath = '%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\config.yaml'
    MihomoControllerAddress = '' # optional override, e.g. 127.0.0.1:9090
    MihomoControllerPipe = '' # optional override, e.g. \\.\pipe\verge-mihomo
    ManagedConnectionProcesses = @(
        'steam.exe', 'steamwebhelper.exe', 'steamservice.exe',
        'steamcommunity_302', 'steamcommunity_302.cli', 'steamcommunity_302.caddy'
    )

    # The enabled value is intentional: Mihomo must honor Windows Hosts while
    # a local accelerator is active. The original value is restored later.
    EnsureSystemHosts = $true

    LogPath = '%LOCALAPPDATA%\LocalAcceleratorRoutingWatcher\watcher.log'
    MutexName = 'Local\LocalAcceleratorRoutingWatcher'
}
