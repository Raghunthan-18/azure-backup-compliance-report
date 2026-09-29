#Requires -Version 7.2
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Resource Graph queries. Kept in /queries as .kql too, so the same logic can
# be pasted into Resource Graph Explorer or the workbook.
# ---------------------------------------------------------------------------

$script:BackupQuery = @'
resources
| where type =~ 'microsoft.compute/virtualmachines'
| project vmId = tolower(id), vmName = name, resourceGroup, subscriptionId, location,
          powerState = tostring(properties.extended.instanceView.powerState.code),
          environment = tostring(tags['environment']),
          backupExempt = tostring(tags['backup-exempt'])
| join kind=leftouter (
    recoveryservicesresources
    | where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems'
    | where tostring(properties.workloadType) =~ 'VM'
    | project vmId = tolower(tostring(properties.sourceResourceId)),
              vaultName = tostring(split(id, '/')[8]),
              protectionState = tostring(properties.protectionState),
              lastBackupStatus = tostring(properties.lastBackupStatus),
              lastBackupTime = tostring(properties.lastBackupTime),
              backupPolicy = tostring(properties.policyName)
) on vmId
| project-away vmId1
'@

$script:AsrQuery = @'
recoveryservicesresources
| where type =~ 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems'
| project vmId = tolower(tostring(properties.providerSpecificDetails.fabricObjectId)),
          asrVault = tostring(split(id, '/')[8]),
          replicationHealth = tostring(properties.replicationHealth),
          asrProtectionState = tostring(properties.protectionState),
          rpoSeconds = toint(properties.providerSpecificDetails.rpoInSeconds),
          lastTestFailover = tostring(properties.lastSuccessfulTestFailoverTime)
| where isnotempty(vmId)
'@

function Invoke-PagedGraphQuery {
    <#
    .SYNOPSIS
    Runs a Resource Graph query and follows SkipToken until every row is returned.
    Resource Graph caps a single page at 1000 rows; a 24,000-VM estate needs 24+ pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$SubscriptionId
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $params = @{ Query = $Query; First = 1000 }
        if ($SubscriptionId) { $params.Subscription = $SubscriptionId } else { $params.UseTenantScope = $true }
        if ($skipToken) { $params.SkipToken = $skipToken }

        $page = Search-AzGraph @params
        if ($page) { $rows.AddRange([object[]]$page.Data) }
        $skipToken = if ($page) { $page.SkipToken } else { $null }
    } while ($skipToken)

    return $rows
}

function Get-BackupStatus {
    <#
    .SYNOPSIS
    Classifies one VM's Azure Backup state. Pure function: no Azure calls, fully unit-tested.
    .OUTPUTS
    Exempt | Unprotected | Stopped | Pending | Failed | Stale | Compliant
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Vm,
        [int]$StaleHours = 26,
        [datetime]$Now = [datetime]::UtcNow
    )

    if ("$($Vm.backupExempt)" -eq 'true') { return 'Exempt' }
    if ([string]::IsNullOrEmpty($Vm.protectionState)) { return 'Unprotected' }

    switch ($Vm.protectionState) {
        'ProtectionStopped' { return 'Stopped' }
        'IRPending'         { return 'Pending' }
    }

    if ($Vm.lastBackupStatus -eq 'Failed') { return 'Failed' }

    $last = [datetime]::MinValue
    if (-not [datetime]::TryParse("$($Vm.lastBackupTime)", [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$last)) {
        return 'Stale'
    }
    if (($Now - $last).TotalHours -gt $StaleHours) { return 'Stale' }

    return 'Compliant'
}

function Get-AsrStatus {
    <#
    .SYNOPSIS
    Classifies one VM's Azure Site Recovery (A2A) state. Pure function.
    .OUTPUTS
    NotReplicated | Critical | Warning | DrillOverdue | Healthy
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $Replica,
        [int]$DrillMaxAgeDays = 180,
        [datetime]$Now = [datetime]::UtcNow
    )

    if (-not $Replica) { return 'NotReplicated' }
    if ($Replica.replicationHealth -eq 'Critical') { return 'Critical' }
    if ($Replica.replicationHealth -eq 'Warning')  { return 'Warning' }

    $drill = [datetime]::MinValue
    $hasDrill = [datetime]::TryParse("$($Replica.lastTestFailover)", [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$drill)
    if (-not $hasDrill -or ($Now - $drill).TotalDays -gt $DrillMaxAgeDays) { return 'DrillOverdue' }

    return 'Healthy'
}

function Get-BackupComplianceData {
    <#
    .SYNOPSIS
    Returns one row per VM with backup and ASR status across the given subscriptions
    (or every subscription the signed-in identity can read).
    #>
    [CmdletBinding()]
    param(
        [string[]]$SubscriptionId,
        [int]$StaleHours = 26,
        [int]$DrillMaxAgeDays = 180
    )

    $vms = Invoke-PagedGraphQuery -Query $script:BackupQuery -SubscriptionId $SubscriptionId
    $replicas = @{}
    foreach ($r in (Invoke-PagedGraphQuery -Query $script:AsrQuery -SubscriptionId $SubscriptionId)) {
        $replicas[$r.vmId] = $r
    }

    $now = [datetime]::UtcNow
    foreach ($vm in $vms) {
        $replica = $replicas[$vm.vmId]
        [pscustomobject]@{
            VmName            = $vm.vmName
            Subscription      = $vm.subscriptionId
            ResourceGroup     = $vm.resourceGroup
            Location          = $vm.location
            Environment       = $vm.environment
            PowerState        = ($vm.powerState -replace '^PowerState/', '')
            BackupStatus      = Get-BackupStatus -Vm $vm -StaleHours $StaleHours -Now $now
            Vault             = $vm.vaultName
            Policy            = $vm.backupPolicy
            LastBackupTime    = $vm.lastBackupTime
            LastBackupResult  = $vm.lastBackupStatus
            AsrStatus         = Get-AsrStatus -Replica $replica -DrillMaxAgeDays $DrillMaxAgeDays -Now $now
            RpoSeconds        = if ($replica) { $replica.rpoSeconds } else { $null }
            LastTestFailover  = if ($replica) { $replica.lastTestFailover } else { $null }
            VmId              = $vm.vmId
        }
    }
}

function Get-ComplianceSummary {
    <#
    .SYNOPSIS
    Aggregates report rows into counts and a coverage percentage. Pure function.
    Exempt VMs are excluded from the denominator.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)

    $inScope   = @($Rows | Where-Object BackupStatus -ne 'Exempt')
    $compliant = @($inScope | Where-Object BackupStatus -eq 'Compliant').Count
    $total     = $inScope.Count

    [pscustomobject]@{
        TotalVms        = $Rows.Count
        InScope         = $total
        Compliant       = $compliant
        CoveragePercent = if ($total) { [math]::Round(100 * $compliant / $total, 1) } else { 100 }
        ByBackupStatus  = $Rows | Group-Object BackupStatus | Sort-Object Name |
                          ForEach-Object { [pscustomobject]@{ Status = $_.Name; Count = $_.Count } }
        ByAsrStatus     = $Rows | Group-Object AsrStatus | Sort-Object Name |
                          ForEach-Object { [pscustomobject]@{ Status = $_.Name; Count = $_.Count } }
    }
}

function ConvertTo-ComplianceHtml {
    <#
    .SYNOPSIS
    Builds a self-contained HTML report: summary first, then only the VMs that need action.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)]$Summary
    )

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $needsAction = @($Rows | Where-Object {
        $_.BackupStatus -in 'Unprotected', 'Failed', 'Stale', 'Stopped' -or
        $_.AsrStatus -in 'Critical', 'Warning'
    } | Sort-Object BackupStatus, VmName)

    $statusRows = ($Summary.ByBackupStatus | ForEach-Object {
        "<tr><td>$(& $enc $_.Status)</td><td>$($_.Count)</td></tr>" }) -join "`n"
    $asrRows = ($Summary.ByAsrStatus | ForEach-Object {
        "<tr><td>$(& $enc $_.Status)</td><td>$($_.Count)</td></tr>" }) -join "`n"
    $actionRows = ($needsAction | ForEach-Object {
        "<tr><td>$(& $enc $_.VmName)</td><td>$(& $enc $_.ResourceGroup)</td><td class='s-$($_.BackupStatus)'>$(& $enc $_.BackupStatus)</td><td>$(& $enc $_.LastBackupTime)</td><td class='s-$($_.AsrStatus)'>$(& $enc $_.AsrStatus)</td><td>$(& $enc $_.Environment)</td></tr>"
    }) -join "`n"
    if (-not $actionRows) { $actionRows = "<tr><td colspan='6'>Nothing needs action.</td></tr>" }

    $generated = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + ' UTC'

    @"
<!doctype html><html><head><meta charset="utf-8"><title>Backup compliance $generated</title>
<style>
body{font:14px/1.5 system-ui,Segoe UI,sans-serif;margin:32px;color:#0e1a2b}
h1{margin:0 0 4px}.muted{color:#586579}
.kpi{display:flex;gap:16px;margin:20px 0}.kpi div{border:1px solid #d8dfe9;border-radius:8px;padding:12px 18px}
.kpi b{display:block;font-size:28px}
table{border-collapse:collapse;margin:12px 0 28px;min-width:360px}th,td{border-bottom:1px solid #e3e8ef;padding:6px 12px;text-align:left}
th{background:#f3f6fa}.s-Unprotected,.s-Failed,.s-Critical{color:#b42318;font-weight:600}
.s-Stale,.s-Stopped,.s-Warning{color:#b54708;font-weight:600}
</style></head><body>
<h1>Backup &amp; DR compliance</h1><p class="muted">Generated $generated</p>
<div class="kpi">
<div><b>$($Summary.CoveragePercent)%</b>backup coverage</div>
<div><b>$($Summary.Compliant) / $($Summary.InScope)</b>VMs compliant (exempt excluded)</div>
<div><b>$($needsAction.Count)</b>need action</div>
</div>
<h2>Backup status</h2><table><tr><th>Status</th><th>VMs</th></tr>$statusRows</table>
<h2>Site Recovery status</h2><table><tr><th>Status</th><th>VMs</th></tr>$asrRows</table>
<h2>Needs action</h2><table><tr><th>VM</th><th>Resource group</th><th>Backup</th><th>Last backup</th><th>ASR</th><th>Env</th></tr>
$actionRows</table>
</body></html>
"@
}

Export-ModuleMember -Function Invoke-PagedGraphQuery, Get-BackupStatus, Get-AsrStatus,
    Get-BackupComplianceData, Get-ComplianceSummary, ConvertTo-ComplianceHtml
