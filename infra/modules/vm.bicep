@description('Azure region for the VM resources.')
param location string

@description('Tags applied to all lab resources.')
param tags object

@description('Size of the Windows workload VM.')
param vmSize string

@description('Enable Trusted Launch security profile when supported by the selected VM size.')
param trustedLaunch bool

@description('Local administrator password for the workload VM.')
@secure()
param adminPassword string

@description('Name of the Windows workload VM.')
param vmName string

@description('Name of the VM network interface.')
param nicName string

@description('Resource ID of the workload subnet.')
param subnetId string

@description('Static private IP address for the workload VM.')
param privateIp string

var contract = loadJsonContent('../../lab.contract.json')
var bootstrapTemplate = loadTextContent('../../guest/bootstrap.ps1')
var bootstrapScript = replace(
  replace(
    replace(
      bootstrapTemplate,
      '__RDP_REMOTE_ADDRESSES__',
      '${contract.network.vnetA},${contract.network.vnetB},${contract.network.snetBastion}'
    ),
    '__BOOTSTRAP_MARKER_PATH__',
    contract.vm.bootstrapMarkerPath
  ),
  '__BOOTSTRAP_MARKER__',
  contract.vm.bootstrapMarker
)
var bootstrapBase64 = base64(bootstrapScript)
// Bicep base64() is UTF-8, while -EncodedCommand expects UTF-16LE; decode UTF-8 in a short PowerShell command instead.
var commandToExecute = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b=\'${bootstrapBase64}\';$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b));iex $s"'
var vmProperties = union(
  {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: contract.vm.imagePublisher
        offer: contract.vm.imageOffer
        sku: contract.vm.imageSku
        version: contract.vm.imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: contract.vm.osDiskSku
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: contract.vm.adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  },
  trustedLaunch
    ? {
        securityProfile: {
          securityType: 'TrustedLaunch'
          uefiSettings: {
            secureBootEnabled: true
            vTpmEnabled: true
          }
        }
      }
    : {}
)

resource nic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  tags: tags
  properties: vmProperties
}

resource bootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: contract.names.cse
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: commandToExecute
    }
  }
}

@description('Name of the workload VM.')
output vmName string = vm.name
