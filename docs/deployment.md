# Deployment guide

How to deploy, verify, update and remove the environment, plus everything that can go wrong. For what is deployed, see [architecture.md](architecture.md). For access, see [rbac.md](rbac.md) and [vpn-client-setup.md](vpn-client-setup.md).

## Requirements

| Requirement | Detail |
|---|---|
| Operating system and shell | Windows with Windows PowerShell 5.1 or later. The script and every command in these docs were written and run for PowerShell 5.1. |
| Azure CLI | Required. Install from [Microsoft](https://learn.microsoft.com/cli/azure/install-azure-cli). |
| Bicep | Install with `az bicep install`. |
| Git | To clone the repository. |
| Azure subscription | Quota in your chosen region for Flex Consumption (`FC1`), Azure AI Services (`S0`), AI Search (`basic`, or `standard` with `SEARCH_SKU`) and Container Registry (`Premium`). For VPN access, the VPN Gateway SKU `VpnGw1AZ`, in a region that supports availability zones. For Bastion access, the VM size (`Standard_B2ms` by default) for `VM_COUNT` VMs. |
| Azure permissions | Owner on the subscription, or Contributor plus User Access Administrator. Contributor alone cannot create role assignments, so step 3 and step 4 fail without the second role. |
| Entra permissions | Permission to create groups, or existing groups whose object IDs you put in `.env`. The deploying account must be able to get a Microsoft Graph token. If your tenant's Conditional Access requires a compliant device, sign in from one (see Troubleshooting). |
| Tenant admin | Only if VPN sign-in asks for it: a Global Administrator, Privileged Role Administrator or Cloud Application Administrator approves the Azure VPN Client app. Not every tenant needs it. See [vpn-client-setup.md](vpn-client-setup.md#grant-admin-consent). |
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
| `NAME_PREFIX` | The `<prefix>` used in every resource name and throughout these docs | Use 3 to 8 lowercase letters or digits. Resource names are length limited, and storage and registry names drop hyphens. Do not change it after the first deployment. |
| `RESOURCE_GROUP_NAME` | Resource group | Created if missing. |
| `VNET_ADDRESS_SPACE` | VNet range | Default `10.0.0.0/16`. |
| `SERVICES_SUBNET_PREFIX` | Private endpoint subnet | Default `10.0.1.0/24`. |
| `GATEWAY_SUBNET_PREFIX` | `GatewaySubnet` | Default `10.0.2.0/24`. |
| `DNS_INBOUND_SUBNET_PREFIX` | Resolver subnet | Default `10.0.3.0/28`. The resolver uses the first usable address (`10.0.3.4`), which the script derives. |
| `FUNCTION_INTEGRATION_SUBNET_PREFIX` | Function VNet integration subnet | Default `10.0.4.0/24`. |
| `ACCESS_MODE` | How people connect (step 5) | `vpn` (default when blank), `bastion` or `both`. See [accessing-the-environment.md](accessing-the-environment.md) for when to use each. |
| `RBAC_ADMIN_GROUP_ID` | Existing admins group | Leave blank to create `sg-<prefix>-admins`. |
| `RBAC_DEVELOPER_GROUP_ID` | Existing developers group | Leave blank to create `sg-<prefix>-developers`. |
| `SEARCH_SKU` | AI Search tier | `basic` (default) or `standard` (S1). Standard is needed for private custom skills (Function App) and Foundry skills, because Basic does not allow private connections for AI enrichment skillsets (embedding skills are the exception). The tier cannot be changed on a deployed service, so delete the search service before switching. See [architecture.md](architecture.md#service-to-service-connections). |
| `FOUNDRY_LAKE_ACCESS` | Let the Foundry account's document features (Document Intelligence) read the Data Lake | `false` (default) or `true`. `true` switches the Data Lake's public endpoint to "enabled from selected networks", default action `Deny`, with one rule for the Foundry account, and gives the Foundry identity Storage Blob Data Contributor on it. Run steps 2 and 4 after changing it. Read the trade-off in [architecture.md](architecture.md#service-to-service-connections) first. |
| `VPN_GATEWAY_SKU` | Gateway SKU | Used with `vpn` and `both`. Default `VpnGw1AZ`. |
| `VPN_CLIENT_ADDRESS_POOL` | Address range handed to VPN clients | Default `172.16.201.0/24`. Must not overlap the VNet. |
| `VPN_AAD_AUDIENCE` | Azure VPN Client app ID | Default is the public-cloud ID `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`. Sovereign clouds use a different ID. |
| `BASTION_SKU` | Bastion SKU | Used with `bastion` and `both`. `Basic` (default) or `Standard`. Only Standard can disable clipboard and file transfer. |
| `BASTION_SUBNET_PREFIX` | `AzureBastionSubnet` | Default `10.0.5.0/26`. Azure requires `/26` or larger. |
| `VM_SUBNET_PREFIX` | Subnet for the VMs | Default `10.0.6.0/24`. |
| `VM_COUNT` | Number of VMs, one per user | Default `3`, maximum `20`. Raising it later adds VMs. Lowering it does not delete any. |
| `VM_SIZE` | VM size | Default `Standard_B2ms`. The VMs run Windows Server 2022. |
| `VM_DISK_GB` | OS disk size | Default `128`. |
| `VM_SHUTDOWN_TIME` | Daily shutdown as `HHmm` in `VM_SHUTDOWN_TIMEZONE`, or `none` | Default `1900`. The VM is deallocated, so compute stops billing. |
| `VM_SHUTDOWN_TIMEZONE` | Time zone for the daily shutdown | Default `UTC`. Use a Windows time zone ID. |
| `VM_IDLE_SHUTDOWN_MINUTES` | Minutes with no active session and no load before a VM deallocates itself | Default `30`. `0` turns it off. |
| `VM_INSTALL_TOOLS` | Install VS Code, Python, Git and the Azure CLI on each VM | Default `true`. A failed install is logged on the VM (`C:\ProvisionTools.log`) and never fails the deployment. |

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

The steps fall into three stages. The infrastructure comes first (steps 1 to 3), then access control (step 4), and last the connectivity layer (step 5), where `ACCESS_MODE` chooses how people connect. Step 6 only reports.

| Step | File | What it does | Notes |
|---|---|---|---|
| 1 | `infra/01-network.bicep` | VNet, subnets, 12 private DNS zones and VNet links | |
| 2 | `infra/02-storage-keyvault.bicep` | Data Lake, two Key Vaults, private endpoints | |
| 3 | `infra/03-ai-ml.bicep` | ACR, AI Search, AI Foundry (including Document Intelligence), Custom Vision (training and prediction), ML workspace, Function App, private endpoints, Search shared private links to the Data Lake and Foundry, ML outbound rules to the Data Lake, Foundry and Search | The script then approves the pending shared private links on the Data Lake, Foundry and Function App and waits for them (a few minutes). See [architecture.md](architecture.md#service-to-service-connections). |
| 4 | `infra/04-rbac.bicep` | Creates the Entra groups if needed, adds you to both, assigns roles, creates the shared identity `id-workloads-<prefix>` and adds it to the developers group (see [rbac.md](rbac.md#workload-identity)) | Needs Owner or User Access Administrator. |
| 5 | `infra/05-access-vpn.bicep` and `infra/05-access-bastion.bicep`, by `ACCESS_MODE` | See [Step 5 by access mode](#step-5-by-access-mode) | The VPN Gateway typically takes 30 to 45 minutes. |
| 6 | (script only) | Prints portal links, private endpoint IPs, and the connection details for the chosen access mode | Read-only. Skips registration and takes about 20 seconds. |

### Step 5 by access mode

| `ACCESS_MODE` | What step 5 does |
|---|---|
| `vpn` | Deploys the DNS Private Resolver and the VPN Gateway, then reruns step 1 to set the resolver as the VNet DNS server. |
| `bastion` | Reruns step 1 to add the Bastion and VM subnets, then deploys the Bastion host and the VMs. |
| `both` | Both of the above, in one run. |

The Bastion subnets are part of the step 1 template, because redeploying the VNet without them would remove them.

For Bastion access the script generates a long random password for each new VM and passes it to the template as a secure parameter. It prints a table of VM names, usernames (`vmuserNN`) and passwords once, and saves the same data to `vm_passwords.jsonl` next to `.env` (git-ignored, one JSON object per line with `vm`, `user` and `password`). Azure cannot show a VM password later, so keep that file safe. Admins can also reset a password in the portal (VM, Help, Reset password). Azure does not allow changing an admin password through a redeployment, so a rerun only creates and records VMs that do not exist yet. VM names are `vm-<prefix>-NN`.

Before step 1 the script also:
- Registers the required resource providers if they are not registered.
- Registers the `Microsoft.Network/AllowBringYourOwnPublicIpAddress` preview feature, which the VPN Gateway's public IP needs, and waits for it. Registration can take several minutes the first time.
- Creates the resource group if it does not exist, and tags a new, empty one `naming=v2` (see [Naming](#naming)).
- Retries any `az` call up to three times, to ride out transient connection resets.

## After deployment (manual steps)

The script cannot do these:

1. **Admin consent, only if needed (VPN).** Try the VPN first. If sign-in says admin approval is required, a tenant admin approves the Azure VPN Client app using [vpn-client-setup.md](vpn-client-setup.md#grant-admin-consent). Once per tenant.
2. **Add people** to `sg-<prefix>-admins` or `sg-<prefix>-developers`. See [rbac.md](rbac.md).
3. **Sign out and back in** (`az login`, and the portal) so tokens include your new group memberships.
4. **Give people access.** VPN: generate the VPN profile (admins only) and share it, then each user installs the client and connects. See [vpn-client-setup.md](vpn-client-setup.md). Bastion: hand each user their VM's username and password from `vm_passwords.jsonl`, and start the VMs in the portal when they are needed (they shut down daily and when idle).
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

Gateway settings (VPN access):

```powershell
az network vnet-gateway show -g <rg> -n vpng-<prefix> --query "{state:provisioningState,sku:sku.name,protocols:vpnClientConfiguration.vpnClientProtocols,auth:vpnClientConfiguration.vpnAuthenticationTypes}" -o json
```

VNet DNS server is the resolver address (VPN access):

```powershell
az network vnet show -g <rg> -n vnet-<prefix> --query "dhcpOptions.dnsServers" -o tsv
```

Bastion host and VMs (Bastion access). Every VM should show `Succeeded`. The tool install and idle shutdown results are in `C:\ProvisionTools.log` and `C:\ProgramData\IdleShutdown` on each VM:

```powershell
az network bastion list -g <rg> --query "[].[name,sku.name,provisioningState]" -o tsv
az vm list -g <rg> --query "[].[name,provisioningState]" -o tsv
```

Role assignments for the two groups (the parentheses matter in Windows PowerShell 5.1):

```powershell
(az role assignment list --all -o json | Out-String | ConvertFrom-Json) | Where-Object { $_.scope -like '*<rg>*' -and $_.principalType -eq 'Group' } | Format-Table roleDefinitionName, scope
```

Checks that need the VPN (run after connecting). Use `Resolve-DnsName`, not `nslookup`, which ignores the VPN's DNS rule on Windows:

```powershell
Resolve-DnsName <vault_name>.vault.azure.net -Type A     # expect a 10.0.1.x address
Test-NetConnection <that address> -Port 443               # expect TcpTestSucceeded : True
```

Then open `https://ml.azure.com` and sign in.

## Naming

Every resource is named `<type>-<purpose>-<prefix>`, so the name alone says what it is. `<prefix>` is the `NAME_PREFIX` value in `.env`, and it is the same value everywhere these docs say "prefix". A short hash from the resource group ID is added only where Azure needs a globally unique name. Names are defined in one place, `infra/names.bicep`. Examples use the prefix `demo`.

| Resource | Pattern | Example |
|---|---|---|
| Virtual network | `vnet-<prefix>` | `vnet-demo` |
| Data Lake storage | `stlake<prefix><hash>` | `stlakedemo...` |
| ML workspace storage (also holds the Function deployment package) | `stmlws<prefix><hash>` | `stmlwsdemo...` |
| Key Vault for the ML workspace | `kv-ml-<prefix>-<hash>` | `kv-ml-demo-...` |
| Key Vault for application and team secrets | `kv-app-<prefix>-<hash>` | `kv-app-demo-...` |
| Container Registry | `acr<prefix><hash>` | `acrdemo...` |
| AI Search | `srch-<prefix>-<hash>` | `srch-demo-...` |
| AI Foundry (AI Services) | `foundry-<prefix>-<hash>` | `foundry-demo-...` |
| Custom Vision training / prediction | `customvision-train-<prefix>-<hash>`, `customvision-pred-<prefix>-<hash>` | `customvision-train-demo-...` |
| Azure ML workspace | `mlw-<prefix>` | `mlw-demo` |
| Function App plan | `plan-func-<prefix>` | `plan-func-demo` |
| Function App | `func-<prefix>-<hash>` | `func-demo-...` |
| Shared workload identity | `id-workloads-<prefix>` | `id-workloads-demo` |
| Log Analytics, Application Insights | `log-<prefix>`, `appi-<prefix>` | `log-demo` |
| DNS Private Resolver | `dnspr-<prefix>` | `dnspr-demo` |
| VPN Gateway and its public IP | `vpng-<prefix>`, `pip-vpng-<prefix>` | `vpng-demo` |
| Bastion, its public IP and its network security group | `bas-<prefix>`, `pip-bas-<prefix>`, `nsg-bas-<prefix>` | `bas-demo` |
| VMs and their network interfaces | `vm-<prefix>-NN`, `nic-vm-<prefix>-NN` | `vm-demo-01` |
| Private endpoints | `pe-<resource name>[-<sub-resource>]` | `pe-kv-app-demo-...` |
| Entra groups | `sg-<prefix>-admins`, `sg-<prefix>-developers` | `sg-demo-admins` |

Storage account and registry names cannot contain hyphens, so the prefix is used without them.

**Resource groups deployed with an earlier version of this repository** used different names (for example `kva-<prefix>-...` for the application Key Vault and `ais-<prefix>-...` for AI Foundry). Azure cannot rename these resources, and the ML workspace cannot switch Key Vault, so rerunning steps 2, 3 or 4 there would create duplicates. The deploy script refuses to do so: it marks resource groups it creates with a `naming=v2` tag, and stops steps 2, 3 and 4 on any resource group that has resources but no tag. Steps 1, 5 and 6 are unaffected. To adopt the current names, deploy to a new resource group (set a new `RESOURCE_GROUP_NAME`, and a new `NAME_PREFIX` if the old vaults are still soft-deleted) and tear the old one down.

## Cost

These resources bill continuously while they exist, whether or not they are used:
- VPN Gateway (`VpnGw1AZ`) and its public IP (VPN access).
- DNS Private Resolver inbound endpoint (VPN access).
- Bastion host and its public IP (Bastion access). It bills hourly whether or not anyone is connected, and only deleting the host stops it.
- AI Search (`basic`).
- Container Registry (`Premium`).
- Private endpoints (each has an hourly charge).
- Search shared private links and, once the Azure ML managed network is provisioned, its outbound private endpoints (billed as private endpoints, plus data processed).
- Log Analytics and Application Insights (usage based).
- The VM disks (Bastion access), even while the VMs are deallocated.

VMs bill for compute only while running. The daily shutdown and the idle shutdown deallocate them, which stops compute billing. Shutting Windows down from inside the VM leaves it `Stopped` and still billed, so use the portal's Stop button or let the idle shutdown do it. Starting a VM is a manual step in the portal.

Flex Consumption bills only for execution. Azure ML, AI Services and Custom Vision bill on usage, and there is no compute or model deployment yet. Use the Azure Pricing Calculator for numbers in your region.

## Update

- Edit a Bicep file or `.env`, then rerun the affected step. Steps are incremental.
- Changing role lists in `infra/04-rbac.bicep` adds assignments but does not remove old ones. See [rbac.md](rbac.md).
- Changing `VNET_ADDRESS_SPACE` or a subnet prefix after the first deployment will fail or require recreating the environment.
- After changing the VNet DNS server or gateway settings, generate and import a new VPN profile.
- Switching `ACCESS_MODE` and rerunning step 5 adds the other access layer. It does not remove the one already deployed. To remove it, delete its resources (the VPN Gateway and resolver, or the Bastion host and VMs) by hand.
- Changing VM settings (size, disk, shutdown time, idle minutes) does not change existing VMs, only VMs created afterwards. The script counts VMs by the highest number that exists (`vm-<prefix>-NN`), so to recreate VMs delete the highest-numbered ones first, then rerun step 5.

## Tear down

1. Delete the resource group. This removes the resources and their role assignments, and takes the gateway a while:

   ```powershell
   az group delete -n <rg> --no-wait
   ```

2. Soft-deleted resources keep their names reserved:
   - Key Vaults have purge protection, so a deleted vault cannot be purged for 90 days. Resource names are derived from the resource group ID, so redeploying to the same resource group name tries to reuse the same vault names and fails. Either recover the vault (`az keyvault recover --name <vault>`) or deploy with a different `NAME_PREFIX`.
   - Deleted AI Services accounts can be purged with `az cognitiveservices account purge`.
   - Azure ML workspaces are soft deleted for 14 days and keep their name. The workspace is named `mlw-<prefix>`, so redeploying with the same prefix inside that window fails with "Soft-deleted workspace exists". Delete the workspace permanently when you tear down (in the portal, tick **Delete the workspace permanently**), or permanently delete it afterwards under Azure Machine Learning, **Recently deleted**. Otherwise use a new `NAME_PREFIX`.
3. Delete the Entra groups if you no longer need them (`az ad group delete --group <name>`). They are not part of the resource group.
4. Delete `vm_passwords.jsonl`, whose entries no longer match any VM.
5. The provider and feature registrations are subscription-wide and are left in place.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unable to load extension 'azure-cli-ml'` printed on every command | A broken legacy Azure CLI extension on your machine. It is harmless to this project. To silence it: `az extension remove -n azure-cli-ml`. |
| `ConnectionResetError(10054)` | Transient network error. The script retries three times. Rerun if it still fails. |
| `SubscriptionNotRegisteredForFeature ... AllowBringYourOwnPublicIpAddress` | The preview feature is not registered yet. The script registers it and waits. If you ran the Bicep manually, register it with `az feature register` and then `az provider register --namespace Microsoft.Network`. |
| Step 4 fails creating groups | Your account cannot create Entra groups. Create them in Entra and put their IDs in `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID`. |
| `AuthorizationFailed` creating role assignments | The identity running the script needs Owner or User Access Administrator. |
| Quota or capacity error for the gateway, Flex Consumption or AI Services | Request quota or choose another region in `AZURE_LOCATION`. |
| Key Vault name conflict or vault shows as deleted | A soft-deleted vault holds the name. See Tear down. |
| Step 3 fails with `Soft-deleted workspace exists` | A previous environment's Azure ML workspace is still soft deleted and holds the name `mlw-<prefix>`. Permanently delete it or use a new `NAME_PREFIX`. See Tear down. Steps 1 and 2 and the rest of step 3 are kept, so after fixing it run `./scripts/deploy.ps1 -Step 3,4,5,6`. |
| `already has resources but no naming=v2 tag` | The resource group was not created by this script, or predates the current naming convention. If it holds nothing from an earlier deployment of this repository, tag it with the command in the error message and rerun. Otherwise see [Naming](#naming). |
| In Azure ML studio, Notebooks, the VS Code option is greyed out | It needs a running compute instance, and none is deployed. In studio go to Manage, Compute, Compute instances, New, wait for Running, then select it in Notebooks. Requires the VPN and the admins or developers group (AzureML Compute Operator). Quota and first-time managed network setup in your region were not tested. |
| `-ValidateOnly` fails on step 2 or later on a fresh subscription | Expected. Those steps need earlier resources to exist. Deploy step by step. |
| Step 5 appears stuck | The VPN Gateway takes 30 to 45 minutes. |
| Step 3 fails with `InvalidResponseFromPrivateLinkService` on the AI Foundry private endpoint, and rerunning does not help | The endpoint is stuck in a `Failed` state although the account itself is `Succeeded`. Delete the endpoint (`az network private-endpoint delete -g <rg> -n pe-foundry-<prefix>-<hash>`) and rerun `./scripts/deploy.ps1 -Step 3`. |
| `AADSTS53000 ... Device is not in required device state: compliant` in step 4 or 6 | Conditional Access requires a compliant device for the Microsoft Graph token the script needs to create groups and read consent state. Sign in again from a compliant device with `az login --tenant <tenant_id> --scope https://graph.microsoft.com//.default`, or create the groups elsewhere and set `RBAC_*_GROUP_ID`. Steps 1 to 3 only need an Azure Resource Manager token and are not affected. |
| Step 3 ends with `Search shared private links are not all approved yet` | The links were created but a pending connection was not approved in time. Rerun `./scripts/deploy.ps1 -Step 3` (it only approves and waits), or approve them under the Data Lake's and the Foundry account's Networking, Private endpoint connections. Check the state with `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/<search>/sharedPrivateLinkResources?api-version=2025-05-01" --query "value[].[name,properties.status]" -o tsv`. |
| An indexer fails to connect to the Data Lake or Foundry | Check that the indexer's configuration sets `"executionEnvironment": "private"` and that the matching shared private link shows `Approved`. Skillsets that use built-in skills other than embeddings, or custom skills, need `SEARCH_SKU="standard"`. See [architecture.md](architecture.md#service-to-service-connections). |
| Step 3 fails creating `spl-function` | The Function link needs Search S1 or higher and a preview API, and Flex Consumption is not a documented target. Remove it by deleting the `splFunction` resource in `infra/03-ai-ml.bicep` if you do not need private custom skills. |
| Step 2 fails with `FOUNDRY_LAKE_ACCESS="true"` because the Foundry account does not exist yet | The firewall rule names the account before step 3 creates it. If Azure rejects it, run steps 2 and 3 with the setting `false`, then set it to `true` and rerun steps 2 and 4. |
| `az ... --query` fails with `was unexpected at this time` | Quoting problem in Windows PowerShell when a query contains parentheses. Use the commands in this guide, or filter in PowerShell. |

## Known limitations

- **Testing status.** The templates were deployed end to end, from an empty resource group through all six steps, in `uksouth` only. With VPN access, a connection from one Windows machine was verified (private name resolution and reachability of the private endpoints). With Bastion access, the deployment completes, but signing in to a VM through Bastion, the tool installation and the idle shutdown have not been verified on a deployed VM. macOS, other operating systems, other regions, other networks and other tenants' Conditional Access and consent settings were not exercised.
- **External (B2B guest) accounts.** They can be group members and use the VPN or Bastion like other accounts. Sign-in as a guest was not verified. See [rbac.md](rbac.md).
- **No workloads.** There is no function code, ML compute instance or cluster, model deployment or Foundry project. Notebook and VS Code features in Azure ML studio need a compute instance that you create. See [architecture.md](architecture.md#not-included).
- **Service-to-service connections are limited.** Search to the Data Lake, Foundry and (on Standard) the Function App, Azure ML to the Data Lake, Foundry and Search, and (optionally) the Foundry account's document features to the Data Lake are configured. Others are not. The Function link and the Foundry Data Lake rule have been validated by Azure but not exercised at runtime. See [architecture.md](architecture.md#service-to-service-connections).
- **Application Insights** accepts public ingestion.
- **Custom Vision is retiring.** Microsoft supports it until 25 September 2028. Its accounts keep key authentication on, because Entra support for its API was not verified.
- **VM sign-in has no MFA.** Bastion VMs use a local username and password. See [accessing-the-environment.md](accessing-the-environment.md).
- **Windows only.** The script and commands target Windows PowerShell 5.1.
