// Network Infrastructure Bicep Template
// Deploys virtual network, subnets, and network security groups

targetScope = 'resourceGroup'

// Parameters
@description('Location for all resources')
param location string

@description('Deployment name prefix')
param deploymentPrefix string

@description('Virtual network address space')
param vnetAddressSpace string

@description('Domain controller subnet address prefix')
param domainSubnetPrefix string

@description('SQL Server 1 subnet address prefix')
param sql1SubnetPrefix string

@description('SQL Server 2 subnet address prefix')
param sql2SubnetPrefix string

@description('Witness server subnet address prefix')
param witnessSubnetPrefix string

@description('Network security group name')
param networkSecurityGroupName string

@description('Virtual network name')
param virtualNetworkName string

@description('Tags to apply to all resources')
param tags object

// Variables
var domainSubnetName = 'domain-subnet'
var sql1SubnetName = 'sql1-subnet'
var sql2SubnetName = 'sql2-subnet'
var witnessSubnetName = 'witness-subnet'

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: networkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          description: 'Allow RDP access'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowSQL'
        properties: {
          description: 'Allow SQL Server access'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1100
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowSQLBrowser'
        properties: {
          description: 'Allow SQL Server Browser'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '1434'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1200
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowAGEndpoint'
        properties: {
          description: 'Allow Always On Availability Group endpoint'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1300
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowClusterCommunication'
        properties: {
          description: 'Allow Windows Failover Cluster communication'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '3343'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1400
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowWinRM'
        properties: {
          description: 'Allow Windows Remote Management'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5985-5986'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1500
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowDNS'
        properties: {
          description: 'Allow DNS'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '53'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1600
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowKerberos'
        properties: {
          description: 'Allow Kerberos authentication'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '88'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1700
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowLDAP'
        properties: {
          description: 'Allow LDAP'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '389'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1800
          direction: 'Inbound'
        }
      }
      {
        name: 'AllowLDAPS'
        properties: {
          description: 'Allow LDAP over SSL'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '636'
          sourceAddressPrefix: vnetAddressSpace
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1900
          direction: 'Inbound'
        }
      }
    ]
  }
}

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: domainSubnetName
        properties: {
          addressPrefix: domainSubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
      {
        name: sql1SubnetName
        properties: {
          addressPrefix: sql1SubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
      {
        name: sql2SubnetName
        properties: {
          addressPrefix: sql2SubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
      {
        name: witnessSubnetName
        properties: {
          addressPrefix: witnessSubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

// Outputs
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output networkSecurityGroupId string = networkSecurityGroup.id
output domainSubnetName string = domainSubnetName
output sql1SubnetName string = sql1SubnetName
output sql2SubnetName string = sql2SubnetName
output witnessSubnetName string = witnessSubnetName
output domainSubnetId string = virtualNetwork.properties.subnets[0].id
output sql1SubnetId string = virtualNetwork.properties.subnets[1].id
output sql2SubnetId string = virtualNetwork.properties.subnets[2].id
output witnessSubnetId string = virtualNetwork.properties.subnets[3].id

