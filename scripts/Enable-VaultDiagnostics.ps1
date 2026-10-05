<#
.SYNOPSIS
    Points Key Vault diagnostic logging at a Log Analytics workspace so
    the KQL detections in kql/ have data to run against.

.PARAMETER VaultName
    Key Vault to enable diagnostics on.

.PARAMETER WorkspaceName
    Existing Log Analytics workspace name.

.EXAMPLE
    .\Enable-VaultDiagnostics.ps1 -VaultName "kv-iam-lab-prod" -WorkspaceName "law-iam-lab"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = (Get-AzKeyVault -VaultName $VaultName).ResourceGroupName
)

Import-Module Az.KeyVault -ErrorAction Stop
Import-Module Az.OperationalInsights -ErrorAction Stop
Import-Module Az.Monitor -ErrorAction Stop

$vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction Stop
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction Stop

$logCategories = @("AuditEvent", "AzurePolicyEvaluationDetails")
$logSettings = $logCategories | ForEach-Object {
    New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category $_
}
$metricSettings = New-AzDiagnosticSettingMetricSettingsObject -Enabled $true -Category "AllMetrics"

Write-Host "Enabling diagnostic settings on '$VaultName', forwarding to workspace '$WorkspaceName'..." -ForegroundColor Cyan

New-AzDiagnosticSetting `
    -Name "$VaultName-diag-to-$WorkspaceName" `
    -ResourceId $vault.ResourceId `
    -WorkspaceId $workspace.ResourceId `
    -Log $logSettings `
    -Metric $metricSettings | Out-Null

Write-Host "Diagnostic setting created. Allow up to 15 minutes for the first audit events to land in Log Analytics." -ForegroundColor Green
Write-Host "Query the AuditEvent category (table AzureDiagnostics, or AZKVAuditLogs if resource-specific tables are enabled on this workspace) using the KQL in kql/." -ForegroundColor Green
