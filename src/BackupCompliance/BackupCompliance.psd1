@{
    RootModule        = 'BackupCompliance.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5f0c6a8e-2b7d-4c1a-9e3f-7a1d2c4b6e90'
    Author            = 'Raghunthan D'
    Description       = 'Azure Backup and Site Recovery coverage report across subscriptions, built on Azure Resource Graph.'
    PowerShellVersion = '7.2'
    RequiredModules   = @()
    FunctionsToExport = @(
        'Invoke-PagedGraphQuery', 'Get-BackupStatus', 'Get-AsrStatus',
        'Get-BackupComplianceData', 'Get-ComplianceSummary', 'ConvertTo-ComplianceHtml'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
