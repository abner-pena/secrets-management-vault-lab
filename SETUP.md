# Setup

Environment and prerequisites for the Secrets Management & Vault Lab.

## Subscription and permissions

You need, at minimum:

- **Owner** or **User Access Administrator + Key Vault Administrator** on the resource group, to create the vault and assign RBAC roles.
- **Contributor** on the resource group, to create the App Service (or VM), Azure SQL Database, virtual network, Automation Account, and Event Grid subscription used in the rotation demo.

Least privilege in production would split these across roles; the lab uses a broader grant on a scoped resource group for simplicity.

## Networking

The private endpoint in Part 2 needs an existing virtual network with a subnet dedicated to private endpoints (`snet-privatelink` in the scripts). If you do not already have one:

```powershell
.\scripts\New-LabVNet.ps1 -VNetName "vnet-iam-lab" -ResourceGroup "rg-iam-lab" -Location "eastus2"
```

Private DNS zone integration (`privatelink.vaultcore.azure.net`) is required for name resolution to route to the private endpoint instead of the public Key Vault DNS record. `New-VaultPrivateEndpoint.ps1` creates and links this zone automatically if one does not already exist in the resource group.

## Tooling

```powershell
Install-Module Az.KeyVault, Az.Resources, Az.Sql, Az.Automation, Az.EventGrid -Scope CurrentUser
Connect-AzAccount
Set-AzContext -SubscriptionId "<your-subscription-id>"
```

## Test resources

The rotation demo (Part 4) targets an Azure SQL Database. If you do not already have one for testing:

```powershell
.\scripts\New-LabSqlServer.ps1 -SqlServerName "sql-iam-lab" -ResourceGroup "rg-iam-lab" -Location "eastus2"
```

This provisions a minimal Azure SQL logical server with a placeholder admin password that Part 4's runbook then takes over rotating.

## Log Analytics workspace

The KQL in `kql/` runs against Key Vault diagnostic logs. Point the vault's diagnostic settings at a Log Analytics workspace before expecting query results:

```powershell
.\scripts\Enable-VaultDiagnostics.ps1 -VaultName "kv-iam-lab-prod" -WorkspaceName "<your-log-analytics-workspace>"
```

Allow up to 15 minutes for the first batch of audit events to land after enabling diagnostics.

## Automation Account

The rotation runbook in `runbooks/Rotate-SqlAdminSecret.ps1` runs inside an Azure Automation Account under a system-assigned managed identity, which is what lets it authenticate to Key Vault and Azure SQL without a stored credential of its own:

```powershell
.\scripts\New-RotationAutomationAccount.ps1 -AccountName "aa-iam-lab-rotation" -ResourceGroup "rg-iam-lab"
```

The script also grants that Automation Account's managed identity `Key Vault Secrets Officer` (write access, since rotation needs to create new secret versions) scoped to the single `sql-admin-password` secret, and the `SQL Server Contributor` role on the SQL server so it can update the admin credential.

## Recommended build order

1. `New-SecureKeyVault.ps1` to provision the vault with RBAC and purge protection.
2. `New-LabVNet.ps1` (if needed) then `New-VaultPrivateEndpoint.ps1` to isolate the network path.
3. `Enable-VaultDiagnostics.ps1` so audit logging is capturing data from the start.
4. `New-LabSqlServer.ps1` (if needed) to have a rotation target.
5. `Grant-ManagedIdentityVaultAccess.ps1` for the application identity that will read the secret day to day.
6. `New-RotationAutomationAccount.ps1` then `New-RotationEventSubscription.ps1` to wire up automated rotation.
7. Deploy `policies/keyvault-rbac-network-policy.json` as an Azure Policy assignment so the guardrails apply tenant-wide going forward, not just to this one vault.
