targetScope = 'subscription'

@description('Azure region selected by preflight and used for all lab resources.')
param location string

@description('Size for both Windows workload VMs.')
param vmSize string = 'Standard_B2ls_v2'

@description('Enable Trusted Launch security profile on the workload VMs when the selected SKU supports it.')
param trustedLaunch bool = true

@description('Local administrator password for the workload VMs.')
@secure()
@minLength(12)
@maxLength(123)
param adminPassword string

@description('Expiration date tag in yyyy-MM-dd. Empty uses the defaultExpiresOn value.')
param expiresOn string = ''

@description('Fallback expiration date used when expiresOn is empty.')
param defaultExpiresOn string = dateTimeAdd(utcNow('yyyy-MM-ddTHH:mm:ssZ'), 'P1D', 'yyyy-MM-dd')

var contract = loadJsonContent('../lab.contract.json')
var tags = union(contract.tags, {
  expiresOn: empty(expiresOn) ? defaultExpiresOn : expiresOn
})

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: contract.names.rg
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: '${contract.names.deploymentPrefix}-monitoring'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
  }
}

module networkNs 'modules/network-ns.bicep' = {
  name: '${contract.names.deploymentPrefix}-network-ns'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
  }
}

module firewallNs 'modules/firewall-ns.bicep' = {
  name: '${contract.names.deploymentPrefix}-firewall-ns'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
  }
  dependsOn: [
    networkNs
  ]
}

module spokes 'modules/spokes.bicep' = {
  name: '${contract.names.deploymentPrefix}-spokes'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    firewallPrivateIp: firewallNs.outputs.privateIp
  }
}

module bastion 'modules/bastion.bicep' = {
  name: '${contract.names.deploymentPrefix}-bastion'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
  }
  dependsOn: [
    spokes
  ]
}

module vwan 'modules/vwan.bicep' = {
  name: '${contract.names.deploymentPrefix}-vwan'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
  }
}

module vwanConnections 'modules/vwan-connections.bicep' = {
  name: '${contract.names.deploymentPrefix}-vwan-connections'
  scope: resourceGroup
  params: {
    vnetAId: spokes.outputs.vnetAId
    vnetBId: spokes.outputs.vnetBId
    firewallId: vwan.outputs.firewallId
  }
}

module vmA 'modules/vm.bicep' = {
  name: '${contract.names.deploymentPrefix}-vm-a'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    vmSize: vmSize
    trustedLaunch: trustedLaunch
    adminPassword: adminPassword
    vmName: contract.names.vmA
    nicName: contract.names.nicA
    subnetId: spokes.outputs.subnetAId
    privateIp: contract.network.vmAIp
  }
  dependsOn: [
    firewallNs
    spokes
  ]
}

module vmB 'modules/vm.bicep' = {
  name: '${contract.names.deploymentPrefix}-vm-b'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    vmSize: vmSize
    trustedLaunch: trustedLaunch
    adminPassword: adminPassword
    vmName: contract.names.vmB
    nicName: contract.names.nicB
    subnetId: spokes.outputs.subnetBId
    privateIp: contract.network.vmBIp
  }
  dependsOn: [
    firewallNs
    spokes
  ]
}

@description('Name of the lab resource group.')
output resourceGroupName string = resourceGroup.name

@description('Azure region where the lab was deployed.')
output location string = location

@description('Name of the north-south firewall.')
output fwNsName string = firewallNs.outputs.name

@description('Private IP address of the north-south firewall.')
output fwNsPrivateIp string = firewallNs.outputs.privateIp

@description('Public IP address of the north-south firewall.')
output fwNsPublicIp string = firewallNs.outputs.publicIp

@description('Name of the east-west secured hub firewall.')
output fwEwName string = vwan.outputs.firewallName

@description('Private IP address of the east-west secured hub firewall.')
output fwEwPrivateIp string = vwan.outputs.firewallPrivateIp

@description('Resource ID of the north-south firewall policy.')
output polNsId string = firewallNs.outputs.policyId

@description('Resource ID of the east-west firewall policy.')
output polEwId string = vwan.outputs.policyId

@description('Resource ID of the Log Analytics workspace.')
output lawId string = monitoring.outputs.workspaceId

@description('Customer ID of the Log Analytics workspace.')
output lawCustomerId string = monitoring.outputs.customerId

@description('Resource ID of the virtual hub.')
output vhubId string = vwan.outputs.virtualHubId

@description('Name of VM A.')
output vmAName string = vmA.outputs.vmName

@description('Name of VM B.')
output vmBName string = vmB.outputs.vmName
