[CmdletBinding()]
param(
    # 1=network+DNS, 2=storage+Key Vault, 3=AI+ML+Function, 4=VPN+resolver (+VNet DNS), 5=RBAC, 6=summary
    [int[]]$Step = @(1, 2, 3, 4, 5, 6),
    [switch]$ValidateOnly,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)

$ErrorActionPreference = 'Stop'
$infra = Join-Path $PSScriptRoot '..\infra'

# Load .env into a hashtable
$cfg = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    $cfg[$k.Trim()] = $v.Trim().Trim('"')
}

$sub = $cfg.AZURE_SUBSCRIPTION_ID
$rg = $cfg.RESOURCE_GROUP_NAME
$prefix = $cfg.ENVIRONMENT_NAME
$loc = $cfg.AZURE_LOCATION
# First usable address of the resolver subnet (.0-.3 are reserved by Azure), e.g. 10.0.3.0/28 -> 10.0.3.4.
$dnsParts = $cfg.DNS_INBOUND_SUBNET_PREFIX -split '[./]'
$resolverIp = "$($dnsParts[0]).$($dnsParts[1]).$($dnsParts[2]).$([int]$dnsParts[3] + 4)"

function Invoke-Az {
    # Retry to ride out transient connection resets; every call here is idempotent.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $out = & az @args
        if ($LASTEXITCODE -eq 0) { return $out }
        if ($attempt -lt 3) { Start-Sleep 5 }
    }
    throw "az $($args -join ' ') failed"
}

function Deploy-Step([string]$File, [string[]]$Params) {
    $path = Join-Path $infra $File
    Write-Host "`n=== $File ===" -ForegroundColor Cyan
    Invoke-Az bicep build --file $path --stdout | Out-Null
    Invoke-Az deployment group validate -g $rg -f $path -p @Params -o none
    if ($ValidateOnly) { return }
    Invoke-Az deployment group create -g $rg -n ($File -replace '\.bicep$', '') -f $path -p @Params -o none
}

function Get-OrCreateGroup([string]$Name, [string]$ExistingId, [string]$Description, [switch]$AddMe) {
    if ($ExistingId) { return $ExistingId }
    $found = (Invoke-Az ad group list --display-name $Name -o json | Out-String) | ConvertFrom-Json
    $match = @($found | Where-Object { $_.displayName -eq $Name })
    if ($match.Count -gt 0) { return $match[0].id }
    if ($ValidateOnly) { return '' }
    Write-Host "Creating Entra group $Name"
    $id = Invoke-Az ad group create --display-name $Name --mail-nickname $Name --description $Description --query id -o tsv
    $me = Invoke-Az ad signed-in-user show --query id -o tsv
    Invoke-Az ad group owner add --group $id --owner-object-id $me
    if ($AddMe) { Invoke-Az ad group member add --group $id --member-id $me }
    $id
}

Invoke-Az account set --subscription $sub
# Step 6 only reads the environment, so it needs no registration or resource group.
$changesAzure = @($Step | Where-Object { $_ -le 5 }).Count -gt 0
if ($changesAzure -and -not $ValidateOnly) {
    foreach ($ns in 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.ContainerRegistry',
        'Microsoft.Search', 'Microsoft.CognitiveServices', 'Microsoft.MachineLearningServices',
        'Microsoft.Web', 'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.Insights') {
        if ((Invoke-Az provider show --namespace $ns --query registrationState -o tsv) -ne 'Registered') {
            Invoke-Az provider register --namespace $ns --wait -o none
        }
    }
    # Required by the VPN Gateway's Standard public IP.
    $feature = Invoke-Az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state -o tsv
    if ($feature -ne 'Registered') {
        Invoke-Az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress -o none
        do {
            Start-Sleep 10
            $feature = Invoke-Az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state -o tsv
        } while ($feature -ne 'Registered')
        Invoke-Az provider register --namespace Microsoft.Network --wait -o none
    }
    Invoke-Az group create -n $rg -l $loc -o none
}
elseif ($changesAzure -and -not (Invoke-Az group exists -n $rg | ConvertFrom-Json)) {
    Invoke-Az group create -n $rg -l $loc -o none
}

# Resource names changed (purpose-based names). Environments deployed before that must not rerun steps 2, 3 or 5.
if ($changesAzure) {
    $existing = @((Invoke-Az resource list -g $rg --query "[].name" -o json | Out-String) | ConvertFrom-Json)
    $rgTags = (Invoke-Az group show -n $rg --query tags -o json | Out-String) | ConvertFrom-Json
    $namingCurrent = ($rgTags -and $rgTags.naming -eq 'v2')
    if ($existing.Count -eq 0) {
        $namingCurrent = $true
        if (-not $ValidateOnly) {
            Invoke-Az tag update --resource-id "/subscriptions/$sub/resourceGroups/$rg" --operation merge --tags naming=v2 -o none
        }
    }
    if (-not $namingCurrent -and @($Step | Where-Object { $_ -in 2, 3, 5 }).Count -gt 0) {
        throw "Resource group $rg was deployed with the previous resource names. Steps 2, 3 and 5 would create duplicate resources under the new names. Use -Step 1,4,6 here, or deploy to a new resource group (see docs/deployment.md, Naming)."
    }
}

$base = @("prefix=$prefix", "location=$loc")
$net = @(
    "vnetAddressSpace=$($cfg.VNET_ADDRESS_SPACE)",
    "servicesSubnetPrefix=$($cfg.SERVICES_SUBNET_PREFIX)",
    "gatewaySubnetPrefix=$($cfg.GATEWAY_SUBNET_PREFIX)",
    "dnsInboundSubnetPrefix=$($cfg.DNS_INBOUND_SUBNET_PREFIX)",
    "funcSubnetPrefix=$($cfg.FUNCTION_INTEGRATION_SUBNET_PREFIX)"
)

if ($Step -contains 1) { Deploy-Step '01-network.bicep' ($base + $net) }
if ($Step -contains 2) { Deploy-Step '02-storage-keyvault.bicep' $base }
if ($Step -contains 3) { Deploy-Step '03-ai-ml.bicep' $base }
if ($Step -contains 4) {
    Deploy-Step '04-vpn-resolver.bicep' ($base + @(
            "tenantId=$($cfg.AZURE_TENANT_ID)",
            "vpnGatewaySku=$($cfg.VPN_GATEWAY_SKU)",
            "vpnClientAddressPool=$($cfg.VPN_CLIENT_ADDRESS_POOL)",
            "vpnAadAudience=$($cfg.VPN_AAD_AUDIENCE)",
            "resolverInboundIp=$resolverIp"))
    # Hand the resolver IP to the VNet so VPN clients pick it up in their profile.
    Deploy-Step '01-network.bicep' ($base + $net + @("dnsServer=$resolverIp"))
}

if ($Step -contains 5) {
    # Groups are created on first run (or taken from RBAC_*_GROUP_ID); membership is managed in Entra afterwards.
    $adminId = Get-OrCreateGroup "sg-$prefix-admins" $cfg.RBAC_ADMIN_GROUP_ID "Admins of the $prefix AI environment" -AddMe
    $devId = Get-OrCreateGroup "sg-$prefix-developers" $cfg.RBAC_DEVELOPER_GROUP_ID "Developers of the $prefix AI environment" -AddMe
    Write-Host "Admins: $adminId`nDevelopers: $devId"
    Deploy-Step '05-rbac.bicep' @("prefix=$prefix", "adminIds=$adminId", "developerIds=$devId", 'principalType=Group')
}

if ($Step -contains 6 -and -not $ValidateOnly) {
    $portal = "https://portal.azure.com/#@$($cfg.AZURE_TENANT_ID)/resource/subscriptions/$sub/resourceGroups/$rg"
    Write-Host "`n=== Portal links ===" -ForegroundColor Cyan
    Write-Host "Resource group: $portal/overview"
    $resources = (Invoke-Az resource list -g $rg --query "[?type!='Microsoft.Network/privateEndpoints' && type!='Microsoft.Network/privateDnsZones' && type!='Microsoft.Network/privateDnsZones/virtualNetworkLinks' && type!='Microsoft.Network/networkInterfaces' && type!='microsoft.alertsmanagement/smartDetectorAlertRules'].{n:name,id:id}" -o json | Out-String) | ConvertFrom-Json
    foreach ($r in $resources) {
        Write-Host ("{0,-45} https://portal.azure.com/#@{1}/resource{2}" -f $r.n, $cfg.AZURE_TENANT_ID, $r.id)
    }

    Write-Host "`n=== Private endpoint IPs ===" -ForegroundColor Cyan
    $nics = (Invoke-Az network nic list -g $rg --query "[?privateEndpoint!=null].{pe:privateEndpoint.id,ip:ipConfigurations[0].privateIPAddress,fqdns:ipConfigurations[0].privateLinkConnectionProperties.fqdns}" -o json | Out-String) | ConvertFrom-Json
    foreach ($nic in ($nics | Sort-Object pe)) {
        Write-Host ("{0,-45} {1,-12} {2}" -f ($nic.pe -split '/')[-1], $nic.ip, ($nic.fqdns -join ', '))
    }

    Write-Host "`n=== VPN client profile ===" -ForegroundColor Cyan
    $gw = "vpng-$prefix"
    Write-Host "Gateway:        $gw"
    Write-Host "Tenant:         https://login.microsoftonline.com/$($cfg.AZURE_TENANT_ID)/"
    Write-Host "Audience:       $($cfg.VPN_AAD_AUDIENCE)"
    Write-Host "Issuer:         https://sts.windows.net/$($cfg.AZURE_TENANT_ID)/"
    Write-Host "Client pool:    $($cfg.VPN_CLIENT_ADDRESS_POOL)"
    Write-Host "DNS server:     $resolverIp (resolver inbound endpoint)"
    $url = Invoke-Az network vnet-gateway vpn-client generate -g $rg -n $gw -o tsv
    Write-Host "Profile zip:    $url  (AzureVPN\azurevpnconfig.xml, import into Azure VPN Client)"
    $consent = (Invoke-Az ad sp list --filter "appId eq '$($cfg.VPN_AAD_AUDIENCE)'" -o json | Out-String) | ConvertFrom-Json
    $consentState = if (@($consent).Count -gt 0) { 'granted (app exists in the tenant)' } else { 'app not in the tenant yet (an admin must approve it, or user consent may add it at first sign-in)' }
    Write-Host "Admin consent:  $consentState"
    Write-Host "Consent URL:    https://login.microsoftonline.com/$($cfg.AZURE_TENANT_ID)/oauth2/authorize?client_id=$($cfg.VPN_AAD_AUDIENCE)&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent"
}
