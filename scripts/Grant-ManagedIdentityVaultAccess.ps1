<#
.SYNOPSIS
    Grants a managed identity RBAC access to a single Key Vault secret,
    not the whole vault.

.DESCRIPTION
    Part 3 of the Secrets Management & Vault Lab. Scopes the role
    assignment to the secret's own resource ID rather than the vault's,
    so a compromised identity's token is useful against exactly one
    secret instead of everything the vault holds.

.PARAMETER VaultName
    Key Vault containing the secret.

.PARAMETER SecretName
    Name of the secret to scope access to.

.PARAMETER PrincipalId
    Object ID of the managed identity (or other principal) to grant access to.

.PARAMETER Role
    RBAC role to assign. Defaults to "Key Vault Secrets User" (read-only get/list
    on secret values). Use "Key Vault Secrets Officer" for identities that also
    need to write new secret versions, such as the rotation runbook.

.EXAMPLE
    .\Grant-ManagedIdentityVaultAccess.ps1 -VaultName "kv-iam-lab-prod" -SecretName "sql-admin-password" -PrincipalId "11111111-2222-3333-4444-555555555555" -Role "Key Vault Secrets User"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$SecretName,

    [Parameter(Mandatory = $true)]
    [string]$PrincipalId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Key Vault Secrets User", "Key Vault Secrets Officer")]
    [string]$Role = "Key Vault Secrets User"
)

Import-Module Az.KeyVault -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

$vault = Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop

if (-not $vault.EnableRbacAuthorization) {
    throw "Vault '$VaultName' is not using RBAC authorization. This script only supports RBAC-model vaults (see New-SecureKeyVault.ps1)."
}

# Scope the assignment to the individual secret, not the vault. This is the
# whole point: Key Vault RBAC lets you scope at the object level, and doing
# so means one compromised managed identity token reaches exactly the
# secret it was issued for.
$secretScope = "$($vault.ResourceId)/secrets/$SecretName"

Write-Host "Assigning '$Role' to principal $PrincipalId, scoped to secret '$SecretName' in vault '$VaultName'..." -ForegroundColor Cyan

$existing = Get-AzRoleAssignment -ObjectId $PrincipalId -Scope $secretScope -RoleDefinitionName $Role -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "Assignment already exists. No change made." -ForegroundColor Yellow
} else {
    New-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $Role -Scope $secretScope | Out-Null
    Write-Host "Role assignment created." -ForegroundColor Green
}

Write-Host ""
Write-Host "Verify with:" -ForegroundColor Cyan
Write-Host "  Get-AzRoleAssignment -ObjectId $PrincipalId -Scope `"$secretScope`""
Write-Host ""
Write-Host "Reminder: this principal can now read (or write, if Officer) ONLY this secret." -ForegroundColor Yellow
Write-Host "A role assignment at the vault's resource ID instead of the secret's would grant access to every secret in the vault. Scope narrow by default." -ForegroundColor Yellow
