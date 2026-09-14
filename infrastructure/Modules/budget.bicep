param amount int = 100
param notificationEmail string
param budgetName string
param startDate string

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: budgetName
  scope: resourceGroup()
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      Actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [notificationEmail]
      }
      Actual100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [notificationEmail]
      }
    }
  }
}
