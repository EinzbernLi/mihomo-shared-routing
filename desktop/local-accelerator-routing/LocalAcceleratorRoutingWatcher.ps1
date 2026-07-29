[CmdletBinding()]
param(
    [switch]$Once,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'LocalAcceleratorRoutingWatcher.config.psd1'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Copy SteamRoutingWatcher.config.example.psd1 first."
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if (-not $config.Profiles -or $config.Profiles.Count -eq 0) {
    throw 'Set at least one Profiles entry in the configuration file.'
}

$pollSeconds = [Math]::Max(1, [int]$config.PollSeconds)
$stableSamples = [Math]::Max(1, [int]$config.StableSamples)
$wattProcessName = if ($config.WattProcessName) { [string]$config.WattProcessName } else { 'Steam++.Accelerator' }
$wattProxyPorts = if ($config.WattProxyPorts) { @($config.WattProxyPorts) } else { @(80, 443) }
$steam302ProxyPorts = if ($config.Steam302ProxyPorts) { @($config.Steam302ProxyPorts) } else { @(80, 443) }
$ensureSystemHosts = if ($null -ne $config.EnsureSystemHosts) { [bool]$config.EnsureSystemHosts } else { $true }
$logPath = if ($config.LogPath) { [string]$config.LogPath } else { Join-Path $PSScriptRoot 'SteamRoutingWatcher.log' }

function Write-Log {
    param([string]$Message)
    $directory = Split-Path -Parent $logPath
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" |
        Add-Content -LiteralPath $logPath -Encoding utf8
}

function New-LocalAcceleratorRoutingBlock {
    $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    $rules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($line in (Get-Content -LiteralPath $hostsPath -ErrorAction Stop)) {
        # Keep only names explicitly mapped to the local loopback listener.
        # Both 302 and Watt use this form for every service they accelerate.
        $entry = ($line -replace '\s+#.*$', '').Trim()
        if ($entry -notmatch '^(?:127(?:\.\d{1,3}){3}|::1)\s+(?<names>.+)$') {
            continue
        }

        foreach ($name in ($matches.names -split '\s+')) {
            $hostname = $name.Trim().ToLowerInvariant()
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

    $orderedRules = @($rules | Sort-Object)
    if ($orderedRules.Count -eq 0) {
        return ''
    }
    return (@(
        '  # BEGIN Local accelerator routing'
        '  # Managed by LocalAcceleratorRoutingWatcher.ps1 from Windows Hosts. Do not edit this block manually.'
        $orderedRules
        '  # END Local accelerator routing'
    ) -join "`n")
}

function Get-ListeningEndpoints {
    # Get-NetTCPConnection can omit listeners for packaged applications in a
    # non-interactive session. Netstat reports the same TCP ownership without
    # that limitation, which matters for the Microsoft Store edition of Watt.
    $endpoints = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (netstat -ano)) {
        if ($line -match '^\s*TCP\s+(?<local>\S+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$') {
            $localEndpoint = $matches.local
            $processId = [int]$matches.pid
            if ($localEndpoint -notmatch ':(?<port>\d+)$') {
                continue
            }
            $endpoints.Add([pscustomobject]@{
                LocalAddress = ($localEndpoint -replace ':\d+$', '')
                LocalPort = [int]$matches.port
                OwningProcess = $processId
            })
        }
    }
    return @($endpoints)
}

function Get-AcceleratorState {
    $sources = [System.Collections.Generic.List[string]]::new()
    $listeners = @(Get-ListeningEndpoints)

    # Steamcommunity_302's GUI can remain open while idle. Require its local
    # service process to own an HTTP/HTTPS listener before treating it as ready.
    $steam302Ids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^steamcommunity_302\.(cli|caddy)$'
    } | Select-Object -ExpandProperty Id)
    $steam302Listener = $listeners | Where-Object {
        $_.OwningProcess -in $steam302Ids -and $_.LocalPort -in $steam302ProxyPorts
    } | Select-Object -First 1
    if ($steam302Listener) {
        $sources.Add('Steamcommunity_302')
    }

    # Watt's UI and module can remain resident while idle. Check that the
    # acceleration process itself owns its local interception listeners.
    $wattIds = @(Get-Process -Name $wattProcessName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id)
    if ($wattIds.Count -gt 0) {
        $wattListener = $listeners |
            Where-Object { $_.OwningProcess -in $wattIds -and $_.LocalPort -in $wattProxyPorts } |
            Select-Object -First 1
        if ($wattListener) {
            $sources.Add('Watt')
        }
    }

    $mode = if ($sources.Count -eq 0) {
        'None'
    } elseif ($sources -contains 'Steamcommunity_302') {
        # Both accelerators can listen on 80/443: 302 owns the more specific
        # loopback binding, while Watt owns the wildcard binding. Let the
        # configured priority choose one deterministic local handler.
        'Steamcommunity_302'
    } elseif ($sources.Count -eq 1) {
        $sources[0]
    } else {
        'Conflict'
    }

    [pscustomobject]@{
        Mode = $mode
        Direct = ($mode -ne 'None' -and $mode -ne 'Conflict')
        Sources = @($sources)
    }
}

function Enable-SystemHostsInOverride {
    param(
        [string]$Content,
        [string]$NewLine
    )

    $Content = [regex]::Replace(
        $Content,
        '(?m)^# Managed by SteamRoutingWatcher\.ps1: honor local accelerator hosts\.$',
        '# Managed by LocalAcceleratorRoutingWatcher.ps1: honor local accelerator hosts.'
    )

    # Clash Verge Rev merges this map into the subscription config. Preserve all
    # user DNS settings while forcing Mihomo to honor the accelerator's hosts file.
    $dnsPattern = [regex]'(?m)^dns:\r?\n(?<body>(?:(?:  |\t)[^\r\n]*(?:\r?\n|$))*)'
    $dnsMatch = $dnsPattern.Match($Content)
    if ($dnsMatch.Success) {
        $dnsBlock = $dnsMatch.Value
        $systemHostsPattern = [regex]'(?m)^(?<indent>  |\t)use-system-hosts:[ \t]*(?:true|false)[ \t]*(?<ending>\r?\n|$)'
        if ($systemHostsPattern.IsMatch($dnsBlock)) {
            $updatedBlock = $systemHostsPattern.Replace($dnsBlock, '${indent}use-system-hosts: true${ending}', 1)
            return $Content.Substring(0, $dnsMatch.Index) + $updatedBlock + $Content.Substring($dnsMatch.Index + $dnsMatch.Length)
        }

        $insertAt = $dnsMatch.Index + "dns:$NewLine".Length
        return $Content.Substring(0, $insertAt) + "  use-system-hosts: true$NewLine" + $Content.Substring($insertAt)
    }

    $separator = if ($Content.Length -eq 0 -or $Content.EndsWith("`n")) { '' } else { $NewLine }
    return "$Content$separator`# Managed by LocalAcceleratorRoutingWatcher.ps1: honor local accelerator hosts.$NewLine`dns:$NewLine  use-system-hosts: true$NewLine"
}

function Set-AcceleratorRouting {
    param([bool]$AcceleratorRunning)

    $changed = $false
    foreach ($profile in $config.Profiles) {
        if (-not (Test-Path -LiteralPath $profile)) {
            throw "Clash routing profile not found: $profile"
        }

        # Subscription override files are UTF-8. Explicitly preserve that
        # encoding so non-ASCII proxy group names are never corrupted.
        $content = Get-Content -Raw -LiteralPath $profile -Encoding utf8
        $newLine = if ($content.Contains([Environment]::NewLine)) { [Environment]::NewLine } else { [string][char]10 }
        $routingBlock = New-LocalAcceleratorRoutingBlock
        $block = [regex]::Replace($routingBlock, '\r?\n', $newLine)
        $blockPattern = [regex]'(?ms)^\s{2}# BEGIN (?:Steam(?: and GitHub)?|Local) accelerator routing\r?\n.*?^\s{2}# END (?:Steam(?: and GitHub)?|Local) accelerator routing\r?\n?'
        # Migrate the older fixed Steam DIRECT block too. Clash Verge Rev may
        # save these YAML entries with single quotes, so accept either form.
        $legacyStaticBlockPattern = [regex]'(?ms)^(?:\s{2}# Let local Steam accelerators handle Steam traffic instead of this subscription\.\r?\n)?(?:\s{2}-\s+[''"]?DOMAIN-SUFFIX,(?:steampowered\.com|steamcommunity\.com|steamstatic\.com|steamusercontent\.com|steamcontent\.com|steam-chat\.com|steamserver\.net),DIRECT[''"]?\s*\r?\n){7}'
        $cleanContent = $legacyStaticBlockPattern.Replace($blockPattern.Replace($content, '', 1), '', 1)

        if ($AcceleratorRunning -and -not [string]::IsNullOrWhiteSpace($block)) {
            if ($ensureSystemHosts) {
                $cleanContent = Enable-SystemHostsInOverride -Content $cleanContent -NewLine $newLine
            }
            $prependPattern = [regex]'(?m)^prepend:\r?\n'
            if (-not $prependPattern.IsMatch($cleanContent)) {
                throw "Invalid routing profile (missing prepend): $profile"
            }
            $updated = $prependPattern.Replace($cleanContent, "prepend:$newLine$block$newLine", 1)
        } else {
            $updated = $cleanContent
        }

        if ($updated -ne $content) {
            Set-Content -LiteralPath $profile -Value $updated -NoNewline -Encoding utf8
            $changed = $true
        }
    }
    return $changed
}

function Restart-RunningClient {
    if (-not $config.RestartRunningClient -or -not $config.ClashExecutable) {
        Write-Log 'Routing files updated; client restart disabled.'
        return
    }
    if (-not (Test-Path -LiteralPath $config.ClashExecutable)) {
        Write-Log "Routing files updated; client executable not found: $($config.ClashExecutable)"
        return
    }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.ClashExecutable)
    $client = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if (-not $client) {
        Write-Log 'Routing files updated; Clash is not running and will use them at next start.'
        return
    }

    $client | Stop-Process -Force
    Start-Sleep -Seconds 1
    Start-Process -FilePath $config.ClashExecutable
    Write-Log 'Restarted the running Clash client after local accelerator routing change.'
}

$lastMode = $null
$candidateState = $null
$candidateCount = 0

do {
    $state = Get-AcceleratorState
    if ($state.Mode -eq $lastMode) {
        $candidateState = $null
        $candidateCount = 0
    } elseif ($state.Mode -eq $candidateState) {
        $candidateCount++
    } else {
        $candidateState = $state.Mode
        $candidateCount = 1
    }

    $requiredSamples = if ($Once) { 1 } else { $stableSamples }
    if ($candidateCount -ge $requiredSamples) {
        $changed = Set-AcceleratorRouting -AcceleratorRunning $state.Direct
        switch ($state.Mode) {
            'Watt' {
                Write-Log 'accelerator active: Watt; all local accelerator Hosts domains DIRECT'
            }
            'Steamcommunity_302' {
                if ($state.Sources -contains 'Watt') {
                    Write-Log 'accelerator priority: Steamcommunity_302 selected while Watt is also listening; all local accelerator Hosts domains DIRECT'
                } else {
                    Write-Log 'accelerator active: Steamcommunity_302; all local accelerator Hosts domains DIRECT'
                }
            }
            'Conflict' {
                Write-Log 'accelerator conflict: no configured local handler; restored to Clash subscription rules'
            }
            default {
                Write-Log 'no accelerator: restored to Clash subscription rules'
            }
        }
        if ($changed) {
            Restart-RunningClient
        }
        $lastMode = $state.Mode
        $candidateState = $null
        $candidateCount = 0
    }

    if (-not $Once) {
        Start-Sleep -Seconds $pollSeconds
    }
} while (-not $Once)
