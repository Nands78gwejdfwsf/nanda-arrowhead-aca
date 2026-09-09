param serverName string
param principalObjectId string
param principalName string
param principalType string = 'Group'

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = { name: serverName }
resource admin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = {
  parent: server
  name: principalObjectId
  properties: {
    principalName: principalName
    principalType: principalType
    tenantId: subscription().tenantId
  }
}
