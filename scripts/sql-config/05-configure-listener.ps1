# ============================================================================================
# SQL Server HA on Azure - Configure Availability Group Listener
# ============================================================================================
# This script configures the Availability Group listener for SQL Server Always On
# Author: Manus AI
# Version: 1.0.0
# ============================================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "config.json",
    
    [Parameter(Mandatory=$false)]
    [switch]$ValidateOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$Help
)

# Import required modules
Import-Module SqlServer -ErrorAction SilentlyContinue
Import-Module FailoverClusters -ErrorAction SilentlyContinue

# Global variables
$script:LogFile = ""
$script:Config = $null
$script:StartTime = Get-Date

# Logging functions
function Write-LogInfo {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [INFO] $Message"
    Write-Host $logMessage -ForegroundColor Green
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logMessage
    }
}

function Write-LogWarning {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [WARNING] $Message"
    Write-Host $logMessage -ForegroundColor Yellow
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logMessage
    }
}

function Write-LogError {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [ERROR] $Message"
    Write-Host $logMessage -ForegroundColor Red
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logMessage
    }
}

function Write-LogPhase {
    param([string]$Message)
    $separator = "=" * 80
    $phaseMessage = @"

$separator
$Message
$separator

"@
    Write-Host $phaseMessage -ForegroundColor Cyan
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $phaseMessage
    }
}

function Show-Usage {
    $usage = @"
============================================================================================
SQL Server HA on Azure - Configure Availability Group Listener
============================================================================================

USAGE:
    .\05-configure-listener.ps1 [OPTIONS]

DESCRIPTION:
    Configures the Availability Group listener for SQL Server Always On High Availability

OPTIONS:
    -ConfigFile <path>      Path to configuration JSON file (default: config.json)
    -ValidateOnly           Validate configuration only, don't make changes
    -Force                  Force configuration without prompts
    -Help                   Show this help message

EXAMPLES:
    .\05-configure-listener.ps1
    .\05-configure-listener.ps1 -ConfigFile "custom-config.json"
    .\05-configure-listener.ps1 -ValidateOnly
    .\05-configure-listener.ps1 -Force

PREREQUISITES:
    - Windows Server Failover Cluster must be configured
    - SQL Server Always On Availability Groups must be enabled
    - Availability Group must be created
    - Load balancer must be configured in Azure
    - PowerShell modules: SqlServer, FailoverClusters

"@
    Write-Host $usage
}

function Initialize-Script {
    Write-LogPhase "Initializing Availability Group Listener Configuration"
    
    # Create logs directory
    $logsDir = Join-Path $PSScriptRoot "..\..\logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    
    # Set log file path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:LogFile = Join-Path $logsDir "configure-listener-$timestamp.log"
    
    Write-LogInfo "Script started at $($script:StartTime)"
    Write-LogInfo "Log file: $($script:LogFile)"
    Write-LogInfo "Configuration file: $ConfigFile"
}

function Test-Prerequisites {
    Write-LogPhase "Checking Prerequisites"
    
    $errors = @()
    
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $errors += "Script must be run as Administrator"
    }
    
    # Check PowerShell modules
    if (-not (Get-Module -ListAvailable -Name SqlServer)) {
        $errors += "SqlServer PowerShell module is not installed"
    }
    
    if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
        $errors += "FailoverClusters PowerShell module is not installed"
    }
    
    # Check if SQL Server service is running
    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if (-not $sqlService -or $sqlService.Status -ne "Running") {
        $errors += "SQL Server service is not running"
    }
    
    # Check if Cluster service is running
    $clusterService = Get-Service -Name "ClusSvc" -ErrorAction SilentlyContinue
    if (-not $clusterService -or $clusterService.Status -ne "Running") {
        $errors += "Cluster service is not running"
    }
    
    if ($errors.Count -gt 0) {
        Write-LogError "Prerequisites check failed:"
        foreach ($error in $errors) {
            Write-LogError "  - $error"
        }
        throw "Prerequisites not met"
    }
    
    Write-LogInfo "All prerequisites met"
}

function Read-Configuration {
    Write-LogPhase "Reading Configuration"
    
    $configPath = Join-Path $PSScriptRoot "..\..\$ConfigFile"
    
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }
    
    try {
        $script:Config = Get-Content $configPath | ConvertFrom-Json
        Write-LogInfo "Configuration loaded successfully"
    }
    catch {
        throw "Failed to parse configuration file: $($_.Exception.Message)"
    }
    
    # Validate required configuration sections
    $requiredSections = @("availabilityGroup", "cluster", "loadBalancer", "sqlServers")
    foreach ($section in $requiredSections) {
        if (-not $script:Config.$section) {
            throw "Missing required configuration section: $section"
        }
    }
    
    Write-LogInfo "Configuration validation completed"
}

function Get-ClusterInformation {
    Write-LogPhase "Getting Cluster Information"
    
    try {
        $cluster = Get-Cluster
        Write-LogInfo "Connected to cluster: $($cluster.Name)"
        
        $clusterNodes = Get-ClusterNode
        Write-LogInfo "Cluster nodes:"
        foreach ($node in $clusterNodes) {
            Write-LogInfo "  - $($node.Name) (State: $($node.State))"
        }
        
        return $cluster
    }
    catch {
        throw "Failed to get cluster information: $($_.Exception.Message)"
    }
}

function Get-AvailabilityGroupInformation {
    Write-LogPhase "Getting Availability Group Information"
    
    $agName = $script:Config.availabilityGroup.name
    $primaryReplica = $script:Config.sqlServers.nodes[0].vmName
    
    try {
        $connectionString = "Server=$primaryReplica;Integrated Security=True;Database=master"
        
        $query = @"
SELECT 
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ar.endpoint_url AS EndpointUrl,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnectedState,
    ars.synchronization_health_desc AS SynchronizationHealth
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$agName'
ORDER BY ar.replica_server_name
"@
        
        $agInfo = Invoke-Sqlcmd -ConnectionString $connectionString -Query $query
        
        if (-not $agInfo) {
            throw "Availability Group '$agName' not found"
        }
        
        Write-LogInfo "Availability Group '$agName' information:"
        foreach ($replica in $agInfo) {
            Write-LogInfo "  - Replica: $($replica.ReplicaServerName)"
            Write-LogInfo "    Role: $($replica.Role)"
            Write-LogInfo "    State: $($replica.ConnectedState)"
            Write-LogInfo "    Health: $($replica.SynchronizationHealth)"
        }
        
        return $agInfo
    }
    catch {
        throw "Failed to get Availability Group information: $($_.Exception.Message)"
    }
}

function Test-LoadBalancerConfiguration {
    Write-LogPhase "Testing Load Balancer Configuration"
    
    $lbName = $script:Config.loadBalancer.name
    $resourceGroup = $script:Config.deployment.resourceGroupName
    $listenerPort = $script:Config.availabilityGroup.listenerPort
    
    Write-LogInfo "Checking load balancer configuration..."
    Write-LogInfo "Load Balancer: $lbName"
    Write-LogInfo "Resource Group: $resourceGroup"
    Write-LogInfo "Listener Port: $listenerPort"
    
    # Test if load balancer probe port is accessible
    $probePort = 59999  # Standard probe port for SQL Server AG
    
    try {
        $testConnection = Test-NetConnection -ComputerName "localhost" -Port $probePort -WarningAction SilentlyContinue
        if ($testConnection.TcpTestSucceeded) {
            Write-LogInfo "Load balancer probe port $probePort is accessible"
        } else {
            Write-LogWarning "Load balancer probe port $probePort is not accessible"
        }
    }
    catch {
        Write-LogWarning "Could not test load balancer probe port: $($_.Exception.Message)"
    }
}

function Configure-ListenerIPResource {
    Write-LogPhase "Configuring Listener IP Resource"
    
    $listenerName = $script:Config.availabilityGroup.listenerName
    $listenerIP = $script:Config.availabilityGroup.listenerIpAddress
    $subnetMask = $script:Config.network.subnets.sql1.subnetMask -replace "/.*", ""
    $agName = $script:Config.availabilityGroup.name
    
    Write-LogInfo "Configuring IP resource for listener: $listenerName"
    Write-LogInfo "Listener IP: $listenerIP"
    Write-LogInfo "Subnet Mask: $subnetMask"
    
    try {
        # Get the availability group cluster resource
        $agResource = Get-ClusterResource | Where-Object { $_.ResourceType -eq "SQL Server Availability Group" -and $_.Name -like "*$agName*" }
        
        if (-not $agResource) {
            throw "Availability Group cluster resource not found for: $agName"
        }
        
        Write-LogInfo "Found AG cluster resource: $($agResource.Name)"
        
        # Create IP Address resource
        $ipResourceName = "$listenerName IP Address"
        
        # Check if IP resource already exists
        $existingIPResource = Get-ClusterResource -Name $ipResourceName -ErrorAction SilentlyContinue
        
        if ($existingIPResource) {
            Write-LogInfo "IP resource already exists: $ipResourceName"
            $ipResource = $existingIPResource
        } else {
            Write-LogInfo "Creating IP resource: $ipResourceName"
            $ipResource = Add-ClusterResource -Name $ipResourceName -ResourceType "IP Address" -Group $agResource.OwnerGroup
            
            # Configure IP resource properties
            $ipResource | Set-ClusterParameter -Name "Address" -Value $listenerIP
            $ipResource | Set-ClusterParameter -Name "SubnetMask" -Value $subnetMask
            $ipResource | Set-ClusterParameter -Name "EnableDhcp" -Value 0
            
            Write-LogInfo "IP resource created and configured"
        }
        
        # Create Network Name resource
        $networkNameResourceName = "$listenerName Network Name"
        
        # Check if Network Name resource already exists
        $existingNetworkNameResource = Get-ClusterResource -Name $networkNameResourceName -ErrorAction SilentlyContinue
        
        if ($existingNetworkNameResource) {
            Write-LogInfo "Network Name resource already exists: $networkNameResourceName"
            $networkNameResource = $existingNetworkNameResource
        } else {
            Write-LogInfo "Creating Network Name resource: $networkNameResourceName"
            $networkNameResource = Add-ClusterResource -Name $networkNameResourceName -ResourceType "Network Name" -Group $agResource.OwnerGroup
            
            # Configure Network Name resource properties
            $networkNameResource | Set-ClusterParameter -Name "Name" -Value $listenerName
            $networkNameResource | Set-ClusterParameter -Name "DnsName" -Value $listenerName
            
            Write-LogInfo "Network Name resource created and configured"
        }
        
        # Create dependencies
        Write-LogInfo "Creating resource dependencies..."
        Add-ClusterResourceDependency -Resource $networkNameResource.Name -Provider $ipResource.Name
        Add-ClusterResourceDependency -Resource $agResource.Name -Provider $networkNameResource.Name
        
        Write-LogInfo "Listener IP resources configured successfully"
        
        return @{
            IPResource = $ipResource
            NetworkNameResource = $networkNameResource
            AGResource = $agResource
        }
    }
    catch {
        throw "Failed to configure listener IP resource: $($_.Exception.Message)"
    }
}

function Configure-AvailabilityGroupListener {
    Write-LogPhase "Configuring Availability Group Listener"
    
    $agName = $script:Config.availabilityGroup.name
    $listenerName = $script:Config.availabilityGroup.listenerName
    $listenerIP = $script:Config.availabilityGroup.listenerIpAddress
    $listenerPort = $script:Config.availabilityGroup.listenerPort
    $primaryReplica = $script:Config.sqlServers.nodes[0].vmName
    
    try {
        $connectionString = "Server=$primaryReplica;Integrated Security=True;Database=master"
        
        # Check if listener already exists
        $checkListenerQuery = @"
SELECT name 
FROM sys.availability_group_listeners 
WHERE name = '$listenerName'
"@
        
        $existingListener = Invoke-Sqlcmd -ConnectionString $connectionString -Query $checkListenerQuery
        
        if ($existingListener) {
            Write-LogInfo "Availability Group listener already exists: $listenerName"
            
            # Update listener configuration if needed
            $updateListenerQuery = @"
ALTER AVAILABILITY GROUP [$agName]
MODIFY LISTENER '$listenerName' (
    WITH IP (('$listenerIP', '255.255.255.0')),
    PORT = $listenerPort
)
"@
            
            try {
                Invoke-Sqlcmd -ConnectionString $connectionString -Query $updateListenerQuery
                Write-LogInfo "Listener configuration updated"
            }
            catch {
                Write-LogWarning "Could not update listener configuration: $($_.Exception.Message)"
            }
        } else {
            Write-LogInfo "Creating Availability Group listener: $listenerName"
            
            $createListenerQuery = @"
ALTER AVAILABILITY GROUP [$agName]
ADD LISTENER '$listenerName' (
    WITH IP (('$listenerIP', '255.255.255.0')),
    PORT = $listenerPort
)
"@
            
            Invoke-Sqlcmd -ConnectionString $connectionString -Query $createListenerQuery
            Write-LogInfo "Availability Group listener created successfully"
        }
        
        # Verify listener creation
        Start-Sleep -Seconds 10
        
        $verifyListenerQuery = @"
SELECT 
    agl.name AS ListenerName,
    agl.port AS Port,
    aglic.ip_address AS IPAddress,
    aglic.ip_subnet_mask AS SubnetMask,
    aglic.state_desc AS State
FROM sys.availability_group_listeners agl
INNER JOIN sys.availability_group_listener_ip_addresses aglic ON agl.listener_id = aglic.listener_id
WHERE agl.name = '$listenerName'
"@
        
        $listenerInfo = Invoke-Sqlcmd -ConnectionString $connectionString -Query $verifyListenerQuery
        
        if ($listenerInfo) {
            Write-LogInfo "Listener verification successful:"
            Write-LogInfo "  - Name: $($listenerInfo.ListenerName)"
            Write-LogInfo "  - Port: $($listenerInfo.Port)"
            Write-LogInfo "  - IP Address: $($listenerInfo.IPAddress)"
            Write-LogInfo "  - State: $($listenerInfo.State)"
        } else {
            throw "Listener verification failed - listener not found after creation"
        }
    }
    catch {
        throw "Failed to configure Availability Group listener: $($_.Exception.Message)"
    }
}

function Configure-LoadBalancerProbe {
    Write-LogPhase "Configuring Load Balancer Probe"
    
    $probePort = 59999  # Standard probe port for SQL Server AG
    $listenerName = $script:Config.availabilityGroup.listenerName
    
    Write-LogInfo "Configuring load balancer probe on port: $probePort"
    
    try {
        # Get the listener cluster resource
        $listenerResource = Get-ClusterResource | Where-Object { $_.Name -like "*$listenerName*" -and $_.ResourceType -eq "Network Name" }
        
        if (-not $listenerResource) {
            throw "Listener cluster resource not found: $listenerName"
        }
        
        # Configure probe port
        $listenerResource | Set-ClusterParameter -Name "ProbePort" -Value $probePort
        
        Write-LogInfo "Probe port configured on cluster resource"
        
        # Restart the listener resource to apply changes
        Write-LogInfo "Restarting listener resource to apply probe configuration..."
        Stop-ClusterResource -Name $listenerResource.Name -Force
        Start-Sleep -Seconds 5
        Start-ClusterResource -Name $listenerResource.Name
        
        Write-LogInfo "Load balancer probe configured successfully"
    }
    catch {
        throw "Failed to configure load balancer probe: $($_.Exception.Message)"
    }
}

function Test-ListenerConnectivity {
    Write-LogPhase "Testing Listener Connectivity"
    
    $listenerName = $script:Config.availabilityGroup.listenerName
    $listenerPort = $script:Config.availabilityGroup.listenerPort
    $testDatabase = "master"
    
    Write-LogInfo "Testing connectivity to listener: $listenerName"
    
    try {
        # Test network connectivity
        $networkTest = Test-NetConnection -ComputerName $listenerName -Port $listenerPort -WarningAction SilentlyContinue
        
        if ($networkTest.TcpTestSucceeded) {
            Write-LogInfo "Network connectivity test: PASSED"
        } else {
            Write-LogWarning "Network connectivity test: FAILED"
            return $false
        }
        
        # Test SQL Server connectivity
        $connectionString = "Server=$listenerName,$listenerPort;Integrated Security=True;Database=$testDatabase;Connection Timeout=30"
        
        $testQuery = "SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName, GETDATE() AS CurrentTime"
        
        $result = Invoke-Sqlcmd -ConnectionString $connectionString -Query $testQuery -QueryTimeout 30
        
        if ($result) {
            Write-LogInfo "SQL Server connectivity test: PASSED"
            Write-LogInfo "  - Connected to server: $($result.ServerName)"
            Write-LogInfo "  - Database: $($result.DatabaseName)"
            Write-LogInfo "  - Connection time: $($result.CurrentTime)"
            return $true
        } else {
            Write-LogWarning "SQL Server connectivity test: FAILED - No result returned"
            return $false
        }
    }
    catch {
        Write-LogError "Connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Show-ListenerStatus {
    Write-LogPhase "Availability Group Listener Status"
    
    $agName = $script:Config.availabilityGroup.name
    $listenerName = $script:Config.availabilityGroup.listenerName
    $primaryReplica = $script:Config.sqlServers.nodes[0].vmName
    
    try {
        $connectionString = "Server=$primaryReplica;Integrated Security=True;Database=master"
        
        $statusQuery = @"
SELECT 
    ag.name AS AvailabilityGroupName,
    agl.name AS ListenerName,
    agl.port AS Port,
    aglic.ip_address AS IPAddress,
    aglic.state_desc AS IPState,
    agl.is_conformant AS IsConformant,
    agl.ip_configuration_string_from_cluster AS ClusterIPConfig
FROM sys.availability_groups ag
INNER JOIN sys.availability_group_listeners agl ON ag.group_id = agl.group_id
INNER JOIN sys.availability_group_listener_ip_addresses aglic ON agl.listener_id = aglic.listener_id
WHERE ag.name = '$agName' AND agl.name = '$listenerName'
"@
        
        $status = Invoke-Sqlcmd -ConnectionString $connectionString -Query $statusQuery
        
        if ($status) {
            Write-LogInfo "Listener Status Summary:"
            Write-LogInfo "  - Availability Group: $($status.AvailabilityGroupName)"
            Write-LogInfo "  - Listener Name: $($status.ListenerName)"
            Write-LogInfo "  - Port: $($status.Port)"
            Write-LogInfo "  - IP Address: $($status.IPAddress)"
            Write-LogInfo "  - IP State: $($status.IPState)"
            Write-LogInfo "  - Is Conformant: $($status.IsConformant)"
        } else {
            Write-LogWarning "No listener status information found"
        }
        
        # Show cluster resource status
        Write-LogInfo "Cluster Resource Status:"
        $clusterResources = Get-ClusterResource | Where-Object { $_.Name -like "*$listenerName*" }
        
        foreach ($resource in $clusterResources) {
            Write-LogInfo "  - $($resource.Name): $($resource.State) (Owner: $($resource.OwnerNode))"
        }
    }
    catch {
        Write-LogError "Failed to get listener status: $($_.Exception.Message)"
    }
}

function Main {
    try {
        if ($Help) {
            Show-Usage
            return
        }
        
        Initialize-Script
        Test-Prerequisites
        Read-Configuration
        
        if ($ValidateOnly) {
            Write-LogInfo "Validation completed successfully"
            return
        }
        
        # Confirm execution unless forced
        if (-not $Force) {
            $confirmation = Read-Host "This will configure the Availability Group listener. Continue? (y/N)"
            if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
                Write-LogInfo "Operation cancelled by user"
                return
            }
        }
        
        # Main configuration steps
        Get-ClusterInformation
        Get-AvailabilityGroupInformation
        Test-LoadBalancerConfiguration
        Configure-ListenerIPResource
        Configure-AvailabilityGroupListener
        Configure-LoadBalancerProbe
        
        # Test and verify
        Start-Sleep -Seconds 15  # Allow time for resources to stabilize
        
        $connectivityTest = Test-ListenerConnectivity
        Show-ListenerStatus
        
        $endTime = Get-Date
        $duration = $endTime - $script:StartTime
        
        Write-LogPhase "Availability Group Listener Configuration Completed"
        Write-LogInfo "Configuration completed successfully at $endTime"
        Write-LogInfo "Total duration: $($duration.ToString('hh\:mm\:ss'))"
        
        if ($connectivityTest) {
            Write-LogInfo "Listener is ready for use!"
        } else {
            Write-LogWarning "Listener configuration completed but connectivity test failed"
            Write-LogWarning "Please verify network and firewall settings"
        }
        
        Write-LogInfo "Log file saved to: $($script:LogFile)"
        
        # Show next steps
        Write-Host ""
        Write-Host "=============================================================================" -ForegroundColor Cyan
        Write-Host "NEXT STEPS" -ForegroundColor Cyan
        Write-Host "=============================================================================" -ForegroundColor Cyan
        Write-Host "1. Test application connectivity to the listener" -ForegroundColor White
        Write-Host "2. Configure client connection strings to use the listener" -ForegroundColor White
        Write-Host "3. Test failover scenarios to ensure high availability" -ForegroundColor White
        Write-Host "4. Configure monitoring and alerting for the listener" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Write-LogError "Script execution failed: $($_.Exception.Message)"
        Write-LogError "Stack trace: $($_.ScriptStackTrace)"
        exit 1
    }
}

# Execute main function
Main

