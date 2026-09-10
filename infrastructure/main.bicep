targetScope = 'subscription'

@description('Azure region')
param location string = 'westus'
@description('Resource group')
param resourceGroupName string = 'NANDA-rg-arrowhead-aca-test1'
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

var vnetName = 'NANDA-vnet-arrowhead-aca-test'
var acaSubnetName = 'NANDA-snet-aca'
var privateEndpointSubnetName = 'NANDA-snet-private-endpoint'
var logAnalyticsWorkspaceName = 'NANDA-law-arrowhead-aca-test'
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
    name: 'NANDA-pe-acr-arrowhead-aca'
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
    name: 'NANDA-pe-keyvault-aca'
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
    name: 'NANDA-pe-postgresql-aca'
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
    name: 'NANDA-pe-pureota-storage'
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
  }
}


module budget './Modules/budget.bicep' = {
  name: 'budget'
  scope: rg
  params: {
    amount: monthlyBudgetAmount
    notificationEmail: notificationEmail
    budgetName: 'NANDA-budget-arrowhead-aca-test'
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
output postgresqlFqdn string = postgres.outputs.fqdn
