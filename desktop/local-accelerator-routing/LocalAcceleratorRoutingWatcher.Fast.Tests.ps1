[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'LocalAcceleratorRoutingWatcher.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Watcher source has $($parseErrors.Count) parse error(s)."
}

function Assert-FastTest {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "FAST_TEST_FAILED: $Message"
    }
}

$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$fastFunction = $functions | Where-Object Name -eq 'Restart-RunningClientFast' | Select-Object -First 1
$guardFunction = $functions | Where-Object Name -eq 'Get-ConfiguredClashGuiProcesses' | Select-Object -First 1
Assert-FastTest ($null -ne $fastFunction) 'Fast function is missing.'
Assert-FastTest ($null -ne $guardFunction) 'GUI path guard function is missing.'
$fastText = $fastFunction.Extent.Text
Assert-FastTest ($fastText -notmatch 'CloseMainWindow') 'Fast function must never call CloseMainWindow.'
Assert-FastTest ($fastText -match 'Stop-Process\s+-Id\s+\(\[int\]\$client\.Id\)\s+-Force') 'Fast function must force-stop only the verified client PID.'
Assert-FastTest ($fastText -match 'Get-ConfiguredClashGuiProcesses') 'Fast function must use the strict path guard.'
Assert-FastTest ($fastText.IndexOf('Stop-Process', [System.StringComparison]::Ordinal) -lt $fastText.IndexOf('Start-Process', [System.StringComparison]::Ordinal)) 'Fast function must terminate and confirm before starting.'
Assert-FastTest ($fastText -match 'FastRestartSettleMilliseconds') 'Fast function must include the configured post-exit settle wait.'
Assert-FastTest ($fastText.IndexOf('FastRestartSettleMilliseconds', [System.StringComparison]::Ordinal) -lt $fastText.IndexOf('Start-Process', [System.StringComparison]::Ordinal)) 'Fast must settle after exit and before launching the GUI.'
$sourceBounds = $source -match '\$fastRestartSettleMilliseconds\s+-lt\s+250' -and $source -match '\$fastRestartSettleMilliseconds\s+-gt\s+3000'
Assert-FastTest $sourceBounds 'FastRestartSettleMilliseconds must be range checked from 250 through 3000.'

# Evaluate only the path-guard function. The test process supplies a fake
# Get-Process command, so no real process is inspected or modified.
Invoke-Expression $guardFunction.Extent.Text
$expectedPath = 'C:\Clash\clash-verge.exe'
$script:fakeProcesses = @(
    [pscustomobject]@{ Id = 101; Path = $expectedPath }
)
function Get-Process {
    param([string]$Name, [string]$ErrorAction)
    return $script:fakeProcesses
}
$guardResult = @(Get-ConfiguredClashGuiProcesses -Executable $expectedPath)
Assert-FastTest ($guardResult.Count -eq 1 -and $guardResult[0].Id -eq 101) 'Matching GUI path was not accepted.'

$script:fakeProcesses = @(
    [pscustomobject]@{ Id = 101; Path = $expectedPath },
    [pscustomobject]@{ Id = 202; Path = 'D:\Other\clash-verge.exe' }
)
$mismatchRejected = $false
try {
    @(Get-ConfiguredClashGuiProcesses -Executable $expectedPath) | Out-Null
} catch {
    $mismatchRejected = $true
}
Assert-FastTest $mismatchRejected 'Mismatched same-name process path was not rejected.'

# Evaluate Fast with fake dependencies. This verifies the stop/start order,
# failure behavior, and that only the pre-verified GUI PID is stopped.
$script:SkipClientReload = $false
$script:clientRestartMode = 'Fast'
$script:fastRestartConfirmMilliseconds = 0
$script:fastRestartSettleMilliseconds = 0
$script:config = @{ ClashExecutable = $expectedPath }
$script:stopCalls = @()
$script:startCalls = @()
$script:logCalls = @()
$script:fastClients = @([pscustomobject]@{ Id = 101; Path = $expectedPath; HasExited = $false })
function Resolve-ClashGuiExecutable { return $expectedPath }
function Test-Path { return $true }
function Get-ConfiguredClashGuiProcesses { return $script:fastClients }
function Stop-Process {
    param([int]$Id, [switch]$Force, [string]$ErrorAction)
    $script:stopCalls += [pscustomobject]@{ Id = $Id; Force = $Force }
    foreach ($client in $script:fastClients) {
        if ($client.Id -eq $Id) { $client.HasExited = $true }
    }
}
function Start-Process {
    param([string]$FilePath, [string]$WorkingDirectory, [switch]$PassThru, [string]$ErrorAction)
    $script:startCalls += $FilePath
    return [pscustomobject]@{ Id = 9001 }
}
function Write-Log {
    param([string]$Message)
    $script:logCalls += $Message
}
Invoke-Expression $fastFunction.Extent.Text
Restart-RunningClientFast
Assert-FastTest ($script:stopCalls.Count -eq 1 -and $script:stopCalls[0].Id -eq 101 -and $script:stopCalls[0].Force) 'Normal Fast did not force-stop only the verified GUI PID.'
Assert-FastTest ($script:startCalls.Count -eq 1 -and $script:startCalls[0] -eq $expectedPath) 'Normal Fast did not start the configured GUI path.'

$script:stopCalls = @()
$script:startCalls = @()
$script:fastClients = @([pscustomobject]@{ Id = 303; Path = $expectedPath; HasExited = $false })
function Stop-Process {
    param([int]$Id, [switch]$Force, [string]$ErrorAction)
    $script:stopCalls += [pscustomobject]@{ Id = $Id; Force = $Force }
    throw 'simulated termination failure'
}
Restart-RunningClientFast
Assert-FastTest ($script:stopCalls.Count -eq 1) 'Termination failure test did not attempt the verified GUI PID.'
Assert-FastTest ($script:startCalls.Count -eq 0) 'Fast started a second GUI after termination failure.'

Write-Output 'FAST_OFFLINE_TESTS=PASS'
