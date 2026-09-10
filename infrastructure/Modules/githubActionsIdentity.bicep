param identityName string
param location string
param githubRepositorySubjectPrefix string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
}

resource mainCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-05-31-preview' = {
  parent: identity
  name: 'github-main'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepositorySubjectPrefix}:ref:refs/heads/main'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource productionCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-05-31-preview' = {
  parent: identity
  name: 'github-production'
  dependsOn: [
    mainCredential
  ]
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepositorySubjectPrefix}:environment:production'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

output id string = identity.id
output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
