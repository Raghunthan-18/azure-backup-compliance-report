<#
.SYNOPSIS
Azure Automation runbook (PowerShell 7.2 runtime): runs the compliance report on a schedule
and drops the CSV + HTML into a storage container.

.NOTES
Setup (see README "Run it on a schedule"):
 - Automation account with a system-assigned managed identity
 - Identity roles: Reader on the subscriptions (or management group) to scan,
   Storage Blob Data Contributor on the target storage account
 - Import Az.Accounts, Az.ResourceGraph, Az.Storage and the BackupCompliance module into the account
 - Automation variables: ReportStorageAccount, ReportContainer
#>
param(
    [string[]]$SubscriptionId,
    [int]$StaleHours = 26
)

$ErrorActionPreference = 'Stop'

# Managed identity: no credentials stored in the runbook or the account.
Connect-AzAccount -Identity | Out-Null

Import-Module BackupCompliance

$account   = Get-AutomationVariable -Name 'ReportStorageAccount'
$container = Get-AutomationVariable -Name 'ReportContainer'

$rows    = @(Get-BackupComplianceData -SubscriptionId $SubscriptionId -StaleHours $StaleHours)
$summary = Get-ComplianceSummary -Rows $rows

$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmm')
$tmp   = [System.IO.Path]::GetTempPath()
$csv   = Join-Path $tmp "backup-compliance-$stamp.csv"
$html  = Join-Path $tmp "backup-compliance-$stamp.html"

$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8
ConvertTo-ComplianceHtml -Rows $rows -Summary $summary | Set-Content -Path $html -Encoding utf8

$ctx = New-AzStorageContext -StorageAccountName $account -UseConnectedAccount
foreach ($f in $csv, $html) {
    Set-AzStorageBlobContent -File $f -Container $container -Blob ("{0}/{1}" -f $stamp.Substring(0, 8), (Split-Path $f -Leaf)) `
        -Context $ctx -Force | Out-Null
}

# Single structured line so the job output is easy to alert on from Log Analytics.
Write-Output ("COMPLIANCE total={0} inScope={1} compliant={2} coverage={3}" -f `
    $summary.TotalVms, $summary.InScope, $summary.Compliant, $summary.CoveragePercent)
