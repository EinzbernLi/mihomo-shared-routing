[CmdletBinding()]
param(
    [switch]$Once,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SteamRoutingWatcher.config.psd1')
)

$ErrorActionPreference = 'Stop'

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
$wattProxyPorts = @($config.WattProxyPorts)
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

    # Steamcommunity_302's GUI can remain open while idle. Its CLI/Caddy
    # processes exist only while the local acceleration service is active.
    $steam302 = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^steamcommunity_302\.(cli|caddy)$'
    }
    if ($steam302) {
        $sources.Add('Steamcommunity_302')
    }

    # Watt's UI and module can remain resident while idle. Check that the
    # acceleration process itself owns its local interception listeners.
    $wattIds = @(Get-Process -Name $wattProcessName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id)
    if ($wattIds.Count -gt 0) {
        $wattListener = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $wattIds -and $_.LocalPort -in $wattProxyPorts } |
            Select-Object -First 1
        if ($wattListener) {
            $sources.Add('Watt')
        }
    }

    [pscustomobject]@{
        Active = ($sources.Count -gt 0)
        Sources = @($sources)
    }
}

function Set-SteamRouting {
    param([bool]$AcceleratorRunning)

    $changed = $false
    foreach ($profile in $config.Profiles) {
        if (-not (Test-Path -LiteralPath $profile)) {
            throw "Clash routing profile not found: $profile"
        }

        $content = Get-Content -Raw -LiteralPath $profile
        $newLine = if ($content.Contains([Environment]::NewLine)) { [Environment]::NewLine } else { [string][char]10 }
        $block = [regex]::Replace($routingBlock, '\r?\n', $newLine)
        $blockPattern = [regex]'(?ms)^\s{2}# BEGIN Steam accelerator routing\r?\n.*?^\s{2}# END Steam accelerator routing\r?\n?'
        $cleanContent = $blockPattern.Replace($content, '', 1)

        if ($AcceleratorRunning) {
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

$lastState = $null
$candidateState = $null
$candidateCount = 0

do {
    $state = Get-AcceleratorState
    if ($state.Active -eq $lastState) {
        $candidateState = $null
        $candidateCount = 0
    } elseif ($state.Active -eq $candidateState) {
        $candidateCount++
    } else {
        $candidateState = $state.Active
        $candidateCount = 1
    }

    $requiredSamples = if ($Once) { 1 } else { $stableSamples }
    if ($candidateCount -ge $requiredSamples) {
        $changed = Set-SteamRouting -AcceleratorRunning $state.Active
        if ($state.Active) {
            Write-Log "accelerator active: $($state.Sources -join ', '); Steam DIRECT"
        } else {
            Write-Log 'no accelerator: Steam via Clash subscription rules'
        }
        if ($changed) {
            Restart-RunningClient
        }
        $lastState = $state.Active
        $candidateState = $null
        $candidateCount = 0
    }

    if (-not $Once) {
        Start-Sleep -Seconds $pollSeconds
    }
} while (-not $Once)
