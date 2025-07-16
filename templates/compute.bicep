// Compute Infrastructure Bicep Template
// Deploys virtual machines, availability sets, and load balancer

targetScope = 'resourceGroup'

// Parameters
@description('Location for all resources')
param location string

@description('Deployment name prefix')
param deploymentPrefix string

@description('Administrator username for VMs')
param adminUsername string

@description('Administrator password for VMs')
@secure()
param adminPassword string

@description('SQL Server service account username')
param sqlServiceAccount string

@description('SQL Server service account password')
@secure()
param sqlServicePassword string

@description('Domain name for Active Directory')
param domainName string

@description('VM size for SQL Server instances')
param sqlVmSize string

@description('VM size for Domain Controller')
param dcVmSize string

@description('VM size for Witness server')
param witnessVmSize string

@description('SQL Server edition')
param sqlServerEdition string

@description('Availability Group name')
param availabilityGroupName string

@description('Availability Group listener name')
param listenerName string

@description('Availability Group listener port')
param listenerPort int

@description('Virtual network name')
param virtualNetworkName string

@description('Domain subnet name')
param domainSubnetName string

@description('SQL Server 1 subnet name')
param sql1SubnetName string

@description('SQL Server 2 subnet name')
param sql2SubnetName string

@description('Witness subnet name')
param witnessSubnetName string

@description('Network security group ID')
param networkSecurityGroupId string

@description('Domain controller name')
param domainControllerName string

@description('SQL Server 1 name')
param sqlServer1Name string

@description('SQL Server 2 name')
param sqlServer2Name string

@description('Witness server name')
param witnessServerName string

@description('Load balancer name')
param loadBalancerName string

@description('Availability set name')
param availabilitySetName string

@description('Tags to apply to all resources')
param tags object

// Variables
var storageAccountName = '${deploymentPrefix}storage${uniqueString(resourceGroup().id)}'
var domainControllerNicName = '${domainControllerName}-nic'
var sqlServer1NicName = '${sqlServer1Name}-nic'
var sqlServer2NicName = '${sqlServer2Name}-nic'
var witnessServerNicName = '${witnessServerName}-nic'
var domainControllerPipName = '${domainControllerName}-pip'
var sqlServer1PipName = '${sqlServer1Name}-pip'
var sqlServer2PipName = '${sqlServer2Name}-pip'
var witnessServerPipName = '${witnessServerName}-pip'
var loadBalancerPipName = '${loadBalancerName}-pip'

// Get existing virtual network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: virtualNetworkName
}

// Storage Account for diagnostics
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// Availability Set for SQL Servers
resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-03-01' = {
  name: availabilitySetName
  location: location
  tags: tags
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// Public IP Addresses
resource domainControllerPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: domainControllerPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${domainControllerName}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource sqlServer1Pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: sqlServer1PipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${sqlServer1Name}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource sqlServer2Pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: sqlServer2PipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${sqlServer2Name}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource witnessServerPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: witnessServerPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${witnessServerName}-${uniqueString(resourceGroup().id)}'
    }
  }
}

resource loadBalancerPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: loadBalancerPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${loadBalancerName}-${uniqueString(resourceGroup().id)}'
    }
  }
}

// Network Interfaces
resource domainControllerNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: domainControllerNicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.1.4'
          publicIPAddress: {
            id: domainControllerPip.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${domainSubnetName}'
          }
        }
      }
    ]
    dnsSettings: {
      dnsServers: [
        '10.0.1.4'
      ]
    }
  }
}

resource sqlServer1Nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: sqlServer1NicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.2.4'
          publicIPAddress: {
            id: sqlServer1Pip.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${sql1SubnetName}'
          }
        }
      }
    ]
    dnsSettings: {
      dnsServers: [
        '10.0.1.4'
      ]
    }
  }
}

resource sqlServer2Nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: sqlServer2NicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.3.4'
          publicIPAddress: {
            id: sqlServer2Pip.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${sql2SubnetName}'
          }
        }
      }
    ]
    dnsSettings: {
      dnsServers: [
        '10.0.1.4'
      ]
    }
  }
}

resource witnessServerNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: witnessServerNicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.4.4'
          publicIPAddress: {
            id: witnessServerPip.id
          }
          subnet: {
            id: '${virtualNetwork.id}/subnets/${witnessSubnetName}'
          }
        }
      }
    ]
    dnsSettings: {
      dnsServers: [
        '10.0.1.4'
      ]
    }
  }
}

// Load Balancer
resource loadBalancer 'Microsoft.Network/loadBalancers@2023-04-01' = {
  name: loadBalancerName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'LoadBalancerFrontend'
        properties: {
          publicIPAddress: {
            id: loadBalancerPip.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'BackendPool'
      }
    ]
    loadBalancingRules: [
      {
        name: 'SQLRule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, 'LoadBalancerFrontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, 'BackendPool')
          }
          protocol: 'Tcp'
          frontendPort: listenerPort
          backendPort: listenerPort
          enableFloatingIP: true
          idleTimeoutInMinutes: 4
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'SQLProbe')
          }
        }
      }
    ]
    probes: [
      {
        name: 'SQLProbe'
        properties: {
          protocol: 'Tcp'
          port: 59999
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// Virtual Machines
resource domainController 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: domainControllerName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: dcVmSize
    }
    osProfile: {
      computerName: domainControllerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter'
        version: 'latest'
      }
      osDisk: {
        name: '${domainControllerName}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: domainControllerNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

resource sqlServer1 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: sqlServer1Name
  location: location
  tags: tags
  properties: {
    availabilitySet: {
      id: availabilitySet.id
    }
    hardwareProfile: {
      vmSize: sqlVmSize
    }
    osProfile: {
      computerName: sqlServer1Name
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: sqlServerEdition == 'Enterprise' ? 'enterprise' : 'standard'
        version: 'latest'
      }
      osDisk: {
        name: '${sqlServer1Name}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: '${sqlServer1Name}-datadisk'
          diskSizeGB: 1023
          lun: 0
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlServer1Nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

resource sqlServer2 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: sqlServer2Name
  location: location
  tags: tags
  properties: {
    availabilitySet: {
      id: availabilitySet.id
    }
    hardwareProfile: {
      vmSize: sqlVmSize
    }
    osProfile: {
      computerName: sqlServer2Name
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: 'sql2022-ws2022'
        sku: sqlServerEdition == 'Enterprise' ? 'enterprise' : 'standard'
        version: 'latest'
      }
      osDisk: {
        name: '${sqlServer2Name}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: '${sqlServer2Name}-datadisk'
          diskSizeGB: 1023
          lun: 0
          createOption: 'Empty'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: sqlServer2Nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

resource witnessServer 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: witnessServerName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: witnessVmSize
    }
    osProfile: {
      computerName: witnessServerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter'
        version: 'latest'
      }
      osDisk: {
        name: '${witnessServerName}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: witnessServerNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

// Outputs
output domainControllerName string = domainController.name
output sqlServer1Name string = sqlServer1.name
output sqlServer2Name string = sqlServer2.name
output witnessServerName string = witnessServer.name
output loadBalancerName string = loadBalancer.name
output availabilitySetName string = availabilitySet.name
output storageAccountName string = storageAccount.name

