// Step 5: tiered RBAC for Entra groups (admin, developer). Key auth is disabled, so roles are the only way in.
import { resourceNames } from 'names.bicep'

param prefix string
// Comma-separated Entra object IDs per tier.
param adminIds string = ''
param developerIds string = ''
@allowed(['User', 'Group', 'ServicePrincipal'])
param principalType string = 'Group'

var n = resourceNames(prefix, resourceGroup().id)

func ids(csv string) array => filter(map(split(csv, ','), p => trim(p)), p => !empty(p))

var principals = {
  admin: ids(adminIds)
  developer: ids(developerIds)
}

// Cross every principal in a tier with that tier's roles for one scope.
func expand(p object, r object) array => concat(
  flatten(map(r.admin, role => map(p.admin, id => { id: id, role: role }))),
  flatten(map(r.developer, role => map(p.developer, id => { id: id, role: role })))
)

func roleId(id string) string => subscriptionResourceId('Microsoft.Authorization/roleDefinitions', id)

var r = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  blobOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  blobContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  filePrivileged: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
  kvAdministrator: '00482a5a-887f-4fb3-b363-3b7fe8e74483'
  kvSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  cogServicesContributor: '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
  openAiContributor: 'a001fd3d-188f-4b5d-821b-7da978bf7442'
  foundryUser: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  customVisionContributor: 'c1ff6cc2-c111-46fe-8896-e0ef812ad9f3'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  mlDataScientist: 'f6c7c914-8db3-469d-8ca1-694a8f32e121'
  mlComputeOperator: 'e503ece1-11d0-4e8e-8e2c-7a6c3bf38815'
  websiteContributor: 'de139f84-1756-47ae-9be6-808fbbe84772'
}

resource lake 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: n.lakeStorage }
resource mlStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: n.mlStorage }
resource kvWorkspace 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: n.keyVault }
resource kvApp 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: n.appKeyVault }
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = { name: n.search }
resource ais 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: n.aiServices }
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: n.acr }
resource mlw 'Microsoft.MachineLearningServices/workspaces@2024-10-01' existing = { name: n.mlWorkspace }
resource func 'Microsoft.Web/sites@2024-04-01' existing = { name: n.funcApp }
resource docIntel 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: n.docIntelligence }
resource cvTraining 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: n.customVisionTraining }
resource cvPrediction 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: n.customVisionPrediction }

var rgAssignments = expand(principals, {
  admin: [r.contributor]
  developer: [r.reader, r.monitoringReader]
})

var lakeAssignments = expand(principals, {
  admin: [r.blobOwner]
  developer: [r.blobContributor]
})

var mlStorageAssignments = expand(principals, {
  admin: [r.blobOwner, r.filePrivileged]
  developer: [r.blobContributor, r.filePrivileged]
})

var kvWorkspaceAssignments = expand(principals, {
  admin: [r.kvAdministrator]
  developer: []
})

var kvAppAssignments = expand(principals, {
  admin: [r.kvAdministrator]
  developer: [r.kvSecretsOfficer]
})

var searchAssignments = expand(principals, {
  admin: [r.searchServiceContributor, r.searchIndexContributor]
  developer: [r.searchServiceContributor, r.searchIndexContributor]
})

var aisAssignments = expand(principals, {
  admin: [r.cogServicesContributor, r.openAiContributor, r.foundryUser]
  developer: [r.cogServicesContributor, r.openAiContributor, r.foundryUser]
})

var acrAssignments = expand(principals, {
  admin: [r.acrPush]
  developer: [r.acrPush]
})

var mlwAssignments = expand(principals, {
  admin: [r.mlDataScientist, r.mlComputeOperator]
  developer: [r.mlDataScientist, r.mlComputeOperator]
})

var funcAssignments = expand(principals, {
  admin: [r.websiteContributor]
  developer: [r.websiteContributor]
})

var docIntelAssignments = expand(principals, {
  admin: [r.cogServicesContributor, r.cognitiveServicesUser]
  developer: [r.cogServicesContributor, r.cognitiveServicesUser]
})

var customVisionAssignments = expand(principals, {
  admin: [r.cogServicesContributor, r.customVisionContributor]
  developer: [r.cogServicesContributor, r.customVisionContributor]
})

resource rgRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in rgAssignments: {
    name: guid(resourceGroup().id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource lakeRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in lakeAssignments: {
    scope: lake
    name: guid(lake.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource mlStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in mlStorageAssignments: {
    scope: mlStorage
    name: guid(mlStorage.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource kvWorkspaceRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in kvWorkspaceAssignments: {
    scope: kvWorkspace
    name: guid(kvWorkspace.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource kvAppRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in kvAppAssignments: {
    scope: kvApp
    name: guid(kvApp.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource searchRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in searchAssignments: {
    scope: search
    name: guid(search.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource aisRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in aisAssignments: {
    scope: ais
    name: guid(ais.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource acrRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in acrAssignments: {
    scope: acr
    name: guid(acr.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource mlwRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in mlwAssignments: {
    scope: mlw
    name: guid(mlw.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource funcRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in funcAssignments: {
    scope: func
    name: guid(func.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource docIntelRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in docIntelAssignments: {
    scope: docIntel
    name: guid(docIntel.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource cvTrainingRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in customVisionAssignments: {
    scope: cvTraining
    name: guid(cvTraining.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

resource cvPredictionRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in customVisionAssignments: {
    scope: cvPrediction
    name: guid(cvPrediction.id, a.id, a.role)
    properties: {
      principalId: a.id
      principalType: principalType
      roleDefinitionId: roleId(a.role)
    }
  }
]

output assigned object = principals
