param name string
param location string
param infrastructureSubnetId string
param workspaceCustomerId string
@secure()
param workspaceSharedKey string
param storageIdentityId string

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${storageIdentityId}': {}
    }
  }
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: true
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspaceCustomerId
        sharedKey: workspaceSharedKey
      }
    }
  }
}

output id string = environment.id
output defaultDomain string = environment.properties.defaultDomain
