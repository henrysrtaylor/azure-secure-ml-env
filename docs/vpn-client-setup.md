# VPN client setup (personal computer)

All services in this environment are private-only. You must be connected to the Point-to-Site VPN to reach them.

Values in angle brackets come from your `.env` or the step 6 output (`./scripts/deploy.ps1 -Step 6`).

## Prerequisites

1. A tenant admin has granted consent for the Azure VPN Client app (one time per tenant, not per user):
   `https://login.microsoftonline.com/<tenant_id>/adminconsent?client_id=c632b3df-fb67-4d84-bdcf-b95ad541b5c8`
   This needs a Global Administrator, Privileged Role Administrator, or Cloud Application Administrator. Without it, VPN sign-in fails with a message that admin approval is required.
2. Your Microsoft Entra account (member or B2B guest) is in the tenant. Your device does not need to be domain joined.
3. Admin access on your machine to install the VPN client.
4. Membership in one of the environment's groups, otherwise you can connect but are not authorized on any service. See [rbac.md](rbac.md). After being added, sign out and back in (`az login`, and the portal) so your token includes the new group. Connecting to the VPN itself does not depend on the groups.

## Apps to install

| App | Needed for | Where |
|---|---|---|
| Azure VPN Client | Connecting (required) | Windows: Microsoft Store. macOS: App Store. Linux (Ubuntu): [Microsoft documentation](https://learn.microsoft.com/azure/vpn-gateway/point-to-site-entra-gateway) |
| Azure CLI | Downloading the VPN profile, managing resources | [Install guide](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| A modern browser | Azure Portal, Azure ML studio (`ml.azure.com`), Foundry (`ai.azure.com`) | Edge or Chrome |
| VS Code (optional) | Working with ML, Functions and Bicep | [code.visualstudio.com](https://code.visualstudio.com) |

## Get the VPN profile

Generating the profile needs write-level rights on the gateway, so only members of the admins group can do it. Developers get the file from an admin (send it through a trusted channel). An admin runs:

```powershell
az login --tenant <tenant_id>
$url = az network vnet-gateway vpn-client generate -g <resource_group> -n <gateway_name> -o tsv
Invoke-WebRequest $url -OutFile vpnprofile.zip
Expand-Archive vpnprofile.zip vpnprofile
```

The profile file is `vpnprofile\AzureVPN\azurevpnconfig.xml`. The download link expires after one hour, so rerun the command if it fails. The same file works for every user, so an admin can generate it once and share it.

Regenerate and re-import the profile whenever the VNet DNS server or gateway settings change. The DNS server is baked into the profile.

## Install and connect (Windows)

1. Install **Azure VPN Client** from the Microsoft Store.
2. Open it, select **+** (bottom left), then **Import**.
3. Choose `azurevpnconfig.xml` and select **Save**.
4. Select the connection and choose **Connect**.
5. Sign in with your Entra account when prompted.

macOS follows the same steps with the App Store client. On Linux, use the Azure VPN Client package and import the same file.

## Verify

```powershell
nslookup <vault_name>.vault.azure.net
```

The answer must be a private `10.0.1.x` address. A public IP means DNS is not going through the VPN. This proves the tunnel is up and the DNS resolver (the VNet DNS server in your profile) is answering.

Then open `https://ml.azure.com` or `https://portal.azure.com` and browse to the resources.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sign-in loop or consent error | Admin consent for the Azure VPN Client app is missing |
| Connected but names resolve to public IPs | Re-import a freshly generated profile. Turn off browser "secure DNS" (DNS over HTTPS) overrides. |
| `403` from a service even though it resolves privately | You need group membership or roles. See [rbac.md](rbac.md). |
| Portal data views fail | Portal data views call the service from your browser, so the VPN must be connected |
| `Unable to load extension 'azure-cli-ml'` on every `az` command | A broken legacy extension on your machine. Harmless; silence it with `az extension remove -n azure-cli-ml` |
| Sign-in fails for an external (guest) account even after consent | Sign-in for guests is expected to work but was not verified. Test with a member account of the tenant, and make sure the guest accepted the invitation |

## Notes

- **Guests:** external (B2B guest) accounts can be used, but guest sign-in to the VPN was not verified. See the troubleshooting table.
- **Verification:** the author verified the gateway configuration with the Azure CLI, not a live client connection. Treat your first connection and the `nslookup` check above as the acceptance test.
- **Linux:** the Azure VPN Client for Linux supports Entra ID sign-in on supported Ubuntu versions. See the Microsoft documentation linked above for the current list.
