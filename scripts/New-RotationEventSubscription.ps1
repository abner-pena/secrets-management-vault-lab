<#
.SYNOPSIS
    Wires Key Vault's SecretNearExpiry system event to the rotation
    Automation runbook via Event Grid.

.DESCRIPTION
    Part 4 of the Secrets Management & Vault Lab. Key Vault emits a
    SecretNearExpiry event through Event Grid a configurable window before a
    secret's expiry date. This script subscribes an Automation runbook
    webhook to that event so rotation triggers itself instead of depending
    on someone remembering to run it.

.PARAMETER VaultName
    Key Vault emitting the event.

.PARAMETER AutomationAccountName
    Automation Account hosting the rotation runbook.

.PARAMETER RunbookName
    Runbook to trigger. Defaults to the SQL admin rotation runbook shipped
    in runbooks/Rotate-SqlAdminSecret.ps1.

.EXAMPLE
    .\New-RotationEventSubscription.ps1 -VaultName "kv-iam-lab-prod" -AutomationAccountName "aa-iam-lab-rotation" -ResourceGroup "rg-iam-lab"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$RunbookName = "Rotate-SqlAdminSecret"
)

Import-Module Az.EventGrid -ErrorAction Stop
Import-Module Az.Automation -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop

$vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction Stop

$webhook = Get-AzAutomationWebhook `
    -AutomationAccountName $AutomationAccountName `
    -ResourceGroupName $ResourceGroup `
    -RunbookName $RunbookName `
    -ErrorAction SilentlyContinue

if (-not $webhook) {
    Write-Host "Creating webhook for runbook '$RunbookName'..." -ForegroundColor Cyan
    $expiry = (Get-Date).AddYears(1)
    $webhook = New-AzAutomationWebhook `
        -AutomationAccountName $AutomationAccountName `
        -ResourceGroupName $ResourceGroup `
        -RunbookName $RunbookName `
        -Name "$RunbookName-eventgrid-trigger" `
        -IsEnabled $true `
        -ExpiryTime $expiry `
        -Force

    Write-Host "Webhook URI generated. This value is shown once by Azure; the script has already used it below, no action needed." -ForegroundColor Yellow
}

Write-Host "Creating Event Grid subscription for SecretNearExpiry on vault '$VaultName'..." -ForegroundColor Cyan

New-AzEventGridSubscription `
    -ResourceId $vault.ResourceId `
    -EventSubscriptionName "$VaultName-secret-near-expiry" `
    -Endpoint $webhook.WebhookUri `
    -EndpointType "webhook" `
    -IncludedEventType @("Microsoft.KeyVault.SecretNearExpiry") `
    -SubjectBeginsWith "sql-admin-password"

Write-Host ""
Write-Host "Subscription created." -ForegroundColor Green
Write-Host "Secrets are tagged with a 90-day expiry on creation; the near-expiry event fires 30 days out, giving the rotation job a wide window before anything actually breaks." -ForegroundColor Green
