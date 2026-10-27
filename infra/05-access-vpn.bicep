// Step 5, ACCESS_MODE=vpn or both: DNS Private Resolver (inbound) and P2S VPN Gateway (OpenVPN + Entra ID).
import { resourceNames } from 'names.bicep'

param prefix string
param location string = resourceGroup().location
param tenantId string = tenant().tenantId
param vpnGatewaySku string = 'VpnGw1AZ'
param vpnClientAddressPool string = '172.16.201.0/24'
// Public-cloud Azure VPN Client app ID.
param vpnAadAudience string = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
// First usable address in a /28 (.0-.3 are reserved); re-used as VNet DNS in step 1.
param resolverInboundIp string = '10.0.3.4'

var n = resourceNames(prefix, resourceGroup().id)
var vnetId = resourceId('Microsoft.Network/virtualNetworks', n.vnet)

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: n.resolver
  location: location
  properties: { virtualNetwork: { id: vnetId } }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: n.resolverInbound
  location: location
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Static'
        privateIpAddress: resolverInboundIp
        subnet: { id: '${vnetId}/subnets/${n.dnsInboundSubnet}' }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: n.vpnPip
  location: location
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource gateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: n.vpnGateway
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    enableBgp: false
    sku: {
      name: vpnGatewaySku
      tier: vpnGatewaySku
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
          subnet: { id: '${vnetId}/subnets/${n.gatewaySubnet}' }
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: { addressPrefixes: [vpnClientAddressPool] }
      vpnClientProtocols: ['OpenVPN']
      vpnAuthenticationTypes: ['AAD']
      aadTenant: '${environment().authentication.loginEndpoint}${tenantId}/'
      aadAudience: vpnAadAudience
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
    }
  }
}

output resolverInboundIp string = inbound.properties.ipConfigurations[0].privateIpAddress
output vpnGatewayName string = gateway.name
output vpnGatewayPublicIpId string = pip.id
