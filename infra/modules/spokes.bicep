@description('Azure region for spoke networking resources.')
param location string

@description('Tags applied to all lab resources.')
param tags object

@description('Private IP address of the north-south firewall used as the default route next hop.')
param firewallPrivateIp string

var contract = loadJsonContent('../../lab.contract.json')

resource routeTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: contract.names.rt
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: contract.names.routeDefault
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource vnetA 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: contract.names.vnetA
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        contract.network.vnetA
      ]
    }
    subnets: [
      {
        name: contract.names.snetWorkload
        properties: {
          addressPrefix: contract.network.snetA
          defaultOutboundAccess: false
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

resource vnetB 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: contract.names.vnetB
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        contract.network.vnetB
      ]
    }
    subnets: [
      {
        name: contract.names.snetWorkload
        properties: {
          addressPrefix: contract.network.snetB
          defaultOutboundAccess: false
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

resource vnetNs 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: contract.names.vnetNs
}

resource subnetA 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: vnetA
  name: contract.names.snetWorkload
}

resource subnetB 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' existing = {
  parent: vnetB
  name: contract.names.snetWorkload
}

resource peerAtoNs 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: vnetA
  name: contract.names.peerAtoNs
  properties: {
    remoteVirtualNetwork: {
      id: vnetNs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerNsToA 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: vnetNs
  name: contract.names.peerNsToA
  dependsOn: [
    peerAtoNs
  ]
  properties: {
    remoteVirtualNetwork: {
      id: vnetA.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerBtoNs 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: vnetB
  name: contract.names.peerBtoNs
  properties: {
    remoteVirtualNetwork: {
      id: vnetNs.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerNsToB 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
  parent: vnetNs
  name: contract.names.peerNsToB
  // Serializa as duas escritas de peering na vnet-fwlab-ns para reduzir AnotherOperationInProgress.
  dependsOn: [
    peerNsToA
    peerBtoNs
  ]
  properties: {
    remoteVirtualNetwork: {
      id: vnetB.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

@description('Resource ID of spoke VNet A.')
output vnetAId string = vnetA.id

@description('Resource ID of spoke VNet B.')
output vnetBId string = vnetB.id

@description('Resource ID of the workload subnet in spoke A.')
output subnetAId string = subnetA.id

@description('Resource ID of the workload subnet in spoke B.')
output subnetBId string = subnetB.id
