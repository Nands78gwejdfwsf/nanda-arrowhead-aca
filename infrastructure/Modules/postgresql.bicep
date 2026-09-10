param serverName string
param location string
param administratorLogin string
@secure()
param administratorLoginPassword string
param storageSizeGB int = 32
param backupRetentionDays int = 7

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    version: '16'
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    storage: {
      storageSizeGB: storageSizeGB
      tier: 'P4'
      autoGrow: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
    network: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

output id string = server.id
output fqdn string = server.properties.fullyQualifiedDomainName
