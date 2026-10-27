# RBAC

Key authentication is disabled on the data services, so every user needs Azure roles in addition to network access (the VPN or a Bastion VM). Roles are granted to two Entra security groups, and you manage access by managing group membership.

## Groups

`./scripts/deploy.ps1 -Step 4` creates these groups if they don't exist (named from `NAME_PREFIX` in `.env`). It makes the deploying user their owner and a member of both, then assigns the roles below.

| Group | Purpose |
|---|---|
| `sg-<prefix>-admins` | Full control of the environment |
| `sg-<prefix>-developers` | Day-to-day data, ML and AI work, including application secrets and model deployments |

To use existing groups instead (for example when your tenant restricts group creation), set `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID` in `.env` to their object IDs.

Roles are assigned only to these groups, never to individual users.

## Roles by tier

| Scope | Admins | Developers |
|---|---|---|
| Resource group | Contributor | Reader, Monitoring Reader |
| Data Lake | Storage Blob Data Owner | Storage Blob Data Contributor |
| ML storage | Storage Blob Data Owner, Storage File Data Privileged Contributor | Storage Blob Data Contributor, Storage File Data Privileged Contributor |
| Key Vault (ML workspace) | Key Vault Administrator | none |
| Key Vault (application) | Key Vault Administrator | Key Vault Secrets Officer (read and write) |
| AI Search | Search Service Contributor, Search Index Data Contributor | same as admins |
| AI Foundry | Cognitive Services Contributor, Cognitive Services OpenAI Contributor, Foundry User | same as admins (can create and manage model deployments) |
| Custom Vision (training and prediction accounts) | Cognitive Services Contributor, Cognitive Services Custom Vision Contributor | same as admins |
| Container Registry | AcrPush | AcrPush |
| Azure ML workspace | AzureML Data Scientist, AzureML Compute Operator | same as admins |
| Function App | Website Contributor | Website Contributor |

Admins also get Contributor on the resource group, which covers creating and changing resources. Contributor cannot assign roles, so the identity running step 4 needs Owner or User Access Administrator.

## Workload identity

Step 4 also creates one user-assigned managed identity, `id-workloads-<prefix>`, and adds it to the developers group. It therefore has exactly the developer roles in the table above. Assign it to any compute or other resource that needs the same access as a developer, and you never grant roles per resource.

**Use it for:**

- **Azure ML compute clusters.** In the studio, create the compute, open Advanced settings, set Assign identity to User-assigned and choose `id-workloads-<prefix>`. The cluster can then read and write the Data Lake and use the registry. A cluster created with a system-assigned identity has no roles and fails with permission errors.
- **Other resources that accept a user-assigned identity,** such as a Function App, when its code needs the developer roles.

A compute instance runs as the person who creates it by default, so it already has that person's group roles and needs no identity.

**This is deliberately lenient.** Every resource using the identity gets the full developer role set, including writing application Key Vault secrets and pushing to the Container Registry, which a workload rarely needs. That is the trade-off for being able to create compute and other resources without any role setup. It suits a sandbox or a single trusted team. For stricter separation, create one identity per team or workload and give it only the roles it needs, either by assigning roles to it directly or by putting it in a separate group.

It still needs a network path. Compute reaches the Data Lake through the ML managed network (see [architecture.md](architecture.md#service-to-service-connections)), and a Function App through its VNet integration. Group membership changes can take several minutes to apply, so a newly added identity can briefly fail with `403`.

If step 4 cannot add the identity to the group (for example when you use an existing group you do not own), it prints a warning. Add it in Entra under the group's members, or run:

```powershell
az ad group member add --group <developers_group_id> --member-id (az identity show -g <resource_group> -n id-workloads-<prefix> --query principalId -o tsv)
```

## Add members

Membership changes take effect without redeploying anything. Only a group owner, or an Entra admin who can manage groups, can change membership. The user who ran step 4 is an owner of both groups.

Choose a group:

| Person needs to | Add to |
|---|---|
| Run the environment, change resources, manage Key Vaults | `sg-<prefix>-admins` |
| Build and use data, ML, AI Search, models and application secrets | `sg-<prefix>-developers` |

Admins do not need to be in both groups, because the admin roles already cover developer access. Add someone to both only if you want that.

### Option 1: Azure portal

1. Open the [Entra admin center](https://entra.microsoft.com) and go to **Groups**, then **All groups**.
2. Select `sg-<prefix>-developers` (or `-admins`).
3. Select **Members**, then **Add members**.
4. Search for the person by name or email, select them, and choose **Select**.

### Option 2: Azure CLI

```powershell
az login --tenant <tenant_id>
$id = az ad user show --id user@contoso.com --query id -o tsv
az ad group member add --group sg-<prefix>-developers --member-id $id
```

Add several people at once:

```powershell
$emails = 'a@contoso.com', 'b@contoso.com'
foreach ($e in $emails) {
    $id = az ad user show --id $e --query id -o tsv
    az ad group member add --group sg-<prefix>-developers --member-id $id
}
```

If `az ad user show` can't find the person, they may be an external guest whose sign-in name differs from their email. Look them up by email instead:

```powershell
az ad user list --filter "mail eq 'user@contoso.com'" --query "[0].id" -o tsv
```

### Check and remove

```powershell
az ad group member list --group sg-<prefix>-developers -o table
az ad group member check --group sg-<prefix>-developers --member-id $id
az ad group member remove --group sg-<prefix>-developers --member-id $id
```

### External users (B2B guests)

Invite them first in the Entra admin center under **Users**, then **Invite external user**. Once they accept, add them to a group the same way. They can then use the environment like any other member.

### What the new member must do

1. Sign out and back in (`az login`, or the portal) so their token includes the new group. Roles can take several minutes to apply.
2. Connect. With VPN access, install the VPN client and import the profile (see [vpn-client-setup.md](vpn-client-setup.md)). With Bastion access, get a VM's username and password from an admin and open the VM in the portal (see [accessing-the-environment.md](accessing-the-environment.md)).
3. With VPN access, if sign-in says admin approval is required, a tenant admin must approve the Azure VPN Client app. See [vpn-client-setup.md](vpn-client-setup.md#grant-admin-consent).

### Use an existing group instead

To use groups you already manage, set `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID` in `.env` to their object IDs and rerun `./scripts/deploy.ps1 -Step 4`. Membership is then managed wherever those groups are managed.

## Change what a tier can do

Edit the role lists in `infra/04-rbac.bicep` (the `*Assignments` variables) and rerun `./scripts/deploy.ps1 -Step 4`. Role assignments are tracked by name, so removing a role from a list does not delete the old assignment. Delete it with `az role assignment delete`.

## Audit

In Windows PowerShell 5.1 the parentheses around the first command are required:

```powershell
(az role assignment list --all -o json | Out-String | ConvertFrom-Json) | Where-Object { $_.scope -like '*<resource_group>*' } | Format-Table principalType, roleDefinitionName, scope
az role assignment list --assignee <group_object_id> --all -o table
```

Assignments of type `ServicePrincipal` belong to the services' own managed identities (Function App, ML workspace and others), not to people.

## Limits

- **VPN profile:** generating the VPN profile needs write-level rights on the gateway. Only admins have them. Developers get the profile file from an admin.
- **Reader scope:** developers have Reader on the resource group, so they can see resources but not change them. Changes to infrastructure go through admins or the deployment script.
- **Groups outlive the resource group:** the Entra groups are not deleted when the resource group is deleted. Delete them separately.
- **Removed roles:** removing a role from `infra/04-rbac.bicep` does not delete the existing assignment.
- **Guests:** external (B2B guest) users can be group members. Their sign-in name differs from their email, so look them up by email as shown above.
- **Token refresh:** new memberships and roles apply after a fresh sign-in and can take several minutes.
- **Service identities:** the Function App identity has Storage Blob Data Owner on the ML storage account and Key Vault Secrets User on the application vault. Each Bastion VM's identity has Virtual Machine Contributor on that VM only, so it can deallocate itself. Step 4 also grants the Search identity Storage Blob Data Reader on the Data Lake and Cognitive Services OpenAI User and Cognitive Services User on the Foundry account, the Foundry identity Storage Blob Data Contributor on the Data Lake (only with `FOUNDRY_LAKE_ACCESS="true"`), and the ML workspace identity Storage Blob Data Contributor on the Data Lake plus Azure AI Enterprise Network Connection Approver on the Data Lake, Foundry and Search. The ML workspace identity receives its other roles from Azure when the workspace is created.
- **Bastion:** admins and developers can open the VMs through Bastion because both groups have Reader on the resource group. Signing in to a VM uses its local username and password, not these roles. Admins can reset a VM password (Contributor on the resource group).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `403` from a service that resolves to a private IP | You lack a role. Check group membership, then sign out and in |
| Step 4 fails creating groups | Your account lacks permission to create groups. Create them in Entra and set the `RBAC_*_GROUP_ID` values in `.env` |
| Step 4 fails creating role assignments | The deploying identity needs Owner or User Access Administrator |
| Cannot read secrets in the ML workspace vault | By design. That vault is for admins only; use the application vault |
| A compute cluster fails reading the Data Lake with a permission error | The cluster has no roles. Recreate it with the user-assigned identity `id-workloads-<prefix>` (see [Workload identity](#workload-identity)) |
