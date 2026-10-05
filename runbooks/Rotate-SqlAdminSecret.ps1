<#
.SYNOPSIS
    Azure Automation runbook that rotates the Azure SQL admin password and
    updates its Key Vault secret, in that order, with a rollback-safe
    sequence.

.DESCRIPTION
    Runs under the Automation Account's system-assigned managed identity,
    so it authenticates to both Key Vault and Azure SQL with zero stored
    credentials of its own. Triggered by the Event Grid subscription created
    in New-RotationEventSubscription.ps1, or run manually / on a schedule.

    Sequence, and why it is ordered this way:
      1. Generate a new high-entropy password.
      2. Update the Azure SQL Server admin credential to the new password.
      3. Only after SQL confirms the change, write the new value as a new
         Key Vault secret version.
      4. Disable the previous secret version.

    If step 2 fails, nothing in Key Vault has changed and the application
    keeps working with the old password. If step 2 succeeds but step 3
    fails, the runbook logs a critical alert rather than silently leaving
    the vault out of sync with the database, because that combination is
    the one failure mode that actually causes an outage.

.PARAMETER VaultName
    Key Vault holding the secret.

.PARAMETER SecretName
    Secret to rotate.

.PARAMETER SqlServerName
    Azure SQL logical server whose admin password is being rotated.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$SecretName,

    [Parameter(Mandatory = $true)]
    [string]$SqlServerName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = $env:LAB_RESOURCE_GROUP,

    [Parameter(Mandatory = $false)]
    [int]$NewSecretExpiryDays = 90
)

# Authenticate using the Automation Account's system-assigned managed
# identity. No client secret, no certificate, no stored credential.
Connect-AzAccount -Identity | Out-Null

function New-HighEntropyPassword {
    param([int]$Length = 32)
    $upper = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = [char[]]"abcdefghijkmnpqrstuvwxyz"
    $digit = [char[]]"23456789"
    $special = [char[]]"!@#$%^&*-_=+"
    $all = $upper + $lower + $digit + $special

    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $passwordChars = for ($i = 0; $i -lt $Length; $i++) { $all[$bytes[$i] % $all.Length] }
    $password = -join $passwordChars

    # Guarantee complexity requirements are met regardless of random draw.
    return $password + ($upper | Get-Random) + ($digit | Get-Random) + ($special | Get-Random)
}

Write-Output "Starting rotation for secret '$SecretName' in vault '$VaultName'..."

$newPassword = New-HighEntropyPassword
$secureNewPassword = ConvertTo-SecureString -String $newPassword -AsPlainText -Force

try {
    Write-Output "Step 1/3: Updating Azure SQL Server admin credential..."
    Set-AzSqlServer -ResourceGroupName $ResourceGroup -ServerName $SqlServerName -SqlAdministratorPassword $secureNewPassword -ErrorAction Stop
    Write-Output "  SQL Server credential updated successfully."
}
catch {
    Write-Error "SQL credential update failed. Key Vault was NOT touched; the current secret value is still correct for the database. $_"
    throw
}

try {
    Write-Output "Step 2/3: Writing new secret version to Key Vault..."
    $expiry = (Get-Date).AddDays($NewSecretExpiryDays)
    $newVersion = Set-AzKeyVaultSecret `
        -VaultName $VaultName `
        -Name $SecretName `
        -SecretValue $secureNewPassword `
        -Expires $expiry `
        -ContentType "text/plain" `
        -Tag @{ "rotated-by" = "automation-runbook"; "rotated-on" = (Get-Date -Format "o") } `
        -ErrorAction Stop
    Write-Output "  New secret version created: $($newVersion.Version), expires $expiry."
}
catch {
    Write-Error "CRITICAL: SQL password was changed but the new Key Vault secret version failed to write. Vault and database are now OUT OF SYNC. Manual intervention required immediately. $_"
    throw
}

try {
    Write-Output "Step 3/3: Disabling previous secret version..."
    $allVersions = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -IncludeVersions
    $previousVersion = $allVersions | Where-Object { $_.Version -ne $newVersion.Version -and $_.Enabled } | Sort-Object Updated -Descending | Select-Object -First 1

    if ($previousVersion) {
        Update-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -Version $previousVersion.Version -Enable $false | Out-Null
        Write-Output "  Previous version $($previousVersion.Version) disabled."
    }
}
catch {
    Write-Warning "New secret version is live and the database is updated, but disabling the previous version failed. Non-blocking; clean up manually. $_"
}

Write-Output "Rotation complete for '$SecretName'."
