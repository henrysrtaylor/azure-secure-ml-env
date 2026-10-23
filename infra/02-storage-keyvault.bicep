// Step 2: ADLS Gen2 and two Key Vaults (ML workspace, application secrets), all private-only.
import { privateDnsZones, resourceNames } from 'names.bicep'

param prefix string
param location string = resourceGroup().location

var n = resourceNames(prefix, resourceGroup().id)
var subnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', n.vnet, n.servicesSubnet)

func zoneId(zone string) string => resourceId('Microsoft.Network/privateDnsZones', zone)

resource lake 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: n.lakeStorage
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
    isHnsEnabled: true
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Used by the Azure ML workspace only; keep team secrets in appKv.
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: n.keyVault
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// General-purpose vault for application and team secrets.
resource appKv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: n.appKeyVault
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

module peBlob 'modules/private-endpoint.bicep' = {
  name: 'pe-lake-blob'
  params: {
    name: 'pe-${n.lakeStorage}-blob'
    location: location
    subnetId: subnetId
    targetResourceId: lake.id
    groupIds: ['blob']
    zoneIds: [zoneId(privateDnsZones.blob)]
  }
}

module peDfs 'modules/private-endpoint.bicep' = {
  name: 'pe-lake-dfs'
  dependsOn: [peBlob]
  params: {
    name: 'pe-${n.lakeStorage}-dfs'
    location: location
    subnetId: subnetId
    targetResourceId: lake.id
    groupIds: ['dfs']
    zoneIds: [zoneId(privateDnsZones.dfs)]
  }
}

module peVault 'modules/private-endpoint.bicep' = {
  name: 'pe-keyvault'
  params: {
    name: 'pe-${n.keyVault}'
    location: location
    subnetId: subnetId
    targetResourceId: kv.id
    groupIds: ['vault']
    zoneIds: [zoneId(privateDnsZones.vault)]
  }
}

module peAppVault 'modules/private-endpoint.bicep' = {
  name: 'pe-app-keyvault'
  dependsOn: [peVault]
  params: {
    name: 'pe-${n.appKeyVault}'
    location: location
    subnetId: subnetId
    targetResourceId: appKv.id
    groupIds: ['vault']
    zoneIds: [zoneId(privateDnsZones.vault)]
  }
}

output privateEndpoints array = [
  { name: peBlob.outputs.name, dns: peBlob.outputs.dnsConfigs }
  { name: peDfs.outputs.name, dns: peDfs.outputs.dnsConfigs }
  { name: peVault.outputs.name, dns: peVault.outputs.dnsConfigs }
  { name: peAppVault.outputs.name, dns: peAppVault.outputs.dnsConfigs }
]
