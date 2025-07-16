// SQL Server High Availability on Azure - Main Bicep Template
// This template deploys the complete SQL Server HA infrastructure

targetScope = 'resourceGroup'

// Parameters
@description('Location for all resources')
param location string = resourceGroup().location

@description('Deployment name prefix')
param deploymentPrefix string = 'sqlha'

@description('Administrator username for VMs')
param adminUsername string

@description('Administrator password for VMs')
@secure()
param adminPassword string

@description('SQL Server service account username')
param sqlServiceAccount string = 'sqlservice'

@description('SQL Server service account password')
@secure()
param sqlServicePassword string

@description('Domain name for Active Directory')
param domainName string = 'contoso.local'

@description('Virtual network address space')
param vnetAddressSpace string = '10.0.0.0/16'

@description('Domain controller subnet address prefix')
param domainSubnetPrefix string = '10.0.1.0/24'

@description('SQL Server 1 subnet address prefix')
param sql1SubnetPrefix string = '10.0.2.0/24'

@description('SQL Server 2 subnet address prefix')
param sql2SubnetPrefix string = '10.0.3.0/24'

@description('Witness server subnet address prefix')
param witnessSubnetPrefix string = '10.0.4.0/24'

@description('VM size for SQL Server instances')
param sqlVmSize string = 'Standard_D4s_v3'

@description('VM size for Domain Controller')
param dcVmSize string = 'Standard_D2s_v3'

@description('VM size for Witness server')
param witnessVmSize string = 'Standard_D2s_v3'

@description('SQL Server edition')
@allowed([
  'Enterprise'
  'Standard'
  'Developer'
])
param sqlServerEdition string = 'Standard'

@description('Availability Group name')
param availabilityGroupName string = 'AG-Demo'

@description('Availability Group listener name')
param listenerName string = 'AG-Listener'

@description('Availability Group listener port')
param listenerPort int = 1433

@description('Tags to apply to all resources')
param tags object = {
  Environment: 'Demo'
  Project: 'SQL-HA-Azure'
  Owner: 'IT-Team'
}

// Variables
var networkSecurityGroupName = '${deploymentPrefix}-nsg'
var virtualNetworkName = '${deploymentPrefix}-vnet'
var domainControllerName = '${deploymentPrefix}-dc'
var sqlServer1Name = '${deploymentPrefix}-sql1'
var sqlServer2Name = '${deploymentPrefix}-sql2'
var witnessServerName = '${deploymentPrefix}-witness'
var loadBalancerName = '${deploymentPrefix}-lb'
var availabilitySetName = '${deploymentPrefix}-avset'

// Deploy network infrastructure
module network 'network.bicep' = {
  name: 'networkDeployment'
  params: {
    location: location
    deploymentPrefix: deploymentPrefix
    vnetAddressSpace: vnetAddressSpace
    domainSubnetPrefix: domainSubnetPrefix
    sql1SubnetPrefix: sql1SubnetPrefix
    sql2SubnetPrefix: sql2SubnetPrefix
    witnessSubnetPrefix: witnessSubnetPrefix
    networkSecurityGroupName: networkSecurityGroupName
    virtualNetworkName: virtualNetworkName
    tags: tags
  }
}

// Deploy compute resources
module compute 'compute.bicep' = {
  name: 'computeDeployment'
  params: {
    location: location
    deploymentPrefix: deploymentPrefix
    adminUsername: adminUsername
    adminPassword: adminPassword
    sqlServiceAccount: sqlServiceAccount
    sqlServicePassword: sqlServicePassword
    domainName: domainName
    sqlVmSize: sqlVmSize
    dcVmSize: dcVmSize
    witnessVmSize: witnessVmSize
    sqlServerEdition: sqlServerEdition
    availabilityGroupName: availabilityGroupName
    listenerName: listenerName
    listenerPort: listenerPort
    virtualNetworkName: network.outputs.virtualNetworkName
    domainSubnetName: network.outputs.domainSubnetName
    sql1SubnetName: network.outputs.sql1SubnetName
    sql2SubnetName: network.outputs.sql2SubnetName
    witnessSubnetName: network.outputs.witnessSubnetName
    networkSecurityGroupId: network.outputs.networkSecurityGroupId
    domainControllerName: domainControllerName
    sqlServer1Name: sqlServer1Name
    sqlServer2Name: sqlServer2Name
    witnessServerName: witnessServerName
    loadBalancerName: loadBalancerName
    availabilitySetName: availabilitySetName
    tags: tags
  }
  dependsOn: [
    network
  ]
}

// Outputs
output resourceGroupName string = resourceGroup().name
output virtualNetworkName string = network.outputs.virtualNetworkName
output domainControllerName string = domainControllerName
output sqlServer1Name string = sqlServer1Name
output sqlServer2Name string = sqlServer2Name
output witnessServerName string = witnessServerName
output loadBalancerName string = loadBalancerName
output availabilityGroupName string = availabilityGroupName
output listenerName string = listenerName
output listenerPort int = listenerPort
output domainName string = domainName

