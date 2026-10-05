<#
.SYNOPSIS
    Provisions a minimal Azure SQL logical server for the rotation demo,
    with a placeholder admin password that Rotate-SqlAdminSecret.ps1 then
    takes over managing.

.DESCRIPTION
    Support script for SETUP.md Part 4 (automated rotation). The
    placeholder password set here is never meant to persist; treat first
    boot as already-compromised and run the rotation runbook immediately
    after this script to hand credential ownership to Key Vault.

.PARAMETER SqlServerName
    Globally unique Azure SQL logical server name.

.PARAMETER ResourceGroup
    Resource group to create it in.

.PARAMETER Location
    Azure region.

.EXAMPLE
    .\New-LabSqlServer.ps1 -SqlServerName "sql-iam-lab" -ResourceGroup "rg-iam-lab" -Location "eastus2"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [Parameter(Mandatory = $false)]
    [string]$AdminLogin = "sqlvaultadmin"
)

Import-Module Az.Sql -ErrorAction Stop

if (-not (Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
}

# Placeholder only. This value is intentionally never reused; the rotation
# runbook overwrites it on first run and Key Vault becomes the source of
# truth for this credential from that point forward.
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$placeholderPassword = [Convert]::ToBase64String($bytes) + "aA1!"
$securePlaceholder = ConvertTo-SecureString -String $placeholderPassword -AsPlainText -Force

Write-Host "Creating Azure SQL Server '$SqlServerName' with a placeholder admin credential..." -ForegroundColor Cyan

$sqlServer = New-AzSqlServer `
    -ServerName $SqlServerName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -SqlAdministratorCredentials (New-Object System.Management.Automation.PSCredential($AdminLogin, $securePlaceholder))

Write-Host "SQL Server provisioned: $($sqlServer.FullyQualifiedDomainName)" -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT: the admin password set here is a throwaway placeholder, not stored anywhere durable." -ForegroundColor Yellow
Write-Host "Run Rotate-SqlAdminSecret.ps1 immediately after this to generate the real credential and write it to Key Vault as the source of truth." -ForegroundColor Yellow
