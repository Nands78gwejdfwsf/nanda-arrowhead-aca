param containerAppName string
param clientId string
param tenantId string
param allowedGroupId string
param settingName string

resource app 'Microsoft.App/containerApps@2025-07-01' existing = { name: containerAppName }

resource auth 'Microsoft.App/containerApps/authConfigs@2025-07-01' = {
  parent: app
  name: 'current'
  properties: {
    globalValidation: {
      redirectToProvider: 'azureactivedirectory'
      unauthenticatedClientAction: 'RedirectToLoginPage'
    }
    httpSettings: { requireHttps: true }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: clientId
          clientSecretSettingName: settingName
          openIdIssuer: '${az.environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [clientId]
          defaultAuthorizationPolicy: {
            allowedPrincipals: { groups: [allowedGroupId] }
          }
        }
      }
    }
    platform: { enabled: true }
  }
}
