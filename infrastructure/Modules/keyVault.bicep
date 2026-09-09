param name string
param location string
param publicNetworkAccess string = 'Enabled'

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  properties: {
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: publicNetworkAccess
    sku: { family: 'A'
name: 'standard' }
  }
}

output id string = vault.id
output uri string = vault.properties.vaultUri
