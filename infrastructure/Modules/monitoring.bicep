param location string
param actionGroupName string
param notificationEmail string
param logAnalyticsWorkspaceId string
param pureotaAppId string
param helixBridgeAppId string
param postgresqlId string
param storageFileServiceId string
param postgresqlConnectionThreshold int = 80
param storageThreshold int = 80
param fileShareBandwidthThreshold int = 80

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'ACAAlerts'
    enabled: true
    emailReceivers: [
      {
        name: 'Primary'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource pureotaRestart 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'aca-pureota-restart-loop'
  location: 'global'
  properties: {
    description: 'PureOTA replica restart count exceeded the POC threshold.'
    severity: 2
    enabled: true
    scopes: [pureotaAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'RestartCount'
          metricName: 'RestartCount'
          metricNamespace: 'Microsoft.App/containerapps'
          operator: 'GreaterThan'
          threshold: 3
          timeAggregation: 'Maximum'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource helixRestart 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'aca-helixbridge-restart-loop'
  location: 'global'
  properties: {
    description: 'HelixBridge replica restart count exceeded the POC threshold.'
    severity: 2
    enabled: true
    scopes: [helixBridgeAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'RestartCount'
          metricName: 'RestartCount'
          metricNamespace: 'Microsoft.App/containerapps'
          operator: 'GreaterThan'
          threshold: 3
          timeAggregation: 'Maximum'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource postgresConnections 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'postgresql-connection-saturation'
  location: 'global'
  properties: {
    description: 'PostgreSQL active connections exceeded the configured POC threshold. Tune after workload profiling.'
    severity: 2
    enabled: true
    scopes: [postgresqlId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ActiveConnections'
          metricName: 'active_connections'
          metricNamespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
          operator: 'GreaterThan'
          threshold: postgresqlConnectionThreshold
          timeAggregation: 'Maximum'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource postgresStorage 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'postgresql-storage-threshold'
  location: 'global'
  properties: {
    description: 'PostgreSQL storage utilization exceeded 80 percent.'
    severity: 2
    enabled: true
    scopes: [postgresqlId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'StoragePercent'
          metricName: 'storage_percent'
          metricNamespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
          operator: 'GreaterThan'
          threshold: storageThreshold
          timeAggregation: 'Average'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource fileBandwidth 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'azure-files-bandwidth-saturation'
  location: 'global'
  properties: {
    description: 'Azure Files share bandwidth utilization exceeded 80 percent.'
    severity: 2
    enabled: true
    scopes: [storageFileServiceId]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'PercentFileShareBandwidthUtilization'
          metricName: 'PercentFileShareBandwidthUtilization'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          operator: 'GreaterThan'
          threshold: fileShareBandwidthThreshold
          timeAggregation: 'Average'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource fileCapacity 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'azure-files-capacity-threshold'
  location: 'global'
  properties: {
    description: 'Azure Files share capacity utilization exceeded 80 percent.'
    severity: 2
    enabled: true
    scopes: [storageFileServiceId]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'PercentFileShareUtilization'
          metricName: 'PercentFileShareUtilization'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          operator: 'GreaterThan'
          threshold: storageThreshold
          timeAggregation: 'Average'
          dimensions: []
          skipMetricValidation: false
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource revisionFailure 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'aca-revision-provisioning-failure'
  location: location
  properties: {
    displayName: 'ACA revision provisioning failure'
    description: 'Detects Container Apps revision provisioning errors.'
    severity: 2
    enabled: true
    scopes: [logAnalyticsWorkspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: 'ContainerAppSystemLogs_CL | where Log_s has "Error provisioning revision" | where ContainerAppName_s in ("nanda-ca-pureota", "nanda-ca-helixbridge") | summarize Count=count()'
          timeAggregation: 'Count'
          dimensions: []
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1
minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup.id] }
  }
}

resource healthFailure 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'aca-health-probe-failure'
  location: location
  properties: {
    displayName: 'ACA health or readiness probe failure'
    description: 'Detects Container Apps system log messages indicating health or readiness probe failure.'
    severity: 2
    enabled: true
    scopes: [logAnalyticsWorkspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: 'ContainerAppSystemLogs_CL | where ContainerAppName_s in ("nanda-ca-pureota", "nanda-ca-helixbridge") | where Log_s has_any ("health probe", "readiness probe", "liveness probe") and Log_s has_any ("failed", "failure", "unhealthy") | summarize Count=count()'
          timeAggregation: 'Count'
          dimensions: []
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1
minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup.id] }
  }
}

resource keyVaultDenied 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'keyvault-secret-access-denied'
  location: location
  properties: {
    displayName: 'Key Vault access denied'
    description: 'Detects denied Key Vault operations in audit logs.'
    severity: 2
    enabled: true
    scopes: [logAnalyticsWorkspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: 'AzureDiagnostics | where ResourceProvider == "MICROSOFT.KEYVAULT" | where ResultType == "Forbidden" or ResultSignature == "Forbidden" | summarize Count=count()'
          timeAggregation: 'Count'
          dimensions: []
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1
minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup.id] }
  }
}
