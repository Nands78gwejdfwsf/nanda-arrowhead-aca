param name string
param location string
param subnetId string
param targetResourceId string
param groupIds array
param connectionName string

resource pe 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: connectionName
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: groupIds
        }
      }
    ]
  }
}

output id string = pe.id
