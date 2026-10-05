<#
.SYNOPSIS
    Creates a minimal lab virtual network with a subnet dedicated to
    private endpoints.

.DESCRIPTION
    Support script for SETUP.md. Only needed if you do not already have a
    VNet to attach the Key Vault private endpoint to in Part 2.

.PARAMETER VNetName
    Name for the new virtual network.

.PARAMETER ResourceGroup
    Resource group to create it in.

.PARAMETER Location
    Azure region.

.EXAMPLE
    .\New-LabVNet.ps1 -VNetName "vnet-iam-lab" -ResourceGroup "rg-iam-lab" -Location "eastus2"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VNetName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [Parameter(Mandatory = $false)]
    [string]$AddressPrefix = "10.42.0.0/16",

    [Parameter(Mandatory = $false)]
    [string]$PrivateLinkSubnetPrefix = "10.42.1.0/24",

    [Parameter(Mandatory = $false)]
    [string]$AppSubnetPrefix = "10.42.2.0/24"
)

Import-Module Az.Network -ErrorAction Stop

if (-not (Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
}

$privateLinkSubnet = New-AzVirtualNetworkSubnetConfig -Name "snet-privatelink" -AddressPrefix $PrivateLinkSubnetPrefix -PrivateEndpointNetworkPoliciesFlag "Disabled"
$appSubnet = New-AzVirtualNetworkSubnetConfig -Name "snet-app" -AddressPrefix $AppSubnetPrefix

Write-Host "Creating VNet '$VNetName' ($AddressPrefix) with subnets snet-privatelink and snet-app..." -ForegroundColor Cyan

$vnet = New-AzVirtualNetwork `
    -Name $VNetName `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -AddressPrefix $AddressPrefix `
    -Subnet $privateLinkSubnet, $appSubnet

Write-Host "VNet created: $($vnet.Name)" -ForegroundColor Green
Write-Host "Private endpoint subnet: snet-privatelink ($PrivateLinkSubnetPrefix)"
Write-Host "Application subnet:      snet-app ($AppSubnetPrefix)"
