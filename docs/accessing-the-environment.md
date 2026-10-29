# Accessing the environment

Every service in this environment is private-only, with public network access disabled. People reach them through the virtual network, and there are two ways in:

- **VPN**: a Point-to-Site VPN from the user's own computer. For trusted teams.
- **Bastion**: browser-based remote desktop into a VM inside the network. For multiple third-party users.

You choose which to deploy with `ACCESS_MODE` in `.env`: `vpn`, `bastion`, or `both` to run the two side by side (see [Choosing at deployment](#choosing-at-deployment)).

## At a glance

| | VPN | Bastion |
|---|---|---|
| Intended for | Trusted teams | Multiple third-party users |
| What the user needs | Azure VPN Client installed, an imported profile, an Entra account | A web browser, a portal sign-in, and the username and password for their VM |
| Where the user works | On their own computer, with their own tools | On a VM in the environment, through the browser |
| Sign-in | Microsoft Entra ID, so MFA and Conditional Access apply | Entra account for the portal (member or external guest), then a local username and password for the VM |
| Network reach | The whole virtual network (everything their roles allow) | Whatever the VM can reach |
| Data on the user's device | Yes, it can be copied to their computer | No, it stays on the VM (Bastion Standard can also block clipboard and file transfer) |
| Install on user devices | Yes | No |
| Billing | VPN Gateway and DNS resolver, hourly | Bastion host and one VM per user, hourly |
| Guide | [vpn-client-setup.md](vpn-client-setup.md) | This document |

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
- Setup, verification and troubleshooting are in [vpn-client-setup.md](vpn-client-setup.md). Linux is not supported by the Azure VPN Client for this gateway.

## Bastion: for multiple third-party users

Azure Bastion gives a remote desktop session in the browser, into a VM that sits inside the network. Each user gets their own VM and works on it. The VM, not the user's computer, is what reaches the private services.

**Use it when**
- The users are third parties, and you do not want to install anything on their devices or trust those devices with your data.
- You want work to stay inside the environment, with no direct path from the user's laptop to the services.
- You need several people working at the same time, each isolated on their own VM.
- Access should be easy to hand out and to remove: create the VMs, give each user their credentials, delete the VMs when finished.

**How it works**
1. An admin sets how many VMs to create (`VM_COUNT`). Each VM (`vm-<prefix>-NN`) gets its own username (`vmuserNN`) and a generated password. Step 5 prints them once and saves them to `vm_passwords.jsonl` next to `.env` (git-ignored), because Azure cannot show them again. Admins can reset a password in the portal (VM, Help, Reset password).
2. The user signs in to the Azure portal, opens their VM, and chooses Connect, then Bastion.
3. They enter that VM's username and password. Bastion does not map users to VMs, so the credentials are what grant access to that machine.
4. Their tools run on the VM. To use an Azure service from the VM they sign in with their own Entra account, so the roles they have still decide what they can do.

**Things to know**
- Setting `ACCESS_MODE` to `bastion` or `both` deploys Bastion (`BASTION_SKU`, Basic by default) and the VMs. Each VM shuts down daily at `VM_SHUTDOWN_TIME` and after `VM_IDLE_SHUTDOWN_MINUTES` with no active session, and is deallocated so compute stops billing. A VM does not start when someone connects, so an admin starts it in the portal.
- VM sign-in uses a local password, so there is no MFA at the VM. Mitigate with long random passwords, short lifetimes and deleting the VMs when finished.
- Each VM costs money while it exists, and Bastion bills hourly whether or not anyone is connected.
- Bastion Basic cannot disable clipboard or file transfer. Bastion Standard can.

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

| `ACCESS_MODE` | Deploys |
|---|---|
| `vpn` | DNS Private Resolver and VPN Gateway (default) |
| `bastion` | Bastion and the user VMs |
| `both` | The VPN and Bastion side by side |

Steps 1 to 4 (the infrastructure and the roles) are the same whichever you choose. See [deployment.md](deployment.md) for the full flow.

## Access path and permissions are separate

Both options only provide a network path in. What a person can do once they are in is decided by their Azure roles. Step 4 manages two groups, admins and developers (see [rbac.md](rbac.md)). Both can open the VMs through Bastion, because both have Reader on the resource group, which the portal needs. People who should have narrower access than the developers tier need a group of your own with roles you assign, which this repository does not create. Give third-party users the narrowest roles that let them do their work.

## Related documents

- [vpn-client-setup.md](vpn-client-setup.md): installing the VPN client and connecting.
- [rbac.md](rbac.md): groups, roles, adding and removing people.
- [architecture.md](architecture.md): what is deployed and why.
- [deployment.md](deployment.md): requirements, configuration, running and verifying.
