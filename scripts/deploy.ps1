[CmdletBinding()]
param(
    # 1=network+DNS, 2=storage+Key Vault, 3=AI+ML+Function, 4=RBAC, 5=access (VPN or Bastion per ACCESS_MODE), 6=summary
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
$prefix = $cfg.NAME_PREFIX
if (-not $prefix) {
    throw "NAME_PREFIX is missing in $EnvFile. It was called ENVIRONMENT_NAME in earlier versions, so rename it."
}
$loc = $cfg.AZURE_LOCATION
# ACCESS_MODE picks how people connect in step 5: vpn, bastion, or both (VPN and Bastion deployed side by side).
$accessMode = if ($cfg.ACCESS_MODE) { $cfg.ACCESS_MODE.ToLower() } else { 'vpn' }
if ($accessMode -notin 'vpn', 'bastion', 'both') {
    throw "ACCESS_MODE must be vpn, bastion or both (got '$accessMode')."
}
$vpnOn = $accessMode -in 'vpn', 'both'
$bastionOn = $accessMode -in 'bastion', 'both'
function Get-Setting($name, $default) { if ($cfg[$name]) { $cfg[$name] } else { $default } }
if ($bastionOn) {
    $bastionSku = Get-Setting 'BASTION_SKU' 'Basic'
    if ($bastionSku -notin 'Basic', 'Standard') { throw "BASTION_SKU must be Basic or Standard (got '$bastionSku')." }
    $vmCount = [int](Get-Setting 'VM_COUNT' '3')
    if ($vmCount -lt 0 -or $vmCount -gt 20) { throw "VM_COUNT must be between 0 and 20 (got $vmCount)." }
    $bastionSubnetPrefix = Get-Setting 'BASTION_SUBNET_PREFIX' '10.0.5.0/26'
    $vmSubnetPrefix = Get-Setting 'VM_SUBNET_PREFIX' '10.0.6.0/24'
}
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

# 24 characters from unambiguous letters and digits only (no characters that need quoting), with all three classes present.
function New-VmPassword {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $sets = @('ABCDEFGHJKMNPQRSTUVWXYZ', 'abcdefghjkmnpqrstuvwxyz', '23456789')
    $all = $sets -join ''
    function Pick($chars) { $b = New-Object byte[] 4; $rng.GetBytes($b); $chars[[BitConverter]::ToUInt32($b, 0) % $chars.Length] }
    $pw = @(foreach ($s in $sets) { Pick $s })
    while ($pw.Count -lt 24) { $pw += Pick $all }
    # Fisher-Yates shuffle so the guaranteed characters are not always first.
    for ($i = $pw.Count - 1; $i -gt 0; $i--) {
        $b = New-Object byte[] 4; $rng.GetBytes($b); $j = [BitConverter]::ToUInt32($b, 0) % ($i + 1)
        $pw[$i], $pw[$j] = $pw[$j], $pw[$i]
    }
    -join $pw
}

# Highest VM number that already exists (vm-<prefix>-NN). Their passwords cannot be changed by a redeployment.
function Get-ExistingVmNumber {
    $names = @(Invoke-Az vm list -g $rg --query "[].name" -o tsv | Where-Object { $_ })
    $nums = @($names | Where-Object { $_ -match "^vm-$prefix-(\d\d)$" } | ForEach-Object { [int]$Matches[1] })
    if ($nums.Count -eq 0) { 0 } else { ($nums | Measure-Object -Maximum).Maximum }
}
# Step 6 only reads the environment, so it needs no registration or resource group.
$changesAzure = @($Step | Where-Object { $_ -le 5 }).Count -gt 0
if ($changesAzure -and -not $ValidateOnly) {
    foreach ($ns in 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.ContainerRegistry',
        'Microsoft.Search', 'Microsoft.CognitiveServices', 'Microsoft.MachineLearningServices',
        'Microsoft.Web', 'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
        'Microsoft.Compute', 'Microsoft.DevTestLab') {
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
}
# Only when missing: 'az group create' on an existing group replaces its tags, which removed the naming tag on every rerun.
if ($changesAzure -and -not (Invoke-Az group exists -n $rg | ConvertFrom-Json)) {
    Invoke-Az group create -n $rg -l $loc -o none
}

# Resource names changed (purpose-based names). Environments deployed before that must not rerun steps 2, 3 or 4.
if ($changesAzure) {
    # TSV, not JSON: Windows PowerShell 5.1 parses the text "[]" into one empty-array object, which counts as 1 item.
    $existing = @(Invoke-Az resource list -g $rg --query "[].name" -o tsv | Where-Object { $_ })
    $rgTags = (Invoke-Az group show -n $rg --query tags -o json | Out-String) | ConvertFrom-Json
    $namingCurrent = ($rgTags -and $rgTags.naming -eq 'v2')
    if ($existing.Count -eq 0) {
        $namingCurrent = $true
        if (-not $ValidateOnly) {
            Invoke-Az tag update --resource-id "/subscriptions/$sub/resourceGroups/$rg" --operation merge --tags naming=v2 -o none
        }
    }
    if (-not $namingCurrent -and @($Step | Where-Object { $_ -in 2, 3, 4 }).Count -gt 0) {
        throw "Resource group $rg was deployed with the previous resource names. Steps 2, 3 and 4 would create duplicate resources under the new names. Use -Step 1,5,6 here, or deploy to a new resource group (see docs/deployment.md, Naming)."
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
# The Bastion and VM subnets belong to the VNet definition, so every step 1 run must carry them.
if ($bastionOn) { $net += @("bastionSubnetPrefix=$bastionSubnetPrefix", "vmSubnetPrefix=$vmSubnetPrefix") }

if ($Step -contains 1) { Deploy-Step '01-network.bicep' ($base + $net) }
if ($Step -contains 2) { Deploy-Step '02-storage-keyvault.bicep' $base }
if ($Step -contains 3) { Deploy-Step '03-ai-ml.bicep' $base }
if ($Step -contains 4) {
    # Groups are created on first run (or taken from RBAC_*_GROUP_ID); membership is managed in Entra afterwards.
    $adminId = Get-OrCreateGroup "sg-$prefix-admins" $cfg.RBAC_ADMIN_GROUP_ID "Admins of the $prefix AI environment" -AddMe
    $devId = Get-OrCreateGroup "sg-$prefix-developers" $cfg.RBAC_DEVELOPER_GROUP_ID "Developers of the $prefix AI environment" -AddMe
    Write-Host "Admins: $adminId`nDevelopers: $devId"
    Deploy-Step '04-rbac.bicep' @("prefix=$prefix", "adminIds=$adminId", "developerIds=$devId", 'principalType=Group')
}

# Access layer, chosen by ACCESS_MODE: vpn (resolver and VPN gateway), bastion (Bastion and one VM per user), or both side by side.
if ($Step -contains 5) {
    $dnsArg = @()
    if ($vpnOn) {
        Deploy-Step '05-access-vpn.bicep' ($base + @(
                "tenantId=$($cfg.AZURE_TENANT_ID)",
                "vpnGatewaySku=$($cfg.VPN_GATEWAY_SKU)",
                "vpnClientAddressPool=$($cfg.VPN_CLIENT_ADDRESS_POOL)",
                "vpnAadAudience=$($cfg.VPN_AAD_AUDIENCE)",
                "resolverInboundIp=$resolverIp"))
        # Hand the resolver IP to the VNet so VPN clients pick it up in their profile.
        $dnsArg = @("dnsServer=$resolverIp")
    }
    # Reruns step 1 to set the VNet DNS (vpn) and to make sure the Bastion subnets exist (bastion).
    Deploy-Step '01-network.bicep' ($base + $net + $dnsArg)

    if ($bastionOn) {
        $existingVms = Get-ExistingVmNumber
        $newVms = [Math]::Max($vmCount - $existingVms, 0)
        $passwords = @(for ($i = 0; $i -lt $newVms; $i++) { New-VmPassword })
        $shutdown = Get-Setting 'VM_SHUTDOWN_TIME' '1900'
        if ($shutdown -eq 'none') { $shutdown = '' }
        $tools = (Get-Setting 'VM_INSTALL_TOOLS' 'true').ToLower()
        Write-Host "Bastion: $bastionSku, $vmCount VM(s) wanted, $existingVms already exist, $newVms to create"
        Deploy-Step '05-access-bastion.bicep' ($base + @(
                "bastionSku=$bastionSku",
                "vmCount=$vmCount",
                "existingVmCount=$existingVms",
                "vmSize=$(Get-Setting 'VM_SIZE' 'Standard_B2ms')",
                "vmDiskGb=$(Get-Setting 'VM_DISK_GB' '128')",
                "vmPasswords=$($passwords -join ',')",
                "installTools=$tools",
                "idleShutdownMinutes=$(Get-Setting 'VM_IDLE_SHUTDOWN_MINUTES' '30')",
                "vmShutdownTime=$shutdown",
                "vmShutdownTimeZone=$(Get-Setting 'VM_SHUTDOWN_TIMEZONE' 'UTC')"))
        if (-not $ValidateOnly -and $newVms -gt 0) {
            Write-Host "`n=== VM sign-ins (shown once, store them securely) ===" -ForegroundColor Yellow
            for ($i = 0; $i -lt $newVms; $i++) {
                $num = $existingVms + $i + 1
                $vmName = 'vm-{0}-{1:d2}' -f $prefix, $num
                Write-Host ('{0,-18} user: evt{1:d2}   password: {2}' -f $vmName, $num, $passwords[$i])
            }
            Write-Host 'Admins can reset a password in the Azure portal: VM, Help, Reset password.'
            # Azure never returns a VM password later, so keep them next to .env (git-ignored). Later runs update only the VMs they create.
            $pwFile = Join-Path $PSScriptRoot '..\vm_passwords.jsonl'
            $kept = @(if (Test-Path $pwFile) { Get-Content $pwFile | Where-Object { $_.Trim() } })
            $lines = for ($i = 0; $i -lt $newVms; $i++) {
                $num = $existingVms + $i + 1
                $vmName = 'vm-{0}-{1:d2}' -f $prefix, $num
                $kept = @($kept | Where-Object { ($_ | ConvertFrom-Json).vm -ne $vmName })
                [ordered]@{ vm = $vmName; user = ('evt{0:d2}' -f $num); password = $passwords[$i] } | ConvertTo-Json -Compress
            }
            Set-Content -Path $pwFile -Value (@($kept) + @($lines)) -Encoding ASCII
            Write-Host "Saved to $pwFile"
        }
    }
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

    Write-Host "`n=== Access mode: $accessMode ===" -ForegroundColor Cyan
    if ($accessMode -in 'vpn', 'both') {
        $gw = "vpng-$prefix"
        Write-Host "VPN gateway:    $gw"
        Write-Host "Tenant:         https://login.microsoftonline.com/$($cfg.AZURE_TENANT_ID)/"
        Write-Host "Audience:       $($cfg.VPN_AAD_AUDIENCE)"
        Write-Host "Issuer:         https://sts.windows.net/$($cfg.AZURE_TENANT_ID)/"
        Write-Host "Client pool:    $($cfg.VPN_CLIENT_ADDRESS_POOL)"
        Write-Host "DNS server:     $resolverIp (resolver inbound endpoint)"
        $url = Invoke-Az network vnet-gateway vpn-client generate -g $rg -n $gw -o tsv
        Write-Host "Profile zip:    $url  (AzureVPN\azurevpnconfig.xml, import into Azure VPN Client)"
        $consent = (Invoke-Az ad sp list --filter "appId eq '$($cfg.VPN_AAD_AUDIENCE)'" -o json | Out-String) | ConvertFrom-Json
        $consentState = if (@($consent).Count -gt 0) { 'app exists in the tenant directory' } else { 'app not in the tenant directory (not needed unless VPN sign-in asks for admin approval)' }
        Write-Host "VPN app consent: $consentState"
        Write-Host "Consent URL:    https://login.microsoftonline.com/$($cfg.AZURE_TENANT_ID)/oauth2/authorize?client_id=$($cfg.VPN_AAD_AUDIENCE)&response_type=code&redirect_uri=https://portal.azure.com&nonce=1234&prompt=admin_consent (only if needed)"
    }
    if ($bastionOn) {
        Write-Host "Bastion host:   bas-$prefix ($(Get-Setting 'BASTION_SKU' 'Basic') SKU)"
        Write-Host "Who can connect: the admins and developers groups (they have Reader on the resource group, which the portal needs to open a VM through Bastion)"
        $vmList = @(Invoke-Az vm list -g $rg --query "[].name" -o tsv | Where-Object { $_ -match "^vm-$prefix-\d\d$" })
        foreach ($vmName in ($vmList | Sort-Object)) {
            $num = [int]($vmName -replace "^vm-$prefix-", '')
            Write-Host ('{0,-18} user: evt{1:d2}   https://portal.azure.com/#@{2}/resource/subscriptions/{3}/resourceGroups/{4}/providers/Microsoft.Compute/virtualMachines/{0}/overview' -f $vmName, $num, $cfg.AZURE_TENANT_ID, $sub, $rg)
        }
        Write-Host 'Users open their VM in the portal, choose Connect, then Bastion, and enter that VM''s username and password.'
    }
}
