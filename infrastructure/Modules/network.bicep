param vnetName string
param location string
param addressPrefix string
param acaSubnetName string
param acaSubnetAddressPrefix string
param privateEndpointSubnetName string
param privateEndpointSubnetAddressPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: acaSubnetName
        properties: {
          addressPrefixes: [acaSubnetAddressPrefix]
          delegations: [
            {
              name: 'acaDelegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefixes: [privateEndpointSubnetAddressPrefix]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output acaSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, acaSubnetName)
output privateEndpointSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
