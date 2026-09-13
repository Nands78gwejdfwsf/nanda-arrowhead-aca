param registryName string
param location string
param retentionDays int = 30
param applicationPrincipalIds array = []
param githubPrincipalId string = ''

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    policies: {
      retentionPolicy: { status: 'enabled', days: retentionDays }
    }
  }
}

resource applicationPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in applicationPrincipalIds: {
  name: guid(acr.id, principalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}]

resource githubPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(githubPrincipalId)) {
  name: guid(acr.id, githubPrincipalId, '8311e382-0749-4cb8-b61a-304f252e45ec')
  scope: acr
  properties: {
    principalId: githubPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
  }
}

output id string = acr.id
output name string = acr.name
output loginServer string = acr.properties.loginServer
