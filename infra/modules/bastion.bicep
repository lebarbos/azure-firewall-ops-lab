@description('Azure region for Bastion resources.')
param location string

@description('Tags applied to all lab resources.')
param tags object

var contract = loadJsonContent('../../lab.contract.json')

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: contract.names.vnetNs
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: contract.names.pipBastion
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: contract.names.bastion
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

@description('Resource ID of Azure Bastion.')
output bastionId string = bastion.id
