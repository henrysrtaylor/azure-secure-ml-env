# VPN client setup (personal computer)

All services in this environment are private-only. You must be connected to the Point-to-Site VPN to reach them. The VPN is intended for trusted teams. For third-party users see [accessing-the-environment.md](accessing-the-environment.md), which compares the VPN with Bastion.

Values in angle brackets come from your `.env` or the step 6 output (`./scripts/deploy.ps1 -Step 6`).

## Prerequisites

1. Tenant admin consent for the Azure VPN Client app is **not required in every tenant**. In the reference tenant a non-admin guest account connected without it, and the app never appeared in the tenant's directory. Import the profile and try to connect first. Only if sign-in says admin approval is required, follow [Grant admin consent](#grant-admin-consent) below. It is one time per tenant, not per user.
2. Your Microsoft Entra account (member or B2B guest) is in the tenant. Your device does not need to be domain joined.
3. Admin access on your machine to install the VPN client.
4. Membership in one of the environment's groups, otherwise you can connect but are not authorized on any service. See [rbac.md](rbac.md). After being added, sign out and back in (`az login`, and the portal) so your token includes the new group. Connecting to the VPN itself does not depend on the groups.

## Grant admin consent

Only needed if VPN sign-in says admin approval is required (see the first prerequisite). Whether it is needed depends on the tenant's user-consent settings.

The VPN Gateway accepts sign-ins for the Azure VPN Client app (`c632b3df-fb67-4d84-bdcf-b95ad541b5c8`, public cloud). A tenant admin must approve that app once for the whole tenant. This needs a Global Administrator, Privileged Role Administrator, or Cloud Application Administrator **in the tenant that hosts the environment**. A guest account without one of these roles cannot grant it.

1. Sign in to a browser as that admin. Use a private window if your browser is signed in to another account.
2. Open this URL, replacing `<tenant_id>` (it is the `AZURE_TENANT_ID` in `.env`):

   ```text
   https://login.microsoftonline.com/<tenant_id>/oauth2/authorize?client_id=c632b3df-fb67-4d84-bdcf-b95ad541b5c8&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent
   ```

3. Select **Accept** on the consent page. The browser then lands on the Azure portal.

Do not use the `.../adminconsent?client_id=...` form of the URL. It redirects to `localhost` when it finishes, and the browser shows "localhost refused to connect" whether or not consent was granted.

If the URL does not work, an admin can approve the app in the Entra admin center instead: **Enterprise applications**, search for **Azure VPN**, open it, then **Permissions** and **Grant admin consent**. If the app is not listed, sign in once to the URL above so the app is added to the tenant.

Check that consent took effect. This prints a line when the app exists in the tenant and nothing when it does not:

```powershell
az ad sp list --filter "appId eq 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'" --query "[].displayName" -o tsv
```

Step 6 of the deploy script runs this check too.

### If you are not an admin

1. **Try connecting first.** Importing the profile and signing in is the real test. If the tenant allows users to consent to this app, sign-in works after a consent prompt and nothing more is needed.
2. **If sign-in says admin approval is required,** ask someone with one of the roles above in that tenant to open the URL in step 2 of the previous section and select **Accept**. Send them this:

   > Please approve the Microsoft app "Azure VPN Client" (app ID `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`) for our tenant `<tenant_id>`, by opening the consent URL in docs/vpn-client-setup.md and selecting Accept. It is a Microsoft app used for VPN sign-in, and it needs only the sign-in and basic profile permissions.

3. **Check the result** with the `az ad sp list` command above. An empty result means the app has not been added to the tenant directory. That alone does not mean sign-in will fail: in the reference tenant the result stayed empty after a successful connection.

The environment's Azure subscription and the Entra tenant are linked, so approval has to happen in that tenant. It cannot be done from another tenant.

## Apps to install

| App | Needed for | Where |
|---|---|---|
| Azure VPN Client | Connecting (required) | Windows: [Microsoft Store](https://go.microsoft.com/fwlink/?linkid=2117554). macOS: [App Store](https://apps.apple.com/us/app/azure-vpn-client/id1553936137). Linux is not supported, see Notes. |
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

1. Install **Azure VPN Client** from the [Microsoft Store](https://go.microsoft.com/fwlink/?linkid=2117554). Other ways to install on Windows:
   - Installer download: <https://aka.ms/azvpnclientdownload>
   - WinGet: `winget install Microsoft.AzureVPNClient --source winget`
2. Open it, select **+** (bottom left), then **Import**.
3. Choose `azurevpnconfig.xml` and select **Save**.
4. Select the connection and choose **Connect**.
5. Sign in with your Entra account when prompted.

macOS follows the same steps with the [App Store client](https://apps.apple.com/us/app/azure-vpn-client/id1553936137): select **Import**, choose `azurevpnconfig.xml`, select **Save**, then **Connect**.

## Verify

Use `Resolve-DnsName`, not `nslookup`. On Windows the VPN sets a DNS rule that only the Windows resolver follows. `nslookup` ignores it and asks your normal DNS server, so it returns public addresses even when the VPN works.

```powershell
Resolve-DnsName <vault_name>.vault.azure.net -Type A
Test-NetConnection <private_ip> -Port 443
```

The first command must return a private `10.0.1.x` address. A public IP means DNS is not going through the VPN. The second, with that address, must report `TcpTestSucceeded : True`. Together they prove the tunnel is up, the DNS resolver (the VNet DNS server in your profile) is answering, and the private endpoint is reachable.

To test the resolver itself, ask it directly: `nslookup <vault_name>.vault.azure.net <resolver_ip>`. This works through the tunnel whatever your DNS settings are.

Then open `https://ml.azure.com` or `https://portal.azure.com` and browse to the resources.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sign-in loop or consent error | Sign-in says admin approval is required. See [Grant admin consent](#grant-admin-consent) |
| "localhost refused to connect" after opening the consent URL | You used the `adminconsent` URL, which redirects to `localhost`. Use the `oauth2/authorize` URL in [Grant admin consent](#grant-admin-consent) and check with `az ad sp list` |
| Connected but names resolve to public IPs | First check with `Resolve-DnsName`, not `nslookup` (see [Verify](#verify)). If `Resolve-DnsName` also returns public addresses, re-import a freshly generated profile and turn off browser "secure DNS" (DNS over HTTPS) overrides. |
| `403` from a service even though it resolves privately | You need group membership or roles. See [rbac.md](rbac.md). |
| Portal data views fail | Portal data views call the service from your browser, so the VPN must be connected |
| `Unable to load extension 'azure-cli-ml'` on every `az` command | A broken legacy extension on your machine. Harmless; silence it with `az extension remove -n azure-cli-ml` |
| Sign-in fails for an external (guest) account even after consent | Sign-in for guests is expected to work but was not verified. Test with a member account of the tenant, and make sure the guest accepted the invitation |

## Notes

- **Guests:** external (B2B guest) accounts can be used, but guest sign-in to the VPN was not verified. See the troubleshooting table.
- **Verification:** the Azure VPN Client connection, private name resolution and TCP reachability of the private endpoints were verified from a Windows 11 machine on a personal home network, using an account that is an external guest in the tenant. Linux is not covered. The macOS client, other networks and the users who connect after you were not tested. Use the checks in [Verify](#verify) as the acceptance test.
- **Linux is not supported.** The Azure VPN Client for Linux was retired on 31 August 2026, and the OpenVPN and strongSwan clients do not support Microsoft Entra ID sign-in with this gateway. Linux users need a Windows or macOS machine, such as a virtual machine or remote desktop.
- **Supported platforms:** Windows 11 (x64, x86, ARM64) and macOS 12 to 15 (x64, Arm64). The macOS client is not available in France and China.
- **Permissions on Windows:** the Azure VPN Client must be allowed to run in the background. In the client, **... > Prerequisites > Run Prerequisites Test** reports anything missing.
