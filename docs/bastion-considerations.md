# Bastion: considerations for the next phase

Planning notes. Nothing in this document is built yet. The environment today is VPN only (see [architecture.md](architecture.md)). For when to choose VPN or Bastion, see [accessing-the-environment.md](accessing-the-environment.md).

## Goal

Give 3 one-day-event guests, whose email addresses are not in the tenant, browser-based access to the private environment without installing the VPN client. Keep the VPN as an option. The deployment should be configurable so that the VPN, Bastion or both can be deployed.

## What Bastion does and does not do

- Bastion provides browser RDP or SSH to a VM inside the VNet. It does not give direct access to the private services.
- Users work on the VM. The VM reaches the private endpoints through the VNet's DNS, so a browser, VS Code, Python and the Azure CLI have to be on the VM.
- It avoids the Azure VPN Client, and the tenant admin approval that some tenants require for it. It does not avoid the need to invite guests and give them roles.

## Decisions needed

| # | Decision | Options | Leaning | Status |
|---|---|---|---|---|
| 1 | Access mode setting | `ACCESS_MODE` = `vpn`, `bastion` or `both` | Default `vpn` | Open |
| 2 | Bastion SKU | Developer (free, one session, limited regions), Basic, Standard (clipboard and file-transfer controls) | Basic, Standard if exfiltration controls matter | Open |
| 3 | VM layout | One VM per user, or one pooled VM | One per user, because a Windows client or server VM gives one interactive session at a time | Open |
| 4 | VM size and image | `B2ms` Windows Server, `B2s`, Windows 11 | `B2ms` Windows Server (licence included in the price). Windows 11 needs separate licensing | Open |
| 5 | VM sign-in | Microsoft Entra ID, or local user ID and password | Local user ID and password per VM for the one-day event, because guest sign-in with Entra is unverified. Admins reset passwords in the portal. Revisit Entra if guest sign-in is confirmed | Decided: password |
| 6 | Guest group and roles | Developers group, or a new event group with narrower roles | New event group. The developers group includes secrets, registry push and AI contributor rights | Open |
| 7 | Software on the VMs | Install script at deployment, custom image, Dev Box or Azure Virtual Desktop | Install script for 3 to 4 VMs | Open |
| 8 | Lifecycle | Deploy the day before and delete afterwards, or keep and deallocate | Deploy and delete | Open |
| 9 | Step numbering | Decided: step 5 is the access step and `ACCESS_MODE` chooses VPN or Bastion. The summary stays step 6 | Add `05-access-bastion.bicep` for Bastion | Decided |

## Technical considerations

**Network**
- Bastion Basic and Standard need a subnet named exactly `AzureBastionSubnet`, at least a /26. The Developer SKU needs none.
- The VMs need their own subnet (for example `10.0.5.0/24`). Do not reuse the private endpoint subnet.
- Ranges would be new `.env` keys.
- **Risk to verify:** the subscription attaches empty network security groups to subnets (it did to three of ours). An empty NSG on `AzureBastionSubnet` would block Bastion, which needs specific rules. Check whether the policy attaches one to the new subnet, and add the required rules if it does.
- A Standard static public IP is needed for Basic and Standard.

**DNS**
- With `both`, the VNet DNS server is the resolver (`10.0.3.4`) and the VMs use it. With `bastion` only, no resolver is needed and the VMs use Azure's default DNS, which resolves the linked private zones.
- Step 5 deploys the VPN Gateway and the resolver, and sets the VNet DNS. `ACCESS_MODE` already selects it. `bastion` and `both` are refused by the script until the Bastion template exists.

**Sign-in and RBAC**
- Entra sign-in needs the `AADLoginForWindows` extension and a system-assigned identity on each VM, plus the Virtual Machine User Login (or Administrator Login) role for the group.
- Bastion needs read access to the VM, its network interface and the Bastion host.
- **Not verified:** that an Entra B2B guest can sign in to the VM through Bastion. Test with one guest first. Fallback is a local admin password.
- Windows VM creation requires an admin password even with Entra sign-in. Generate a random one at deployment, do not store it, and reset it in the portal if needed.
**Password sign-in (decided for the one-day event)**
- One VM and one local account per guest. A `VM_COUNT` setting in `.env` sets how many VMs are created, named `vm-<prefix>-01`, `-02` and so on, with usernames such as `evt01`, `evt02`. Azure rejects usernames like `admin` and `user1`. VM size, disk and auto-shutdown would be settings too.
- The deploy script generates a long random password per VM, passes them to the template as secure parameters, and prints a table once (VM, username, password) for an admin to hand over through a secure channel. Never store them in the repo.\n- Bastion does not map a username to a VM. A guest opens their own VM in the portal (VM, Connect, Bastion), then enters that VM's username and password. Typing credentials on the wrong VM simply fails. The printed handout should therefore include a portal link to each guest's VM as well as the username and password, and each guest should get Reader on only their own VM, its network interface and the Bastion host so they see only that VM.
- Azure does not allow changing a VM's admin password through a redeployment, so the script passes passwords only for VMs that do not exist yet. Raising `VM_COUNT` adds VMs. Lowering it does not delete any, so extra VMs are removed by hand.
- Admins reset it in the Azure portal (VM, Help, Reset password). This needs write rights on the VM, which the admins group has through Contributor on the resource group. Developers and guests do not have it.
- Trade-offs: no MFA or Conditional Access on the VM sign-in, and the password has to be distributed. Mitigate with a long random password, a one-day lifetime and deleting the VMs afterwards.
- Guests still need an Entra guest account and read access to the VM, its network interface and the Bastion host to open it from the portal. With password sign-in they do not need the VM login roles.
- Bastion Standard has a shareable link feature that lets someone connect with the VM's username and password without an Azure sign-in. It would remove the invite step, but the link plus the password would then be the only protection. Not verified here, so check the Microsoft documentation and test before using it.

- Role assignments for the new resources could live in the Bastion step, so they work on environments where step 4 is refused by the naming guard.

**Software**
- Use a VM extension script that downloads and installs VS Code, Python, Git and the Azure CLI. Windows Server 2022 does not include `winget`, so use direct installers.
- The VMs need outbound internet for the downloads and for `pip`. Azure's default outbound access for new subnets has been changing, so check at the first deployment whether a NAT gateway is needed.
- Open internet from the VMs weakens the private-only design. Consider restricting outbound traffic or using a private package mirror.

**Data exfiltration**
- Bastion Standard can disable clipboard and file transfer. Basic cannot.
- Anyone on a VM can reach everything their roles allow, so keep the guest roles narrow.

**Cost** (UK South list prices, pre-VAT, bandwidth and discounts excluded)

| Item | Per hour | About per month |
|---|---|---|
| Bastion Developer | free | £0 |
| Bastion Basic | £0.143 | £105 |
| Bastion Standard | £0.219 | £160 |
| Public IP (Standard, static) | £0.0038 | £3 |
| VM `B2ms` Windows Server | £0.077 | £17 for 220 hours, £56 always on |
| VM `B2s` Windows Server | £0.042 | £9 for 220 hours, £30 always on |
| 128 GiB standard SSD disk | n/a | £8 per VM, even when stopped |

For a one-day event deployed and deleted within a day or two, Bastion Basic plus 3 VMs costs a few pounds. Left running for a month it is about £130 to £210. Bastion bills hourly even when no one is connected.

**Capacity**
- Check vCPU quota for the chosen VM family. Three `B2ms` VMs need 6 vCPUs.
- Check that the chosen Bastion SKU is available in the region.

**Naming and guards**
- Names would follow the convention: for example `bas-<prefix>`, `pip-bas-<prefix>`, `vm-<prefix>-01`. See [deployment.md](deployment.md#naming).
- Bastion is additive, so the naming guard that blocks steps 2, 3 and 4 on older environments does not need to block it.

## Guests

- The guests are invited as Entra B2B guests and added to a group. See [rbac.md](rbac.md).
- **Invite checks, days before the event:**
  - You can invite guests in the tenant (guests often cannot, by default).
  - The tenant's external collaboration settings allow the guests' email domain.
  - The guests can complete the sign-in and MFA prompts.
- A script to invite from a list and add to the group, and another to remove them and delete their accounts, would make setup and cleanup repeatable.
- Guests open the portal through `https://portal.azure.com/<tenant_id>` so they land in the right tenant.

## Acceptance tests (run a few days before)

1. A guest accepts the invitation and signs in to the portal.
2. The guest opens the VM through Bastion and signs in.
3. On the VM, a private name resolves to a `10.0.1.x` address (`Resolve-DnsName`, not `nslookup`).
4. On the VM, ML studio opens and a compute instance can be created.
5. On the VM, VS Code and Python run, and `pip install` works.
6. A call to Document Intelligence works from the VM.
7. Cleanup removes the guests, the group membership and the VMs.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Guests cannot sign in to the VM with Entra | Event blocked | Test early, fall back to local passwords |
| Policy-attached NSG breaks `AzureBastionSubnet` | Bastion fails to deploy or connect | Check on the first deploy, add the required rules |
| Guest invites blocked by tenant settings | Guests cannot join | Test with one invite well before the event |
| No outbound internet from the VMs | Software install and `pip` fail | Check outbound access, add a NAT gateway if needed |
| VM quota or Bastion SKU not available in the region | Deployment fails | Check quota and availability first |
| Cost left running | Unplanned spend | Tear down after the event, add the tear-down to the runbook |

## Proposed work order

1. Settle the decisions above.
2. Done: the `ACCESS_MODE` setting exists in `.env` and the step order puts the access choice last (step 5).
3. Add `infra/05-access-bastion.bicep`: subnets, Bastion, VMs, install extension, auto-shutdown, roles. Extend the Bastion-specific settings in `.env`.
4. Make step 5 in the deploy script run the Bastion template for `bastion` and `both`, and show the Bastion connection details in step 6.
5. Update every doc that mentions the access step.
6. Add the guest invite and cleanup scripts.
7. Deploy to a test resource group, run the acceptance tests, fix what fails.
8. Write the event-day runbook and update [deployment.md](deployment.md), [rbac.md](rbac.md) and [architecture.md](architecture.md).
