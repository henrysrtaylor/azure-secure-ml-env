param name string
param kind string
param location string
param subnetId string
param zoneIds array
param sku string = 'S0'
// Entra-only unless the service's API cannot use Entra tokens.
param disableLocalAuth bool = true

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  kind: kind
  sku: { name: sku }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: disableLocalAuth
    networkAcls: { defaultAction: 'Deny' }
  }
}

module pe 'private-endpoint.bicep' = {
  name: 'pe-${name}'
  params: {
    name: 'pe-${name}'
    location: location
    subnetId: subnetId
    targetResourceId: account.id
    groupIds: ['account']
    zoneIds: zoneIds
  }
}

output id string = account.id
output peName string = pe.outputs.name
output dnsConfigs array = pe.outputs.dnsConfigs
