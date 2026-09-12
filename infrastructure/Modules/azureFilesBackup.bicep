@description('Azure region for the Recovery Services vault. Must match the storage account region.')
param location string

@description('Recovery Services vault name used for Azure Files backup.')
param vaultName string

@description('Backup policy name for the protected Azure File share.')
param policyName string

@description('Resource group containing the storage account and file share.')
param storageResourceGroupName string

@description('Storage account name containing the Azure File share.')
param storageAccountName string

@description('Azure File share name to protect.')
param fileShareName string

@description('Daily backup time in UTC.')
param scheduleRunTimeUtc string = '2026-01-01T02:00:00Z'

@description('Number of days to retain daily Azure Files recovery points.')
param retentionDays int = 30

var backupFabric = 'Azure'
var backupManagementType = 'AzureStorage'
var protectionContainerName = 'storagecontainer;Storage;${storageResourceGroupName};${storageAccountName}'
var protectedItemName = 'AzureFileShare;${fileShareName}'
var storageAccountId = resourceId(
  storageResourceGroupName,
  'Microsoft.Storage/storageAccounts',
  storageAccountName
)

resource vault 'Microsoft.RecoveryServices/vaults@2022-10-01' = {
  name: vaultName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-02-01' = {
  name: policyName
  parent: vault
  properties: {
    backupManagementType: backupManagementType
    workLoadType: 'AzureFileShare'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        scheduleRunTimeUtc
      ]
    }
    timeZone: 'UTC'
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionDuration: {
          count: retentionDays
          durationType: 'Days'
        }
        retentionTimes: [
          scheduleRunTimeUtc
        ]
      }
    }
  }
}

resource protectionContainer 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers@2021-12-01' = {
  name: '${vaultName}/${backupFabric}/${protectionContainerName}'
  dependsOn: [
    vault
    backupPolicy
  ]
  properties: {
    backupManagementType: backupManagementType
    containerType: 'StorageContainer'
    sourceResourceId: storageAccountId
  }
}

resource protectedItem 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2021-12-01' = {
  name: '${vaultName}/${backupFabric}/${protectionContainerName}/${protectedItemName}'
  dependsOn: [
    vault
    backupPolicy
    protectionContainer
  ]
  properties: {
    protectedItemType: 'AzureFileShareProtectedItem'
    sourceResourceId: storageAccountId
    policyId: backupPolicy.id
    isInlineInquiry: true
  }
}

output recoveryServicesVaultId string = vault.id
output backupPolicyId string = backupPolicy.id
output protectedItemId string = protectedItem.id
