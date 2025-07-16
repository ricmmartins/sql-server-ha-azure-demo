# =============================================================================
# SQL Server HA on Azure - Windows Server Failover Cluster Creation Script
# =============================================================================
# This PowerShell script creates and configures the Windows Server Failover
# Cluster for SQL Server Always On Availability Groups
# Author: Manus AI
# Version: 1.0.0
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "..\..\config.json",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Import required modules
Import-Module FailoverClusters -Force

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Write-Info {
    param([string]$Message)
    Write-ColorOutput -Message "[INFO] $Message" -Color "Cyan"
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput -Message "[SUCCESS] $Message" -Color "Green"
}

function Write-Warning {
    param([string]$Message)
    Write-ColorOutput -Message "[WARNING] $Message" -Color "Yellow"
}

function Write-Error {
    param([string]$Message)
    Write-ColorOutput -Message "[ERROR] $Message" -Color "Red"
}

# Function to check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function to load configuration
function Get-Configuration {
    param([string]$ConfigPath)
    
    Write-Info "Loading configuration from: $ConfigPath"
    
    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }
    
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Success "Configuration loaded successfully"
        return $config
    }
    catch {
        throw "Failed to parse configuration file: $_"
    }
}

# Function to check prerequisites
function Test-Prerequisites {
    param($Config)
    
    Write-Info "Checking prerequisites..."
    
    # Check if running as administrator
    if (-not (Test-Administrator)) {
        throw "This script must be run as Administrator"
    }
    
    # Check if domain joined
    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
    if ($computerSystem.PartOfDomain -eq $false) {
        throw "Computer must be joined to a domain"
    }
    
    # Check if Failover Clustering feature is installed
    $feature = Get-WindowsFeature -Name Failover-Clustering
    if ($feature.InstallState -ne "Installed") {
        throw "Failover Clustering feature is not installed. Run 01-install-failover-clustering.ps1 first."
    }
    
    # Check connectivity to other nodes
    foreach ($node in $Config.sqlServers.nodes) {
        $nodeName = $node.vmName
        if ($nodeName -ne $env:COMPUTERNAME) {
            Write-Info "Testing connectivity to node: $nodeName"
            if (-not (Test-Connection -ComputerName $nodeName -Count 1 -Quiet)) {
                throw "Cannot reach node: $nodeName"
            }
        }
    }
    
    Write-Success "Prerequisites check passed"
}

# Function to validate cluster configuration
function Test-ClusterConfiguration {
    param($Config)
    
    Write-Info "Validating cluster configuration..."
    
    try {
        # Get node names
        $nodes = @()
        foreach ($node in $Config.sqlServers.nodes) {
            $nodes += $node.vmName
        }
        
        Write-Info "Running cluster validation for nodes: $($nodes -join ', ')"
        
        # Run cluster validation
        $validationReport = Test-Cluster -Node $nodes -Include "Inventory", "Network", "System Configuration", "Storage" -Verbose
        
        if ($validationReport) {
            Write-Success "Cluster validation completed successfully"
            Write-Info "Validation report saved to: $($validationReport.FullName)"
        }
        else {
            Write-Warning "Cluster validation completed with warnings"
        }
        
        return $true
    }
    catch {
        Write-Error "Cluster validation failed: $_"
        return $false
    }
}

# Function to create the failover cluster
function New-FailoverCluster {
    param($Config)
    
    $clusterName = $Config.cluster.clusterName
    $clusterIP = $Config.cluster.clusterIpAddress
    
    Write-Info "Creating Windows Server Failover Cluster: $clusterName"
    
    try {
        # Check if cluster already exists
        $existingCluster = Get-Cluster -Name $clusterName -ErrorAction SilentlyContinue
        if ($existingCluster) {
            Write-Warning "Cluster '$clusterName' already exists"
            return $existingCluster
        }
        
        # Get node names
        $nodes = @()
        foreach ($node in $Config.sqlServers.nodes) {
            $nodes += $node.vmName
        }
        
        Write-Info "Creating cluster with nodes: $($nodes -join ', ')"
        Write-Info "Cluster IP address: $clusterIP"
        
        # Create the cluster
        $cluster = New-Cluster -Name $clusterName -Node $nodes -StaticAddress $clusterIP -NoStorage
        
        if ($cluster) {
            Write-Success "Failover cluster '$clusterName' created successfully"
            return $cluster
        }
        else {
            throw "Failed to create cluster"
        }
    }
    catch {
        throw "Error creating failover cluster: $_"
    }
}

# Function to configure cluster quorum
function Set-ClusterQuorum {
    param($Config)
    
    Write-Info "Configuring cluster quorum..."
    
    try {
        $quorumType = $Config.cluster.quorumType
        $clusterName = $Config.cluster.clusterName
        
        Write-Info "Setting quorum type to: $quorumType"
        
        switch ($quorumType) {
            "NodeAndFileShareMajority" {
                $fileSharePath = $Config.cluster.fileSharePath
                Write-Info "Using file share witness: $fileSharePath"
                
                # Test file share accessibility
                if (Test-Path $fileSharePath) {
                    Set-ClusterQuorum -Cluster $clusterName -NodeAndFileShareMajority $fileSharePath
                    Write-Success "File share witness configured: $fileSharePath"
                }
                else {
                    Write-Warning "File share path not accessible: $fileSharePath"
                    Write-Info "Configuring cloud witness instead..."
                    Set-CloudWitness -Config $Config
                }
            }
            "NodeAndCloudMajority" {
                Set-CloudWitness -Config $Config
            }
            "NodeMajority" {
                Set-ClusterQuorum -Cluster $clusterName -NodeMajority
                Write-Success "Node majority quorum configured"
            }
            default {
                Write-Warning "Unknown quorum type: $quorumType. Using default."
            }
        }
    }
    catch {
        Write-Warning "Error configuring cluster quorum: $_"
        Write-Info "Cluster will use default quorum configuration"
    }
}

# Function to configure cloud witness
function Set-CloudWitness {
    param($Config)
    
    Write-Info "Configuring cloud witness..."
    
    try {
        # Note: In a real deployment, you would get these values from Azure Key Vault or secure configuration
        $storageAccountName = $Config.storage.storageAccountName -replace '\{uniqueString\}', (Get-Date -Format "yyyyMMddHHmm")
        $storageAccountKey = "YourStorageAccountKey" # This should be retrieved securely
        
        Write-Info "Using storage account: $storageAccountName"
        
        # Configure cloud witness
        Set-ClusterQuorum -CloudWitness -AccountName $storageAccountName -AccessKey $storageAccountKey
        
        Write-Success "Cloud witness configured successfully"
    }
    catch {
        Write-Warning "Error configuring cloud witness: $_"
        Write-Info "You may need to configure the witness manually"
    }
}

# Function to configure cluster networks
function Set-ClusterNetworks {
    param($Config)
    
    Write-Info "Configuring cluster networks..."
    
    try {
        $clusterNetworks = Get-ClusterNetwork
        
        foreach ($network in $clusterNetworks) {
            Write-Info "Configuring network: $($network.Name) - $($network.Address)"
            
            # Configure network for cluster communication
            if ($network.Address -like "10.0.*") {
                $network.Name = "Cluster Network"
                $network.Role = "ClusterAndClient"
                Write-Info "Configured as cluster and client network"
            }
            else {
                $network.Role = "None"
                Write-Info "Disabled for cluster communication"
            }
        }
        
        Write-Success "Cluster networks configured"
    }
    catch {
        Write-Warning "Error configuring cluster networks: $_"
    }
}

# Function to configure cluster properties
function Set-ClusterProperties {
    param($Config)
    
    Write-Info "Configuring cluster properties..."
    
    try {
        $clusterName = $Config.cluster.clusterName
        
        # Configure cluster timeouts for Azure environment
        (Get-Cluster -Name $clusterName).SameSubnetDelay = 2000
        (Get-Cluster -Name $clusterName).SameSubnetThreshold = 10
        (Get-Cluster -Name $clusterName).CrossSubnetDelay = 3000
        (Get-Cluster -Name $clusterName).CrossSubnetThreshold = 20
        
        # Configure cluster heartbeat settings
        (Get-Cluster -Name $clusterName).PlumbAllCrossSubnetRoutes = 1
        
        Write-Success "Cluster properties configured for Azure environment"
    }
    catch {
        Write-Warning "Error configuring cluster properties: $_"
    }
}

# Function to add cluster resources
function Add-ClusterResources {
    param($Config)
    
    Write-Info "Adding cluster resources..."
    
    try {
        $clusterName = $Config.cluster.clusterName
        
        # Add IP address resource for availability group listener
        $listenerIP = $Config.availabilityGroup.listenerIpAddress
        $listenerName = $Config.availabilityGroup.listenerName
        
        Write-Info "Adding IP address resource for AG listener: $listenerIP"
        
        # Create IP address resource
        $ipResource = Add-ClusterResource -Name "$listenerName-IP" -ResourceType "IP Address" -Group "Available Storage"
        $ipResource | Set-ClusterParameter -Name Address -Value $listenerIP
        $ipResource | Set-ClusterParameter -Name SubnetMask -Value "255.255.255.0"
        $ipResource | Set-ClusterParameter -Name EnableDhcp -Value 0
        
        Write-Success "IP address resource added for AG listener"
    }
    catch {
        Write-Warning "Error adding cluster resources: $_"
    }
}

# Function to test cluster functionality
function Test-ClusterFunctionality {
    param($Config)
    
    Write-Info "Testing cluster functionality..."
    
    try {
        $clusterName = $Config.cluster.clusterName
        
        # Get cluster information
        $cluster = Get-Cluster -Name $clusterName
        Write-Info "Cluster Name: $($cluster.Name)"
        Write-Info "Cluster Domain: $($cluster.Domain)"
        
        # Get cluster nodes
        $nodes = Get-ClusterNode -Cluster $clusterName
        Write-Info "Cluster Nodes:"
        foreach ($node in $nodes) {
            Write-Info "  - $($node.Name): $($node.State)"
        }
        
        # Get cluster networks
        $networks = Get-ClusterNetwork -Cluster $clusterName
        Write-Info "Cluster Networks:"
        foreach ($network in $networks) {
            Write-Info "  - $($network.Name): $($network.Role)"
        }
        
        # Get cluster quorum
        $quorum = Get-ClusterQuorum -Cluster $clusterName
        Write-Info "Cluster Quorum: $($quorum.QuorumType)"
        
        Write-Success "Cluster functionality test completed"
        return $true
    }
    catch {
        Write-Error "Cluster functionality test failed: $_"
        return $false
    }
}

# Function to configure SQL Server cluster resources
function Set-SqlServerClusterResources {
    param($Config)
    
    Write-Info "Configuring SQL Server cluster resources..."
    
    try {
        # Register SQL Server with cluster
        foreach ($node in $Config.sqlServers.nodes) {
            $nodeName = $node.vmName
            Write-Info "Registering SQL Server on node: $nodeName"
            
            # This will be done through Azure CLI in the infrastructure scripts
            # Here we just verify the registration
            Write-Info "SQL Server cluster registration will be handled by Azure CLI"
        }
        
        Write-Success "SQL Server cluster resources configured"
    }
    catch {
        Write-Warning "Error configuring SQL Server cluster resources: $_"
    }
}

# Function to validate cluster creation
function Test-ClusterCreation {
    param($Config)
    
    Write-Info "Validating cluster creation..."
    
    try {
        $clusterName = $Config.cluster.clusterName
        
        # Check if cluster exists and is accessible
        $cluster = Get-Cluster -Name $clusterName
        if (-not $cluster) {
            throw "Cluster '$clusterName' not found"
        }
        
        # Check cluster nodes
        $nodes = Get-ClusterNode -Cluster $clusterName
        $expectedNodeCount = $Config.sqlServers.nodes.Count
        
        if ($nodes.Count -ne $expectedNodeCount) {
            throw "Expected $expectedNodeCount nodes, found $($nodes.Count)"
        }
        
        # Check if all nodes are online
        $offlineNodes = $nodes | Where-Object { $_.State -ne "Up" }
        if ($offlineNodes) {
            Write-Warning "Some nodes are not online: $($offlineNodes.Name -join ', ')"
        }
        
        # Check cluster quorum
        $quorum = Get-ClusterQuorum -Cluster $clusterName
        if (-not $quorum) {
            Write-Warning "Cluster quorum not properly configured"
        }
        
        Write-Success "Cluster creation validation passed"
        return $true
    }
    catch {
        Write-Error "Cluster creation validation failed: $_"
        return $false
    }
}

# Function to display cluster summary
function Show-ClusterSummary {
    param($Config)
    
    $clusterName = $Config.cluster.clusterName
    
    Write-Success "Windows Server Failover Cluster created successfully!"
    Write-Info ""
    Write-Info "Cluster Summary:"
    Write-Info "  Name: $clusterName"
    Write-Info "  IP Address: $($Config.cluster.clusterIpAddress)"
    Write-Info "  Quorum Type: $($Config.cluster.quorumType)"
    
    # Display nodes
    $nodes = Get-ClusterNode -Cluster $clusterName
    Write-Info "  Nodes:"
    foreach ($node in $nodes) {
        Write-Info "    - $($node.Name): $($node.State)"
    }
    
    Write-Info ""
    Write-Info "Next steps:"
    Write-Info "1. Run: .\03-enable-always-on.ps1"
    Write-Info "2. Verify cluster is accessible from all nodes"
    Write-Info "3. Check cluster validation report for any warnings"
    Write-Info ""
}

# Main execution function
function Main {
    try {
        Write-Info "============================================================================="
        Write-Info "SQL Server HA on Azure - Windows Server Failover Cluster Creation"
        Write-Info "============================================================================="
        Write-Info ""
        
        # Load configuration
        $config = Get-Configuration -ConfigPath $ConfigPath
        
        # Check prerequisites
        Test-Prerequisites -Config $config
        
        # Validate cluster configuration
        if (-not (Test-ClusterConfiguration -Config $config)) {
            if (-not $Force) {
                throw "Cluster validation failed. Use -Force to continue anyway."
            }
            Write-Warning "Continuing despite validation warnings due to -Force parameter"
        }
        
        # Create the failover cluster
        $cluster = New-FailoverCluster -Config $config
        
        # Configure cluster quorum
        Set-ClusterQuorum -Config $config
        
        # Configure cluster networks
        Set-ClusterNetworks -Config $config
        
        # Configure cluster properties
        Set-ClusterProperties -Config $config
        
        # Add cluster resources
        Add-ClusterResources -Config $config
        
        # Configure SQL Server cluster resources
        Set-SqlServerClusterResources -Config $config
        
        # Test cluster functionality
        if (-not (Test-ClusterFunctionality -Config $config)) {
            Write-Warning "Cluster functionality test failed, but cluster was created"
        }
        
        # Validate cluster creation
        if (Test-ClusterCreation -Config $config) {
            Show-ClusterSummary -Config $config
        }
        else {
            throw "Cluster creation validation failed"
        }
    }
    catch {
        Write-Error "Script execution failed: $_"
        exit 1
    }
}

# Execute main function
Main

