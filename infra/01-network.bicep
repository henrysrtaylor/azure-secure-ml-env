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
// Set to the resolver inbound IP in step 5 so VPN clients receive it.
param dnsServer string = ''
// Both set (ACCESS_MODE bastion or both) adds the Bastion and VM subnets. They must be part of the VNet
// definition, because redeploying the VNet without them would remove them.
param bastionSubnetPrefix string = ''
param vmSubnetPrefix string = ''

var n = resourceNames(prefix, resourceGroup().id)
var bastionEnabled = !empty(bastionSubnetPrefix) && !empty(vmSubnetPrefix)

// Rules Azure Bastion requires on its subnet when an NSG is attached.
// https://learn.microsoft.com/azure/bastion/bastion-nsg
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (bastionEnabled) {
  name: n.bastionNsg
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

var baseSubnets = [
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

var accessSubnets = bastionEnabled
  ? [
      {
        name: n.bastionSubnet
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: { id: resourceId('Microsoft.Network/networkSecurityGroups', n.bastionNsg) }
        }
      }
      {
        name: n.vmSubnet
        properties: { addressPrefix: vmSubnetPrefix }
      }
    ]
  : []

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: n.vnet
  location: location
  dependsOn: [bastionNsg]
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressSpace] }
    dhcpOptions: { dnsServers: empty(dnsServer) ? [] : [dnsServer] }
    subnets: concat(baseSubnets, accessSubnets)
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
