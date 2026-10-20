@description('Resource ID of spoke VNet A.')
param vnetAId string

@description('Resource ID of spoke VNet B.')
param vnetBId string

@description('Resource ID of the east-west secured hub firewall (Routing Intent next hop).')
param firewallId string

var contract = loadJsonContent('../../lab.contract.json')

// Separate module so the hub (the slowest branch) starts at t=0 instead of waiting for the N-S firewall and the spokes.
resource virtualHub 'Microsoft.Network/virtualHubs@2024-07-01' existing = {
  name: contract.names.vhub
}

resource connectionA 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-07-01' = {
  parent: virtualHub
  name: contract.names.connA
  properties: {
    remoteVirtualNetwork: {
      id: vnetAId
    }
    enableInternetSecurity: false
  }
}

resource connectionB 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-07-01' = {
  parent: virtualHub
  name: contract.names.connB
  // Conexoes em serie para reduzir AnotherOperationInProgress no hub.
  dependsOn: [
    connectionA
  ]
  properties: {
    remoteVirtualNetwork: {
      id: vnetBId
    }
    enableInternetSecurity: false
  }
}

resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2024-07-01' = {
  parent: virtualHub
  name: contract.names.routingIntent
  // Apos a conexao, o roteador do hub pode levar minutos para aceitar Routing Intent.
  dependsOn: [
    connectionB
  ]
  properties: {
    routingPolicies: [
      {
        name: contract.names.routingPolicy
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: firewallId
      }
    ]
  }
}

@description('Name of the Routing Intent resource.')
output routingIntentName string = routingIntent.name
