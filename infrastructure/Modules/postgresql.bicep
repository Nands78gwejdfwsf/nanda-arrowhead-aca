param serverName string
param location string
param administratorLogin string
@secure()
param administratorLoginPassword string
param storageSizeGB int = 32
param backupRetentionDays int = 7

// The PostgreSQL Flexible Server was successfully created during the foundation deployment.
// Keep this module as an existing-resource reference so subsequent deployments are idempotent
// and do not resend the server create/update request that returned the Azure control-plane
// InternalServerError even though the server became Ready.
resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' existing = {
  name: serverName
}

output id string = server.id
output fqdn string = server.properties.fullyQualifiedDomainName
