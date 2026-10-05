<#
.SYNOPSIS
    Attaches a private endpoint to a Key Vault and links the private DNS
    zone so vault traffic never touches the public internet.

.DESCRIPTION
    Part 2 of the Secrets Management & Vault Lab. RBAC and purge protection
    control who can read a secret and how deletion works, but neither
    controls where a request can come from. This script closes that gap by
    creating a private endpoint into the vault's subnet and a private DNS
    zone (privatelink.vaultcore.azure.net) so name resolution routes calls
    from inside the VNet to the private IP instead of the public endpoint,
    which is already set to Disabled by New-SecureKeyVault.ps1.

.PARAMETER VaultName
    Key Vault to attach the private endpoint to.

.PARAMETER VNetName
    Virtual network containing the private endpoint subnet.

.PARAMETER SubnetName
    Subnet dedicated to private endpoints.

.EXAMPLE
    .\New-VaultPrivateEndpoint.ps1 -VaultName "kv-iam-lab-prod" -VNetName "vnet-iam-lab" -SubnetName "snet-privatelink"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$VNetName,

    [Parameter(Mandatory = $true)]
    [string]$SubnetName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = (Get-AzKeyVault -VaultName $VaultName).ResourceGroupName
)

Import-Module Az.Network -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop
Import-Module Az.PrivateDns -ErrorAction Stop

$vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction Stop
$vnet  = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup -ErrorAction Stop
$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }

if (-not $subnet) {
    throw "Subnet '$SubnetName' not found in VNet '$VNetName'."
}

# Private endpoints require the subnet to explicitly allow it.
if ($subnet.PrivateEndpointNetworkPolicies -ne "Disabled") {
    Write-Host "Disabling private endpoint network policies on subnet '$SubnetName'..." -ForegroundColor Cyan
    ($vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }).PrivateEndpointNetworkPolicies = "Disabled"
    Set-AzVirtualNetwork -VirtualNetwork $vnet | Out-Null
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
}

$connectionName = "$VaultName-pe-connection"
$peConnection = New-AzPrivateLinkServiceConnection `
    -Name $connectionName `
    -PrivateLinkServiceId $vault.ResourceId `
    -GroupId "vault"

Write-Host "Creating private endpoint for '$VaultName' in subnet '$SubnetName'..." -ForegroundColor Cyan

$pe = New-AzPrivateEndpoint `
    -Name "$VaultName-pe" `
    -ResourceGroupName $ResourceGroup `
    -Location $vault.Location `
    -Subnet $subnet `
    -PrivateLinkServiceConnection $peConnection

# Private DNS zone so resolution of {vaultname}.vault.azure.net inside the
# VNet returns the private endpoint's IP instead of the public one.
$zoneName = "privatelink.vaultcore.azure.net"
$zone = Get-AzPrivateDnsZone -ResourceGroupName $ResourceGroup -Name $zoneName -ErrorAction SilentlyContinue

if (-not $zone) {
    Write-Host "Creating private DNS zone '$zoneName'..." -ForegroundColor Cyan
    $zone = New-AzPrivateDnsZone -ResourceGroupName $ResourceGroup -Name $zoneName
}

$linkName = "$VNetName-link"
$existingLink = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $ResourceGroup -ZoneName $zoneName -Name $linkName -ErrorAction SilentlyContinue

if (-not $existingLink) {
    Write-Host "Linking DNS zone to VNet '$VNetName'..." -ForegroundColor Cyan
    New-AzPrivateDnsVirtualNetworkLink `
        -ResourceGroupName $ResourceGroup `
        -ZoneName $zoneName `
        -Name $linkName `
        -VirtualNetworkId $vnet.Id `
        -EnableRegistration:$false | Out-Null
}

$dnsConfig = New-AzPrivateDnsZoneConfig -Name $zoneName -PrivateDnsZoneId $zone.ResourceId
New-AzPrivateDnsZoneGroup `
    -ResourceGroupName $ResourceGroup `
    -PrivateEndpointName "$VaultName-pe" `
    -Name "default" `
    -PrivateDnsZoneConfig $dnsConfig | Out-Null

Write-Host ""
Write-Host "Private endpoint provisioned and DNS wired." -ForegroundColor Green
Write-Host "Vault public network access remains Disabled; only resources inside '$VNetName' (or peered/linked networks) can now reach it." -ForegroundColor Green
