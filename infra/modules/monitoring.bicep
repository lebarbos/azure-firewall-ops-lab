@description('Azure region for the Log Analytics workspace.')
param location string

@description('Tags applied to all lab resources.')
param tags object

var contract = loadJsonContent('../../lab.contract.json')

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: contract.names.law
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

@description('Resource ID of the Log Analytics workspace.')
output workspaceId string = workspace.id

@description('Customer ID of the Log Analytics workspace.')
output customerId string = workspace.properties.customerId
