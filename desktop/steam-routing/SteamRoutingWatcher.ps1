[CmdletBinding()]
param(
    [switch]$Once,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'SteamRoutingWatcher.config.psd1'
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

$routingBlock = @'
  # BEGIN Steam accelerator routing
  # Managed by SteamRoutingWatcher.ps1. Do not edit this block manually.
  - DOMAIN-SUFFIX,steampowered.com,DIRECT
  - DOMAIN-SUFFIX,steamcommunity.com,DIRECT
  - DOMAIN-SUFFIX,steamstatic.com,DIRECT
  - DOMAIN-SUFFIX,steamusercontent.com,DIRECT
  - DOMAIN-SUFFIX,steamcontent.com,DIRECT
  - DOMAIN-SUFFIX,steam-chat.com,DIRECT
  - DOMAIN-SUFFIX,steamserver.net,DIRECT
  # END Steam accelerator routing
'@.TrimEnd([char]13, [char]10)

function Write-Log {
    param([string]$Message)
    $directory = Split-Path -Parent $logPath
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" |
        Add-Content -LiteralPath $logPath -Encoding utf8
}

function Get-AcceleratorState {
    $sources = [System.Collections.Generic.List[string]]::new()
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)

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
    } elseif ($sources.Count -eq 1) {
        $sources[0]
    } else {
        'Conflict'
    }

    [pscustomobject]@{
        Mode = $mode
        Direct = ($sources.Count -eq 1)
        Sources = @($sources)
    }
}

function Enable-SystemHostsInOverride {
    param(
        [string]$Content,
        [string]$NewLine
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
    return "$Content$separator`# Managed by SteamRoutingWatcher.ps1: honor local accelerator hosts.$NewLine`dns:$NewLine  use-system-hosts: true$NewLine"
}

function Set-SteamRouting {
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
        $block = [regex]::Replace($routingBlock, '\r?\n', $newLine)
        $blockPattern = [regex]'(?ms)^\s{2}# BEGIN Steam accelerator routing\r?\n.*?^\s{2}# END Steam accelerator routing\r?\n?'
        # Migrate the older fixed Steam DIRECT block too. Clash Verge Rev may
        # save these YAML entries with single quotes, so accept either form.
        $legacyStaticBlockPattern = [regex]'(?ms)^(?:\s{2}# Let local Steam accelerators handle Steam traffic instead of this subscription\.\r?\n)?(?:\s{2}-\s+[''"]?DOMAIN-SUFFIX,(?:steampowered\.com|steamcommunity\.com|steamstatic\.com|steamusercontent\.com|steamcontent\.com|steam-chat\.com|steamserver\.net),DIRECT[''"]?\s*\r?\n){7}'
        $cleanContent = $legacyStaticBlockPattern.Replace($blockPattern.Replace($content, '', 1), '', 1)

        if ($AcceleratorRunning) {
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
    Write-Log 'Restarted the running Clash client after Steam routing change.'
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
        $changed = Set-SteamRouting -AcceleratorRunning $state.Direct
        switch ($state.Mode) {
            'Watt' {
                Write-Log 'accelerator active: Watt; Steam DIRECT with system hosts'
            }
            'Steamcommunity_302' {
                Write-Log 'accelerator active: Steamcommunity_302; Steam DIRECT with system hosts'
            }
            'Conflict' {
                Write-Log 'accelerator conflict: Watt and Steamcommunity_302 are both listening; Steam restored to Clash subscription rules'
            }
            default {
                Write-Log 'no accelerator: Steam via Clash subscription rules'
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
