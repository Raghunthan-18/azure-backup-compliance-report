#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.13.0' }, @{ ModuleName = 'Az.ResourceGraph'; ModuleVersion = '0.13.0' }
<#
.SYNOPSIS
Reports Azure Backup and Site Recovery coverage for every VM you can read.

.DESCRIPTION
Queries Azure Resource Graph (one call per 1000 VMs, not one call per VM), classifies each VM,
and writes a CSV with every VM plus an HTML report that shows only the VMs needing action.

.EXAMPLE
./scripts/Get-BackupComplianceReport.ps1
All subscriptions the signed-in identity can read.

.EXAMPLE
./scripts/Get-BackupComplianceReport.ps1 -SubscriptionId 1111-..., 2222-... -StaleHours 30 -FailBelowPercent 95
Two subscriptions; exit code 1 if coverage is under 95% (useful in a pipeline).
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,

    # Daily backups finish at different times; 26h avoids flagging a VM that is only running late.
    [ValidateRange(1, 720)][int]$StaleHours = 26,

    [ValidateRange(1, 3650)][int]$DrillMaxAgeDays = 180,

    [string]$OutputPath = './out',

    [ValidateRange(0, 100)][double]$FailBelowPercent = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/BackupCompliance/BackupCompliance.psd1') -Force

if (-not (Get-AzContext)) {
    throw 'Not signed in. Run Connect-AzAccount first.'
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rows = @(Get-BackupComplianceData -SubscriptionId $SubscriptionId -StaleHours $StaleHours -DrillMaxAgeDays $DrillMaxAgeDays)
$summary = Get-ComplianceSummary -Rows $rows

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmm')
$csv  = Join-Path $OutputPath "backup-compliance-$stamp.csv"
$html = Join-Path $OutputPath "backup-compliance-$stamp.html"

$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8
ConvertTo-ComplianceHtml -Rows $rows -Summary $summary | Set-Content -Path $html -Encoding utf8

Write-Host ("{0} VMs scanned in {1:n1}s. Coverage {2}% ({3}/{4} in scope)." -f `
    $summary.TotalVms, $sw.Elapsed.TotalSeconds, $summary.CoveragePercent, $summary.Compliant, $summary.InScope)
$summary.ByBackupStatus | Format-Table -AutoSize | Out-Host
$summary.ByAsrStatus    | Format-Table -AutoSize | Out-Host
Write-Host "CSV:  $csv"
Write-Host "HTML: $html"

if ($FailBelowPercent -gt 0 -and $summary.CoveragePercent -lt $FailBelowPercent) {
    Write-Error "Coverage $($summary.CoveragePercent)% is below the $FailBelowPercent% threshold." -ErrorAction Continue
    exit 1
}
