@description('Azure region. The vault must be in the same region as the Storage Account it protects.')
param location string

@description('Recovery Services vault used for Azure Files backup.')
param vaultName string

@description('Daily Azure Files backup policy name.')
param policyName string

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
    backupManagementType: 'AzureStorage'
    workLoadType: 'AzureFileShare'
    timeZone: 'UTC'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2026-01-01T02:00:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2026-01-01T02:00:00Z'
        ]
        retentionDuration: {
          count: 30
          durationType: 'Days'
        }
      }
    }
  }
}

output vaultId string = vault.id
output policyId string = backupPolicy.id
