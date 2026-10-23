# azure-secure-ml-env

A Bicep-based, private-only Azure environment for an AI engineering team. All PaaS services have public network access disabled and are reachable only through private endpoints, over a Point-to-Site VPN with Microsoft Entra ID authentication.

## 📋 Core Components

- `infra/names.bicep`: Shared resource naming and the list of private DNS zones, so every step derives identical names.
- `infra/01-network.bicep`: Virtual network, subnets, and private DNS zones linked to the VNet.
- `infra/02-storage-keyvault.bicep`: ADLS Gen2 storage account and two Key Vaults (ML workspace, application secrets) with private endpoints.
- `infra/03-ai-ml.bicep`: Container Registry, AI Search, AI Foundry (AI Services / Azure OpenAI), Azure Machine Learning, and a Flex Consumption Function App with private endpoints.
- `infra/04-vpn-resolver.bicep`: DNS Private Resolver with an inbound endpoint and a VPN Gateway (P2S, OpenVPN, Entra ID).
- `infra/05-rbac.bicep`: Tiered roles (admin, developer) for Entra groups on each resource. Key authentication is disabled, so RBAC is required.
- `infra/modules/private-endpoint.bicep`: Reusable private endpoint with DNS zone group.
- `scripts/deploy.ps1`: Builds, validates, and deploys the steps in order, then prints portal links, private endpoint IPs, and VPN client profile details.
- `.env`: Local deployment values (subscription, tenant, location, prefix, network ranges, optional existing RBAC group IDs). Do not commit it to Git.
- `.env.example`: Template for `.env`.

## � Documentation

- [docs/deployment.md](docs/deployment.md): requirements, `.env` reference, running and verifying the deployment, cost, tear down, troubleshooting, known limitations.
- [docs/architecture.md](docs/architecture.md): what is deployed and why.
- [docs/rbac.md](docs/rbac.md): groups, roles, adding and removing people.
- [docs/vpn-client-setup.md](docs/vpn-client-setup.md): installing the VPN client and connecting.

## �📈 Future Roadmap

- Azure OpenAI model deployments and Foundry projects.
- Service-to-service private connectivity (for example Search to the Data Lake).
- Network security groups and route tables on the services subnet.
- Azure Monitor Private Link Scope for Application Insights.

## 📂 Project Structure

```text
azure-secure-ml-env/
├── infra/
│   ├── modules/
│   │   └── private-endpoint.bicep      # Private endpoint + DNS zone group
│   ├── names.bicep                     # Shared names and DNS zone list
│   ├── 01-network.bicep                # VNet, subnets, private DNS zones
│   ├── 02-storage-keyvault.bicep       # ADLS Gen2, Key Vaults
│   ├── 03-ai-ml.bicep                  # ACR, Search, AI Services, ML, Function App
│   ├── 04-vpn-resolver.bicep           # DNS Private Resolver, VPN Gateway
│   ├── 05-rbac.bicep                   # Tiered role assignments for Entra groups
│   └── bicepconfig.json                # Linter settings
├── scripts/
│   └── deploy.ps1                      # Step-by-step deployment
├── docs/                               # Deployment, architecture, RBAC and VPN guides
├── .env.example                        # Environment variable template
├── .gitignore                          # Git ignore rules
└── README.md                           # Project documentation
```

### Network layout

| Subnet | Range | Purpose |
|---|---|---|
| `services-subnet` | `10.0.1.0/24` | Private endpoints |
| `GatewaySubnet` | `10.0.2.0/24` | VPN Gateway only |
| `dns-inbound-subnet` | `10.0.3.0/28` | DNS Private Resolver inbound endpoint (`10.0.3.4`) |
| `func-integration-subnet` | `10.0.4.0/24` | Function App VNet integration (extra, required by Flex Consumption) |

## 🚀 Getting Started

### Prerequisites

To deploy:

- Windows PowerShell 5.1 or later
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (required: the deployment script is built on `az`)
- Bicep, installed through the CLI with `az bicep install`
- Git (to clone the repository)
- An Azure subscription with quota in your chosen region for VpnGw1AZ, Flex Consumption, and Azure AI Services
- Owner (or Contributor plus User Access Administrator) on the subscription, to create resources and role assignments
- Permission in Microsoft Entra ID to create groups, or existing groups to use instead
- A tenant admin to grant consent for the Azure VPN Client app

To use the environment:

- [Azure VPN Client](https://learn.microsoft.com/azure/vpn-gateway/openvpn-azure-ad-client) (required: every service is private-only, so you must be connected to the VPN)
- Azure CLI, for admins to generate the VPN profile
- A modern browser for the Azure Portal, Azure ML studio, and Foundry
- Membership in the admins or developers Entra group

See [docs/vpn-client-setup.md](docs/vpn-client-setup.md) for installing the VPN client.

### High-Level Steps

1. Install the Azure CLI and Bicep, then sign in with `az login`.
2. Copy `.env.example` to `.env` and fill in your values.
3. Run `./scripts/deploy.ps1` to deploy everything (about 45 minutes, mostly the VPN Gateway).
4. Have a tenant admin grant consent for the Azure VPN Client app (the URL is printed by the script).
5. Add users to the Entra groups. See [docs/rbac.md](docs/rbac.md).
6. An admin generates the VPN profile and shares it. Each user installs the Azure VPN Client, imports the profile, and connects.
7. Verify that a private name resolves to a `10.0.1.x` address and that the Azure ML studio opens.

### Clone the Repository

```powershell
git clone <your-repo-url>
cd azure-secure-ml-env
```

### Configure the Environment

Copy the template, then fill in your subscription ID, tenant ID, location, and environment prefix:

```powershell
Copy-Item .env.example .env
az login --tenant <your_tenant_id>
```

## 🛠️ Development

Validate every step without deploying. It creates no groups or resources (apart from an empty resource group), and later steps only validate fully once earlier steps are deployed, so on a fresh subscription validate step by step (`-Step 1 -ValidateOnly`, then deploy it, and so on):

```powershell
./scripts/deploy.ps1 -ValidateOnly
```

Deploy everything in order (steps 1 to 6; the VPN Gateway typically takes 30 to 45 minutes). Running the script with no `-Step` does all of them, and rerunning is safe:

```powershell
./scripts/deploy.ps1
```

Deploy selected steps only. Step 5 grants RBAC and step 6 prints the summary:

```powershell
./scripts/deploy.ps1 -Step 3
./scripts/deploy.ps1 -Step 4,5,6
```

Step 5 creates two Entra groups (`sg-<prefix>-admins` and `sg-<prefix>-developers`) if they don't exist, adds you to both, and assigns roles to them. Add people to a group to give them access, with no redeploy. To use existing groups, set the `RBAC_*_GROUP_ID` values in `.env`. The deploying identity needs Owner or User Access Administrator. See [docs/rbac.md](docs/rbac.md).

After step 4, grant admin consent for the Azure VPN Client app (the URL is printed by step 6), import `azurevpnconfig.xml` from the generated profile zip into the Azure VPN Client, and connect. Private names then resolve through the resolver at `10.0.3.4`. See [docs/vpn-client-setup.md](docs/vpn-client-setup.md) and [docs/architecture.md](docs/architecture.md).

## 🤝 Contributing

Contributions are welcome! Please open an issue before starting substantial work so that proposed changes can be discussed and coordinated.

To contribute:

1. Fork the repository.
2. Create a branch for your change.
3. Run `./scripts/deploy.ps1 -ValidateOnly` against a sandbox subscription.
4. Submit a pull request describing your changes.

Bug reports, feature suggestions, and documentation improvements are all welcome.
