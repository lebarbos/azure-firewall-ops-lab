@description('Azure region for north-south firewall resources.')
param location string

@description('Tags applied to all lab resources.')
param tags object

var contract = loadJsonContent('../../lab.contract.json')

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: contract.names.vnetNs
}

resource firewallSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: vnet
  name: 'AzureFirewallSubnet'
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: contract.names.pipFw
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

resource policy 'Microsoft.Network/firewallPolicies@2024-07-01' = {
  name: contract.names.polNs
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Premium'
    }
    threatIntelMode: 'Alert'
    // The lab enables IDPS/TLS in Ex6 so students can observe the policy change.
  }
}

resource infrastructureRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-07-01' = {
  parent: policy
  name: contract.rcg.infrastructure.name
  properties: {
    priority: contract.rcg.infrastructure.priority
    ruleCollections: [
      {
        name: contract.rc.infra.name
        priority: contract.rc.infra.priority
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: contract.rc.infra.action
        }
        rules: [
          {
            name: contract.rules.infraBlob
            ruleType: 'ApplicationRule'
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            sourceAddresses: contract.ipGroupCidrs.ipgSpokes
            targetFqdns: contract.infraFqdns
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-07-01' = {
  name: contract.names.fwNs
  location: location
  tags: tags
  dependsOn: [
    infrastructureRules
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Premium'
    }
    threatIntelMode: 'Alert'
    firewallPolicy: {
      id: policy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: firewallSubnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

@description('Name of the north-south firewall.')
output name string = firewall.name

@description('Private IP address of the north-south firewall.')
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress

@description('Public IP address of the north-south firewall.')
output publicIp string = publicIp.properties.ipAddress

@description('Resource ID of the north-south firewall policy.')
output policyId string = policy.id
