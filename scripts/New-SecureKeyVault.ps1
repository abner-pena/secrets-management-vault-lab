<#
.SYNOPSIS
    Provisions an Azure Key Vault with RBAC authorization, soft-delete, purge
    protection, and public network access disabled from the start.

.DESCRIPTION
    Part 1 of the Secrets Management & Vault Lab. Creates a vault configured
    to the secure defaults this lab assumes everywhere else: RBAC instead of
    the legacy access-policy model, soft-delete with a 90-day retention
    window, purge protection so a soft-deleted secret cannot be purged early,
    and public network access disabled (a private endpoint is added
    separately in Part 2).

.PARAMETER VaultName
    Globally unique Key Vault name.

.PARAMETER ResourceGroup
    Resource group to create the vault in.

.PARAMETER Location
    Azure region.

.EXAMPLE
    .\New-SecureKeyVault.ps1 -VaultName "kv-iam-lab-prod" -ResourceGroup "rg-iam-lab" -Location "eastus2"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [Parameter(Mandatory = $false)]
    [int]$SoftDeleteRetentionDays = 90
)

Import-Module Az.KeyVault -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {
    throw "Not connected to Azure. Run Connect-AzAccount first."
}

if (-not (Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)) {
    Write-Host "Resource group '$ResourceGroup' not found. Creating it in $Location." -ForegroundColor Yellow
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
}

Write-Host "Creating Key Vault '$VaultName' with RBAC authorization, soft-delete, and purge protection..." -ForegroundColor Cyan

$vault = New-AzKeyVault `
    -VaultName $VaultName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -EnableRbacAuthorization $true `
    -EnableSoftDelete $true `
    -SoftDeleteRetentionInDays $SoftDeleteRetentionDays `
    -EnablePurgeProtection $true `
    -PublicNetworkAccess "Disabled" `
    -Sku "standard"

if (-not $vault) {
    throw "Key Vault creation failed. Check subscription quota and naming (vault names must be globally unique)."
}

Write-Host ""
Write-Host "Vault provisioned:" -ForegroundColor Green
Write-Host "  Name:                    $($vault.VaultName)"
Write-Host "  RBAC authorization:      enabled (legacy access policies are ignored on this vault)"
Write-Host "  Soft-delete retention:   $SoftDeleteRetentionDays days"
Write-Host "  Purge protection:        enabled (irreversible; cannot be turned off later)"
Write-Host "  Public network access:   Disabled (attach a private endpoint before anything needs to reach this vault)"
Write-Host ""
Write-Host "Next: run New-VaultPrivateEndpoint.ps1 to give something a network path to this vault." -ForegroundColor Cyan

# Grant the deploying user Key Vault Administrator on the vault so day-2 secret
# and access management can happen without falling back to access policies.
$currentUser = (Get-AzContext).Account.Id
$scope = $vault.ResourceId

Write-Host "Granting 'Key Vault Administrator' to $currentUser scoped to this vault for initial setup..." -ForegroundColor Cyan
New-AzRoleAssignment -SignInName $currentUser -RoleDefinitionName "Key Vault Administrator" -Scope $scope -ErrorAction SilentlyContinue | Out-Null

Write-Host "Done." -ForegroundColor Green
