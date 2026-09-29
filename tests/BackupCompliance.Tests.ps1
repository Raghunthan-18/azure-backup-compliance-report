BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/BackupCompliance/BackupCompliance.psd1') -Force

    $script:now = [datetime]::new(2026, 9, 29, 12, 0, 0, [DateTimeKind]::Utc)

    function New-Vm {
        param(
            [string]$ProtectionState = 'Protected',
            [string]$LastBackupStatus = 'Completed',
            [string]$LastBackupTime = '2026-09-29T02:00:00Z',
            [string]$BackupExempt = ''
        )
        [pscustomobject]@{
            vmId = '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1'
            vmName = 'vm1'; resourceGroup = 'rg'; subscriptionId = 'x'; location = 'centralindia'
            powerState = 'PowerState/running'; environment = 'prod'; backupExempt = $BackupExempt
            vaultName = 'rsv1'; protectionState = $ProtectionState; lastBackupStatus = $LastBackupStatus
            lastBackupTime = $LastBackupTime; backupPolicy = 'DefaultPolicy'
        }
    }

    function New-Replica {
        param([string]$Health = 'Normal', [string]$LastTestFailover = '2026-08-01T00:00:00Z')
        [pscustomobject]@{ replicationHealth = $Health; lastTestFailover = $LastTestFailover; rpoSeconds = 30 }
    }
}

Describe 'Get-BackupStatus' {
    It 'is Compliant for a recent successful backup' {
        Get-BackupStatus -Vm (New-Vm) -Now $now | Should -Be 'Compliant'
    }
    It 'is Unprotected when the VM has no protected item' {
        Get-BackupStatus -Vm (New-Vm -ProtectionState '') -Now $now | Should -Be 'Unprotected'
    }
    It 'is Exempt when tagged backup-exempt=true, even if unprotected' {
        Get-BackupStatus -Vm (New-Vm -ProtectionState '' -BackupExempt 'true') -Now $now | Should -Be 'Exempt'
    }
    It 'is Stopped when protection was stopped' {
        Get-BackupStatus -Vm (New-Vm -ProtectionState 'ProtectionStopped') -Now $now | Should -Be 'Stopped'
    }
    It 'is Pending while the initial backup has not run' {
        Get-BackupStatus -Vm (New-Vm -ProtectionState 'IRPending') -Now $now | Should -Be 'Pending'
    }
    It 'is Failed when the last job failed' {
        Get-BackupStatus -Vm (New-Vm -LastBackupStatus 'Failed') -Now $now | Should -Be 'Failed'
    }
    It 'is Stale when the last backup is older than the threshold' {
        Get-BackupStatus -Vm (New-Vm -LastBackupTime '2026-09-27T10:00:00Z') -Now $now | Should -Be 'Stale'
    }
    It 'respects a custom StaleHours threshold' {
        Get-BackupStatus -Vm (New-Vm -LastBackupTime '2026-09-27T10:00:00Z') -StaleHours 72 -Now $now | Should -Be 'Compliant'
    }
    It 'is Stale when the backup time cannot be parsed' {
        Get-BackupStatus -Vm (New-Vm -LastBackupTime 'not-a-date') -Now $now | Should -Be 'Stale'
    }
}

Describe 'Get-AsrStatus' {
    It 'is NotReplicated when there is no replica' {
        Get-AsrStatus -Replica $null -Now $now | Should -Be 'NotReplicated'
    }
    It 'passes Critical through' {
        Get-AsrStatus -Replica (New-Replica -Health 'Critical') -Now $now | Should -Be 'Critical'
    }
    It 'passes Warning through' {
        Get-AsrStatus -Replica (New-Replica -Health 'Warning') -Now $now | Should -Be 'Warning'
    }
    It 'is Healthy with a recent test failover' {
        Get-AsrStatus -Replica (New-Replica) -Now $now | Should -Be 'Healthy'
    }
    It 'is DrillOverdue when the last test failover is too old' {
        Get-AsrStatus -Replica (New-Replica -LastTestFailover '2025-01-01T00:00:00Z') -Now $now | Should -Be 'DrillOverdue'
    }
    It 'is DrillOverdue when no test failover was ever run' {
        Get-AsrStatus -Replica (New-Replica -LastTestFailover '') -Now $now | Should -Be 'DrillOverdue'
    }
}

Describe 'Get-ComplianceSummary' {
    It 'excludes exempt VMs from the coverage denominator' {
        $rows = @(
            [pscustomobject]@{ BackupStatus = 'Compliant'; AsrStatus = 'Healthy' }
            [pscustomobject]@{ BackupStatus = 'Compliant'; AsrStatus = 'Healthy' }
            [pscustomobject]@{ BackupStatus = 'Unprotected'; AsrStatus = 'NotReplicated' }
            [pscustomobject]@{ BackupStatus = 'Exempt'; AsrStatus = 'NotReplicated' }
        )
        $s = Get-ComplianceSummary -Rows $rows
        $s.TotalVms | Should -Be 4
        $s.InScope | Should -Be 3
        $s.Compliant | Should -Be 2
        $s.CoveragePercent | Should -Be 66.7
    }
    It 'reports 100% for an empty estate instead of dividing by zero' {
        (Get-ComplianceSummary -Rows @()).CoveragePercent | Should -Be 100
    }
}

Describe 'ConvertTo-ComplianceHtml' {
    It 'lists only VMs that need action and HTML-encodes names' {
        $rows = @(
            [pscustomobject]@{ VmName = 'ok-vm'; ResourceGroup = 'rg'; BackupStatus = 'Compliant'; LastBackupTime = ''; AsrStatus = 'Healthy'; Environment = 'prod' }
            [pscustomobject]@{ VmName = '<bad>'; ResourceGroup = 'rg'; BackupStatus = 'Failed'; LastBackupTime = ''; AsrStatus = 'Healthy'; Environment = 'prod' }
        )
        $html = ConvertTo-ComplianceHtml -Rows $rows -Summary (Get-ComplianceSummary -Rows $rows)
        $html | Should -Match '&lt;bad&gt;'
        $html | Should -Not -Match 'ok-vm'
    }
}
