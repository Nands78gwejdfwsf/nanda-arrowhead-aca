targetScope = 'resourceGroup'

@description('Azure region')
param location string = 'westus'
@description('Enabled application configurations from apps/apps.json.')
param enabledApplications array
@description('Applications with Azure Files enabled.')
param storageApplications array
@description('Applications with ACA Jobs enabled.')
param jobApplications array
@description('Applications with Easy Auth enabled.')
param authApplications array
@description('Runtime Entra metadata keyed by application key. Each entry contains groupId and clientId.')
param entraMetadata object
@description('PostgreSQL Entra administrator group object ID')
param postgresqlEntraAdministratorObjectId string
@description('PostgreSQL Entra administrator group display name')
param postgresqlEntraAdministratorName string
@description('Microsoft Entra tenant ID')
param tenantId string
@description('Monitoring notification email')
param notificationEmail string

param acrName string
param keyVaultName string
param postgresqlServerName string
param containerAppsEnvironmentName string
param storageIdentityName string
param githubIdentityName string
param logAnalyticsWorkspaceName string
param monitoringActionGroupName string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: acrName }
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = { name: postgresqlServerName }
resource acaEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' existing = { name: containerAppsEnvironmentName }
resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = { name: storageIdentityName }
resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = { name: githubIdentityName }
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = { name: logAnalyticsWorkspaceName }

resource appIdentityRefs 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = [for app in enabledApplications: {
  name: app.value.identity.name
}]

resource storageRefs 'Microsoft.Storage/storageAccounts@2023-05-01' existing = [for app in storageApplications: {
  name: app.value.storage.accountName
}]

resource authIdentityRefs 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = [for app in authApplications: {
  name: app.value.identity.name
}]

resource jobIdentityRefs 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = [for app in jobApplications: {
  name: app.value.identity.name
}]

module containerStorage './Modules/containerAppsStorage.bicep' = [for app in storageApplications: {
  name: 'containerStorage-${app.key}'
  params: {
    environmentName: containerAppsEnvironmentName
    storageName: app.value.storage.bindingName
    storageAccountName: app.value.storage.accountName
    fileShareName: app.value.storage.fileShareName
    keyVaultName: keyVaultName
    storageIdentityId: storageIdentity.id
    secretName: app.value.keyVault.storageKeySecretName
  }
}]

module containerApps './Modules/containerApp.bicep' = [for (app, i) in enabledApplications: {
  name: 'containerApp-${app.key}'
  dependsOn: [containerStorage]
  params: {
    name: app.value.containerAppName
    location: location
    environmentId: acaEnvironment.id
    image: 'nginx:alpine'
    containerPort: int(app.value.targetPort)
    minReplicas: int(app.value.minReplicas)
    maxReplicas: int(app.value.maxReplicas)
    identityId: appIdentityRefs[i].id
    githubActionsPrincipalId: githubIdentity.properties.principalId
    acrLoginServer: acr.properties.loginServer
    keyVaultName: keyVaultName
    keyVaultSecretName: app.value.keyVault.authSecretName
    enableKeyVaultSecret: bool(app.value.keyVault.readAuthSecret)
    enableAzureFile: bool(app.value.storage.enabled)
    azureFileStorageName: app.value.storage.bindingName
    azureFileMountPath: app.value.storage.mountPath
    healthPath: app.value.healthPath
    ingressExternal: bool(app.value.ingress.external)
    ingressTransport: toUpper(app.value.ingress.transport) == 'AUTO' ? 'Auto' : app.value.ingress.transport
    postgresHost: app.value.postgres.enabled ? postgres.properties.fullyQualifiedDomainName : ''
    postgresDatabase: app.value.postgres.enabled ? app.value.postgres.databaseName : ''
    postgresUser: app.value.postgres.enabled ? app.value.identity.name : ''
    postgresClientId: app.value.postgres.enabled ? appIdentityRefs[i].properties.clientId : ''
  }
}]

module authConfigs './Modules/containerAppAuth.bicep' = [for (app, i) in authApplications: {
  name: 'auth-${app.key}'
  dependsOn: [containerApps]
  params: {
    containerAppName: app.value.containerAppName
    clientId: entraMetadata[app.key].clientId
    tenantId: tenantId
    allowedGroupId: entraMetadata[app.key].groupId
    settingName: app.value.keyVault.authSecretName
    enabled: true
  }
}]

module containerJobs './Modules/containerAppJob.bicep' = [for (app, i) in jobApplications: {
  name: 'job-${app.key}'
  dependsOn: [containerStorage]
  params: {
    name: app.value.job.jobName
    location: location
    environmentId: acaEnvironment.id
    image: 'nginx:alpine'
    identityId: jobIdentityRefs[i].id
    githubActionsPrincipalId: githubIdentity.properties.principalId
    acrLoginServer: acr.properties.loginServer
    storageName: app.value.storage.bindingName
    enableAzureFile: bool(app.value.storage.enabled)
    command: app.value.job.command
    postgresHost: app.value.postgres.enabled ? postgres.properties.fullyQualifiedDomainName : ''
    postgresDatabase: app.value.postgres.enabled ? app.value.postgres.databaseName : ''
    postgresUser: app.value.postgres.enabled ? app.value.identity.name : ''
    postgresClientId: app.value.postgres.enabled ? jobIdentityRefs[i].properties.clientId : ''
  }
}]

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
  dependsOn: [
    containerApps
    containerJobs
    authConfigs
  ]
  params: {
    location: location
    actionGroupName: monitoringActionGroupName
    notificationEmail: notificationEmail
    logAnalyticsWorkspaceId: law.id
    applicationIds: [for app in enabledApplications: resourceId('Microsoft.App/containerApps', app.value.containerAppName)]
    applicationNames: [for app in enabledApplications: app.value.containerAppName]
    storageFileServiceIds: [for app in storageApplications: resourceId('Microsoft.Storage/storageAccounts/fileServices', app.value.storage.accountName, 'default')]
    postgresqlId: postgres.id
    postgresqlConnectionThreshold: 80
    storageThreshold: 80
    fileShareBandwidthThreshold: 80
  }
}

output applicationNames array = [for app in enabledApplications: app.value.containerAppName]
output postgresqlFqdn string = postgres.properties.fullyQualifiedDomainName
