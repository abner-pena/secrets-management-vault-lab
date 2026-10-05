<#
.SYNOPSIS
    Creates the Azure Automation Account that hosts the rotation runbook,
    enables its system-assigned managed identity, imports the runbook, and
    grants that identity exactly the access it needs: write access to the
    one secret it rotates, and SQL Server Contributor on the target server.

.PARAMETER AccountName
    Name for the new Automation Account.

.PARAMETER ResourceGroup
    Resource group to create it in.

.EXAMPLE
    .\New-RotationAutomationAccount.ps1 -AccountName "aa-iam-lab-rotation" -ResourceGroup "rg-iam-lab" -VaultName "kv-iam-lab-prod" -SecretName "sql-admin-password" -SqlServerName "sql-iam-lab"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [Parameter(Mandatory = $false)]
    [string]$VaultName,

    [Parameter(Mandatory = $false)]
    [string]$SecretName = "sql-admin-password",

    [Parameter(Mandatory = $false)]
    [string]$SqlServerName
)

Import-Module Az.Automation -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

Write-Host "Creating Automation Account '$AccountName' with a system-assigned managed identity..." -ForegroundColor Cyan

$account = New-AzAutomationAccount `
    -Name $AccountName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -AssignSystemIdentity

Write-Host "Importing rotation runbook..." -ForegroundColor Cyan

Import-AzAutomationRunbook `
    -Name "Rotate-SqlAdminSecret" `
    -Path "$PSScriptRoot\..\runbooks\Rotate-SqlAdminSecret.ps1" `
    -Type PowerShell `
    -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $AccountName `
    -Published | Out-Null

$principalId = $account.Identity.PrincipalId

if ($VaultName) {
    Write-Host "Granting 'Key Vault Secrets Officer' scoped to secret '$SecretName' (rotation needs write access to create new versions)..." -ForegroundColor Cyan
    & "$PSScriptRoot\Grant-ManagedIdentityVaultAccess.ps1" -VaultName $VaultName -SecretName $SecretName -PrincipalId $principalId -Role "Key Vault Secrets Officer"
}

if ($SqlServerName) {
    Write-Host "Granting 'SQL Server Contributor' on '$SqlServerName' so the runbook can update the admin credential..." -ForegroundColor Cyan
    $sqlServerResourceId = (Get-AzSqlServer -ServerName $SqlServerName -ResourceGroupName $ResourceGroup).ResourceId
    New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName "SQL Server Contributor" -Scope $sqlServerResourceId | Out-Null
}

# The runbook reads the resource group from an environment variable rather
# than a hardcoded value, set as an Automation variable here.
New-AzAutomationVariable `
    -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $AccountName `
    -Name "LAB_RESOURCE_GROUP" `
    -Value $ResourceGroup `
    -Encrypted $false | Out-Null

Write-Host ""
Write-Host "Automation Account ready." -ForegroundColor Green
Write-Host "Principal ID (for reference or further grants): $principalId"
Write-Host "Next: New-RotationEventSubscription.ps1 to trigger this runbook on SecretNearExpiry." -ForegroundColor Cyan
