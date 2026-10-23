// Step 1: VNet, subnets and private DNS zones linked to the VNet.
import { privateDnsZones, resourceNames } from 'names.bicep'

param prefix string
param location string = resourceGroup().location
param vnetAddressSpace string = '10.0.0.0/16'
param servicesSubnetPrefix string = '10.0.1.0/24'
param gatewaySubnetPrefix string = '10.0.2.0/24'
param dnsInboundSubnetPrefix string = '10.0.3.0/28'
// Flex Consumption VNet integration needs its own delegated subnet.
param funcSubnetPrefix string = '10.0.4.0/24'
// Set to the resolver inbound IP in step 4 so VPN clients receive it.
param dnsServer string = ''

var n = resourceNames(prefix, resourceGroup().id)

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: n.vnet
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressSpace] }
    dhcpOptions: { dnsServers: empty(dnsServer) ? [] : [dnsServer] }
    subnets: [
      {
        name: n.servicesSubnet
        properties: { addressPrefix: servicesSubnetPrefix }
      }
      {
        name: n.gatewaySubnet
        properties: { addressPrefix: gatewaySubnetPrefix }
      }
      {
        name: n.dnsInboundSubnet
        properties: {
          addressPrefix: dnsInboundSubnetPrefix
          delegations: [
            {
              name: 'dnsResolver'
              properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
            }
          ]
        }
      }
      {
        name: n.funcSubnet
        properties: {
          addressPrefix: funcSubnetPrefix
          delegations: [
            {
              name: 'flexConsumption'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for z in items(privateDnsZones): {
    name: z.value
    location: 'global'
  }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in items(privateDnsZones): {
    parent: zones[i]
    name: 'link-${n.vnet}'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: vnet.id }
    }
  }
]

output vnetId string = vnet.id
output zoneNames array = [for z in items(privateDnsZones): z.value]
