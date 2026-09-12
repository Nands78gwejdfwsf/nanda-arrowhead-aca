targetScope = 'subscription'

@description('Azure region')
param location string = 'westus'
@description('Resource group')
param resourceGroupName string
@description('GitHub OIDC subject prefix in OWNER@OWNER-ID/REPOSITORY@REPOSITORY-ID format')
param githubRepositorySubjectPrefix string
@secure()
@description('Temporary PostgreSQL administrator password. Used only to bootstrap the server.')
param postgresqlAdministratorLoginPassword string
@description('Monitoring notification email. Required when runtime resources are deployed.')
param notificationEmail string
@description('Monthly resource group budget amount in subscription currency.')
param monthlyBudgetAmount int = 100
@description('First day of the current budget month in ISO-8601 UTC format.')
param budgetStartDate string = '2026-09-01T00:00:00Z'
@description('Enable Key Vault private endpoint. Keep false until Arrowhead network/DNS integration is approved.')
param enableKeyVaultPrivateEndpoint bool = false

@description('Recovery Services vault name for Azure Files backup.')
param azureFilesBackupVaultName string

@description('Azure Files backup policy name.')
param azureFilesBackupPolicyName string

@description('Daily Azure Files backup time in UTC.')
param azureFilesBackupScheduleRunTimeUtc string = '2026-01-01T02:00:00Z'

@description('Azure Files backup retention in days.')
param azureFilesBackupRetentionDays int = 30

@description('Virtual network name.')
param vnetName string
@description('ACA infrastructure subnet name.')
param acaSubnetName string
@description('Private endpoint subnet name.')
param privateEndpointSubnetName string
@description('Log Analytics workspace name.')
param logAnalyticsWorkspaceName string
@description('Azure Container Registry name.')
param acrName string
@description('Key Vault name.')
param keyVaultName string
@description('PostgreSQL Flexible Server name.')
param postgresqlServerName string
@description('Azure Container Apps environment name.')
param containerAppsEnvironmentName string
@description('Azure Storage account name for PureOTA files.')
param pureotaStorageAccountName string
@description('Azure Files share name.')
param pureotaFileShareName string
@description('PureOTA managed identity name.')
param pureotaIdentityName string
@description('HelixBridge managed identity name.')
param helixIdentityName string
@description('Storage managed identity name.')
param storageIdentityName string
@description('GitHub Actions managed identity name.')
param githubIdentityName string
@description('PureOTA Container App name.')
param pureotaAppName string
@description('HelixBridge Container App name.')
param helixAppName string
@description('PureOTA Container Apps Job name.')
param pureotaJobName string
@description('Container Apps Azure Files storage binding name.')
param storageBindingName string
@description('Key Vault secret name for Azure Files storage key.')
param pureotaStorageKeySecretName string
@description('Key Vault secret name for PureOTA Entra client secret.')
param pureotaAuthSecretName string
@description('Key Vault secret name for HelixBridge Entra client secret.')
param helixAuthSecretName string
@description('Resource group budget name.')
param budgetName string
@description('ACR private endpoint name.')
param acrPrivateEndpointName string
@description('Key Vault private endpoint name.')
param keyVaultPrivateEndpointName string
@description('PostgreSQL private endpoint name.')
param postgresPrivateEndpointName string
@description('Azure Files storage private endpoint name.')
param storagePrivateEndpointName string

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
}

module network './Modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    vnetName: vnetName
    location: location
    addressPrefix: '10.50.0.0/16'
    acaSubnetName: acaSubnetName
    acaSubnetAddressPrefix: '10.50.0.0/23'
    privateEndpointSubnetName: privateEndpointSubnetName
    privateEndpointSubnetAddressPrefix: '10.50.2.0/24'
  }
}

module law './Modules/logAnalytics.bicep' = {
  name: 'logAnalytics'
  scope: rg
  params: {
    workspaceName: logAnalyticsWorkspaceName
    location: location
    retentionInDays: 30
  }
}

module acr './Modules/acr.bicep' = {
  name: 'acr'
  scope: rg
  params: {
    registryName: acrName
    location: location
    retentionDays: 30
    pureotaPrincipalId: pureotaIdentity.outputs.principalId
    helixPrincipalId: helixIdentity.outputs.principalId
    githubPrincipalId: githubIdentity.outputs.principalId
  }
}

module defender './Modules/defenderContainers.bicep' = {
  name: 'defenderContainers'
  params: { enabled: true }
}

module acrPe './Modules/privateEndpoint.bicep' = {
  name: 'acrPrivateEndpoint'
  scope: rg
  params: {
    name: acrPrivateEndpointName
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    targetResourceId: acr.outputs.id
    groupIds: ['registry']
    connectionName: 'acr'
  }
}

module acrDns './Modules/privateDns.bicep' = {
  name: 'acrPrivateDns'
  scope: rg
  dependsOn: [acrPe]
  params: {
    zoneName: 'privatelink.azurecr.io'
    linkName: 'NANDA-link-acr-private-dns'
    vnetId: network.outputs.vnetId
    privateEndpointName: 'NANDA-pe-acr-arrowhead-aca'
    zoneGroupName: 'acr-dns-zone-group'
  }
}

module pureotaIdentity './Modules/managedIdentity.bicep' = {
  name: 'pureotaIdentity'
  scope: rg
  params: { name: pureotaIdentityName
location: location }
}
module helixIdentity './Modules/managedIdentity.bicep' = {
  name: 'helixIdentity'
  scope: rg
  params: { name: helixIdentityName
location: location }
}
module storageIdentity './Modules/managedIdentity.bicep' = {
  name: 'storageIdentity'
  scope: rg
  params: { name: storageIdentityName
location: location }
}
module githubIdentity './Modules/githubActionsIdentity.bicep' = {
  name: 'githubIdentity'
  scope: rg
  params: {
    identityName: githubIdentityName
    location: location
    githubRepositorySubjectPrefix: githubRepositorySubjectPrefix
  }
}

module keyVault './Modules/keyVault.bicep' = {
  name: 'keyVault'
  scope: rg
  params: {
    name: keyVaultName
    location: location
    publicNetworkAccess: enableKeyVaultPrivateEndpoint ? 'Disabled' : 'Enabled'
  }
}
module keyVaultDiagnostics './Modules/keyVaultDiagnostics.bicep' = {
  name: 'keyVaultDiagnostics'
  scope: rg
  params: {
    keyVaultName: keyVaultName
    workspaceId: law.outputs.id
  }
}
module keyVaultPe './Modules/privateEndpoint.bicep' = if (enableKeyVaultPrivateEndpoint) {
  name: 'keyVaultPrivateEndpoint'
  scope: rg
  params: {
    name: keyVaultPrivateEndpointName
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    targetResourceId: keyVault.outputs.id
    groupIds: ['vault']
    connectionName: 'keyvault'
  }
}
module keyVaultDns './Modules/privateDns.bicep' = if (enableKeyVaultPrivateEndpoint) {
  name: 'keyVaultPrivateDns'
  scope: rg
  dependsOn: [keyVaultPe]
  params: {
    zoneName: 'privatelink.vaultcore.azure.net'
    linkName: 'NANDA-link-keyvault-private-dns'
    vnetId: network.outputs.vnetId
    privateEndpointName: 'NANDA-pe-keyvault-aca'
    zoneGroupName: 'keyvault-dns-zone-group'
  }
}

module postgres './Modules/postgresql.bicep' = {
  name: 'postgres'
  scope: rg
  params: {
    serverName: postgresqlServerName
    location: location
    administratorLogin: 'nandaadmin'
    administratorLoginPassword: postgresqlAdministratorLoginPassword
    storageSizeGB: 32
    backupRetentionDays: 7
  }
}
module postgresPe './Modules/privateEndpoint.bicep' = {
  name: 'postgresPrivateEndpoint'
  scope: rg
  params: {
    name: postgresPrivateEndpointName
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    targetResourceId: postgres.outputs.id
    groupIds: ['postgresqlServer']
    connectionName: 'postgresql'
  }
}
module postgresDns './Modules/privateDns.bicep' = {
  name: 'postgresPrivateDns'
  scope: rg
  dependsOn: [postgresPe]
  params: {
    zoneName: 'privatelink.postgres.database.azure.com'
    linkName: 'NANDA-link-postgresql-private-dns'
    vnetId: network.outputs.vnetId
    privateEndpointName: 'NANDA-pe-postgresql-aca'
    zoneGroupName: 'postgresql-dns-zone-group'
  }
}
module storage './Modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    storageAccountName: pureotaStorageAccountName
    location: location
    fileShareName: pureotaFileShareName
    fileShareQuotaGB: 100
  }
}
module storagePe './Modules/privateEndpoint.bicep' = {
  name: 'storagePrivateEndpoint'
  scope: rg
  params: {
    name: storagePrivateEndpointName
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    targetResourceId: storage.outputs.id
    groupIds: ['file']
    connectionName: 'storage-file'
  }
}
module storageDns './Modules/privateDns.bicep' = {
  name: 'storagePrivateDns'
  scope: rg
  dependsOn: [storagePe]
  params: {
    zoneName: 'privatelink.file.${az.environment().suffixes.storage}'
    linkName: 'NANDA-link-pureota-storage-private-dns'
    vnetId: network.outputs.vnetId
    privateEndpointName: 'NANDA-pe-pureota-storage'
    zoneGroupName: 'storage-file-dns-zone-group'
  }
}

module azureFilesBackup './Modules/azureFilesBackup.bicep' = {
  name: 'azureFilesBackup'
  scope: rg
  dependsOn: [
    storage
  ]
  params: {
    location: location
    vaultName: azureFilesBackupVaultName
    policyName: azureFilesBackupPolicyName
    storageResourceGroupName: resourceGroupName
    storageAccountName: pureotaStorageAccountName
    fileShareName: pureotaFileShareName
    scheduleRunTimeUtc: azureFilesBackupScheduleRunTimeUtc
    retentionDays: azureFilesBackupRetentionDays
  }
}

module acaEnvironment './Modules/containerAppsEnvironment.bicep' = {
  name: 'containerAppsEnvironment'
  scope: rg
  params: {
    name: containerAppsEnvironmentName
    location: location
    infrastructureSubnetId: network.outputs.acaSubnetId
    workspaceCustomerId: law.outputs.customerId
    workspaceSharedKey: law.outputs.sharedKey
    storageIdentityId: storageIdentity.outputs.id
  }
}

module githubRgReader './Modules/resourceGroupRoleAssignment.bicep' = {
  name: 'githubResourceGroupReader'
  scope: rg
  params: {
    principalId: githubIdentity.outputs.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  }
}

// GitHub Actions needs deterministic resource-group scope permissions for
// revision inspection/deployment and ACA Job execution. Resource-group scoped
// role assignments are deployed through modules because this main file is
// subscription-scoped. The assignments are therefore reproducible on a clean
// rebuild without relying on manual RBAC changes.
module githubRgContainerAppsContributor './Modules/resourceGroupRoleAssignment.bicep' = {
  name: 'githubResourceGroupContainerAppsContributor'
  scope: rg
  params: {
    principalId: githubIdentity.outputs.principalId
    roleDefinitionId: '358470bc-b998-42bd-ab17-a7e34c199c0f'
  }
}

module githubRgContainerAppsJobsContributor './Modules/resourceGroupRoleAssignment.bicep' = {
  name: 'githubResourceGroupContainerAppsJobsContributor'
  scope: rg
  params: {
    principalId: githubIdentity.outputs.principalId
    roleDefinitionId: '4e3d2b60-56ae-4dc6-a233-09c8e5a82e68'
  }
}


module budget './Modules/budget.bicep' = {
  name: 'budget'
  scope: rg
  params: {
    amount: monthlyBudgetAmount
    notificationEmail: notificationEmail
    budgetName: budgetName
    startDate: budgetStartDate
  }
}

// Runtime starts only after deploy.ps1 has populated Key Vault and Entra configuration.

// Runtime resources are deployed separately by runtime.bicep.
// This foundation template creates the platform once and never attempts
// to recreate those resources during the runtime deployment.

output resourceGroup string = rg.name
output acrLoginServer string = acr.outputs.loginServer
output keyVaultUri string = keyVault.outputs.uri
output acaEnvironmentId string = acaEnvironment.outputs.id
output githubActionsClientId string = githubIdentity.outputs.clientId
output githubActionsPrincipalId string = githubIdentity.outputs.principalId
output pureotaStorageAccountName string = pureotaStorageAccountName
output pureotaFileShareName string = pureotaFileShareName
output azureFilesBackupVaultName string = azureFilesBackupVaultName
output azureFilesBackupPolicyName string = azureFilesBackupPolicyName
output postgresqlFqdn string = postgres.outputs.fqdn
