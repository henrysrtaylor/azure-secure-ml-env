# Deployment guide

How to deploy, verify, update and remove the environment, plus everything that can go wrong. For what is deployed, see [architecture.md](architecture.md). For access, see [rbac.md](rbac.md) and [vpn-client-setup.md](vpn-client-setup.md).

## Requirements

| Requirement | Detail |
|---|---|
| Operating system and shell | Windows with Windows PowerShell 5.1 or later. The script and every command in these docs were written and run for PowerShell 5.1. |
| Azure CLI | Required. Install from [Microsoft](https://learn.microsoft.com/cli/azure/install-azure-cli). |
| Bicep | Install with `az bicep install`. |
| Git | To clone the repository. |
| Azure subscription | Quota in your chosen region for the VPN Gateway SKU `VpnGw1AZ`, Flex Consumption (`FC1`), Azure AI Services (`S0`), AI Search (`standard`) and Container Registry (`Premium`). The region must support availability zones for `VpnGw1AZ`. |
| Azure permissions | Owner on the subscription, or Contributor plus User Access Administrator. Contributor alone cannot create role assignments, so step 3 and step 5 fail without the second role. |
| Entra permissions | Permission to create groups, or existing groups whose object IDs you put in `.env`. |
| Tenant admin | A Global Administrator, Privileged Role Administrator or Cloud Application Administrator must grant consent for the Azure VPN Client app (see below). |
| Network access | The machine running the script needs internet access to Azure. It does **not** need the VPN, because deployment uses the public Azure control plane. |

## Configure

```powershell
Copy-Item .env.example .env
az login --tenant <tenant_id>
```

Edit `.env`. `.env` is git-ignored and holds your values.

| Key | Meaning | Notes |
|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | Target subscription | The script selects it with `az account set`. |
| `AZURE_TENANT_ID` | Entra tenant | Used for the VPN sign-in settings and links. |
| `AZURE_LOCATION` | Azure region | Must be a valid region name, for example `uksouth`. |
| `ENVIRONMENT_NAME` | Name prefix | Use 3 to 8 lowercase letters or digits. Resource names are length limited, and storage and registry names drop hyphens. |
| `RESOURCE_GROUP_NAME` | Resource group | Created if missing. |
| `VNET_ADDRESS_SPACE` | VNet range | Default `10.0.0.0/16`. |
| `SERVICES_SUBNET_PREFIX` | Private endpoint subnet | Default `10.0.1.0/24`. |
| `GATEWAY_SUBNET_PREFIX` | `GatewaySubnet` | Default `10.0.2.0/24`. |
| `DNS_INBOUND_SUBNET_PREFIX` | Resolver subnet | Default `10.0.3.0/28`. The resolver uses the first usable address (`10.0.3.4`), which the script derives. |
| `FUNCTION_INTEGRATION_SUBNET_PREFIX` | Function VNet integration subnet | Default `10.0.4.0/24`. |
| `RBAC_ADMIN_GROUP_ID` | Existing admins group | Leave blank to create `sg-<prefix>-admins`. |
| `RBAC_DEVELOPER_GROUP_ID` | Existing developers group | Leave blank to create `sg-<prefix>-developers`. |
| `VPN_GATEWAY_SKU` | Gateway SKU | Default `VpnGw1AZ`. |
| `VPN_CLIENT_ADDRESS_POOL` | Address range handed to VPN clients | Default `172.16.201.0/24`. Must not overlap the VNet. |
| `VPN_AAD_AUDIENCE` | Azure VPN Client app ID | Default is the public-cloud ID `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`. Sovereign clouds use a different ID. |

Treat the network ranges as fixed after the first deployment. Subnets that contain private endpoints, a gateway or a delegated service cannot be resized or moved in place.

## Deploy

Validate without deploying:

```powershell
./scripts/deploy.ps1 -ValidateOnly
```

This creates no groups and no resources apart from an empty resource group. Later steps only validate fully once earlier steps exist, so on a fresh subscription validate and deploy one step at a time (`-Step 1 -ValidateOnly`, then `-Step 1`, and so on).

Deploy everything:

```powershell
./scripts/deploy.ps1
```

Running with no `-Step` runs steps 1 to 6 in order. Rerunning is safe because every step is incremental.

Run selected steps:

```powershell
./scripts/deploy.ps1 -Step 3
./scripts/deploy.ps1 -Step 4,5,6
```

| Step | File | What it does | Notes |
|---|---|---|---|
| 1 | `infra/01-network.bicep` | VNet, subnets, 12 private DNS zones and VNet links | |
| 2 | `infra/02-storage-keyvault.bicep` | Data Lake, two Key Vaults, private endpoints | |
| 3 | `infra/03-ai-ml.bicep` | ACR, AI Search, AI Foundry, ML workspace, Function App, private endpoints | |
| 4 | `infra/04-vpn-resolver.bicep` | DNS Private Resolver, VPN Gateway, then step 1 again | The gateway typically takes 30 to 45 minutes. The repeat of step 1 sets the resolver as the VNet DNS server. |
| 5 | `infra/05-rbac.bicep` | Creates the Entra groups if needed, adds you to both, assigns roles | Needs Owner or User Access Administrator. |
| 6 | (script only) | Prints portal links, private endpoint IPs, VPN profile details | Read-only. Skips registration and takes about 20 seconds. |

Before step 1 the script also:
- Registers the required resource providers if they are not registered.
- Registers the `Microsoft.Network/AllowBringYourOwnPublicIpAddress` preview feature, which the VPN Gateway's public IP needs, and waits for it. Registration can take several minutes the first time.
- Creates the resource group.
- Retries any `az` call up to three times, to ride out transient connection resets.

## After deployment (manual steps)

The script cannot do these:

1. **Admin consent.** A tenant admin approves the Azure VPN Client app using the steps in [vpn-client-setup.md](vpn-client-setup.md#grant-admin-consent). Once per tenant. Step 6 reports whether it has been granted.
2. **Add people** to `sg-<prefix>-admins` or `sg-<prefix>-developers`. See [rbac.md](rbac.md).
3. **Sign out and back in** (`az login`, and the portal) so tokens include your new group memberships.
4. **Generate the VPN profile** (admins only) and share it, then each user installs the client and connects. See [vpn-client-setup.md](vpn-client-setup.md).
5. **Verify** with the checks below.

## Verify the deployment

Run these from any machine. They use the public control plane, so no VPN is needed. Replace `<rg>` with your resource group.

Everything deployed, by type:

```powershell
az resource list -g <rg> -o table
```

Private endpoints are all `Approved`:

```powershell
az network private-endpoint list -g <rg> --query "[].{name:name,state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table
```

Public access is disabled and shared keys are off on storage:

```powershell
az storage account list -g <rg> --query "[].{name:name,public:publicNetworkAccess,sharedKey:allowSharedKeyAccess}" -o table
az keyvault list -g <rg> --query "[].{name:name,public:properties.publicNetworkAccess}" -o table
az acr list -g <rg> --query "[].{name:name,public:publicNetworkAccess}" -o table
```

Gateway settings:

```powershell
az network vnet-gateway show -g <rg> -n vpng-<prefix> --query "{state:provisioningState,sku:sku.name,protocols:vpnClientConfiguration.vpnClientProtocols,auth:vpnClientConfiguration.vpnAuthenticationTypes}" -o json
```

VNet DNS server is the resolver address:

```powershell
az network vnet show -g <rg> -n vnet-<prefix> --query "dhcpOptions.dnsServers" -o tsv
```

Role assignments for the two groups (the parentheses matter in Windows PowerShell 5.1):

```powershell
(az role assignment list --all -o json | Out-String | ConvertFrom-Json) | Where-Object { $_.scope -like '*<rg>*' -and $_.principalType -eq 'Group' } | Format-Table roleDefinitionName, scope
```

Checks that need the VPN (run after connecting):

```powershell
nslookup <vault_name>.vault.azure.net     # expect a 10.0.1.x address
```

Then open `https://ml.azure.com` and sign in.

## Naming

Every resource is named `<type>-<purpose>-<environment prefix>`, so the name alone says what it is. A short hash from the resource group ID is added only where Azure needs a globally unique name. Names are defined in one place, `infra/names.bicep`. Examples use the prefix `aisandbox`.

| Resource | Pattern | Example |
|---|---|---|
| Virtual network | `vnet-<prefix>` | `vnet-aisandbox` |
| Data Lake storage | `stlake<prefix><hash>` | `stlakeaisandbox...` |
| ML workspace storage (also holds the Function deployment package) | `stmlws<prefix><hash>` | `stmlwsaisandbox...` |
| Key Vault for the ML workspace | `kv-ml-<prefix>-<hash>` | `kv-ml-aisandbox-...` |
| Key Vault for application and team secrets | `kv-app-<prefix>-<hash>` | `kv-app-aisandbox-...` |
| Container Registry | `acr<prefix><hash>` | `acraisandbox...` |
| AI Search | `srch-<prefix>-<hash>` | `srch-aisandbox-...` |
| AI Foundry (AI Services) | `foundry-<prefix>-<hash>` | `foundry-aisandbox-...` |
| Azure ML workspace | `mlw-<prefix>` | `mlw-aisandbox` |
| Function App plan | `plan-func-<prefix>` | `plan-func-aisandbox` |
| Function App | `func-<prefix>-<hash>` | `func-aisandbox-...` |
| Log Analytics, Application Insights | `log-<prefix>`, `appi-<prefix>` | `log-aisandbox` |
| DNS Private Resolver | `dnspr-<prefix>` | `dnspr-aisandbox` |
| VPN Gateway and its public IP | `vpng-<prefix>`, `pip-vpng-<prefix>` | `vpng-aisandbox` |
| Private endpoints | `pe-<resource name>[-<sub-resource>]` | `pe-kv-app-aisandbox-...` |
| Entra groups | `sg-<prefix>-admins`, `sg-<prefix>-developers` | `sg-aisandbox-admins` |

Storage account and registry names cannot contain hyphens, so the prefix is used without them.

**Environments deployed before this convention** used `kv-<prefix>-...` and `kva-<prefix>-...` for the Key Vaults, `stml<prefix>...` for the ML storage, `ais-<prefix>-...` for AI Foundry and `plan-<prefix>` for the plan. Azure cannot rename these resources, and the ML workspace cannot switch Key Vault, so rerunning steps 2, 3 or 5 there would create duplicates. The deploy script refuses to do so: it marks resource groups created with the new names by a `naming=v2` tag, and stops steps 2, 3 and 5 on any resource group that has resources but no tag. Steps 1, 4 and 6 are unaffected. To adopt the new names, deploy to a new resource group (set a new `RESOURCE_GROUP_NAME`, and a new `ENVIRONMENT_NAME` if the old vaults are still soft-deleted) and tear the old one down.

## Cost

These resources bill continuously while they exist, whether or not they are used:
- VPN Gateway (`VpnGw1AZ`) and its public IP.
- DNS Private Resolver inbound endpoint.
- AI Search (`standard`).
- Container Registry (`Premium`).
- Private endpoints (each has an hourly charge).
- Log Analytics and Application Insights (usage based).

Flex Consumption bills only for execution. Azure ML and AI Services bill on usage, and there is no compute or model deployment yet. Use the Azure Pricing Calculator for numbers in your region.

## Update

- Edit a Bicep file or `.env`, then rerun the affected step. Steps are incremental.
- Changing role lists in `infra/05-rbac.bicep` adds assignments but does not remove old ones. See [rbac.md](rbac.md).
- Changing `VNET_ADDRESS_SPACE` or a subnet prefix after the first deployment will fail or require recreating the environment.
- After changing the VNet DNS server or gateway settings, generate and import a new VPN profile.

## Tear down

1. Delete the resource group. This removes the resources and their role assignments, and takes the gateway a while:

   ```powershell
   az group delete -n <rg> --no-wait
   ```

2. Soft-deleted resources keep their names reserved:
   - Key Vaults have purge protection, so a deleted vault cannot be purged for 90 days. Resource names are derived from the resource group ID, so redeploying to the same resource group name tries to reuse the same vault names and fails. Either recover the vault (`az keyvault recover --name <vault>`) or deploy with a different `ENVIRONMENT_NAME`.
   - Deleted AI Services accounts can be purged with `az cognitiveservices account purge`.
3. Delete the Entra groups if you no longer need them (`az ad group delete --group <name>`). They are not part of the resource group.
4. The provider and feature registrations are subscription-wide and are left in place.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unable to load extension 'azure-cli-ml'` printed on every command | A broken legacy Azure CLI extension on your machine. It is harmless to this project. To silence it: `az extension remove -n azure-cli-ml`. |
| `ConnectionResetError(10054)` | Transient network error. The script retries three times. Rerun if it still fails. |
| `SubscriptionNotRegisteredForFeature ... AllowBringYourOwnPublicIpAddress` | The preview feature is not registered yet. The script registers it and waits. If you ran the Bicep manually, register it with `az feature register` and then `az provider register --namespace Microsoft.Network`. |
| Step 5 fails creating groups | Your account cannot create Entra groups. Create them in Entra and put their IDs in `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID`. |
| `AuthorizationFailed` creating role assignments | The identity running the script needs Owner or User Access Administrator. |
| Quota or capacity error for the gateway, Flex Consumption or AI Services | Request quota or choose another region in `AZURE_LOCATION`. |
| Key Vault name conflict or vault shows as deleted | A soft-deleted vault holds the name. See Tear down. |
| `was deployed with the previous resource names` | The resource group predates the current naming convention. See [Naming](#naming). |
| In Azure ML studio, Notebooks, the VS Code option is greyed out | It needs a running compute instance, and none is deployed. In studio go to Manage, Compute, Compute instances, New, wait for Running, then select it in Notebooks. Requires the VPN and the admins or developers group (AzureML Compute Operator). Quota and first-time managed network setup in your region were not tested. |
| `-ValidateOnly` fails on step 2 or later on a fresh subscription | Expected. Those steps need earlier resources to exist. Deploy step by step. |
| Step 4 appears stuck | The VPN Gateway takes 30 to 45 minutes. |
| `az ... --query` fails with `was unexpected at this time` | Quoting problem in Windows PowerShell when a query contains parentheses. Use the commands in this guide, or filter in PowerShell. |

## Known limitations

- **Verified by checks, not by users.** The deployed configuration was verified with the Azure CLI checks above and with ARM validation of every step. A live VPN connection, private name resolution from a client, and access as a group member were not exercised by the author. Run the checks in [vpn-client-setup.md](vpn-client-setup.md) after your first connection.
- **One region deployed.** The templates were deployed to `uksouth` only. A clean deployment from an empty subscription was not exercised, because the steps were run incrementally.
- **Guest accounts.** The deploying account in the reference environment is an external (B2B guest) account. Entra sign-in to the VPN is expected to work for guests once admin consent is granted, but this was not verified. If sign-in fails for a guest, test with a member account.
- **No workloads.** There is no function code, ML compute instance or cluster, model deployment or Foundry project. Notebook and VS Code features in Azure ML studio need a compute instance that you create. See [architecture.md](architecture.md#not-included).
- **No service-to-service private connectivity.** See [architecture.md](architecture.md).
- **Application Insights** accepts public ingestion.
- **Windows only.** The script and commands target Windows PowerShell 5.1.
