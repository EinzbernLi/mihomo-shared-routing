[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'LocalAcceleratorRoutingWatcher.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Watcher source has $($parseErrors.Count) parse error(s)." }

function Assert-DiagnosticsTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "DIAGNOSTICS_TEST_FAILED: $Message" }
}

Assert-DiagnosticsTest ($source.Contains("'^steamcommunity_302(?:\.(cli|caddy))?$'")) '302 listener detection does not accept bare and suffixed process names.'

$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in @('Get-WattDiagnostics', 'Test-ManagedHost', 'Select-MihomoConnectionsForRefresh', 'New-LocalAcceleratorRoutingBlock', 'Test-RuntimeRoutingReady', 'Get-MihomoManagedRuleAudit', 'Test-MihomoRuntimeRulesReady', 'Invoke-ConnectionRefresh')) {
    Assert-DiagnosticsTest ($null -ne ($functions | Where-Object Name -eq $name | Select-Object -First 1)) "Missing function $name."
}
$getState = $functions | Where-Object Name -eq 'Get-AcceleratorState' | Select-Object -First 1
Assert-DiagnosticsTest ($null -ne $getState) 'Missing function Get-AcceleratorState.'
Assert-DiagnosticsTest ($getState.Extent.Text -match '(?m)^\s*\$wattDiagnostics\s*=\s*Get-WattDiagnostics\s*$') 'Production state detection bypasses Watt CIM parent/path enrichment.'
$getWatt = $functions | Where-Object Name -eq 'Get-WattDiagnostics' | Select-Object -First 1
$testHost = $functions | Where-Object Name -eq 'Test-ManagedHost' | Select-Object -First 1
$selectConnections = $functions | Where-Object Name -eq 'Select-MihomoConnectionsForRefresh' | Select-Object -First 1
$newBlock = $functions | Where-Object Name -eq 'New-LocalAcceleratorRoutingBlock' | Select-Object -First 1
$runtimeReady = $functions | Where-Object Name -eq 'Test-RuntimeRoutingReady' | Select-Object -First 1
$ruleAudit = $functions | Where-Object Name -eq 'Get-MihomoManagedRuleAudit' | Select-Object -First 1
$runtimeRulesReady = $functions | Where-Object Name -eq 'Test-MihomoRuntimeRulesReady' | Select-Object -First 1
$refresh = $functions | Where-Object Name -eq 'Invoke-ConnectionRefresh' | Select-Object -First 1
Invoke-Expression $getWatt.Extent.Text
Invoke-Expression $testHost.Extent.Text
Invoke-Expression $selectConnections.Extent.Text
Invoke-Expression $newBlock.Extent.Text
Invoke-Expression $runtimeReady.Extent.Text
Invoke-Expression $ruleAudit.Extent.Text

$generatedBlock = New-LocalAcceleratorRoutingBlock -AcceleratorPolicy 'DIRECT' -DomainRules @('  - DOMAIN,fixture.example,DIRECT')
$generatedProcessRules = @(
    'PROCESS-NAME,Steam++.Accelerator.exe,DIRECT'
    'PROCESS-NAME,steamcommunity_302.caddy.exe,DIRECT'
    'PROCESS-NAME,steamcommunity_302.cli.exe,DIRECT'
    'PROCESS-NAME,steamcommunity_302.exe,DIRECT'
    'PROCESS-NAME,Steam++.Accelerator,DIRECT'
    'PROCESS-NAME,steamcommunity_302.caddy,DIRECT'
    'PROCESS-NAME,steamcommunity_302.cli,DIRECT'
    'PROCESS-NAME,steamcommunity_302,DIRECT'
)
foreach ($processRule in $generatedProcessRules) {
    Assert-DiagnosticsTest ($generatedBlock.Contains("  - $processRule")) "Generated routing block omitted $processRule."
}
Assert-DiagnosticsTest ($generatedBlock.IndexOf('PROCESS-NAME,steamcommunity_302.caddy,DIRECT') -lt $generatedBlock.IndexOf('DOMAIN,fixture.example,DIRECT')) 'Generated accelerator process rules were not placed before managed domains.'

$script:wattProcessName = 'Steam++.Accelerator'
$script:wattProxyPorts = @(80, 443)
$notReadyProcesses = @(
    [pscustomobject]@{ Id = 10; ProcessName = 'Steam++.Accelerator.exe'; ExecutablePath = 'C:\Watt\Steam++.Accelerator.exe'; ParentProcessId = 1 }
)
$notReadyListeners = @(
    [pscustomobject]@{ LocalPort = 81; OwningProcess = 10 },
    [pscustomobject]@{ LocalPort = 444; OwningProcess = 10 }
)
$notReady = Get-WattDiagnostics -Processes $notReadyProcesses -Listeners $notReadyListeners
Assert-DiagnosticsTest (-not $notReady.Active -and $notReady.Status -eq 'NotReady') 'Watt listening only on 81/444 was incorrectly marked active.'
Assert-DiagnosticsTest (@($notReady.ObservedPorts) -join ',' -eq '81,444') 'Not-ready Watt ports were not retained for diagnostics.'

$helperProcesses = @(
    [pscustomobject]@{ Id = 10; ProcessName = 'Steam++.Accelerator.exe'; ExecutablePath = 'C:\Watt\Steam++.Accelerator.exe'; ParentProcessId = 1 },
    [pscustomobject]@{ Id = 11; ProcessName = 'Steam++.Helper.exe'; ExecutablePath = 'C:\Watt\Steam++.Helper.exe'; ParentProcessId = 10 }
)
$helperListeners = @([pscustomobject]@{ LocalPort = 80; OwningProcess = 11 })
$active = Get-WattDiagnostics -Processes $helperProcesses -Listeners $helperListeners
Assert-DiagnosticsTest ($active.Active -and $active.Status -eq 'Active' -and 80 -in @($active.MatchedPorts)) 'Verified Watt helper owning 80 was not recognized.'

$unsafeHelper = @(
    [pscustomobject]@{ Id = 10; ProcessName = 'Steam++.Accelerator.exe'; ExecutablePath = 'C:\Watt\Steam++.Accelerator.exe'; ParentProcessId = 1 },
    [pscustomobject]@{ Id = 11; ProcessName = 'Steam++.Helper.exe'; ExecutablePath = 'D:\Other\Steam++.Helper.exe'; ParentProcessId = 10 }
)
$unsafe = Get-WattDiagnostics -Processes $unsafeHelper -Listeners $helperListeners
Assert-DiagnosticsTest (-not $unsafe.Active -and $unsafe.Status -eq 'NotReady') 'Watt helper without same-directory evidence was trusted.'

$hostsInfo = [pscustomobject]@{ Rules = @('  - DOMAIN,steamcommunity.com,DIRECT', '  - DOMAIN-SUFFIX,steamstatic.com,DIRECT') }
$connections = @(
    [pscustomobject]@{ id = 'steam-process'; metadata = [pscustomobject]@{ process = 'steam.exe'; host = 'unrelated.example' } },
    [pscustomobject]@{ id = 'managed-host'; metadata = [pscustomobject]@{ process = ''; host = 'cdn.steamstatic.com' } },
    [pscustomobject]@{ id = 'caddy-upstream'; metadata = [pscustomobject]@{ process = 'steamcommunity_302.caddy'; host = 'unrelated.example' } },
    [pscustomobject]@{ id = 'watt-upstream'; metadata = [pscustomobject]@{ process = 'Steam++.Accelerator.exe'; host = 'unrelated.example' } },
    [pscustomobject]@{ id = 'custom-process'; metadata = [pscustomobject]@{ process = 'custom-helper.exe'; host = 'unrelated.example' } },
    [pscustomobject]@{ id = 'unrelated'; metadata = [pscustomobject]@{ process = 'chrome.exe'; host = 'unrelated.example' } }
)
$script:wattProcessName = 'Steam++.Accelerator'
$script:managedConnectionProcesses = @('steam.exe', 'steamwebhelper.exe', 'steamservice.exe', 'custom-helper.exe')
$selected302 = @(Select-MihomoConnectionsForRefresh -Connections $connections -HostsInfo $hostsInfo -Mode 'Steamcommunity_302')
Assert-DiagnosticsTest ($selected302.Count -eq 4 -and (@($selected302.id) -contains 'steam-process') -and (@($selected302.id) -contains 'managed-host') -and (@($selected302.id) -contains 'caddy-upstream') -and (@($selected302.id) -contains 'custom-process') -and (@($selected302.id) -notcontains 'watt-upstream')) '302 mode selected the wrong process fallback set.'
$selectedWatt = @(Select-MihomoConnectionsForRefresh -Connections $connections -HostsInfo $hostsInfo -Mode 'Watt')
Assert-DiagnosticsTest ($selectedWatt.Count -eq 4 -and (@($selectedWatt.id) -contains 'steam-process') -and (@($selectedWatt.id) -contains 'managed-host') -and (@($selectedWatt.id) -contains 'watt-upstream') -and (@($selectedWatt.id) -contains 'custom-process') -and (@($selectedWatt.id) -notcontains 'caddy-upstream')) 'Watt mode selected the wrong process fallback set.'

# Runtime gate fixture: no controller operation can be reached unless all
# eight process rules (with and without .exe), current Hosts rules, and
# use-system-hosts=true are present.
$script:runtimeConfigPath = 'C:\fixture\clash-verge.yaml'
$script:runtimeFixture = @"
dns:
  use-system-hosts: true
rules:
  - PROCESS-NAME,Steam++.Accelerator.exe,DIRECT
  - PROCESS-NAME,steamcommunity_302.caddy.exe,DIRECT
  - PROCESS-NAME,steamcommunity_302.cli.exe,DIRECT
  - PROCESS-NAME,steamcommunity_302.exe,DIRECT
  - PROCESS-NAME,Steam++.Accelerator,DIRECT
  - PROCESS-NAME,steamcommunity_302.caddy,DIRECT
  - PROCESS-NAME,steamcommunity_302.cli,DIRECT
  - PROCESS-NAME,steamcommunity_302,DIRECT
  - DOMAIN,steamcommunity.com,DIRECT
  - DOMAIN-SUFFIX,steamstatic.com,DIRECT
"@
function Test-Path { return $true }
function Get-Utf8File { return [pscustomobject]@{ Content = $script:runtimeFixture } }
function Write-Log { param([string]$Message) $script:runtimeLogs += $Message }
$script:runtimeLogs = @()
Assert-DiagnosticsTest (Test-RuntimeRoutingReady -HostsInfo $hostsInfo) 'Valid runtime routing fixture was rejected.'
$runtimeRules = @(
    [pscustomobject]@{ type = 'ProcessName'; payload = 'Steam++.Accelerator.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.caddy.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.cli.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'Steam++.Accelerator'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.caddy'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.cli'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'Domain'; payload = 'steamcommunity.com'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'DomainSuffix'; payload = 'steamstatic.com'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'DomainKeyword'; payload = 'steamcommunity'; proxy = 'Steam' }
)
$audit = Get-MihomoManagedRuleAudit -HostsInfo $hostsInfo -Rules $runtimeRules
Assert-DiagnosticsTest ($audit.ExpectedCount -eq 10 -and $audit.RuntimeManagedRuleCount -eq 10 -and $audit.MissingCount -eq 0 -and $audit.DuplicateCount -eq 0 -and $audit.OrderViolationCount -eq 0) 'Complete managed-rule audit did not report the valid fixture.'
$runtimeRules = @($runtimeRules | Where-Object { $_.payload -ne 'steamcommunity.com' })
$auditMissing = Get-MihomoManagedRuleAudit -HostsInfo $hostsInfo -Rules $runtimeRules
Assert-DiagnosticsTest ($auditMissing.MissingCount -gt 0) 'Complete managed-rule audit missed a deleted managed rule.'
$largeHostsInfo = [pscustomobject]@{
    Rules = @(1..969 | ForEach-Object { "  - DOMAIN,fixture-$_.example,DIRECT" })
}
$largeRuntimeRules = @(
    [pscustomobject]@{ type = 'ProcessName'; payload = 'Steam++.Accelerator.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.caddy.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.cli.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.exe'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'Steam++.Accelerator'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.caddy'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302.cli'; proxy = 'DIRECT' }
    [pscustomobject]@{ type = 'ProcessName'; payload = 'steamcommunity_302'; proxy = 'DIRECT' }
    @($largeHostsInfo.Rules | ForEach-Object {
        [pscustomobject]@{ type = 'Domain'; payload = (($_ -split ',')[1]); proxy = 'DIRECT' }
    })
)
$largeAudit = Get-MihomoManagedRuleAudit -HostsInfo $largeHostsInfo -Rules $largeRuntimeRules
Assert-DiagnosticsTest ($largeAudit.ExpectedCount -eq 977 -and $largeAudit.RuntimeManagedRuleCount -eq 977 -and $largeAudit.MissingCount -eq 0 -and $largeAudit.DuplicateCount -eq 0 -and $largeAudit.OrderViolationCount -eq 0) '969-domain complete audit did not report the expected 977 managed rules.'
$largeDuplicateAudit = Get-MihomoManagedRuleAudit -HostsInfo $largeHostsInfo -Rules @($largeRuntimeRules + $largeRuntimeRules[8])
Assert-DiagnosticsTest ($largeDuplicateAudit.DuplicateCount -gt 0) 'Complete audit missed a duplicate in the 969-domain fixture.'
$subscriptionFirst = [pscustomobject]@{ type = 'DomainKeyword'; payload = 'steamcommunity'; proxy = 'Steam' }
$largeOrderRules = @($subscriptionFirst) + @($largeRuntimeRules)
$largeOrderAudit = Get-MihomoManagedRuleAudit -HostsInfo $largeHostsInfo -Rules $largeOrderRules
Assert-DiagnosticsTest ($largeOrderAudit.OrderViolationCount -gt 0) 'Complete audit missed managed rules placed after a subscription Steam matcher.'
$script:runtimeFixture = $script:runtimeFixture -replace 'use-system-hosts: true', 'use-system-hosts: false'
Assert-DiagnosticsTest (-not (Test-RuntimeRoutingReady -HostsInfo $hostsInfo)) 'Runtime gate accepted use-system-hosts=false.'

$refreshText = $refresh.Extent.Text
Assert-DiagnosticsTest ($refreshText -match 'Test-RuntimeRoutingReady') 'Connection refresh lacks the runtime configuration safety gate.'
Assert-DiagnosticsTest ($refreshText -match 'Test-MihomoRuntimeRulesReady') 'Connection refresh lacks the final Mihomo /rules order safety gate.'
Assert-DiagnosticsTest ($refreshText -match 'Select-MihomoConnectionsForRefresh[^\r\n]*-Mode \$Mode') 'Connection refresh does not pass the active accelerator mode to connection selection.'
Assert-DiagnosticsTest ($refreshText -match '/connections/\$idPath') 'Connection refresh lacks per-connection deletion.'
Assert-DiagnosticsTest ($refreshText -notmatch "-Path\s+'/connections'\s+-Method\s+'DELETE'") 'Connection refresh contains an unfiltered connection delete.'
Assert-DiagnosticsTest ($refreshText -match 'exceeds safety limit') 'Connection refresh lacks a selected-connection count safety limit.'
Assert-DiagnosticsTest ($refreshText -match 'failed safely; watcher continues') 'Connection refresh lacks safe error handling that keeps the watcher alive.'
Assert-DiagnosticsTest ($refreshText -match 'fake-ip flush failed; continuing') 'Connection refresh lacks fake-ip failure handling.'

Write-Output 'DIAGNOSTICS_OFFLINE_TESTS=PASS'
