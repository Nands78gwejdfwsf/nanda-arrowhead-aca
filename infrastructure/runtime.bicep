targetScope = 'resourceGroup'

@description('Azure region')
param location string = 'westus'

@description('Existing resource group')
param resourceGroupName string = 'NANDA-rg-arrowhead-aca-test1'

@description('PostgreSQL Entra administrator group object ID')
param postgresqlEntraAdministratorObjectId string

@description('PostgreSQL Entra administrator group display name')
param postgresqlEntraAdministratorName string

@description('PureOTA Entra group object ID')
param pureotaEntraGroupObjectId string

@description('PureOTA Entra application client ID')
param pureotaEntraClientId string

@description('HelixBridge Entra group object ID')
param helixbridgeEntraGroupObjectId string

@description('HelixBridge Entra application client ID')
param helixbridgeEntraClientId string

@description('Monitoring notification email')
param notificationEmail string

var acrName = 'nandaacrarrowheadaca'
var keyVaultName = 'NANDA-kv-aca-test20'
var postgresqlServerName = 'nanda-pg-aca-test'
var containerAppsEnvironmentName = 'NANDA-cae-arrowhead-aca-test'
var pureotaStorageAccountName = 'nandastpureotaaca'
var pureotaFileShareName = 'pureota-data'
var pureotaIdentityName = 'NANDA-id-pureota'
var helixIdentityName = 'NANDA-id-helixbridge'
var storageIdentityName = 'NANDA-id-aca-storage'
var githubIdentityName = 'NANDA-id-github-actions'
var pureotaAppName = 'nanda-ca-pureota'
var helixAppName = 'nanda-ca-helixbridge'
var pureotaJobName = 'nanda-job-pureota'
var storageBindingName = 'nanda-pureota-storage'
var pureotaStorageKeySecretName = 'pureota-storage-key'
var pureotaAuthSecretName = 'pureota-entra-client-secret'
var helixAuthSecretName = 'helixbridge-entra-client-secret'
var tenantId = subscription().tenantId

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = {
  name: postgresqlServerName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: pureotaStorageAccountName
}

resource acaEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: containerAppsEnvironmentName
}

resource pureotaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: pureotaIdentityName
}

resource helixIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: helixIdentityName
}

resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: storageIdentityName
}

resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: githubIdentityName
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'NANDA-law-arrowhead-aca-test'
}

module storageKvAccess './Modules/roleAssignment.bicep' = {
  name: 'storageKvAccess'
  params: {
    keyVaultName: keyVaultName
    secretName: pureotaStorageKeySecretName
    principalId: storageIdentity.properties.principalId
    roleDefinitionId: '4633458b-17de-408a-b874-0445c86b69e6'
  }
}

module pureotaKvAccess './Modules/roleAssignment.bicep' = {
  name: 'pureotaKvAccess'
  params: {
    keyVaultName: keyVaultName
    secretName: pureotaAuthSecretName
    principalId: pureotaIdentity.properties.principalId
    roleDefinitionId: '4633458b-17de-408a-b874-0445c86b69e6'
  }
}

module helixKvAccess './Modules/roleAssignment.bicep' = {
  name: 'helixKvAccess'
  params: {
    keyVaultName: keyVaultName
    secretName: helixAuthSecretName
    principalId: helixIdentity.properties.principalId
    roleDefinitionId: '4633458b-17de-408a-b874-0445c86b69e6'
  }
}

module containerStorage './Modules/containerAppsStorage.bicep' = {
  name: 'containerStorage'
  dependsOn: [storageKvAccess]
  params: {
    environmentName: containerAppsEnvironmentName
    storageName: storageBindingName
    storageAccountName: pureotaStorageAccountName
    fileShareName: pureotaFileShareName
    keyVaultName: keyVaultName
    storageIdentityId: storageIdentity.id
    secretName: pureotaStorageKeySecretName
  }
}

module pureotaApp './Modules/containerApp.bicep' = {
  name: 'pureotaApp'
  dependsOn: [containerStorage, pureotaKvAccess]
  params: {
    name: pureotaAppName
    location: location
    environmentId: acaEnvironment.id
    image: 'nginx:alpine'
    containerPort: 80
    minReplicas: 1
    maxReplicas: 1
    identityId: pureotaIdentity.id
    githubActionsPrincipalId: githubIdentity.properties.principalId
    acrLoginServer: '${acr.name}.azurecr.io'
    keyVaultName: keyVaultName
    keyVaultSecretName: pureotaAuthSecretName
    enableKeyVaultSecret: true
    enableAzureFile: true
    azureFileStorageName: storageBindingName
    azureFileMountPath: '/usr/share/nginx/html/tier-data'
    healthPath: '/healthz'
  }
}

module helixApp './Modules/containerApp.bicep' = {
  name: 'helixApp'
  dependsOn: [helixKvAccess]
  params: {
    name: helixAppName
    location: location
    environmentId: acaEnvironment.id
    image: 'nginx:alpine'
    containerPort: 80
    minReplicas: 1
    maxReplicas: 1
    identityId: helixIdentity.id
    githubActionsPrincipalId: githubIdentity.properties.principalId
    acrLoginServer: '${acr.name}.azurecr.io'
    keyVaultName: keyVaultName
    keyVaultSecretName: helixAuthSecretName
    enableKeyVaultSecret: true
    enableAzureFile: false
    healthPath: '/healthz'
  }
}

module pureotaAuth './Modules/containerAppAuth.bicep' = {
  name: 'pureotaAuth'
  dependsOn: [pureotaApp]
  params: {
    containerAppName: pureotaAppName
    clientId: pureotaEntraClientId
    tenantId: tenantId
    allowedGroupId: pureotaEntraGroupObjectId
    settingName: pureotaAuthSecretName
  }
}

module helixAuth './Modules/containerAppAuth.bicep' = {
  name: 'helixAuth'
  dependsOn: [helixApp]
  params: {
    containerAppName: helixAppName
    clientId: helixbridgeEntraClientId
    tenantId: tenantId
    allowedGroupId: helixbridgeEntraGroupObjectId
    settingName: helixAuthSecretName
  }
}

module pureotaJob './Modules/containerAppJob.bicep' = {
  name: 'pureotaJob'
  dependsOn: [containerStorage]
  params: {
    name: pureotaJobName
    location: location
    environmentId: acaEnvironment.id
    image: 'nginx:alpine'
    identityId: pureotaIdentity.id
    githubActionsPrincipalId: githubIdentity.properties.principalId
    acrLoginServer: '${acr.name}.azurecr.io'
    storageName: storageBindingName
    command: 'echo "PureOTA dummy ACA Job executed" > /mnt/tier-data/job-validation.txt && date -u >> /mnt/tier-data/job-validation.txt && cat /mnt/tier-data/job-validation.txt'
  }
}

module postgresAdmin './Modules/postgresqlAdmin.bicep' = {
  name: 'postgresAdmin'
  params: {
    serverName: postgresqlServerName
    principalObjectId: postgresqlEntraAdministratorObjectId
    principalName: postgresqlEntraAdministratorName
    principalType: 'Group'
  }
}

module monitoring './Modules/monitoring.bicep' = {
  name: 'monitoring'
  dependsOn: [pureotaApp, helixApp, postgres, storage]
  params: {
    location: location
    actionGroupName: 'NANDA-ag-aca-platform'
    notificationEmail: notificationEmail
    logAnalyticsWorkspaceId: law.id
    pureotaAppId: pureotaApp.outputs.id!
    helixBridgeAppId: helixApp.outputs.id!
    postgresqlId: postgres.id
    storageFileServiceId: '${storage.id}/fileServices/default'
    postgresqlConnectionThreshold: 80
    storageThreshold: 80
    fileShareBandwidthThreshold: 80
  }
}

output pureotaAppName string = pureotaAppName
output helixBridgeAppName string = helixAppName
output postgresqlFqdn string = postgres.properties.fullyQualifiedDomainName
