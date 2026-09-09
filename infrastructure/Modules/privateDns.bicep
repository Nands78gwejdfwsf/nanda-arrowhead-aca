param zoneName string
param linkName string
param vnetId string
param privateEndpointName string
param zoneGroupName string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: linkName
  parent: zone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2024-07-01' existing = {
  name: privateEndpointName
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  name: zoneGroupName
  parent: pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: { privateDnsZoneId: zone.id }
      }
    ]
  }
}
