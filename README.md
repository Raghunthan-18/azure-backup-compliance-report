# Azure Backup & DR Compliance Report

Answers one question fast, for any size of Azure estate: **which VMs are not properly backed up or replicated, right now?**

It uses Azure Resource Graph, so a 24,000-VM estate is about 25 paged queries instead of 24,000 API calls. It needs only **Reader** access. It runs three ways: as a script on your laptop, as a scheduled Azure Automation runbook, or as an Azure Workbook dashboard.

I built it because I spend real time on backup compliance for a large estate at work. The runbooks I maintain there list what exists; this one classifies what is wrong and shows only the VMs that need action.

## What it reports

Every VM gets two statuses.

**Backup status**

| Status | Meaning |
|---|---|
| `Compliant` | Protected, last backup succeeded within `StaleHours` (default 26h) |
| `Stale` | Protected, but the last successful backup is older than the threshold |
| `Failed` | Last backup job failed |
| `Pending` | Protection configured, initial backup not yet run |
| `Stopped` | Protection was stopped; restore points may remain, new ones are not taken |
| `Unprotected` | No Azure Backup at all |
| `Exempt` | Tagged `backup-exempt=true`; excluded from coverage % |

**Site Recovery status** (Azure-to-Azure replication)

| Status | Meaning |
|---|---|
| `Healthy` | Replication normal and a test failover ran within `DrillMaxAgeDays` (default 180) |
| `Warning` / `Critical` | Replication health as reported by ASR |
| `DrillOverdue` | Replicating fine, but DR has not been proven by a test failover recently |
| `NotReplicated` | No ASR protection |

`DrillOverdue` matters: replication that has never been test-failed-over is an assumption, not a recovery plan.

## Output

- **CSV:** every VM with both statuses, vault, policy, last backup time, RPO. For filtering in Excel.
- **HTML:** coverage %, counts by status, and a table of **only** the VMs needing action. Something you can send to a manager.

```
2412 VMs scanned in 9.4s. Coverage 96.8% (2301/2377 in scope).

Status       Count
------       -----
Compliant     2301
Exempt          35
Failed          12
Stale           41
Unprotected     23
```
*(Example output format; numbers are illustrative.)*

## Run it locally

```powershell
Install-Module Az.Accounts, Az.ResourceGraph -Scope CurrentUser
Connect-AzAccount

./scripts/Get-BackupComplianceReport.ps1                              # every subscription you can read
./scripts/Get-BackupComplianceReport.ps1 -SubscriptionId <id1>,<id2>  # specific subscriptions
./scripts/Get-BackupComplianceReport.ps1 -FailBelowPercent 95          # exit 1 under 95%, for pipelines
```

Needs PowerShell 7.2+ and Az.ResourceGraph 0.13+.

## Run it on a schedule (Azure Automation)

1. Create an Automation account with a **system-assigned managed identity**.
2. Give the identity **Reader** on the subscriptions (or a management group) and **Storage Blob Data Contributor** on a storage account for the reports.
3. In the account, import `Az.Accounts`, `Az.ResourceGraph`, `Az.Storage`, and this repo's `src/BackupCompliance` folder (zipped) as a PowerShell 7.2 module.
4. Create Automation variables `ReportStorageAccount` and `ReportContainer`.
5. Import `runbooks/Invoke-BackupComplianceRunbook.ps1` as a PowerShell 7.2 runbook and link it to a daily schedule.

No credentials are stored anywhere; the runbook signs in as the managed identity. Each run writes the CSV and HTML to `<container>/<yyyyMMdd>/` and emits one `COMPLIANCE total=… coverage=…` line you can alert on.

## Dashboard (Azure Workbook)

Azure portal → **Monitor → Workbooks → New → Advanced Editor (`</>`)** → paste `workbook/backup-compliance.workbook.json` → Apply → Save.

It shows coverage per subscription with a red-to-green bar, every VM needing action, and ASR replication health, filtered by a subscription picker.

## Queries

Standalone versions in `/queries` for Resource Graph Explorer or Log Analytics:

| File | Where to run | What |
|---|---|---|
| `vm-backup-protection.kql` | Resource Graph | Every VM with its backup state |
| `asr-replication-health.kql` | Resource Graph | ASR health, RPO, last test failover |
| `coverage-by-subscription.kql` | Resource Graph | Coverage % per subscription, worst first |
| `failed-backup-jobs-24h.kql` | Log Analytics | Failed jobs with error codes (needs vault diagnostics) |

## How it is built

```
src/BackupCompliance/        # module: queries, paging, classification, HTML
scripts/                     # CLI entry point
runbooks/                    # Azure Automation entry point
workbook/                    # Azure Workbook JSON
queries/                     # standalone KQL
tests/                       # Pester unit tests for all classification logic
```

- **Classification is pure functions** (`Get-BackupStatus`, `Get-AsrStatus`, `Get-ComplianceSummary`) with no Azure calls, so every rule is unit-tested with Pester in CI.
- **Paging is handled.** Resource Graph returns at most 1000 rows per call; `Invoke-PagedGraphQuery` follows `SkipToken` until done. Without this, any estate over 1000 VMs silently reports wrong numbers.
- **ASR data is joined in PowerShell, not in KQL,** to stay within Resource Graph's join limits and keep each query readable on its own.
- **HTML output is encoded**, so a VM name can never inject markup into the report.

## Limits

- Covers Azure VMs protected by Azure Backup (IaaS VM workload). SQL-in-VM, Azure Files and on-prem MARS agents are not included yet.
- ASR status covers Azure-to-Azure replication. VMware/Hyper-V to Azure is not included.
- Resource Graph data can lag the portal by a few minutes.
