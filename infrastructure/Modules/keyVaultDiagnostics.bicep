param keyVaultName string
param workspaceId string

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = { name: keyVaultName }

resource diagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'audit-to-loganalytics'
  scope: vault
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'AuditEvent'
enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics'
enabled: true }
    ]
  }
}
