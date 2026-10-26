// Shared naming so every step file derives identical resource names.

@export()
var privateDnsZones = {
  amlApi: 'privatelink.api.azureml.ms'
  amlNotebooks: 'privatelink.notebooks.azure.net'
  openai: 'privatelink.openai.azure.com'
  cognitive: 'privatelink.cognitiveservices.azure.com'
  aiServices: 'privatelink.services.ai.azure.com'
  search: 'privatelink.search.windows.net'
  blob: 'privatelink.blob.core.windows.net'
  dfs: 'privatelink.dfs.core.windows.net'
  file: 'privatelink.file.core.windows.net'
  vault: 'privatelink.vaultcore.azure.net'
  acr: 'privatelink.azurecr.io'
  sites: 'privatelink.azurewebsites.net'
}

// Convention: <type>-<purpose>-<prefix>[-<hash>]. The hash is only added where Azure needs a globally unique name.
@export()
func resourceNames(prefix string, seed string) object => {
  vnet: 'vnet-${prefix}'
  servicesSubnet: 'services-subnet'
  gatewaySubnet: 'GatewaySubnet'
  dnsInboundSubnet: 'dns-inbound-subnet'
  funcSubnet: 'func-integration-subnet'
  lakeStorage: take('stlake${replace(toLower(prefix), '-', '')}${uniqueString(seed)}', 24)
  mlStorage: take('stmlws${replace(toLower(prefix), '-', '')}${uniqueString(seed)}', 24)
  keyVault: take('kv-ml-${prefix}-${uniqueString(seed)}', 24)
  appKeyVault: take('kv-app-${prefix}-${uniqueString(seed)}', 24)
  acr: take('acr${replace(toLower(prefix), '-', '')}${uniqueString(seed)}', 50)
  search: 'srch-${prefix}-${take(uniqueString(seed), 6)}'
  aiServices: 'foundry-${prefix}-${take(uniqueString(seed), 6)}'
  docIntelligence: 'docintel-${prefix}-${take(uniqueString(seed), 6)}'
  customVisionTraining: 'customvision-train-${prefix}-${take(uniqueString(seed), 6)}'
  customVisionPrediction: 'customvision-pred-${prefix}-${take(uniqueString(seed), 6)}'
  logAnalytics: 'log-${prefix}'
  appInsights: 'appi-${prefix}'
  mlWorkspace: 'mlw-${prefix}'
  funcPlan: 'plan-func-${prefix}'
  funcApp: 'func-${prefix}-${take(uniqueString(seed), 6)}'
  resolver: 'dnspr-${prefix}'
  resolverInbound: 'inbound'
  vpnGateway: 'vpng-${prefix}'
  vpnPip: 'pip-vpng-${prefix}'
}
