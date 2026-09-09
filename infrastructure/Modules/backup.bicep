param vaultName string
param location string
param policyName string
param retentionDays int = 30

resource vault 'Microsoft.RecoveryServices/vaults@2022-10-01' = {
  name: vaultName
  location: location
  sku: { name: 'Standard' }
  properties: { publicNetworkAccess: 'Enabled' }
}

resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-02-01' = {
  name: policyName
  parent: vault
  properties: {
    backupManagementType: 'AzureStorage'
    retentionPolicy: {
      dailySchedule: {
        retentionDuration: { count: retentionDays
durationType: 'Days' }
        retentionTimes: ['2026-01-01T23:00:00Z']
      }
      retentionPolicyType: 'LongTermRetentionPolicy'
    }
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: ['2026-01-01T23:00:00Z']
    }
    timeZone: 'UTC'
    workLoadType: 'AzureFileShare'
  }
}

output vaultId string = vault.id
output policyName string = policy.name
