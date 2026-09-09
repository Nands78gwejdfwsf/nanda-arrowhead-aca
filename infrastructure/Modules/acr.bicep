param registryName string
param location string
param retentionDays int = 30
param pureotaPrincipalId string = ''
param helixPrincipalId string = ''
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
      retentionPolicy: {
        status: 'enabled'
        days: retentionDays
      }
    }
  }
}

resource pureotaPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(pureotaPrincipalId)) {
  name: guid(acr.id, pureotaPrincipalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: pureotaPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

resource helixPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(helixPrincipalId)) {
  name: guid(acr.id, helixPrincipalId, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: acr
  properties: {
    principalId: helixPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

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
