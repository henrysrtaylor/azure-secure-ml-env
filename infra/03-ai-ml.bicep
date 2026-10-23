// Step 3: ACR, AI Search, AI Foundry (AI Services), Azure ML and Function App, all private-only.
import { privateDnsZones, resourceNames } from 'names.bicep'

param prefix string
param location string = resourceGroup().location

var n = resourceNames(prefix, resourceGroup().id)
var vnetSubnet = '${resourceId('Microsoft.Network/virtualNetworks', n.vnet)}/subnets'
var subnetId = '${vnetSubnet}/${n.servicesSubnet}'
var funcSubnetId = '${vnetSubnet}/${n.funcSubnet}'
var deployContainer = 'app-package'

func zoneId(zone string) string => resourceId('Microsoft.Network/privateDnsZones', zone)

// ---- Container Registry ----
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: n.acr
  location: location
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: 'Disabled'
  }
}

// ---- AI Search ----
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: n.search
  location: location
  sku: { name: 'standard' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
  }
}

// ---- AI Foundry (Azure OpenAI + Cognitive Services) ----
resource ais 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: n.aiServices
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: n.aiServices
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAcls: { defaultAction: 'Deny' }
  }
}

// ---- Storage for ML workspace and Function deployment package ----
resource mlStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: n.mlStorage
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
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

resource mlBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: mlStorage
  name: 'default'
}

resource deployBlob 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: mlBlobService
  name: deployContainer
}

// ---- Monitoring ----
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: n.logAnalytics
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: n.appInsights
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// ---- Private endpoints (storage, ACR, Search, AI Services) ----
module peMlBlob 'modules/private-endpoint.bicep' = {
  name: 'pe-mlstorage-blob'
  params: {
    name: 'pe-${n.mlStorage}-blob'
    location: location
    subnetId: subnetId
    targetResourceId: mlStorage.id
    groupIds: ['blob']
    zoneIds: [zoneId(privateDnsZones.blob)]
  }
}

module peMlFile 'modules/private-endpoint.bicep' = {
  name: 'pe-mlstorage-file'
  dependsOn: [peMlBlob]
  params: {
    name: 'pe-${n.mlStorage}-file'
    location: location
    subnetId: subnetId
    targetResourceId: mlStorage.id
    groupIds: ['file']
    zoneIds: [zoneId(privateDnsZones.file)]
  }
}

module peAcr 'modules/private-endpoint.bicep' = {
  name: 'pe-acr'
  params: {
    name: 'pe-${n.acr}'
    location: location
    subnetId: subnetId
    targetResourceId: acr.id
    groupIds: ['registry']
    zoneIds: [zoneId(privateDnsZones.acr)]
  }
}

module peSearch 'modules/private-endpoint.bicep' = {
  name: 'pe-search'
  params: {
    name: 'pe-${n.search}'
    location: location
    subnetId: subnetId
    targetResourceId: search.id
    groupIds: ['searchService']
    zoneIds: [zoneId(privateDnsZones.search)]
  }
}

module peAis 'modules/private-endpoint.bicep' = {
  name: 'pe-aiservices'
  params: {
    name: 'pe-${n.aiServices}'
    location: location
    subnetId: subnetId
    targetResourceId: ais.id
    groupIds: ['account']
    zoneIds: [
      zoneId(privateDnsZones.openai)
      zoneId(privateDnsZones.cognitive)
      zoneId(privateDnsZones.aiServices)
    ]
  }
}

// ---- Azure Machine Learning ----
resource mlw 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: n.mlWorkspace
  location: location
  kind: 'Default'
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  identity: { type: 'SystemAssigned' }
  dependsOn: [peMlBlob, peMlFile, peAcr]
  properties: {
    friendlyName: n.mlWorkspace
    storageAccount: mlStorage.id
    keyVault: resourceId('Microsoft.KeyVault/vaults', n.keyVault)
    applicationInsights: appi.id
    containerRegistry: acr.id
    publicNetworkAccess: 'Disabled'
    // Accepted by the API but missing from the Bicep type definition.
    #disable-next-line BCP037
    systemDatastoresAuthMode: 'identity'
    managedNetwork: { isolationMode: 'AllowInternetOutbound' }
  }
}

module peMlw 'modules/private-endpoint.bicep' = {
  name: 'pe-mlworkspace'
  params: {
    name: 'pe-${n.mlWorkspace}'
    location: location
    subnetId: subnetId
    targetResourceId: mlw.id
    groupIds: ['amlworkspace']
    zoneIds: [
      zoneId(privateDnsZones.amlApi)
      zoneId(privateDnsZones.amlNotebooks)
    ]
  }
}

// ---- Function App (Flex Consumption, VNet integrated) ----
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: n.funcPlan
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: n.funcApp
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  dependsOn: [peMlBlob]
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: funcSubnetId
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: mlStorage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appi.properties.ConnectionString
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${mlStorage.properties.primaryEndpoints.blob}${deployContainer}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
  }
}

// Storage Blob Data Owner
resource funcStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: mlStorage
  name: guid(mlStorage.id, func.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    )
  }
}

resource appKv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: n.appKeyVault }

// Key Vault Secrets User, so the app can resolve Key Vault references.
resource funcKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appKv
  name: guid(appKv.id, func.id, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

module peFunc 'modules/private-endpoint.bicep' = {
  name: 'pe-functionapp'
  params: {
    name: 'pe-${n.funcApp}'
    location: location
    subnetId: subnetId
    targetResourceId: func.id
    groupIds: ['sites']
    zoneIds: [zoneId(privateDnsZones.sites)]
  }
}

output privateEndpoints array = [
  { name: peMlBlob.outputs.name, dns: peMlBlob.outputs.dnsConfigs }
  { name: peMlFile.outputs.name, dns: peMlFile.outputs.dnsConfigs }
  { name: peAcr.outputs.name, dns: peAcr.outputs.dnsConfigs }
  { name: peSearch.outputs.name, dns: peSearch.outputs.dnsConfigs }
  { name: peAis.outputs.name, dns: peAis.outputs.dnsConfigs }
  { name: peMlw.outputs.name, dns: peMlw.outputs.dnsConfigs }
  { name: peFunc.outputs.name, dns: peFunc.outputs.dnsConfigs }
]
