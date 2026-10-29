// Step 3: ACR, AI Search, AI Foundry (AI Services), Azure ML and Function App, all private-only.
import { privateDnsZones, resourceNames } from 'names.bicep'

param prefix string
param location string = resourceGroup().location
// basic: indexers and embedding connections only. standard (S1): also private custom skills (Function App) and Foundry skills.
@allowed(['basic', 'standard'])
param searchSku string = 'basic'

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
resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: n.search
  location: location
  // Basic is the cheapest tier with private endpoint support (Free has none).
  sku: { name: searchSku }
  // The identity is what the indexers and the Foundry embedding calls authenticate with (roles are assigned in step 4).
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
  }
}

resource lake 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: n.lakeStorage }

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

// ---- AI Search shared private links: private outbound connections from Search to the Data Lake and Foundry ----
// Each link is created pending. deploy.ps1 approves it on the target (Search cannot approve itself). Chained, because the
// Search service is updated by each one. Basic supports indexers and embedding connections; other built-in skills need S1.
resource splLakeBlob 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-lake-blob'
  dependsOn: [peSearch]
  properties: {
    privateLinkResourceId: lake.id
    groupId: 'blob'
    requestMessage: 'Shared private link from ${n.search}'
  }
}

resource splLakeDfs 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-lake-dfs'
  dependsOn: [splLakeBlob]
  properties: {
    privateLinkResourceId: lake.id
    groupId: 'dfs'
    requestMessage: 'Shared private link from ${n.search}'
  }
}

resource splFoundryOpenAi 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = {
  parent: search
  name: 'spl-foundry-openai'
  dependsOn: [splLakeDfs, peAis]
  properties: {
    privateLinkResourceId: ais.id
    groupId: 'openai_account'
    requestMessage: 'Shared private link from ${n.search}'
  }
}

resource splFoundryModels 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01' = if (searchSku != 'basic') {
  parent: search
  name: 'spl-foundry-models'
  dependsOn: [splFoundryOpenAi]
  properties: {
    privateLinkResourceId: ais.id
    groupId: 'foundry_account'
    requestMessage: 'Shared private link from ${n.search}'
  }
}

// Private custom skills: Search calls the Function App. Needs tier S1 or higher, and the sites group ID is a preview feature.
// Flex Consumption is not in Microsoft's list of supported hosting plans for this link.
resource splFunction 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-02-01-preview' = if (searchSku != 'basic') {
  parent: search
  name: 'spl-function'
  dependsOn: [splFoundryModels, peFunc]
  properties: {
    privateLinkResourceId: func.id
    groupId: 'sites'
    requestMessage: 'Shared private link from ${n.search}'
  }
}

// ---- Custom Vision (shares the cognitiveservices DNS zone with Foundry, so chain it after the Foundry private endpoint) ----
// Custom Vision keeps key auth on because its API is used with keys. Access is private-only.
module customVisionTraining 'modules/cognitive-account.bicep' = {
  name: 'customvision-training'
  dependsOn: [peAis]
  params: {
    name: n.customVisionTraining
    kind: 'CustomVision.Training'
    location: location
    subnetId: subnetId
    zoneIds: [zoneId(privateDnsZones.cognitive)]
    disableLocalAuth: false
  }
}

module customVisionPrediction 'modules/cognitive-account.bicep' = {
  name: 'customvision-prediction'
  dependsOn: [customVisionTraining]
  params: {
    name: n.customVisionPrediction
    kind: 'CustomVision.Prediction'
    location: location
    subnetId: subnetId
    zoneIds: [zoneId(privateDnsZones.cognitive)]
    disableLocalAuth: false
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

// ---- Azure ML managed network: outbound private endpoints from ML jobs and studio to the other services ----
// The managed network is created when the first compute is created, and these rules become private endpoints then.
// The workspace identity approves them (role assigned in step 4). Chained, because the workspace is updated by each one.
resource mlOutLakeBlob 'Microsoft.MachineLearningServices/workspaces/outboundRules@2024-10-01' = {
  parent: mlw
  name: 'lake-blob'
  properties: {
    type: 'PrivateEndpoint'
    category: 'UserDefined'
    destination: {
      serviceResourceId: lake.id
      subresourceTarget: 'blob'
      sparkEnabled: false
    }
  }
}

resource mlOutLakeDfs 'Microsoft.MachineLearningServices/workspaces/outboundRules@2024-10-01' = {
  parent: mlw
  name: 'lake-dfs'
  dependsOn: [mlOutLakeBlob]
  properties: {
    type: 'PrivateEndpoint'
    category: 'UserDefined'
    destination: {
      serviceResourceId: lake.id
      subresourceTarget: 'dfs'
      sparkEnabled: false
    }
  }
}

resource mlOutFoundry 'Microsoft.MachineLearningServices/workspaces/outboundRules@2024-10-01' = {
  parent: mlw
  name: 'foundry'
  dependsOn: [mlOutLakeDfs]
  properties: {
    type: 'PrivateEndpoint'
    category: 'UserDefined'
    destination: {
      serviceResourceId: ais.id
      subresourceTarget: 'account'
      sparkEnabled: false
    }
  }
}

resource mlOutSearch 'Microsoft.MachineLearningServices/workspaces/outboundRules@2024-10-01' = {
  parent: mlw
  name: 'search'
  dependsOn: [mlOutFoundry]
  properties: {
    type: 'PrivateEndpoint'
    category: 'UserDefined'
    destination: {
      serviceResourceId: search.id
      subresourceTarget: 'searchService'
      sparkEnabled: false
    }
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
  { name: customVisionTraining.outputs.peName, dns: customVisionTraining.outputs.dnsConfigs }
  { name: customVisionPrediction.outputs.peName, dns: customVisionPrediction.outputs.dnsConfigs }
  { name: peMlw.outputs.name, dns: peMlw.outputs.dnsConfigs }
  { name: peFunc.outputs.name, dns: peFunc.outputs.dnsConfigs }
]
