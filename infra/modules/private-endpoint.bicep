param name string
param location string
param subnetId string
param targetResourceId string
param groupIds array
param zoneIds array

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for (zoneId, i) in zoneIds: {
        name: 'config${i}'
        properties: { privateDnsZoneId: zoneId }
      }
    ]
  }
}

output name string = pe.name
output id string = pe.id
output dnsConfigs array = pe.properties.customDnsConfigs
