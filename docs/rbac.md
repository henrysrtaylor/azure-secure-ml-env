# RBAC

Key authentication is disabled on the data services, so every user needs Azure roles in addition to network access (the VPN). Roles are granted to two Entra security groups, and you manage access by managing group membership.

## Groups

`./scripts/deploy.ps1 -Step 5` creates these groups if they don't exist (named from `ENVIRONMENT_NAME` in `.env`). It makes the deploying user their owner and a member of both, then assigns the roles below.

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
| Document Intelligence | Cognitive Services Contributor, Cognitive Services User | same as admins |
| Custom Vision (training and prediction accounts) | Cognitive Services Contributor, Cognitive Services Custom Vision Contributor | same as admins |
| Container Registry | AcrPush | AcrPush |
| Azure ML workspace | AzureML Data Scientist, AzureML Compute Operator | same as admins |
| Function App | Website Contributor | Website Contributor |

Admins also get Contributor on the resource group, which covers creating and changing resources. Contributor cannot assign roles, so the identity running step 5 needs Owner or User Access Administrator.

## Add members

Membership changes take effect without redeploying anything. Only a group owner, or an Entra admin who can manage groups, can change membership. The user who ran step 5 is an owner of both groups.

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
2. Install the VPN client and import the profile. See [vpn-client-setup.md](vpn-client-setup.md).
3. Admin consent for the Azure VPN Client app must already be granted for the tenant.

### Use an existing group instead

To use groups you already manage, set `RBAC_ADMIN_GROUP_ID` and `RBAC_DEVELOPER_GROUP_ID` in `.env` to their object IDs and rerun `./scripts/deploy.ps1 -Step 5`. Membership is then managed wherever those groups are managed.

## Change what a tier can do

Edit the role lists in `infra/05-rbac.bicep` (the `*Assignments` variables) and rerun `./scripts/deploy.ps1 -Step 5`. Role assignments are tracked by name, so removing a role from a list does not delete the old assignment. Delete it with `az role assignment delete`.

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
- **Removed roles:** removing a role from `infra/05-rbac.bicep` does not delete the existing assignment.
- **Guests:** external (B2B guest) users can be group members. Their sign-in name differs from their email, so look them up by email as shown above.
- **Token refresh:** new memberships and roles apply after a fresh sign-in and can take several minutes.
- **Service identities:** the Function App identity has Storage Blob Data Owner on the ML storage account and Key Vault Secrets User on the application vault. The ML workspace identity receives its roles from Azure when the workspace is created. These are not managed by step 5.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `403` from a service that resolves to a private IP | You lack a role. Check group membership, then sign out and in |
| Step 5 fails creating groups | Your account lacks permission to create groups. Create them in Entra and set the `RBAC_*_GROUP_ID` values in `.env` |
| Step 5 fails creating role assignments | The deploying identity needs Owner or User Access Administrator |
| Cannot read secrets in the ML workspace vault | By design. That vault is for admins only; use the application vault |
