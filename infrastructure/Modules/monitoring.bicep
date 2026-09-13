@description('Azure region.')
param location string

@description('Platform/application alert action group name.')
param actionGroupName string

@description('Notification email address.')
param notificationEmail string

@description('Log Analytics workspace resource ID.')
param logAnalyticsWorkspaceId string

@description('Application resource IDs.')
param applicationIds array

@description('Application names used by Log Analytics queries.')
param applicationNames array

@description('Azure Files file service resource IDs.')
param storageFileServiceIds array

@description('PostgreSQL Flexible Server resource ID.')
param postgresqlId string

@description('PostgreSQL active connection threshold.')
param postgresqlConnectionThreshold int = 80

@description('Storage utilization threshold.')
param storageThreshold int = 80

@description('Azure Files bandwidth threshold.')
param fileShareBandwidthThreshold int = 80

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'ACAPlatform'
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

resource appRestart 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (appId, i) in applicationIds: {
  name: 'aca-${uniqueString(appId)}-restart-loop'
  location: 'global'
  properties: {
    description: 'Container App replica restart count exceeded the POC threshold.'
    severity: 2
    enabled: true
    scopes: [
      appId
    ]
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
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}]

resource postgresConnections 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'postgresql-connection-saturation'
  location: 'global'
  properties: {
    description: 'PostgreSQL active connections exceeded the configured POC threshold.'
    severity: 2
    enabled: true
    scopes: [
      postgresqlId
    ]
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
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource postgresStorage 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'postgresql-storage-threshold'
  location: 'global'
  properties: {
    description: 'PostgreSQL storage utilization exceeded the configured threshold.'
    severity: 2
    enabled: true
    scopes: [
      postgresqlId
    ]
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
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource fileBandwidth 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (storageId, i) in storageFileServiceIds: {
  name: 'azure-files-${uniqueString(storageId)}-bandwidth'
  location: 'global'
  properties: {
    description: 'Azure Files bandwidth utilization exceeded the configured threshold.'
    severity: 2
    enabled: true
    scopes: [
      storageId
    ]
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
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}]

resource fileCapacity 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (storageId, i) in storageFileServiceIds: {
  name: 'azure-files-${uniqueString(storageId)}-capacity'
  location: 'global'
  properties: {
    description: 'Azure Files capacity utilization exceeded the configured threshold.'
    severity: 2
    enabled: true
    scopes: [
      storageId
    ]
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
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}]

resource revisionFailure 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'aca-revision-provisioning-failure'
  location: location
  properties: {
    displayName: 'ACA revision provisioning failure'
    description: 'Detects Container Apps revision provisioning errors for configured applications.'
    severity: 2
    enabled: true
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: 'ContainerAppSystemLogs_CL | where Log_s has "Error provisioning revision" | where ContainerAppName_s in ("${join(applicationNames, '","')}") | summarize Count=count()'
          timeAggregation: 'Count'
          dimensions: []
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
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
    scopes: [
      logAnalyticsWorkspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: 'ContainerAppSystemLogs_CL | where ContainerAppName_s in ("${join(applicationNames, '","')}") | where Log_s has_any ("health probe", "readiness probe", "liveness probe") and Log_s has_any ("failed", "failure", "unhealthy") | summarize Count=count()'
          timeAggregation: 'Count'
          dimensions: []
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}
