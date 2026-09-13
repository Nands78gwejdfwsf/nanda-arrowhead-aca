@description('Azure region.')
param location string

@description('Platform alert action group name.')
param actionGroupName string

@description('Notification email address.')
param notificationEmail string

@description('Log Analytics workspace resource ID.')
param logAnalyticsWorkspaceId string

@description('Foundation resource IDs to watch for Resource Health changes.')
param resourceIds array

@description('Shared Storage Account resource ID.')
param storageAccountId string

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

resource resourceHealth 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'platform-resource-health'
  location: 'Global'
  properties: {
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          field: 'resourceId'
          containsAny: resourceIds
        }
        {
          field: 'properties.currentHealthStatus'
          containsAny: [
            'Unavailable'
            'Degraded'
          ]
        }
        {
          field: 'status'
          equals: 'Active'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Alerts when a foundation resource enters an active Resource Health event.'
  }
}

resource platformOperationFailure 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'platform-operation-failure'
  location: 'Global'
  properties: {
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'resourceId'
          containsAny: resourceIds
        }
        {
          field: 'status'
          equals: 'Failed'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    description: 'Alerts when a control-plane operation against a foundation resource fails.'
  }
}

resource storageAvailability 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'storage-availability'
  location: 'global'
  properties: {
    description: 'Shared Storage Account availability dropped below 99 percent.'
    severity: 2
    enabled: true
    scopes: [
      storageAccountId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Availability'
          metricName: 'Availability'
          metricNamespace: 'Microsoft.Storage/storageAccounts'
          operator: 'LessThan'
          threshold: 99
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

resource keyVaultDenied 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'platform-keyvault-access-denied'
  location: location
  properties: {
    displayName: 'Platform Key Vault access denied'
    description: 'Detects denied Key Vault operations in audit logs.'
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
          query: 'AzureDiagnostics | where ResourceProvider == "MICROSOFT.KEYVAULT" | where ResultType == "Forbidden" or ResultSignature == "Forbidden" | summarize Count=count()'
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
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}
