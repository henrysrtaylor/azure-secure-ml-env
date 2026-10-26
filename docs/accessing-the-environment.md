# Accessing the environment

Every service in this environment is private-only, with public network access disabled. People reach them through the virtual network, and there are two ways in:

- **VPN**: a Point-to-Site VPN from the user's own computer. For trusted teams.
- **Bastion**: browser-based remote desktop into a VM inside the network. For multiple third-party users.

You choose which to deploy with `ACCESS_MODE` in `.env` (see [Choosing at deployment](#choosing-at-deployment)).

## At a glance

| | VPN | Bastion |
|---|---|---|
| Intended for | Trusted teams | Multiple third-party users |
| Status | Deployed and verified | Planned, not built yet |
| What the user needs | Azure VPN Client installed, an imported profile, an Entra account | A web browser, a portal sign-in, and the username and password for their VM |
| Where the user works | On their own computer, with their own tools | On a VM in the environment, through the browser |
| Sign-in | Microsoft Entra ID, so MFA and Conditional Access apply | Entra guest account for the portal, then a local username and password for the VM |
| Network reach | The whole virtual network (everything their roles allow) | Whatever the VM can reach |
| Data on the user's device | Yes, it can be copied to their computer | No, it stays on the VM (Bastion Standard can also block clipboard and file transfer) |
| Install on user devices | Yes | No |
| Billing | VPN Gateway and DNS resolver, hourly | Bastion host and one VM per user, hourly |
| Guide | [vpn-client-setup.md](vpn-client-setup.md) | [bastion-considerations.md](bastion-considerations.md) |

## VPN: for trusted teams

The user installs the Azure VPN Client, imports a profile, and connects with their Entra account. Their computer then behaves as if it were inside the network: private names resolve to private addresses, and they can use their normal tools (browser, VS Code, Python, the Azure CLI) against the private services.

**Use it when**
- The users are your own team or a partner team you trust.
- Their devices are managed, or you are comfortable with data reaching them.
- They need their own tools and want to work locally.
- You want Entra sign-in with MFA and Conditional Access end to end.

**Things to know**
- Users must be able to install software, and need a VPN profile from an admin. Only admins can generate the profile.
- Whatever their roles allow is reachable from their own computer, so the trust placed in the device matters.
- Setup, verification and troubleshooting are in [vpn-client-setup.md](vpn-client-setup.md). It was verified from one Windows machine. Linux is not supported by the Azure VPN Client for this gateway.

## Bastion: for multiple third-party users

Azure Bastion gives a remote desktop session in the browser, into a VM that sits inside the network. Each user gets their own VM and works on it. The VM, not the user's computer, is what reaches the private services.

**Use it when**
- The users are third parties, and you do not want to install anything on their devices or trust those devices with your data.
- You want work to stay inside the environment, with no direct path from the user's laptop to the services.
- You need several people working at the same time, each isolated on their own VM.
- Access should be easy to hand out and to remove: create the VMs, give each user their credentials, delete the VMs when finished.

**How it works**
1. An admin sets how many VMs to create (`VM_COUNT`). Each VM gets its own username and a generated password. See [bastion-considerations.md](bastion-considerations.md).
2. The user signs in to the Azure portal, opens their VM, and chooses Connect, then Bastion.
3. They enter that VM's username and password. Bastion does not map users to VMs, so the credentials are what grant access to that machine.
4. Their tools run on the VM. To use an Azure service from the VM they sign in with their own Entra account, so the roles they have still decide what they can do.

**Things to know**
- It is not built yet. Setting `ACCESS_MODE` to `bastion` or `both` is refused by the deploy script until it is.
- VM sign-in uses a local password, so there is no MFA at the VM. Mitigate with long random passwords, short lifetimes and deleting the VMs when finished.
- Each VM costs money while it exists, and Bastion bills hourly whether or not anyone is connected.
- The open points (SKU, VM size, shareable links, guest sign-in) are tracked in [bastion-considerations.md](bastion-considerations.md).

## Which should I use?

| Situation | Use |
|---|---|
| Your own team, on laptops you manage | VPN |
| A partner team you trust, who work with their own tools | VPN |
| Several third parties who must not keep data or install software | Bastion |
| Third parties on devices you do not control | Bastion |
| A trusted team and third parties together | Both |
| A very small number of users who occasionally need access | Either; Bastion avoids installs, VPN avoids VM cost |

## Choosing at deployment

Step 5 of `./scripts/deploy.ps1` is the access layer. `ACCESS_MODE` in `.env` selects what it deploys:

| `ACCESS_MODE` | Deploys | Status |
|---|---|---|
| `vpn` | DNS Private Resolver and VPN Gateway (default) | Built |
| `bastion` | Bastion and the user VMs | Planned |
| `both` | The VPN and Bastion side by side | Planned |

Steps 1 to 4 (the infrastructure and the roles) are the same whichever you choose. See [deployment.md](deployment.md) for the full flow.

## Access path and permissions are separate

Both options only provide a network path in. What a person can do once they are in is decided by their Azure roles. People join the admins or developers group, or a group you create for third parties. See [rbac.md](rbac.md). Give third-party users the narrowest roles that let them do their work.

## Related documents

- [vpn-client-setup.md](vpn-client-setup.md): installing the VPN client and connecting.
- [bastion-considerations.md](bastion-considerations.md): planning notes for Bastion.
- [rbac.md](rbac.md): groups, roles, adding and removing people.
- [architecture.md](architecture.md): what is deployed and why.
- [deployment.md](deployment.md): requirements, configuration, running and verifying.
