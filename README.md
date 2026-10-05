# Secrets Management & Vault Lab

A hands-on Azure Key Vault build that gets application and database credentials out of config files, pipeline variables, and Slack messages, and into a governed secrets store: managed identity access with no vault credential to leak, RBAC scoped to individual secrets instead of the whole vault, automated rotation that ships a new password before the old one expires, network isolation with a private endpoint, and KQL detections for anomalous secret access.

**Author:** Abner Peña, IAM & Cloud Security Engineer
**Stack:** Azure Key Vault, Managed Identities, Azure RBAC, Event Grid, Azure Automation, Private Endpoints, Az PowerShell, KQL

---

## Overview

Every environment has secrets: database connection strings, API keys, TLS certificates, service account passwords. Most of them end up in the wrong place because the wrong place is the path of least resistance:

- **Hardcoded in app config or source control.** `appsettings.json` gets committed once, and now the secret's real lifecycle is "until someone notices in a GitHub secret-scanning alert."
- **Pasted into CI/CD pipeline variables.** Convenient, but the pipeline log can echo it, and every contributor with edit access on the pipeline can read it.
- **Never rotated.** A password set during initial deployment three years ago is still the password, because rotating it means finding every place that reads it and nobody wants to own that.
- **Shared over Slack or a wiki page "just this once."** It is never just once, and the message never gets deleted.

This lab replaces all four patterns with one model: secrets live in **Azure Key Vault**, only identities that specifically need a secret can read it, nothing that reads a secret authenticates with a credential of its own, and rotation is a scheduled job instead of a ticket nobody files.

| Problem | What this lab does about it |
|---|---|
| Secrets committed to source control or config files | Application code calls Key Vault at runtime; nothing sensitive ships in the repo or the image |
| Vault access itself needs a credential | Managed identity on the calling resource authenticates to Key Vault with zero secrets |
| Anyone with vault access can read every secret | Azure RBAC scoped per-secret (`Key Vault Secrets User` on a single secret, not `Contributor` on the vault) |
| Passwords never rotate because rotation is manual and risky | Event Grid fires on near-expiry, an Automation runbook rotates the value and updates the downstream system before the old one dies |
| Vault reachable from the public internet | Private endpoint plus firewall deny public network access by default |
| Deleted or purged secrets are unrecoverable and unaudited | Soft-delete and purge protection enabled, all operations logged to Log Analytics |
| No visibility into who read what, when | Diagnostic logging plus KQL detections for bulk reads, off-hours access, and access from unexpected principals |

---

## Architecture

```
   App Service / VM / Function            Azure Key Vault                Downstream system
  ───────────────────────────          ──────────────────────          ──────────────────────
   System-assigned                      RBAC: Key Vault Secrets
   managed identity          ───────>   User, scoped to one              Azure SQL Database
   (no credential stored)               secret via a role                (admin password)
          │                             assignment condition
          │  GET secret                       │
          └───────────────────────────────────┘
                                                │
                                          Private Endpoint
                                          (no public network access)
                                                │
                                          Diagnostic Settings
                                                │
                                                v
                                        Log Analytics Workspace
                                                │
                                    KQL: anomalous access detections

   Rotation path:
   Key Vault "secret near expiry" event  ──Event Grid──>  Automation Account runbook
                                                                  │
                                                     generates new password, updates
                                                     Azure SQL, writes new secret version
```

---

## What this lab builds

1. **A Key Vault with RBAC authorization** (not the legacy access-policy model), soft-delete and purge protection on, and public network access disabled behind a private endpoint.
2. **Per-secret RBAC assignments.** Instead of granting `Key Vault Secrets Officer` on the whole vault, each managed identity gets `Key Vault Secrets User` scoped to the one secret it needs, using Azure RBAC conditions.
3. **Managed identity access from a calling resource.** A system-assigned managed identity on an App Service (or VM) reads a secret at runtime with zero stored credentials.
4. **Automated rotation.** An Azure Automation runbook, triggered by an Event Grid `SecretNearExpiry` event, generates a new value, updates the downstream system (Azure SQL admin password in this lab), and writes the new value as a new secret version, all before the old value expires.
5. **A Key Vault firewall and Azure Policy guardrail** that denies creation of any Key Vault with public network access enabled or RBAC authorization turned off.
6. **KQL detections** for bulk secret enumeration, access from an unexpected principal or IP, and secrets approaching expiry with no rotation configured.

---

## Part 1: Provision the vault

See [SETUP.md](SETUP.md) for prerequisites. Create the vault with RBAC authorization, soft-delete, and purge protection:

```powershell
.\scripts\New-SecureKeyVault.ps1 -VaultName "kv-iam-lab-prod" -ResourceGroup "rg-iam-lab" -Location "eastus2"
```

The script sets `--enable-rbac-authorization true`, `--enable-soft-delete true` (90-day retention), `--enable-purge-protection true`, and `--public-network-access Disabled`. Purge protection matters because without it, an attacker (or a mistake) with delete rights can purge a soft-deleted secret immediately instead of waiting out the retention window, which defeats the point of soft-delete entirely.

---

## Part 2: Lock down the network path

A vault with perfect RBAC and a public endpoint is still one leaked management-plane credential away from being readable from anywhere. Attach a private endpoint and deny public access:

```powershell
.\scripts\New-VaultPrivateEndpoint.ps1 -VaultName "kv-iam-lab-prod" -VNetName "vnet-iam-lab" -SubnetName "snet-privatelink"
```

The Azure Policy definition in [`policies/keyvault-rbac-network-policy.json`](policies/keyvault-rbac-network-policy.json) enforces this tenant-wide going forward: it audits (and can be set to deny) any Key Vault created with access-policy authorization instead of RBAC, or with public network access left enabled.

---

## Part 3: Grant access with managed identity, not credentials

Enable a system-assigned managed identity on the resource that needs the secret, then grant that identity `Key Vault Secrets User` scoped to exactly one secret:

```powershell
.\scripts\Grant-ManagedIdentityVaultAccess.ps1 `
  -VaultName "kv-iam-lab-prod" `
  -SecretName "sql-admin-password" `
  -PrincipalId "<managed-identity-object-id>" `
  -Role "Key Vault Secrets User"
```

Scoping the role assignment to the secret's resource ID, not the vault's, means an App Service that needs the SQL password cannot also read the API key sitting three secrets over. This is the same least-privilege principle as everything else in this portfolio applied to secrets specifically: a broad grant here is a broad grant everywhere that identity's compromised token can reach.

The application itself never sees a vault credential. The App Service SDK (or the Key Vault reference in App Service configuration) requests a token from the platform's managed identity endpoint and presents that token to Key Vault. Nothing to rotate on the application side, nothing to leak from application config.

---

## Part 4: Automate rotation

Manual rotation does not happen. Automated rotation does. This lab rotates the Azure SQL admin password stored in Key Vault on a schedule and on-demand near expiry.

```powershell
.\runbooks\Rotate-SqlAdminSecret.ps1 -VaultName "kv-iam-lab-prod" -SecretName "sql-admin-password" -SqlServerName "sql-iam-lab"
```

Deployed as an Azure Automation runbook, this script:

1. Generates a new high-entropy password.
2. Calls `Set-AzSqlServer` to update the SQL Server admin credential to the new value.
3. Writes the new value as a new version of the Key Vault secret, with a fresh expiry date set.
4. Only after both steps confirm success does it disable the previous secret version, so a failure mid-rotation never leaves the application holding a password that no longer works anywhere.

The trigger is an Event Grid subscription on the vault's `SecretNearExpiry` system event, wired to the runbook via a webhook, configured in [`scripts/New-RotationEventSubscription.ps1`](scripts/New-RotationEventSubscription.ps1). Secrets are tagged with a 90-day expiry on creation, and the event fires 30 days out, giving the rotation job a wide, unhurried window.

---

## Part 5: Detect anomalous access

The queries in [`kql/`](kql) run against the `AzureDiagnostics` (or `AZKVAuditLogs` in the resource-specific table) data from Key Vault's diagnostic settings, forwarded to Log Analytics.

- [`bulk-secret-enumeration.kql`](kql/bulk-secret-enumeration.kql) flags a single principal listing or retrieving an abnormal number of distinct secrets in a short window, the signature of an attacker who has landed on a compromised identity and is harvesting everything the vault holds.
- [`unauthorized-access-attempts.kql`](kql/unauthorized-access-attempts.kql) surfaces `Forbidden` results on `SecretGet` operations, which tells you either a misconfigured RBAC assignment or a principal actively probing for secrets it should not have.
- [`secrets-nearing-expiry-unrotated.kql`](kql/secrets-nearing-expiry-unrotated.kql) cross-references secret expiry dates against rotation runbook execution history, so a secret with no automation wired to it gets caught before it expires and breaks production instead of after.
- [`access-outside-expected-principals.kql`](kql/access-outside-expected-principals.kql) alerts when a secret is read by an identity other than the specific managed identities it was scoped to in Part 3, which is exactly what a lateral-movement attempt into the vault looks like.

---

## Key takeaways

- **The credential to read a secret should never itself be a stored secret.** Managed identity breaks the circular problem of needing a credential to fetch a credential.
- **RBAC scope belongs on the secret, not the vault.** Broad vault-level access turns one compromised identity into a full secrets dump; per-secret scoping contains the blast radius to what that identity actually needed.
- **Rotation only happens if it is automated.** A manual rotation process is a process that runs once, at deployment, and never again.
- **Purge protection is not optional.** Soft-delete without purge protection is a checkbox that provides no real recovery guarantee.
- **Network isolation and identity are complementary, not redundant.** RBAC controls who can read a secret; the private endpoint controls where the request can even come from. A leaked management-plane token is far less useful against a vault with no public listener.

---

## Technologies used

Azure Key Vault (RBAC authorization, soft-delete, purge protection), System-Assigned Managed Identities, Azure RBAC, Private Endpoints, Azure Policy, Event Grid, Azure Automation (PowerShell runbooks), Azure SQL Database, Az PowerShell, Log Analytics / KQL.
