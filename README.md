# azure-secure-ml-env

A Bicep-based Azure environment for AI engineering teams, built so that nothing is exposed to the internet. Every PaaS service has public network access disabled and is reachable only through a private endpoint, and key-based authentication is turned off wherever the service allows it, so access is controlled by Microsoft Entra ID and Azure RBAC.

Use it as a personal sandbox in your own Azure subscription for testing and developing, or as a shared environment for a team. The same templates serve both: deploy it for yourself, or add people to the admins and developers groups and give them a way in.

Many AI use cases can be built using this sandbox. It does not cover every ML or AI use case, but offers a secure infrastructure baseline to start from and build on.

You choose how people get in:

- **VPN**: a Point-to-Site VPN with Microsoft Entra ID sign-in, so people use their own tools from their own computers. Best for trusted teams and personal sandbox environments.
- **Bastion**: browser-based remote desktop into a VM inside the network, one VM per user, so nothing is installed on their devices and work stays in the environment. Best for third parties, and for people who can't install the VPN client or whose devices you don't manage.
- **Both**, side by side.

See [docs/accessing-the-environment.md](docs/accessing-the-environment.md) for how to choose.

## 🧩 What Gets Deployed

`./scripts/deploy.ps1` creates the following in one resource group. Names follow `<type>-<purpose>-<prefix>` (see [docs/deployment.md](docs/deployment.md#naming)).

| Step | Area | Resources |
|---|---|---|
| 1 | Network | Virtual network with four subnets (services, gateway, DNS resolver, Function integration), 12 private DNS zones linked to the network. With Bastion access: a Bastion subnet with its network security group, and a VM subnet |
| 2 | Data and secrets | ADLS Gen2 Data Lake storage account, two Key Vaults (one for the ML workspace, one for application secrets) |
| 3 | AI and ML | Container Registry (Premium), AI Search (Basic), AI Foundry (AI Services, including Azure OpenAI and Document Intelligence), two Custom Vision accounts (training and prediction), Azure Machine Learning workspace with its own storage account, Function App (Flex Consumption) with its plan, Log Analytics workspace, Application Insights |
| 3 | Private connectivity | 13 private endpoints, one per service endpoint above, each registered in the matching private DNS zone |
| 3 | Service connections | Shared private links from AI Search to the Data Lake (blob, dfs) and AI Foundry (embeddings), approved by the script, and Azure ML outbound rules to the Data Lake (blob, dfs), AI Foundry and AI Search. With `SEARCH_SKU="standard"`, also links for Foundry skills and the Function App (custom skills). With `FOUNDRY_LAKE_ACCESS="true"`, the Foundry account's document features can read the Data Lake. See [docs/architecture.md](docs/architecture.md#service-to-service-connections) |
| 4 | Access control | Two Entra groups (`sg-<prefix>-admins`, `sg-<prefix>-developers`, created if they don't exist) and tiered role assignments on every resource, plus the roles the Search and ML workspace identities need to use the Data Lake and Foundry, and one shared user-assigned identity (`id-workloads-<prefix>`) in the developers group |
| 5 | VPN access (`vpn` or `both`) | DNS Private Resolver with an inbound endpoint, VPN Gateway with its public IP |
| 5 | Bastion access (`bastion` or `both`) | Bastion host with its public IP, and per user a Windows Server 2022 VM with a network interface, a daily shutdown schedule, a setup run command and a self-deallocate role assignment |

Not deployed: ML compute, model deployments, Foundry projects and function code. See [docs/architecture.md](docs/architecture.md#not-included).

### Choosing the AI Search tier

`SEARCH_SKU` in `.env` sets the tier. The default, `basic`, is the cheapest tier that supports private endpoints.

| Private connection | `basic` | `standard` (S1) |
|---|---|---|
| Search indexers reading the Data Lake | Yes | Yes |
| Search calling Foundry for embeddings (vectorization) | Yes | Yes |
| Search calling Foundry for other skills | No | Yes |
| Search calling the Function App (custom skills) | No | Yes |

Basic does not allow private connections for AI enrichment skillsets, with embeddings the one exception. The tier cannot be changed on a deployed service, so decide before you deploy. Details are in [docs/architecture.md](docs/architecture.md#service-to-service-connections).

## 👥 Groups and Access

Access is controlled by two Microsoft Entra security groups. Roles are assigned only to the groups, never to individuals, so you give or remove access by changing group membership, with no redeploy. Because key authentication is disabled on the data services, a network path in (VPN or Bastion) is not enough on its own: a person also needs to be in one of these groups.

| Group | For | Can do |
|---|---|---|
| `sg-<prefix>-admins` | People who run the environment | Change resources (Contributor on the resource group), full control of the Data Lake and both Key Vaults, manage AI Search, AI Foundry, Custom Vision, Container Registry, the ML workspace and the Function App. Generate the VPN profile and reset VM passwords. |
| `sg-<prefix>-developers` | Day-to-day data, ML and AI work | Read the resource group, read and write the Data Lake, read and write application secrets, and use the same AI, ML, Search and Function App roles as admins, including model deployments. Cannot change infrastructure and cannot read the ML workspace Key Vault. |

Step 4 creates both groups if they don't exist and makes the deploying user their owner and a member. It also creates a shared managed identity, `id-workloads-<prefix>`, in the developers group, so compute clusters and other resources get developer access without role setup (deliberately lenient, see [docs/rbac.md](docs/rbac.md#workload-identity)). To use groups you already manage, set `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID` in `.env`. The full role table and how to add and remove people are in [docs/rbac.md](docs/rbac.md).

## 🚀 Getting Started

### Prerequisites

To deploy:

- Windows PowerShell 5.1 or later
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and Bicep (`az bicep install`)
- Git
- An Azure subscription with quota in your chosen region for the services you deploy: Flex Consumption and Azure AI Services always, `VpnGw1AZ` for VPN access, and the VM size (default `Standard_B2ms`) for Bastion access
- Owner (or Contributor plus User Access Administrator) on the subscription, to create resources and role assignments
- Permission in Microsoft Entra ID to create groups, or existing groups to use instead
- A way to get a Microsoft Graph token. Steps 4 and 6 call Microsoft Graph
- A tenant admin, only if VPN sign-in asks for approval of the Azure VPN Client app

To use the environment:

- With VPN access: the [Azure VPN Client](https://learn.microsoft.com/azure/vpn-gateway/openvpn-azure-ad-client) and the Azure CLI (admins use it to generate the VPN profile)
- With Bastion access: a browser, plus a VM username and password from an admin
- A modern browser for the Azure Portal, Azure ML studio and Foundry
- Membership in the admins or developers Entra group

### 1. Clone and configure

```powershell
git clone https://github.com/henrysrtaylor/azure-secure-ml-env.git
cd azure-secure-ml-env
Copy-Item .env.example .env
az login --tenant <tenant_id>
```

If your tenant's Conditional Access requires a compliant device, sign in from one with the Graph scope instead: `az login --tenant <tenant_id> --scope https://graph.microsoft.com//.default`. Without it, steps 4 and 6 fail with `AADSTS53000` (see [docs/deployment.md](docs/deployment.md#troubleshooting)).

Edit `.env` and set your subscription ID, tenant ID, location, `NAME_PREFIX` (the `<prefix>` in resource names and throughout the docs) and `ACCESS_MODE` (`vpn`, `bastion` or `both`). Every setting is described in [docs/deployment.md](docs/deployment.md#configure).

### 2. Deploy

```powershell
./scripts/deploy.ps1
```

This runs all six steps in order and takes about 45 minutes with a VPN Gateway, the slowest resource. Rerunning is safe. The script deploys the infrastructure (steps 1 to 3), then access control (step 4), then the connectivity layer (step 5, where `ACCESS_MODE` chooses how people connect), and step 6 prints a summary.

Validate without deploying, or run selected steps:

```powershell
./scripts/deploy.ps1 -ValidateOnly
./scripts/deploy.ps1 -Step 3
./scripts/deploy.ps1 -Step 4,5,6
```

Later steps only validate fully once earlier ones are deployed, so on a fresh subscription validate and deploy step by step (`-Step 1 -ValidateOnly`, then `-Step 1`, and so on).

### 3. Give people access

1. Add users to `sg-<prefix>-admins` or `sg-<prefix>-developers`. See [docs/rbac.md](docs/rbac.md).
2. **VPN:** an admin generates the VPN profile and shares it. Each user installs the Azure VPN Client, imports `azurevpnconfig.xml` and connects. If sign-in asks for admin approval, a tenant admin approves the Azure VPN Client app. See [docs/vpn-client-setup.md](docs/vpn-client-setup.md).
3. **Bastion:** the script prints each VM's username and password once and saves them to `vm_passwords.jsonl`. Hand each user their VM's sign-in. They open the VM in the Azure portal and choose Connect, then Bastion.
4. Verify the deployment. See [docs/deployment.md](docs/deployment.md#verify-the-deployment).

## 📚 Documentation

- [docs/deployment.md](docs/deployment.md): requirements, `.env` reference, running and verifying the deployment, cost, tear down, troubleshooting, known limitations.
- [docs/architecture.md](docs/architecture.md): what is deployed and why.
- [docs/rbac.md](docs/rbac.md): groups, roles, adding and removing people.
- [docs/accessing-the-environment.md](docs/accessing-the-environment.md): the two ways in (VPN for trusted teams, Bastion for third parties, or both) and when to use each.
- [docs/vpn-client-setup.md](docs/vpn-client-setup.md): installing the VPN client and connecting.

## 📈 Optional Hardening for Security

Not needed for a sandbox. Consider these for a shared environment with stricter compliance requirements:

- Network security groups and route tables on the services subnet.
- Azure Monitor Private Link Scope for Application Insights.

## 📂 Project Structure

```text
azure-secure-ml-env/
├── infra/
│   ├── modules/
│   │   ├── cognitive-account.bicep     # Cognitive account + private endpoint
│   │   └── private-endpoint.bicep      # Private endpoint + DNS zone group
│   ├── names.bicep                     # Shared names and DNS zone list
│   ├── 01-network.bicep                # VNet, subnets, private DNS zones
│   ├── 02-storage-keyvault.bicep       # ADLS Gen2, Key Vaults
│   ├── 03-ai-ml.bicep                  # ACR, Search, AI Services, ML, Function App
│   ├── 04-rbac.bicep                   # Tiered role assignments for Entra groups
│   ├── 05-access-vpn.bicep             # VPN access: DNS Private Resolver, VPN Gateway
│   ├── 05-access-bastion.bicep         # Bastion access: Bastion host and per-user VMs
│   ├── scripts/
│   │   └── configure-vm.ps1            # Runs on each VM: tools and idle shutdown
│   └── bicepconfig.json                # Linter settings
├── scripts/
│   └── deploy.ps1                      # Step-by-step deployment
├── docs/                               # Deployment, architecture, access, RBAC and VPN guides
├── .env.example                        # Environment variable template
├── .gitignore                          # Git ignore rules
└── README.md                           # Project documentation
```

Files created locally and git-ignored: `.env` (your settings) and `vm_passwords.jsonl` (generated VM sign-ins, Bastion modes only). Subnet ranges and what each is for are in [docs/architecture.md](docs/architecture.md#network).

## 🤝 Contributing

Contributions are welcome! Please open an issue before starting substantial work so that proposed changes can be discussed and coordinated.

To contribute:

1. Fork the repository.
2. Create a branch for your change.
3. Run `./scripts/deploy.ps1 -ValidateOnly` against a sandbox subscription.
4. Submit a pull request describing your changes.

Bug reports, feature suggestions, and documentation improvements are all welcome.
