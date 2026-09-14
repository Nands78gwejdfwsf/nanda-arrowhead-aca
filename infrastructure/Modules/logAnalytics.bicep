param workspaceName string
param location string
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: retentionInDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

output id string = workspace.id
output customerId string = workspace.properties.customerId
@secure()
output sharedKey string = workspace.listKeys().primarySharedKey
