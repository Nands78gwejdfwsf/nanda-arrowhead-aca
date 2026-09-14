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
@description('Monitoring notification email.')
param notificationEmail string
@description('Monthly resource group budget amount in subscription currency.')
param monthlyBudgetAmount int = 100
@description('First day of the current budget month in ISO-8601 UTC format.')
param budgetStartDate string = '2026-09-01T00:00:00Z'
@description('Enable Key Vault private endpoint.')
param enableKeyVaultPrivateEndpoint bool = false
param vnetName string
param acaSubnetName string
param privateEndpointSubnetName string
param logAnalyticsWorkspaceName string
param acrName string
param keyVaultName string
param postgresqlServerName string
@description('Shared platform Storage Account name. Application file shares are created during application onboarding.')
param storageAccountName string = 'nandastarrowheadacatest'
param containerAppsEnvironmentName string
param githubIdentityName string
param storageIdentityName string = 'NANDA-id-aca-storage'
param budgetName string
param acrPrivateEndpointName string
param keyVaultPrivateEndpointName string
param postgresPrivateEndpointName string

@description('Recovery Services vault for Azure Files backup.')
param recoveryServicesVaultName string = 'NANDA-rsv-arrowhead-aca-files12'

@description('Azure Files daily backup policy name.')
param azureFilesBackupPolicyName string = 'NANDA-afs-daily-30d'

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

module githubIdentity './Modules/githubActionsIdentity.bicep' = {
  name: 'githubIdentity'
  scope: rg
  params: {
    identityName: githubIdentityName
    location: location
    githubRepositorySubjectPrefix: githubRepositorySubjectPrefix
  }
}

module storageIdentity './Modules/managedIdentity.bicep' = {
  name: 'storageIdentity'
  scope: rg
  params: {
    identityName: storageIdentityName
    location: location
  }
}

module acr './Modules/acr.bicep' = {
  name: 'acr'
  scope: rg
  params: {
    registryName: acrName
    location: location
    retentionDays: 30
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
    privateEndpointName: acrPrivateEndpointName
    zoneGroupName: 'acr-dns-zone-group'
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
    privateEndpointName: keyVaultPrivateEndpointName
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
    privateEndpointName: postgresPrivateEndpointName
    zoneGroupName: 'postgresql-dns-zone-group'
  }
}

// Shared platform storage account.
// No application file share is created here; application onboarding creates
// the required file share, private endpoint and application-specific binding.
// Shared platform storage account.
// No application file share is created here; application onboarding creates
// the required file share, private endpoint and application-specific binding.
module platformStorage './Modules/storageAccount.bicep' = {
  name: 'platformStorage'
  scope: rg
  params: {
    storageAccountName: storageAccountName
    location: location
  }
}
module azureFilesBackup './Modules/azureFilesBackup.bicep' = {
  name: 'azureFilesBackup'
  scope: rg
  params: {
    location: location
    vaultName: recoveryServicesVaultName
    policyName: azureFilesBackupPolicyName
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

output resourceGroup string = rg.name
output acrLoginServer string = acr.outputs.loginServer
output keyVaultUri string = keyVault.outputs.uri
output acaEnvironmentId string = acaEnvironment.outputs.id
output githubActionsClientId string = githubIdentity.outputs.clientId
output githubActionsPrincipalId string = githubIdentity.outputs.principalId
output postgresqlFqdn string = postgres.outputs.fqdn
output storageAccountName string = platformStorage.outputs.storageAccountName
output storageAccountId string = platformStorage.outputs.storageAccountId
output recoveryServicesVaultId string = azureFilesBackup.outputs.vaultId
output azureFilesBackupPolicyId string = azureFilesBackup.outputs.policyId
