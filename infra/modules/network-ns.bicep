@description('Azure region for the north-south virtual network.')
param location string

@description('Tags applied to all lab resources.')
param tags object

var contract = loadJsonContent('../../lab.contract.json')

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: contract.names.vnetNs
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        contract.network.vnetNs
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: contract.network.snetFw
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: contract.network.snetBastion
        }
      }
    ]
  }
}

@description('Resource ID of the north-south virtual network.')
output vnetId string = vnet.id
