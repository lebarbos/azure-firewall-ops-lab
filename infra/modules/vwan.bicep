@description('Azure region for vWAN resources.')
param location string

@description('Tags applied to all lab resources.')
param tags object

var contract = loadJsonContent('../../lab.contract.json')

resource virtualWan 'Microsoft.Network/virtualWans@2024-07-01' = {
  name: contract.names.vwan
  location: location
  tags: tags
  properties: {
    type: 'Standard'
  }
}

resource virtualHub 'Microsoft.Network/virtualHubs@2024-07-01' = {
  name: contract.names.vhub
  location: location
  tags: tags
  // O hub e seus filhos sao serializados para reduzir AnotherOperationInProgress.
  dependsOn: [
    virtualWan
  ]
  properties: {
    addressPrefix: contract.network.vhub
    sku: 'Standard'
    virtualWan: {
      id: virtualWan.id
    }
  }
}

resource policy 'Microsoft.Network/firewallPolicies@2024-07-01' = {
  name: contract.names.polEw
  location: location
  tags: tags
  dependsOn: [
    virtualHub
  ]
  properties: {
    sku: {
      tier: 'Premium'
    }
    threatIntelMode: 'Alert'
    // The lab enables IDPS/TLS in Ex6 so students can observe the policy change.
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-07-01' = {
  name: contract.names.fwEw
  location: location
  tags: tags
  dependsOn: [
    policy
  ]
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: 'Premium'
    }
    // AZFW_Hub rejects threatIntelMode on the firewall; the policy carries it.
    firewallPolicy: {
      id: policy.id
    }
    virtualHub: {
      id: virtualHub.id
    }
    hubIPAddresses: {
      publicIPs: {
        count: 1
      }
    }
  }
}

@description('Name of the east-west secured hub firewall.')
output firewallName string = firewall.name

@description('Resource ID of the east-west secured hub firewall (Routing Intent next hop).')
output firewallId string = firewall.id

@description('Private IP address of the east-west secured hub firewall.')
output firewallPrivateIp string = firewall.properties.hubIPAddresses.privateIPAddress

@description('Resource ID of the east-west firewall policy.')
output policyId string = policy.id

@description('Resource ID of the virtual hub.')
output virtualHubId string = virtualHub.id
