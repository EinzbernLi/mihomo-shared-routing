[CmdletBinding()]
param(
    [switch]$Once,
    [string]$ConfigPath,
    [switch]$SkipClientReload,
    [switch]$RestartClientOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'LocalAcceleratorRoutingWatcher.config.psd1'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath. Copy LocalAcceleratorRoutingWatcher.config.example.psd1 first."
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if (-not $config.Profiles -or @($config.Profiles).Count -eq 0) {
    throw 'Set at least one Profiles entry in the configuration file.'
}

function Resolve-ConfiguredPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Get-ConfigString {
    param(
        [hashtable]$Source,
        [string]$Name,
        [string]$Default = ''
    )
    if ($Source.ContainsKey($Name) -and $null -ne $Source[$Name]) {
        return [string]$Source[$Name]
    }
    return $Default
}

$profiles = @(
    foreach ($entry in @($config.Profiles)) {
        if ($entry -is [string]) {
            [pscustomobject]@{
                Path = Resolve-ConfiguredPath -Path ([string]$entry)
                AcceleratorPolicy = 'DIRECT'
            }
        } else {
            [pscustomobject]@{
                Path = Resolve-ConfiguredPath -Path ([string]$entry.Path)
                AcceleratorPolicy = if ($entry.AcceleratorPolicy) { [string]$entry.AcceleratorPolicy } else { 'DIRECT' }
            }
        }
    }
)

if (@($profiles | Where-Object { [string]::IsNullOrWhiteSpace($_.Path) }).Count -gt 0) {
    throw 'Every Profiles entry must contain a non-empty Path.'
}

$profilePaths = @($profiles | Select-Object -ExpandProperty Path)
$duplicateProfiles = @($profilePaths | Group-Object { $_.ToLowerInvariant() } | Where-Object Count -gt 1)
if ($duplicateProfiles.Count -gt 0) {
    throw "Profiles contains duplicate paths: $($duplicateProfiles.Name -join ', ')"
}

$pollSeconds = [Math]::Max(1, [int]$config.PollSeconds)
$stableSamples = [Math]::Max(1, [int]$config.StableSamples)
$wattProcessName = if ($config.WattProcessName) { [string]$config.WattProcessName } else { 'Steam++.Accelerator' }
$wattProxyPorts = if ($config.WattProxyPorts) { @($config.WattProxyPorts | ForEach-Object { [int]$_ }) } else { @(80, 443) }
$steam302ProxyPorts = if ($config.Steam302ProxyPorts) { @($config.Steam302ProxyPorts | ForEach-Object { [int]$_ }) } else { @(80, 443) }
$ensureSystemHosts = if ($null -ne $config.EnsureSystemHosts) { [bool]$config.EnsureSystemHosts } else { $true }
$globalMergeConfigPath = if ($config.GlobalMergePath) { [string]$config.GlobalMergePath } else { '' }
$hostsConfigPath = if ($config.HostsPath) { [string]$config.HostsPath } else { Join-Path $env:WINDIR 'System32\drivers\etc\hosts' }
$logConfigPath = if ($config.LogPath) { [string]$config.LogPath } else { Join-Path $PSScriptRoot 'LocalAcceleratorRoutingWatcher.log' }
$stateConfigPath = if ($config.StatePath) { [string]$config.StatePath } else { Join-Path $env:LOCALAPPDATA 'LocalAcceleratorRoutingWatcher\state.json' }
$backupConfigPath = if ($config.BackupDirectory) { [string]$config.BackupDirectory } else { Join-Path $env:LOCALAPPDATA 'LocalAcceleratorRoutingWatcher\backups' }
$globalMergePath = Resolve-ConfiguredPath -Path $globalMergeConfigPath
$hostsPath = Resolve-ConfiguredPath -Path $hostsConfigPath
$logPath = Resolve-ConfiguredPath -Path $logConfigPath
$statePath = Resolve-ConfiguredPath -Path $stateConfigPath
$backupDirectory = Resolve-ConfiguredPath -Path $backupConfigPath
$mutexName = if ($config.MutexName) { [string]$config.MutexName } else { 'Local\LocalAcceleratorRoutingWatcher' }
$restartGraceConfig = if ($config.RestartGraceSeconds) { $config.RestartGraceSeconds } else { 15 }
$restartGraceSeconds = [Math]::Max(5, [int]$restartGraceConfig)
$fastRestartConfirmConfig = if ($config.FastRestartConfirmMilliseconds) { $config.FastRestartConfirmMilliseconds } else { 500 }
$fastRestartConfirmMilliseconds = [Math]::Max(0, [int]$fastRestartConfirmConfig)
$fastRestartSettleConfig = if ($config.ContainsKey('FastRestartSettleMilliseconds')) { $config.FastRestartSettleMilliseconds } else { 1000 }
try {
    $fastRestartSettleMilliseconds = [int]$fastRestartSettleConfig
} catch {
    throw "FastRestartSettleMilliseconds must be an integer between 250 and 3000; received '$fastRestartSettleConfig'."
}
if ($fastRestartSettleMilliseconds -lt 250 -or $fastRestartSettleMilliseconds -gt 3000) {
    throw "FastRestartSettleMilliseconds must be between 250 and 3000; received '$fastRestartSettleMilliseconds'."
}
$clientRestartMode = if ($config.ClientRestartMode) { [string]$config.ClientRestartMode } elseif ($config.RestartRunningClient) { 'Graceful' } else { 'Disabled' }
if ($clientRestartMode -notin @('Disabled', 'Graceful', 'Fast')) {
    throw "ClientRestartMode must be Disabled, Graceful, or Fast; received '$clientRestartMode'."
}
$controllerConfigPath = Resolve-ConfiguredPath -Path (Get-ConfigString -Source $config -Name 'MihomoControllerConfigPath')
$runtimeConfigPath = Resolve-ConfiguredPath -Path (Get-ConfigString -Source $config -Name 'RuntimeConfigPath')
$controllerPipeOverride = Get-ConfigString -Source $config -Name 'MihomoControllerPipe'
$controllerAddressOverride = Get-ConfigString -Source $config -Name 'MihomoControllerAddress'
$connectionRefreshEnabled = if ($config.ContainsKey('ConnectionRefreshEnabled')) { [bool]$config.ConnectionRefreshEnabled } else { $false }
$connectionRefreshFlushFakeIp = if ($config.ContainsKey('ConnectionRefreshFlushFakeIp')) { [bool]$config.ConnectionRefreshFlushFakeIp } else { $false }
$connectionRefreshOnRoutingChange = if ($config.ContainsKey('ConnectionRefreshOnRoutingChange')) { [bool]$config.ConnectionRefreshOnRoutingChange } else { $true }
$connectionRefreshTimeoutConfig = if ($config.ContainsKey('ConnectionRefreshTimeoutMilliseconds')) { $config.ConnectionRefreshTimeoutMilliseconds } else { 3000 }
try { $connectionRefreshTimeoutMilliseconds = [int]$connectionRefreshTimeoutConfig } catch { throw "ConnectionRefreshTimeoutMilliseconds must be an integer between 500 and 10000; received '$connectionRefreshTimeoutConfig'." }
if ($connectionRefreshTimeoutMilliseconds -lt 500 -or $connectionRefreshTimeoutMilliseconds -gt 10000) {
    throw "ConnectionRefreshTimeoutMilliseconds must be between 500 and 10000; received '$connectionRefreshTimeoutMilliseconds'."
}
$connectionRefreshMaxConfig = if ($config.ContainsKey('ConnectionRefreshMaxConnections')) { $config.ConnectionRefreshMaxConnections } else { 32 }
try { $connectionRefreshMaxConnections = [int]$connectionRefreshMaxConfig } catch { throw "ConnectionRefreshMaxConnections must be an integer between 1 and 128; received '$connectionRefreshMaxConfig'." }
if ($connectionRefreshMaxConnections -lt 1 -or $connectionRefreshMaxConnections -gt 128) {
    throw "ConnectionRefreshMaxConnections must be between 1 and 128; received '$connectionRefreshMaxConnections'."
}
$managedConnectionProcesses = if ($config.ContainsKey('ManagedConnectionProcesses')) {
    @($config.ManagedConnectionProcesses | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
} else {
    @('steam.exe', 'steamwebhelper.exe', 'steamservice.exe')
}

function Write-Log {
    param([string]$Message)
    try {
        $directory = Split-Path -Parent $logPath
        if ($directory) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" |
            Add-Content -LiteralPath $logPath -Encoding utf8
    } catch {
        # Logging must never terminate the watcher or alter routing state.
    }
}

function Get-Utf8File {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $offset = if ($hasBom) { 3 } else { 0 }
    [pscustomobject]@{
        Path = $Path
        Content = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        HasBom = $hasBom
        Hash = (Get-Sha256Bytes -Bytes $bytes)
    }
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Sha256Text {
    param([string]$Text)
    return Get-Sha256Bytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content,
        [bool]$HasBom
    )
    $encoding = [System.Text.UTF8Encoding]::new($HasBom)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-NewLine {
    param([string]$Content)
    if ($Content -match "`r`n") { return "`r`n" }
    return "`n"
}

function Get-HostsRules {
    $hosts = Get-Utf8File -Path $hostsPath
    $rules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($hosts.Content -split "`r?`n")) {
        $entry = ($line -replace '\s+#.*$', '').Trim()
        if ($entry -notmatch '^(?:127(?:\.\d{1,3}){3}|::1)\s+(?<names>.+)$') {
            continue
        }
        foreach ($name in ($matches.names -split '\s+')) {
            $hostname = $name.Trim().TrimEnd('.').ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($hostname) -or $hostname -in @('localhost', 'localhost.localdomain', 'broadcasthost')) {
                continue
            }
            if ($hostname.StartsWith('*.')) {
                $suffix = $hostname.Substring(2)
                if ($suffix -match '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') {
                    [void]$rules.Add("  - DOMAIN-SUFFIX,$suffix,DIRECT")
                }
            } elseif ($hostname -match '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$') {
                [void]$rules.Add("  - DOMAIN,$hostname,DIRECT")
            }
        }
    }
    [pscustomobject]@{ Path = $hostsPath; ContentHash = $hosts.Hash; Rules = @($rules | Sort-Object) }
}

function New-LocalAcceleratorRoutingBlock {
    param(
        [string]$AcceleratorPolicy,
        [string[]]$DomainRules
    )
    if ([string]::IsNullOrWhiteSpace($AcceleratorPolicy) -or $AcceleratorPolicy -match '[,\r\n]') {
        throw 'AcceleratorPolicy must be a non-empty Clash policy name without commas or newlines.'
    }
    if (@($DomainRules).Count -eq 0) { return '' }
    $processRules = @(
        "  - PROCESS-NAME,Steam++.Accelerator.exe,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302.caddy.exe,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302.cli.exe,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302.exe,$AcceleratorPolicy"
        "  - PROCESS-NAME,Steam++.Accelerator,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302.caddy,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302.cli,$AcceleratorPolicy"
        "  - PROCESS-NAME,steamcommunity_302,$AcceleratorPolicy"
    )
    return (@(
        '  # BEGIN Local accelerator routing'
        '  # Managed by LocalAcceleratorRoutingWatcher.ps1 from Windows Hosts. Do not edit this block manually.'
        $processRules
        $DomainRules
        '  # END Local accelerator routing'
    ) -join "`n")
}

function Get-ListeningEndpoints {
    $endpoints = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (netstat -ano)) {
        if ($line -match '^\s*TCP\s+(?<local>\S+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$') {
            # A second -match replaces the automatic $matches table, so save
            # the PID and endpoint before extracting the port.
            $localEndpoint = $matches.local
            $processId = [int]$matches.pid
            if ($localEndpoint -notmatch ':(?<port>\d+)$') { continue }
            $endpoints.Add([pscustomobject]@{
                LocalAddress = ($localEndpoint -replace ':\d+$', '')
                LocalPort = [int]$matches.port
                OwningProcess = $processId
            })
        }
    }
    return @($endpoints)
}

function Get-WattDiagnostics {
    param(
        [object[]]$Processes,
        [object[]]$Listeners
    )

    $processesInjected = $PSBoundParameters.ContainsKey('Processes')
    $listenersInjected = $PSBoundParameters.ContainsKey('Listeners')
    if (-not $processesInjected) {
        $candidateNames = @($wattProcessName, 'Steam++', 'Steam++.Accelerator') |
            ForEach-Object { ([string]$_ -replace '(?i)\.exe$', '') } |
            Sort-Object -Unique
        $processList = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $candidateNames) {
            foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                $processList.Add($process)
            }
        }
        $Processes = @($processList | Sort-Object Id -Unique)
    } else {
        $Processes = @($Processes)
    }
    if (-not $listenersInjected) {
        $Listeners = @(Get-ListeningEndpoints)
    } else {
        $Listeners = @($Listeners)
    }

    if (-not $processesInjected) {
        # Get-Process is sufficient for the normal process-name check but does
        # not expose parentage reliably on all Windows versions. Enrich only
        # the candidate and observed listener PIDs, rather than inferring Watt
        # from an arbitrary 80/443 owner.
        $inspectIds = @(
            @($Processes | Select-Object -ExpandProperty Id)
            @($Listeners | Where-Object { $_.LocalPort -in @($wattProxyPorts + 81 + 444) } | Select-Object -ExpandProperty OwningProcess)
        ) | Sort-Object -Unique
        $enriched = [System.Collections.Generic.List[object]]::new()
        foreach ($processId in $inspectIds) {
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$processId)" -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $cim) {
                    $enriched.Add([pscustomobject]@{
                        Id = [int]$cim.ProcessId
                        ProcessName = [string]$cim.Name
                        ExecutablePath = [string]$cim.ExecutablePath
                        ParentProcessId = [int]$cim.ParentProcessId
                    })
                    continue
                }
            } catch { }
            $fallback = @($Processes | Where-Object { [int]$_.Id -eq [int]$processId } | Select-Object -First 1)
            if ($fallback.Count -gt 0) {
                $enriched.Add([pscustomobject]@{
                    Id = [int]$fallback[0].Id
                    ProcessName = [string]$fallback[0].ProcessName
                    ExecutablePath = [string]$(if ($fallback[0].ExecutablePath) { $fallback[0].ExecutablePath } else { $fallback[0].Path })
                    ParentProcessId = [int]$fallback[0].ParentProcessId
                })
            }
        }
        $Processes = @($enriched)
    }

    $candidateNames = @($wattProcessName, 'Steam++', 'Steam++.Accelerator') |
        ForEach-Object { ([string]$_ -replace '(?i)\.exe$', '') } |
        Sort-Object -Unique
    $candidateProcesses = @($Processes | Where-Object {
        $name = [string]$_.ProcessName -replace '(?i)\.exe$', ''
        $name -in $candidateNames
    })
    if ($candidateProcesses.Count -gt 0) {
        $children = [System.Collections.Generic.List[object]]::new()
        foreach ($candidate in $candidateProcesses) {
            try {
                foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$([int]$candidate.Id)" -ErrorAction Stop)) {
                    $children.Add([pscustomobject]@{
                        Id = [int]$child.ProcessId
                        ProcessName = [string]$child.Name
                        ExecutablePath = [string]$child.ExecutablePath
                        ParentProcessId = [int]$child.ParentProcessId
                    })
                }
            } catch { }
        }
        if ($children.Count -gt 0) {
            $Processes = @($Processes + @($children)) | Sort-Object Id -Unique
            $candidateProcesses = @($Processes | Where-Object {
                $name = [string]$_.ProcessName -replace '(?i)\.exe$', ''
                $name -in $candidateNames
            })
        }
    }

    # Only a child with explicit parent/path evidence can extend ownership to
    # a helper; an arbitrary process owning 80/443 is never treated as Watt.
    $helperProcesses = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidateProcesses) {
        $candidatePath = [string]$(if ($candidate.ExecutablePath) { $candidate.ExecutablePath } else { $candidate.Path })
        $candidateDirectory = if ([string]::IsNullOrWhiteSpace($candidatePath)) { '' } else { Split-Path -Parent $candidatePath }
        foreach ($process in @($Processes)) {
            if ([int]$process.Id -eq [int]$candidate.Id) { continue }
            if ([int]$process.ParentProcessId -ne [int]$candidate.Id) { continue }
            $helperPath = [string]$(if ($process.ExecutablePath) { $process.ExecutablePath } else { $process.Path })
            $helperDirectory = if ([string]::IsNullOrWhiteSpace($helperPath)) { '' } else { Split-Path -Parent $helperPath }
            if (-not [string]::IsNullOrWhiteSpace($candidateDirectory) -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals($candidateDirectory, $helperDirectory)) {
                $helperProcesses.Add($process)
            }
        }
    }

    $relevantPorts = @($wattProxyPorts + 81 + 444 | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $observed = @($Listeners | Where-Object { $_.LocalPort -in $relevantPorts })
    $candidateIds = @($candidateProcesses | Select-Object -ExpandProperty Id)
    $ownerIds = @($candidateIds + @($helperProcesses | Select-Object -ExpandProperty Id) | Sort-Object -Unique)
    $matched = @($observed | Where-Object { $_.OwningProcess -in $ownerIds })
    $expectedMatched = @($matched | Where-Object { $_.LocalPort -in $wattProxyPorts })
    $fallbackMatched = @($matched | Where-Object { $_.LocalPort -in @(81, 444) })
    $active = $expectedMatched.Count -gt 0
    $hasCandidate = $candidateProcesses.Count -gt 0
    $status = if ($active) { 'Active' } elseif ($hasCandidate) { 'NotReady' } else { 'Absent' }
    $observedPorts = @($observed | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
    $matchedPorts = @($matched | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
    $candidateSummary = @($candidateProcesses | ForEach-Object {
        $path = [string]$(if ($_.ExecutablePath) { $_.ExecutablePath } else { $_.Path })
        "PID $($_.Id) $([System.IO.Path]::GetFileName([string]$_.ProcessName)) path='$path'"
    })
    $helperSummary = @($helperProcesses | ForEach-Object {
        $path = [string]$(if ($_.ExecutablePath) { $_.ExecutablePath } else { $_.Path })
        "PID $($_.Id) helper path='$path' parent=$($_.ParentProcessId)"
    })
    $fingerprint = @(
        $status
        ($candidateIds -join ',')
        ($ownerIds -join ',')
        ($observedPorts -join ',')
        ($matchedPorts -join ',')
    ) -join '|'
    [pscustomobject]@{
        Status = $status
        Active = $active
        NotReady = ($status -eq 'NotReady')
        CandidateProcesses = @($candidateSummary + $helperSummary)
        CandidateIds = @($candidateIds)
        ObservedPorts = @($observedPorts)
        MatchedPorts = @($matchedPorts)
        FallbackPorts = @($fallbackMatched | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
        Fingerprint = $fingerprint
    }
}

function Get-AcceleratorState {
    $sources = [System.Collections.Generic.List[string]]::new()
    $listeners = @(Get-ListeningEndpoints)
    $processes = @(Get-Process -ErrorAction SilentlyContinue)

    $steam302Ids = @($processes | Where-Object {
        $_.ProcessName -match '^steamcommunity_302(?:\.(cli|caddy))?$'
    } | Select-Object -ExpandProperty Id)
    if (@($listeners | Where-Object { $_.OwningProcess -in $steam302Ids -and $_.LocalPort -in $steam302ProxyPorts }).Count -gt 0) {
        $sources.Add('Steamcommunity_302')
    }

    # Let Watt diagnostics enrich process candidates with CIM parent/path
    # evidence. Get-Process does not expose ParentProcessId consistently on
    # Windows PowerShell 5.1, so passing its objects here would disable the
    # helper-owner safety check.
    $wattDiagnostics = Get-WattDiagnostics
    if ($wattDiagnostics.Active) {
        $sources.Add('Watt')
    }

    $mode = if ($sources -contains 'Steamcommunity_302') {
        'Steamcommunity_302'
    } elseif ($sources -contains 'Watt') {
        'Watt'
    } else {
        'None'
    }
    [pscustomobject]@{
        Mode = $mode
        Direct = ($mode -ne 'None')
        Sources = @($sources)
        WattDiagnostics = $wattDiagnostics
    }
}

function Get-DnsSnapshot {
    param([string]$Content)
    $dnsPattern = [regex]'(?m)^dns:\r?\n(?<body>(?:(?:  |\t)[^\r\n]*(?:\r?\n|$))*)'
    $dnsMatch = $dnsPattern.Match($Content)
    if (-not $dnsMatch.Success) {
        return [pscustomobject]@{ DnsPresent = $false; UseSystemHostsPresent = $false; UseSystemHosts = $false }
    }
    $useMatch = [regex]::Match($dnsMatch.Value, '(?m)^(?:  |\t)use-system-hosts:[ \t]*(?<value>true|false)[ \t]*(?:\r?\n|$)')
    [pscustomobject]@{
        DnsPresent = $true
        UseSystemHostsPresent = $useMatch.Success
        UseSystemHosts = if ($useMatch.Success) { $useMatch.Groups['value'].Value -eq 'true' } else { $false }
    }
}

function Copy-DnsSnapshots {
    param([object[]]$Snapshots)
    return @(
        foreach ($snapshot in @($Snapshots)) {
            if ($snapshot) {
                [pscustomobject]@{
                    Path = [string]$snapshot.Path
                    DnsPresent = [bool]$snapshot.DnsPresent
                    UseSystemHostsPresent = [bool]$snapshot.UseSystemHostsPresent
                    UseSystemHosts = [bool]$snapshot.UseSystemHosts
                }
            }
        }
    )
}

function Load-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{ Version = 1; DnsSnapshots = @() }
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $statePath -Encoding utf8 | ConvertFrom-Json
        return [pscustomobject]@{ Version = 1; DnsSnapshots = @(Copy-DnsSnapshots -Snapshots @($raw.DnsSnapshots)) }
    } catch {
        throw "Cannot read state file '$statePath': $($_.Exception.Message)"
    }
}

function Save-State {
    param([object[]]$Snapshots)
    $directory = Split-Path -Parent $statePath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $payload = [pscustomobject]@{ Version = 1; DnsSnapshots = @(Copy-DnsSnapshots -Snapshots $Snapshots) }
    $temp = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-Utf8File -Path $temp -Content ($payload | ConvertTo-Json -Depth 8) -HasBom $false
        $check = Get-Content -Raw -LiteralPath $temp -Encoding utf8 | ConvertFrom-Json
        if ($null -eq $check.Version) { throw 'state validation failed' }
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $backup = Join-Path $directory ((Split-Path -Leaf $statePath) + "." + (Get-Date -Format 'yyyyMMdd-HHmmss') + "." + [guid]::NewGuid().ToString('N') + '.bak')
            [System.IO.File]::Replace($temp, $statePath, $backup, $true)
        } else {
            [System.IO.File]::Move($temp, $statePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Find-Snapshot {
    param([object[]]$Snapshots, [string]$Path)
    return @($Snapshots | Where-Object { $_.Path.Equals($Path, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
}

function Remove-Snapshot {
    param([object[]]$Snapshots, [string]$Path)
    return @($Snapshots | Where-Object { -not $_.Path.Equals($Path, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Set-DnsSystemHosts {
    param(
        [string]$Content,
        [bool]$Enabled,
        [object]$Original,
        [string]$NewLine
    )
    $dnsPattern = [regex]'(?m)^dns:\r?\n(?<body>(?:(?:  |\t)[^\r\n]*(?:\r?\n|$))*)'
    $dnsMatch = $dnsPattern.Match($Content)
    if ($Enabled) {
        if ($dnsMatch.Success) {
            $dnsBlock = $dnsMatch.Value
            $usePattern = [regex]'(?m)^(?<indent>  |\t)use-system-hosts:[ \t]*(?:true|false)[ \t]*(?<ending>\r?\n|$)'
            if ($usePattern.IsMatch($dnsBlock)) {
                $updatedBlock = $usePattern.Replace($dnsBlock, '${indent}use-system-hosts: true${ending}', 1)
                return $Content.Substring(0, $dnsMatch.Index) + $updatedBlock + $Content.Substring($dnsMatch.Index + $dnsMatch.Length)
            }
            $insertAt = $dnsMatch.Index + ("dns:$NewLine").Length
            return $Content.Substring(0, $insertAt) + "  use-system-hosts: true$NewLine" + $Content.Substring($insertAt)
        }
        $separator = if ($Content.Length -eq 0 -or $Content.EndsWith("`n")) { '' } else { $NewLine }
        return "$Content$separator# Managed by LocalAcceleratorRoutingWatcher.ps1: honor local accelerator hosts.$NewLine`dns:$NewLine  use-system-hosts: true$NewLine"
    }

    if ($null -eq $Original) { return $Content }
    if (-not $Original.UseSystemHostsPresent -and -not $Original.DnsPresent) {
        $managed = [regex]'(?ms)^# Managed by LocalAcceleratorRoutingWatcher\.ps1: honor local accelerator hosts\.\r?\ndns:\r?\n  use-system-hosts: true\r?\n?'
        return $managed.Replace($Content, '', 1)
    }
    if ($dnsMatch.Success) {
        $dnsBlock = $dnsMatch.Value
        if ($Original.UseSystemHostsPresent) {
            $value = if ($Original.UseSystemHosts) { 'true' } else { 'false' }
            $usePattern = [regex]'(?m)^(?<indent>  |\t)use-system-hosts:[ \t]*(?:true|false)[ \t]*(?<ending>\r?\n|$)'
            $updatedBlock = $usePattern.Replace($dnsBlock, "`${indent}use-system-hosts: $value`${ending}", 1)
        } else {
            $updatedBlock = [regex]::Replace($dnsBlock, '(?m)^(?:  |\t)use-system-hosts:[^\r\n]*(?:\r?\n|$)', '', 1)
        }
        return $Content.Substring(0, $dnsMatch.Index) + $updatedBlock + $Content.Substring($dnsMatch.Index + $dnsMatch.Length)
    }
    return $Content
}

function Remove-ManagedRoutingBlock {
    param([string]$Content)
    $blockPattern = [regex]'(?ms)^[ \t]{2}# BEGIN (?:Steam(?: and GitHub)?|Local) accelerator routing\r?\n.*?^[ \t]{2}# END (?:Steam(?: and GitHub)?|Local) accelerator routing\r?\n?'
    $legacyStaticBlockPattern = [regex]'(?ms)^(?:[ \t]{2}# Let local Steam accelerators handle Steam traffic instead of this subscription\.\r?\n)?(?:[ \t]{2}-\s+[''\"]?DOMAIN-SUFFIX,(?:steampowered\.com|steamcommunity\.com|steamstatic\.com|steamusercontent\.com|steamcontent\.com|steam-chat\.com|steamserver\.net),DIRECT[''\"]?\s*\r?\n){7}'
    return $legacyStaticBlockPattern.Replace($blockPattern.Replace($Content, '', 1), '', 1)
}

function Add-ManagedRoutingBlock {
    param([string]$Content, [string]$Block, [string]$NewLine, [string]$Path)
    $prependPattern = [regex]'(?m)^prepend:\r?\n'
    if (-not $prependPattern.IsMatch($Content)) { throw "Invalid routing profile (missing prepend): $Path" }
    return $prependPattern.Replace($Content, "prepend:$NewLine$Block$NewLine", 1)
}

function Test-RoutingContent {
    param([string]$Content, [bool]$Active, [string]$Path)
    $beginCount = ([regex]::Matches($Content, '(?m)^[ \t]{2}# BEGIN Local accelerator routing\r?$')).Count
    $endCount = ([regex]::Matches($Content, '(?m)^[ \t]{2}# END Local accelerator routing\r?$')).Count
    if ($beginCount -ne $endCount -or $beginCount -gt 1) { throw "Managed routing block validation failed: $Path" }
    if ($Active -and $beginCount -ne 1) { throw "Active routing block missing after update: $Path" }
    if (-not $Active -and $beginCount -ne 0) { throw "Inactive routing block remains after update: $Path" }
    return $true
}

function Invoke-AtomicFilePlans {
    param([object[]]$Plans)
    $changedPlans = @($Plans | Where-Object { $_.OldContent -ne $_.NewContent })
    if ($changedPlans.Count -eq 0) { return @() }
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $prepared = @()
    $committed = @()
    try {
        foreach ($plan in $changedPlans) {
            $temp = "$($plan.Path).$([guid]::NewGuid().ToString('N')).tmp"
            Write-Utf8File -Path $temp -Content $plan.NewContent -HasBom ([bool]$plan.HasBom)
            $check = Get-Utf8File -Path $temp
            # Compare decoded content here. The byte hash intentionally
            # includes a preserved UTF-8 BOM, while the planned text hash does
            # not; comparing those two byte representations would reject every
            # BOM-bearing profile even though the file content is valid.
            if ($check.Content -ne $plan.NewContent) {
                throw "Temporary file validation failed: $($plan.Path)"
            }
            $prepared += [pscustomobject]@{ Plan = $plan; Temp = $temp }
        }
        foreach ($item in $prepared) {
            $leaf = Split-Path -Leaf $item.Plan.Path
            $backup = Join-Path $backupDirectory ("$leaf.$(Get-Date -Format 'yyyyMMdd-HHmmss').$([guid]::NewGuid().ToString('N')).bak")
            [System.IO.File]::Replace($item.Temp, $item.Plan.Path, $backup, $true)
            $committed += [pscustomobject]@{ Path = $item.Plan.Path; Backup = $backup }
        }
        return $committed
    } catch {
        for ($index = $committed.Count - 1; $index -ge 0; $index--) {
            $item = $committed[$index]
            try { [System.IO.File]::Copy($item.Backup, $item.Path, $true) } catch { Write-Log "Rollback failed for $($item.Path): $($_.Exception.Message)" }
        }
        throw
    } finally {
        foreach ($item in $prepared) {
            if (Test-Path -LiteralPath $item.Temp) { Remove-Item -LiteralPath $item.Temp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-TargetFingerprint {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $profilePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $parts.Add("$path=$((Get-Utf8File -Path $path).Hash)") } else { $parts.Add("$path=MISSING") }
    }
    if (-not [string]::IsNullOrWhiteSpace($globalMergePath)) {
        if (Test-Path -LiteralPath $globalMergePath -PathType Leaf) { $parts.Add("$globalMergePath=$((Get-Utf8File -Path $globalMergePath).Hash)") } else { $parts.Add("$globalMergePath=MISSING") }
    }
    return Get-Sha256Text -Text ($parts -join "`n")
}

function Find-ByteSequence {
    param(
        [byte[]]$Buffer,
        [byte[]]$Needle,
        [int]$Start = 0
    )
    for ($index = $Start; $index -le $Buffer.Length - $Needle.Length; $index++) {
        $found = $true
        for ($offset = 0; $offset -lt $Needle.Length; $offset++) {
            if ($Buffer[$index + $offset] -ne $Needle[$offset]) {
                $found = $false
                break
            }
        }
        if ($found) { return $index }
    }
    return -1
}

function ConvertFrom-ChunkedHttpBody {
    param(
        [byte[]]$Buffer,
        [int]$BodyStart
    )
    $body = New-Object System.IO.MemoryStream
    $offset = $BodyStart
    while ($true) {
        $lineEnd = Find-ByteSequence -Buffer $Buffer -Needle ([byte[]](13, 10)) -Start $offset
        if ($lineEnd -lt 0) {
            return [pscustomobject]@{ Complete = $false; Body = $null }
        }
        $sizeText = [System.Text.Encoding]::ASCII.GetString($Buffer, $offset, $lineEnd - $offset).Trim().Split(';')[0]
        try { $size = [Convert]::ToInt32($sizeText, 16) } catch {
            throw "Invalid chunk size '$sizeText'."
        }
        $chunkStart = $lineEnd + 2
        if ($size -eq 0) {
            if ($Buffer.Length -lt $chunkStart + 2) {
                return [pscustomobject]@{ Complete = $false; Body = $null }
            }
            return [pscustomobject]@{ Complete = $true; Body = [System.Text.Encoding]::UTF8.GetString($body.ToArray()) }
        }
        if ($Buffer.Length -lt $chunkStart + $size + 2) {
            return [pscustomobject]@{ Complete = $false; Body = $null }
        }
        $body.Write($Buffer, $chunkStart, $size)
        $offset = $chunkStart + $size + 2
    }
}

function Get-MihomoControllerSettings {
    $address = $controllerAddressOverride
    $pipePath = $controllerPipeOverride
    $secret = ''
    if (-not [string]::IsNullOrWhiteSpace($controllerConfigPath) -and (Test-Path -LiteralPath $controllerConfigPath -PathType Leaf)) {
        try {
            $content = Get-Content -Raw -LiteralPath $controllerConfigPath -Encoding utf8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($address) -and $content -match '(?im)^external-controller:\s*["'']?(?<value>[^"''\s]*)["'']?\s*$') { $address = $matches.value }
            if ([string]::IsNullOrWhiteSpace($pipePath) -and $content -match '(?im)^external-controller-pipe:\s*["'']?(?<value>[^"''\s]+)["'']?\s*$') { $pipePath = $matches.value }
            if ($content -match '(?im)^secret:\s*["'']?(?<value>[^"''\r\n]*)["'']?\s*$') { $secret = $matches.value.Trim() }
        } catch {
            Write-Log "Mihomo controller config could not be read; connection refresh skipped: $($_.Exception.Message)"
            return $null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($pipePath)) {
        $pipePath = $pipePath.Trim().Trim('"').Trim("'")
        if ($pipePath -notmatch '^\\\\\.\\pipe\\[^\\/]+$') {
            Write-Log 'Mihomo controller pipe path is not a local named pipe; connection refresh skipped.'
            return $null
        }
    }
    $address = $address.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($pipePath) -and [string]::IsNullOrWhiteSpace($address)) {
        return $null
    }
    [pscustomobject]@{ Address = $address; PipePath = $pipePath; Secret = $secret }
}

function Invoke-MihomoNamedPipeRequest {
    param(
        [string]$PipePath,
        [string]$Path,
        [string]$Method,
        [string]$Secret,
        [int]$TimeoutMilliseconds
    )
    $pipeName = $PipePath.Substring('\\.\pipe\'.Length)
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect($TimeoutMilliseconds)
        $request = "$Method $Path HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`n"
        if (-not [string]::IsNullOrWhiteSpace($Secret)) { $request += "Authorization: Bearer $Secret`r`n" }
        $request += "`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($request)
        $pipe.Write($requestBytes, 0, $requestBytes.Length)
        $pipe.Flush()
        $all = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 65536
        $headerStart = [byte[]](13, 10, 13, 10)
        $headerEnd = -1
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        $complete = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            $readTask = $pipe.ReadAsync($buffer, 0, $buffer.Length)
            $remaining = [Math]::Max(100, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $readTask.Wait([Math]::Min(1000, $remaining))) { break }
            if ($readTask.IsFaulted) { throw $readTask.Exception.InnerException }
            $readCount = $readTask.Result
            if ($readCount -le 0) { break }
            $all.Write($buffer, 0, $readCount)
            $raw = $all.ToArray()
            if ($headerEnd -lt 0) {
                $headerEnd = Find-ByteSequence -Buffer $raw -Needle $headerStart
                if ($headerEnd -ge 0) { $headerEnd += 4 }
            }
            if ($headerEnd -ge 0) {
                $header = [System.Text.Encoding]::ASCII.GetString($raw, 0, $headerEnd)
                if ($header -match '(?im)^Transfer-Encoding:\s*chunked') {
                    $chunked = ConvertFrom-ChunkedHttpBody -Buffer $raw -BodyStart $headerEnd
                    if ($chunked.Complete) { $complete = $true; break }
                } elseif ($header -match '(?im)^Content-Length:\s*(?<length>\d+)\s*$') {
                    if ($raw.Length -ge $headerEnd + [int]$matches.length) { $complete = $true; break }
                } else {
                    # 204 responses have no body; a closed pipe is sufficient.
                    if ($readCount -eq 0) { $complete = $true; break }
                }
            }
        }
        $raw = $all.ToArray()
        if ($headerEnd -lt 0) { throw 'Mihomo controller returned no HTTP headers.' }
        $header = [System.Text.Encoding]::ASCII.GetString($raw, 0, $headerEnd)
        $status = 0
        if ($header -match '^HTTP/\S+\s+(?<status>\d+)') { $status = [int]$matches.status }
        $body = ''
        if ($header -match '(?im)^Transfer-Encoding:\s*chunked') {
            $chunked = ConvertFrom-ChunkedHttpBody -Buffer $raw -BodyStart $headerEnd
            if (-not $chunked.Complete) { throw 'Mihomo controller returned an incomplete chunked response.' }
            $body = [string]$chunked.Body
        } elseif ($header -match '(?im)^Content-Length:\s*(?<length>\d+)\s*$') {
            $bodyLength = [int]$matches.length
            if ($raw.Length -lt $headerEnd + $bodyLength) { throw 'Mihomo controller returned an incomplete response.' }
            $body = [System.Text.Encoding]::UTF8.GetString($raw, $headerEnd, $bodyLength)
        } elseif ($raw.Length -gt $headerEnd) {
            $body = [System.Text.Encoding]::UTF8.GetString($raw, $headerEnd, $raw.Length - $headerEnd)
        }
        [pscustomobject]@{ Status = $status; Body = $body }
    } finally {
        $pipe.Dispose()
    }
}

function Invoke-MihomoControllerRequest {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        [object]$Settings
    )
    if ($null -eq $Settings) { $Settings = Get-MihomoControllerSettings }
    if ($null -eq $Settings) { throw 'Mihomo controller is not configured.' }
    if (-not [string]::IsNullOrWhiteSpace($Settings.PipePath)) {
        return Invoke-MihomoNamedPipeRequest -PipePath $Settings.PipePath -Path $Path -Method $Method -Secret $Settings.Secret -TimeoutMilliseconds $connectionRefreshTimeoutMilliseconds
    }
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($Settings.Secret)) { $headers.Authorization = "Bearer $($Settings.Secret)" }
    $response = Invoke-WebRequest -Uri ("http://{0}{1}" -f $Settings.Address, $Path) -Method $Method -Headers $headers -TimeoutSec ([Math]::Ceiling($connectionRefreshTimeoutMilliseconds / 1000)) -UseBasicParsing -ErrorAction Stop
    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = [string]$response.Content }
}

function Test-ManagedHost {
    param(
        [string]$HostName,
        [object]$HostsInfo
    )
    $normalizedHost = $HostName.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedHost)) { return $false }
    foreach ($rule in @($HostsInfo.Rules)) {
        $parts = $rule.Trim() -split ','
        if ($parts.Count -lt 2) { continue }
        $ruleType = $parts[0].Trim().TrimStart('-').Trim().ToUpperInvariant()
        $domain = $parts[1].Trim().TrimEnd('.').ToLowerInvariant()
        if ($ruleType -eq 'DOMAIN' -and $normalizedHost -eq $domain) { return $true }
        if ($ruleType -eq 'DOMAIN-SUFFIX' -and ($normalizedHost -eq $domain -or $normalizedHost.EndsWith(".$domain", [System.StringComparison]::OrdinalIgnoreCase))) { return $true }
    }
    return $false
}

function Select-MihomoConnectionsForRefresh {
    param(
        [object[]]$Connections,
        [object]$HostsInfo,
        [string]$Mode = 'None'
    )
    $normalizeProcessName = {
        param([string]$Name)
        [System.IO.Path]::GetFileName([string]$Name) -replace '(?i)\.exe$', ''
    }
    $sharedSteamProcesses = @('steam', 'steamwebhelper', 'steamservice')
    $steam302Processes = @('steamcommunity_302', 'steamcommunity_302.cli', 'steamcommunity_302.caddy')
    $wattProcesses = @($wattProcessName, 'Steam++.Accelerator') | ForEach-Object { & $normalizeProcessName ([string]$_) } | Sort-Object -Unique
    $configuredProcesses = @($managedConnectionProcesses | ForEach-Object { & $normalizeProcessName ([string]$_) })
    $knownAcceleratorProcesses = @($sharedSteamProcesses + $steam302Processes + $wattProcesses)
    $otherManagedProcesses = @($configuredProcesses | Where-Object { $_ -notin $knownAcceleratorProcesses })
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($connection in @($Connections)) {
        $id = [string]$connection.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $metadata = $connection.metadata
        $process = & $normalizeProcessName ([string]$metadata.process)
        # A managed Hosts hit is mode-independent (it covers the client/browser
        # first leg). Process-only fallback is mode-aware so a stale Watt or 302
        # upstream cannot be closed merely because the other accelerator is active.
        $processHit = $process -in $sharedSteamProcesses -or $process -in $otherManagedProcesses
        if (-not $processHit) {
            switch ($Mode) {
                'Steamcommunity_302' { $processHit = $process -in $steam302Processes }
                'Watt' { $processHit = $process -in $wattProcesses }
            }
        }
        $hostHit = Test-ManagedHost -HostName ([string]$metadata.host) -HostsInfo $HostsInfo
        if ($processHit -or $hostHit) { $selected.Add($connection) }
    }
    return @($selected)
}

function Test-RuntimeRoutingReady {
    param([object]$HostsInfo)
    if ([string]::IsNullOrWhiteSpace($runtimeConfigPath) -or -not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
        Write-Log 'Connection refresh skipped: RuntimeConfigPath is missing or does not exist.'
        return $false
    }
    try { $content = Get-Utf8File -Path $runtimeConfigPath } catch {
        Write-Log "Connection refresh skipped: runtime config could not be read: $($_.Exception.Message)"
        return $false
    }
    if ($content.Content -notmatch '(?im)^\s*use-system-hosts:\s*true\s*$') {
        Write-Log 'Connection refresh skipped: runtime config does not have use-system-hosts=true.'
        return $false
    }
    $requiredProcessRules = @(
        'PROCESS-NAME,Steam++.Accelerator.exe,',
        'PROCESS-NAME,steamcommunity_302.caddy.exe,',
        'PROCESS-NAME,steamcommunity_302.cli.exe,',
        'PROCESS-NAME,steamcommunity_302.exe,',
        'PROCESS-NAME,Steam++.Accelerator,',
        'PROCESS-NAME,steamcommunity_302.caddy,',
        'PROCESS-NAME,steamcommunity_302.cli,',
        'PROCESS-NAME,steamcommunity_302,'
    )
    foreach ($rulePrefix in $requiredProcessRules) {
        if ($content.Content -notmatch "(?im)^\s*-\s*$([regex]::Escape($rulePrefix)).+$") {
            Write-Log "Connection refresh skipped: runtime config is missing $rulePrefix."
            return $false
        }
    }
    foreach ($rule in @($HostsInfo.Rules)) {
        $needle = [regex]::Escape($rule.Trim())
        if ($content.Content -notmatch "(?im)^\s*$needle\s*$") {
            Write-Log 'Connection refresh skipped: runtime config is missing one or more current Hosts rules.'
            return $false
        }
    }
    return $true
}

function Get-MihomoManagedRuleAudit {
    param([object]$HostsInfo, [object[]]$Rules)
    $expected = [System.Collections.Generic.List[object]]::new()
    foreach ($required in @(
        @{ Type = 'ProcessName'; Payload = 'Steam++.Accelerator.exe' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302.caddy.exe' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302.cli.exe' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302.exe' }
        @{ Type = 'ProcessName'; Payload = 'Steam++.Accelerator' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302.caddy' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302.cli' }
        @{ Type = 'ProcessName'; Payload = 'steamcommunity_302' }
    )) {
        $expected.Add([pscustomobject]@{ Type = $required.Type; Payload = $required.Payload; Proxy = 'DIRECT' })
    }
    foreach ($sourceRule in @($HostsInfo.Rules)) {
        $parts = $sourceRule.Trim().TrimStart('-').Trim() -split ','
        if ($parts.Count -lt 3) { continue }
        $type = switch ($parts[0].Trim().ToUpperInvariant()) {
            'DOMAIN' { 'Domain' }
            'DOMAIN-SUFFIX' { 'DomainSuffix' }
            default { '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($type)) {
            $expected.Add([pscustomobject]@{ Type = $type; Payload = $parts[1].Trim(); Proxy = $parts[2].Trim() })
        }
    }
    $actualByKey = @{}
    for ($ruleIndex = 0; $ruleIndex -lt @($Rules).Count; $ruleIndex++) {
        $rule = $Rules[$ruleIndex]
        $key = ("{0}|{1}|{2}" -f [string]$rule.type, [string]$rule.payload, [string]$rule.proxy).ToLowerInvariant()
        if (-not $actualByKey.ContainsKey($key)) { $actualByKey[$key] = [System.Collections.Generic.List[int]]::new() }
        [void]$actualByKey[$key].Add($ruleIndex)
    }
    $managedIndexes = [System.Collections.Generic.List[int]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $duplicates = [System.Collections.Generic.List[string]]::new()
    foreach ($required in @($expected)) {
        $key = ("{0}|{1}|{2}" -f $required.Type, $required.Payload, $required.Proxy).ToLowerInvariant()
        $matches = if ($actualByKey.ContainsKey($key)) { @($actualByKey[$key]) } else { @() }
        if ($matches.Count -eq 0) {
            [void]$missing.Add("$($required.Type):$($required.Payload):$($required.Proxy)")
        } else {
            foreach ($index in $matches) { [void]$managedIndexes.Add([int]$index) }
            if ($matches.Count -gt 1) { [void]$duplicates.Add("$($required.Type):$($required.Payload):$($required.Proxy)") }
        }
    }
    $relatedIndexes = @(
        for ($ruleIndex = 0; $ruleIndex -lt @($Rules).Count; $ruleIndex++) {
            $rule = $Rules[$ruleIndex]
            if ([string]$rule.proxy -ne 'DIRECT' -and
                [string]$rule.type -in @('DomainKeyword', 'DomainSuffix', 'Domain') -and
                [string]$rule.payload -match '(?i)steam') { $ruleIndex }
        }
    )
    $orderViolations = @()
    if ($relatedIndexes.Count -gt 0) {
        $firstRelated = ($relatedIndexes | Measure-Object -Minimum).Minimum
        $orderViolations = @($managedIndexes | Where-Object { $_ -gt $firstRelated } | Sort-Object -Unique)
    }
    [pscustomobject]@{
        ExpectedCount = $expected.Count
        RuntimeManagedRuleCount = $managedIndexes.Count
        MissingCount = $missing.Count
        Missing = @($missing)
        DuplicateCount = $duplicates.Count
        Duplicates = @($duplicates)
        OrderViolationCount = $orderViolations.Count
        OrderViolationIndexes = @($orderViolations | ForEach-Object { [int]$_ + 1 })
        RelatedSubscriptionRuleCount = $relatedIndexes.Count
    }
}

function Test-MihomoRuntimeRulesReady {
    param(
        [object]$HostsInfo,
        [object]$Settings
    )
    try {
        $response = Invoke-MihomoControllerRequest -Path '/rules' -Method 'GET' -Settings $Settings
        if ($response.Status -ne 200) {
            Write-Log "Connection refresh skipped: Mihomo /rules returned HTTP $($response.Status)."
            return $false
        }
        $payload = $response.Body | ConvertFrom-Json -ErrorAction Stop
        $rules = @($payload.rules)
        $audit = Get-MihomoManagedRuleAudit -HostsInfo $HostsInfo -Rules $rules
        Write-Log "Mihomo rule audit: expected=$($audit.ExpectedCount); runtimeManaged=$($audit.RuntimeManagedRuleCount); missing=$($audit.MissingCount); duplicates=$($audit.DuplicateCount); orderViolations=$($audit.OrderViolationCount); subscriptionRelated=$($audit.RelatedSubscriptionRuleCount)"
        if ($audit.MissingCount -gt 0 -or $audit.DuplicateCount -gt 0 -or $audit.OrderViolationCount -gt 0) {
            Write-Log 'Connection refresh skipped: final Mihomo /rules failed the complete managed-rule audit; override may not be loaded or may be shadowed.'
            return $false
        }
        return $true
    } catch {
        Write-Log "Connection refresh skipped: final Mihomo /rules could not be verified: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-ConnectionRefresh {
    param(
        [object]$HostsInfo,
        [string]$Mode
    )
    if (-not $connectionRefreshEnabled -or -not $connectionRefreshOnRoutingChange -or $Mode -eq 'None') { return }
    if (-not (Test-RuntimeRoutingReady -HostsInfo $HostsInfo)) { return }
    try {
        $settings = Get-MihomoControllerSettings
        if ($null -eq $settings) {
            Write-Log 'Connection refresh skipped: no local Mihomo controller address or pipe was available.'
            return
        }
        if (-not (Test-MihomoRuntimeRulesReady -HostsInfo $HostsInfo -Settings $settings)) { return }
        $connectionsResponse = Invoke-MihomoControllerRequest -Path '/connections' -Method 'GET' -Settings $settings
        if ($connectionsResponse.Status -ne 200) {
            Write-Log "Connection refresh skipped: Mihomo /connections returned HTTP $($connectionsResponse.Status)."
            return
        }
        $payload = $connectionsResponse.Body | ConvertFrom-Json -ErrorAction Stop
        $selected = @(Select-MihomoConnectionsForRefresh -Connections @($payload.connections) -HostsInfo $HostsInfo -Mode $Mode)
        if ($selected.Count -gt $connectionRefreshMaxConnections) {
            Write-Log "Connection refresh refused: $($selected.Count) eligible connections exceeds safety limit $connectionRefreshMaxConnections."
            return
        }
        if ($connectionRefreshFlushFakeIp) {
            try {
                $flush = Invoke-MihomoControllerRequest -Path '/cache/fakeip/flush' -Method 'POST' -Settings $settings
                Write-Log "Connection refresh fake-ip flush returned HTTP $($flush.Status)."
            } catch {
                Write-Log "Connection refresh fake-ip flush failed; continuing with selected connections only: $($_.Exception.Message)"
            }
        }
        $closed = 0
        foreach ($connection in $selected) {
            try {
                $idPath = [Uri]::EscapeDataString([string]$connection.id)
                $closedResponse = Invoke-MihomoControllerRequest -Path "/connections/$idPath" -Method 'DELETE' -Settings $settings
                if ($closedResponse.Status -ge 200 -and $closedResponse.Status -lt 300) { $closed++ }
            } catch {
                Write-Log "Connection refresh could not close one selected connection: $($_.Exception.Message)"
            }
        }
        Write-Log "Connection refresh completed for mode '$Mode': eligible=$($selected.Count), closed=$closed; no unfiltered connection deletion was attempted."
    } catch {
        Write-Log "Connection refresh failed safely; watcher continues without terminating connections: $($_.Exception.Message)"
    }
}

function Set-AcceleratorRouting {
    param(
        [bool]$AcceleratorRunning,
        [object]$HostsInfo,
        [object]$State
    )
    $workingSnapshots = @(Copy-DnsSnapshots -Snapshots $State.DnsSnapshots)
    $plans = [System.Collections.Generic.List[object]]::new()
    $targetPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($profile in $profiles) {
        $targetPaths.Add($profile.Path)
        if (-not (Test-Path -LiteralPath $profile.Path -PathType Leaf)) { throw "Clash routing profile not found: $($profile.Path)" }
        $file = Get-Utf8File -Path $profile.Path
        $snapshot = Find-Snapshot -Snapshots $workingSnapshots -Path $profile.Path
        if ($AcceleratorRunning -and $ensureSystemHosts -and $null -eq $snapshot) {
            $original = Get-DnsSnapshot -Content $file.Content
            $snapshot = [pscustomobject]@{ Path = $profile.Path; DnsPresent = $original.DnsPresent; UseSystemHostsPresent = $original.UseSystemHostsPresent; UseSystemHosts = $original.UseSystemHosts }
            $workingSnapshots += $snapshot
        }
        $newLine = Get-NewLine -Content $file.Content
        $clean = Remove-ManagedRoutingBlock -Content $file.Content
        if ($AcceleratorRunning) {
            $block = New-LocalAcceleratorRoutingBlock -AcceleratorPolicy $profile.AcceleratorPolicy -DomainRules $HostsInfo.Rules
            $updated = if ([string]::IsNullOrWhiteSpace($block)) { $clean } else { Add-ManagedRoutingBlock -Content $clean -Block ([regex]::Replace($block, '\r?\n', $newLine)) -NewLine $newLine -Path $profile.Path }
            if ($ensureSystemHosts) { $updated = Set-DnsSystemHosts -Content $updated -Enabled $true -Original $snapshot -NewLine $newLine }
        } else {
            $updated = $clean
            if ($ensureSystemHosts) { $updated = Set-DnsSystemHosts -Content $updated -Enabled $false -Original $snapshot -NewLine $newLine }
        }
        Test-RoutingContent -Content $updated -Active ($AcceleratorRunning -and @($HostsInfo.Rules).Count -gt 0) -Path $profile.Path | Out-Null
        if ($updated -ne $file.Content) { $plans.Add([pscustomobject]@{ Path = $profile.Path; OldContent = $file.Content; NewContent = $updated; HasBom = $file.HasBom }) }
    }

    if (-not [string]::IsNullOrWhiteSpace($globalMergePath)) {
        $targetPaths.Add($globalMergePath)
        if (-not (Test-Path -LiteralPath $globalMergePath -PathType Leaf)) { throw "Global Merge profile not found: $globalMergePath" }
        $merge = Get-Utf8File -Path $globalMergePath
        $snapshot = Find-Snapshot -Snapshots $workingSnapshots -Path $globalMergePath
        if ($AcceleratorRunning -and $ensureSystemHosts -and $null -eq $snapshot) {
            $original = Get-DnsSnapshot -Content $merge.Content
            $snapshot = [pscustomobject]@{ Path = $globalMergePath; DnsPresent = $original.DnsPresent; UseSystemHostsPresent = $original.UseSystemHostsPresent; UseSystemHosts = $original.UseSystemHosts }
            $workingSnapshots += $snapshot
        }
        if ($ensureSystemHosts) {
            $updatedMerge = Set-DnsSystemHosts -Content $merge.Content -Enabled $AcceleratorRunning -Original $snapshot -NewLine (Get-NewLine -Content $merge.Content)
            if ($updatedMerge -ne $merge.Content) { $plans.Add([pscustomobject]@{ Path = $globalMergePath; OldContent = $merge.Content; NewContent = $updatedMerge; HasBom = $merge.HasBom }) }
        }
    }

    $stateChanged = $false
    if ($AcceleratorRunning -and $ensureSystemHosts) {
        $stateChanged = (ConvertTo-Json @(Copy-DnsSnapshots -Snapshots $State.DnsSnapshots) -Depth 8) -ne (ConvertTo-Json @(Copy-DnsSnapshots -Snapshots $workingSnapshots) -Depth 8)
        if ($stateChanged) { Save-State -Snapshots $workingSnapshots }
    }
    $committed = Invoke-AtomicFilePlans -Plans @($plans)
    if (-not $AcceleratorRunning -and @($workingSnapshots).Count -gt 0) {
        Save-State -Snapshots @()
        $stateChanged = $true
    }
    [pscustomobject]@{ Changed = (@($committed).Count -gt 0 -or $stateChanged); Files = @($committed); State = [pscustomobject]@{ DnsSnapshots = @(if ($AcceleratorRunning) { $workingSnapshots } else { @() }) } }
}

function Get-ConfiguredClashGuiProcesses {
    param([string]$Executable)

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($Executable)
    $expectedPath = [System.IO.Path]::GetFullPath($Executable)
    $allClients = @(
        Get-Process -Name $processName -ErrorAction SilentlyContinue
    )
    $clients = @()
    $pathGuardFailures = @()
    foreach ($client in $allClients) {
        try {
            $actualPath = [string]$client.Path
            if ([string]::IsNullOrWhiteSpace($actualPath)) {
                $pathGuardFailures += "PID $($client.Id) has no readable ExecutablePath"
            } elseif (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFullPath($actualPath), $expectedPath)) {
                $pathGuardFailures += "PID $($client.Id) path '$actualPath' does not equal '$expectedPath'"
            } else {
                $clients += $client
            }
        } catch {
            $pathGuardFailures += "PID $($client.Id) ExecutablePath could not be verified: $($_.Exception.Message)"
        }
    }
    if ($pathGuardFailures.Count -gt 0) {
        throw "Clash GUI path guard refused the operation: $($pathGuardFailures -join '; ')"
    }
    return @($clients)
}

function Resolve-ClashGuiExecutable {
    if ([string]::IsNullOrWhiteSpace($config.ClashExecutable)) {
        return ''
    }
    $executable = Resolve-ConfiguredPath -Path ([string]$config.ClashExecutable)
    if ([System.IO.Path]::GetFileName($executable) -ine 'clash-verge.exe') {
        throw "Restart only accepts the Clash Verge GUI executable named clash-verge.exe: $executable"
    }
    return $executable
}

function Restart-RunningClientGracefully {
    if ($SkipClientReload -or $clientRestartMode -eq 'Disabled' -or [string]::IsNullOrWhiteSpace($config.ClashExecutable)) {
        Write-Log 'Routing files updated; client restart disabled.'
        return
    }
    $executable = Resolve-ClashGuiExecutable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        Write-Log "Routing files updated; client executable not found: $executable"
        return
    }
    $clients = @(Get-ConfiguredClashGuiProcesses -Executable $executable)
    if ($clients.Count -eq 0) {
        Write-Log 'Routing files updated; Clash is not running and will use them at next start.'
        return
    }
    foreach ($client in $clients) {
        if ($client.MainWindowHandle -eq 0 -or -not $client.CloseMainWindow()) {
            Write-Log "Routing files updated; cannot request a graceful close for PID $($client.Id). No force-stop was attempted."
            return
        }
    }
    $waitMilliseconds = $restartGraceSeconds * 1000
    $sleepMilliseconds = 250
    $deadline = (Get-Date).AddMilliseconds($waitMilliseconds)
    do {
        $alive = @($clients | Where-Object { -not $_.HasExited })
        if ($alive.Count -eq 0) { break }
        if ($waitMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    } while ((Get-Date) -lt $deadline)
    if (@($clients | Where-Object { -not $_.HasExited }).Count -gt 0) {
        Write-Log "Routing files updated; Clash did not exit within $restartGraceSeconds seconds. No fast termination was attempted. Rules will not load until the user restarts Clash Verge."
        return
    }
    Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -ErrorAction Stop | Out-Null
    Write-Log 'Restarted the running Clash GUI with a graceful close after local accelerator routing change.'
}

function Restart-RunningClientFast {
    if ($SkipClientReload -or $clientRestartMode -eq 'Disabled' -or [string]::IsNullOrWhiteSpace($config.ClashExecutable)) {
        Write-Log 'Routing files updated; client restart disabled.'
        return
    }
    $executable = Resolve-ClashGuiExecutable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        Write-Log "Routing files updated; client executable not found: $executable"
        return
    }

    # Fast mode intentionally skips the graceful window message: Clash Verge
    # may only minimize to the tray while its WebView is already disconnected.
    # The path guard must complete for every same-name process before any PID
    # is terminated, so service/core processes and other installations remain untouched.
    $clients = @(Get-ConfiguredClashGuiProcesses -Executable $executable)
    if ($clients.Count -eq 0) {
        Write-Log 'Routing files updated; Clash is not running and will use them at next start.'
        return
    }

    $restartStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($client in $clients) {
        try {
            Stop-Process -Id ([int]$client.Id) -Force -ErrorAction Stop
        } catch {
            Write-Log "Fast mode failed to terminate the verified Clash GUI PID $($client.Id): $($_.Exception.Message). No second GUI was started."
            return
        }
    }

    $deadline = (Get-Date).AddMilliseconds($fastRestartConfirmMilliseconds)
    do {
        $alive = @($clients | Where-Object {
            try { -not $_.HasExited } catch { $false }
        })
        if ($alive.Count -eq 0) { break }
        if ($fastRestartConfirmMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(25, $fastRestartConfirmMilliseconds))
        }
    } while ((Get-Date) -lt $deadline)

    if (@($clients | Where-Object {
        try { -not $_.HasExited } catch { $false }
    }).Count -gt 0) {
        Write-Log "Fast mode could not confirm Clash GUI exit within $fastRestartConfirmMilliseconds ms. No second GUI was started."
        return
    }

    Write-Log "Fast mode confirmed GUI exit; waiting $fastRestartSettleMilliseconds ms for WebView2/EBWebView resources to settle."
    Start-Sleep -Milliseconds $fastRestartSettleMilliseconds
    try {
        $started = Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -PassThru -ErrorAction Stop
    } catch {
        Write-Log "Fast mode terminated the verified Clash GUI but could not start '$executable': $($_.Exception.Message)"
        return
    }
    $restartStopwatch.Stop()
    $restartMilliseconds = [Math]::Round($restartStopwatch.Elapsed.TotalMilliseconds, 0)
    Write-Log "Restarted verified Clash GUI PID(s) $($clients.Id -join ',') in Fast mode; new PID $($started.Id), measured stop-to-start interval ${restartMilliseconds} ms, no fixed delay; expected brief proxy/TUN interruption: about 1-2 seconds."
}

function Restart-RunningClient {
    if ($SkipClientReload -or $clientRestartMode -eq 'Disabled') {
        Write-Log 'Routing files updated; client restart disabled.'
        return
    }
    if ($clientRestartMode -eq 'Fast') {
        Restart-RunningClientFast
    } else {
        Restart-RunningClientGracefully
    }
}

$state = Load-State
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-Log 'Another watcher instance is already running; exiting.'
        return
    }

    if ($RestartClientOnly) {
        Restart-RunningClient
        return
    }

    $lastObservation = $null
    $lastOutputFingerprint = $null
    $candidateObservation = $null
    $candidateCount = 0
    $lastWattDiagnosticFingerprint = $null
    do {
        try {
            $acceleratorState = Get-AcceleratorState
            $hostsInfo = Get-HostsRules
            $wattDiagnostics = $acceleratorState.WattDiagnostics
            if ($wattDiagnostics.Fingerprint -ne $lastWattDiagnosticFingerprint) {
                if ($wattDiagnostics.Status -eq 'NotReady') {
                    $observedPorts = if (@($wattDiagnostics.ObservedPorts).Count -gt 0) { @($wattDiagnostics.ObservedPorts) -join ',' } else { 'none' }
                    Write-Log "Watt detected but not ready: expected listener ports $($wattProxyPorts -join ','); observed Watt-associated ports $observedPorts. Candidate(s): $($wattDiagnostics.CandidateProcesses -join '; ')"
                } elseif ($wattDiagnostics.Status -eq 'Active' -and $acceleratorState.Mode -eq 'Steamcommunity_302') {
                    Write-Log '302 active; Watt is listening but is shadowed by Steamcommunity_302 priority.'
                }
                $lastWattDiagnosticFingerprint = $wattDiagnostics.Fingerprint
            }
            $observation = "$($acceleratorState.Mode)|$($hostsInfo.ContentHash)|$($hostsInfo.Rules.Count)"
            if ($observation -eq $candidateObservation) { $candidateCount++ } else { $candidateObservation = $observation; $candidateCount = 1 }
            $requiredSamples = if ($Once) { 1 } else { $stableSamples }
            $outputFingerprint = Get-TargetFingerprint
            $needsReconcile = $candidateCount -ge $requiredSamples -and ($lastObservation -ne $observation -or $lastOutputFingerprint -ne $outputFingerprint)
            if ($needsReconcile) {
                $result = Set-AcceleratorRouting -AcceleratorRunning $acceleratorState.Direct -HostsInfo $hostsInfo -State $state
                $state = if ($acceleratorState.Direct -and $ensureSystemHosts) { $result.State } else { [pscustomobject]@{ DnsSnapshots = @() } }
                switch ($acceleratorState.Mode) {
                    'Watt' { Write-Log 'accelerator active: Watt; Hosts domains DIRECT to local accelerator; accelerator process uses configured AcceleratorPolicy' }
                    'Steamcommunity_302' { if ($acceleratorState.Sources -contains 'Watt') { Write-Log 'accelerator priority: Steamcommunity_302 selected while Watt is also listening' } else { Write-Log 'accelerator active: Steamcommunity_302; Hosts domains DIRECT to local accelerator' } }
                    default { Write-Log 'no accelerator: restored subscription routing and original dns.use-system-hosts state' }
                }
                if ($result.Changed) {
                    Restart-RunningClient
                    Invoke-ConnectionRefresh -HostsInfo $hostsInfo -Mode $acceleratorState.Mode
                }
                $lastObservation = $observation
                $lastOutputFingerprint = Get-TargetFingerprint
                $candidateObservation = $null
                $candidateCount = 0
            }
        } catch {
            Write-Log "Watcher iteration failed: $($_.Exception.Message)"
            if ($Once) { throw }
        }
        if (-not $Once) { Start-Sleep -Seconds $pollSeconds }
    } while (-not $Once)
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
