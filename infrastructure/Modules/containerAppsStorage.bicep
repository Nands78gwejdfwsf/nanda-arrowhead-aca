param environmentName string
param storageName string
param storageAccountName string
param fileShareName string
param keyVaultName string
param storageIdentityId string
param secretName string

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' existing = { name: environmentName }

resource storage 'Microsoft.App/managedEnvironments/storages@2025-10-02-preview' = {
  parent: environment
  name: storageName
  properties: {
    azureFile: {
      accessMode: 'ReadWrite'
      accountName: storageAccountName
      shareName: fileShareName
      accountKeyVaultProperties: {
        identity: storageIdentityId
        keyVaultUrl: 'https://${keyVaultName}${az.environment().suffixes.keyvaultDns}/secrets/${secretName}'
      }
    }
  }
}

output name string = storage.name
