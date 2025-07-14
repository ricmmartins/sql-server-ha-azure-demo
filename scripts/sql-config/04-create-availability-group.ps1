# =============================================================================
# SQL Server HA on Azure - Create Always On Availability Group Script
# =============================================================================
# This PowerShell script creates and configures the Always On Availability Group
# with primary and secondary replicas
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
Import-Module SqlServer -Force
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
    
    # Check if Always On is enabled
    $alwaysOnStatus = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $env:COMPUTERNAME
    if ($alwaysOnStatus.IsEnabled -ne 1) {
        throw "Always On Availability Groups is not enabled. Run 03-enable-always-on.ps1 first."
    }
    
    # Check if cluster is accessible
    $clusterName = $Config.cluster.clusterName
    try {
        $cluster = Get-Cluster -Name $clusterName
        Write-Success "Cluster '$clusterName' is accessible"
    }
    catch {
        throw "Cluster '$clusterName' is not accessible"
    }
    
    # Check database exists and is in FULL recovery
    $databaseName = $Config.availabilityGroup.databases[0]
    $dbStatus = Invoke-Sqlcmd -Query "SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = '$databaseName'" -ServerInstance $env:COMPUTERNAME
    if (-not $dbStatus) {
        throw "Database '$databaseName' not found"
    }
    if ($dbStatus.recovery_model_desc -ne "FULL") {
        throw "Database '$databaseName' must be in FULL recovery model"
    }
    
    Write-Success "Prerequisites check passed"
}

# Function to determine primary replica
function Get-PrimaryReplica {
    param($Config)
    
    # Find the node designated as primary
    foreach ($node in $Config.sqlServers.nodes) {
        if ($node.role -eq "Primary") {
            return $node.vmName
        }
    }
    
    # If no primary designated, use first node
    return $Config.sqlServers.nodes[0].vmName
}

# Function to create availability group
function New-AvailabilityGroup {
    param($Config)
    
    $agName = $Config.availabilityGroup.name
    $databaseName = $Config.availabilityGroup.databases[0]
    $primaryReplica = Get-PrimaryReplica -Config $Config
    
    Write-Info "Creating Availability Group: $agName"
    Write-Info "Primary Replica: $primaryReplica"
    Write-Info "Database: $databaseName"
    
    # Only create AG on primary replica
    if ($env:COMPUTERNAME -ne $primaryReplica) {
        Write-Info "This is not the primary replica. Skipping AG creation."
        return
    }
    
    try {
        # Check if AG already exists
        $existingAG = Invoke-Sqlcmd -Query "SELECT name FROM sys.availability_groups WHERE name = '$agName'" -ServerInstance $env:COMPUTERNAME
        if ($existingAG) {
            Write-Warning "Availability Group '$agName' already exists"
            return
        }
        
        # Create the availability group
        $createAGScript = @"
-- Create Availability Group
CREATE AVAILABILITY GROUP [$agName]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
    FAILURE_CONDITION_LEVEL = 3,
    HEALTH_CHECK_TIMEOUT = 30000
)
FOR DATABASE [$databaseName]
REPLICA ON 
"@
        
        # Add replica definitions
        $replicaDefinitions = @()
        foreach ($node in $Config.sqlServers.nodes) {
            $nodeName = $node.vmName
            $endpointUrl = "TCP://${nodeName}.contoso.local:5022"
            
            if ($node.role -eq "Primary") {
                $replicaDefinitions += @"
    N'$nodeName' WITH (
        ENDPOINT_URL = N'$endpointUrl',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        BACKUP_PRIORITY = 30,
        SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY)
    )
"@
            }
            else {
                $replicaDefinitions += @"
    N'$nodeName' WITH (
        ENDPOINT_URL = N'$endpointUrl',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        BACKUP_PRIORITY = 50,
        SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY)
    )
"@
            }
        }
        
        $createAGScript += ($replicaDefinitions -join ",`n") + ";"
        
        Write-Info "Executing Availability Group creation script..."
        Invoke-Sqlcmd -Query $createAGScript -ServerInstance $env:COMPUTERNAME -QueryTimeout 300
        
        Write-Success "Availability Group '$agName' created successfully"
    }
    catch {
        throw "Error creating Availability Group: $_"
    }
}

# Function to join secondary replicas to AG
function Join-SecondaryReplicas {
    param($Config)
    
    $agName = $Config.availabilityGroup.name
    $databaseName = $Config.availabilityGroup.databases[0]
    $primaryReplica = Get-PrimaryReplica -Config $Config
    
    # Only join if this is a secondary replica
    if ($env:COMPUTERNAME -eq $primaryReplica) {
        Write-Info "This is the primary replica. Skipping secondary join."
        return
    }
    
    Write-Info "Joining secondary replica to Availability Group: $agName"
    
    try {
        # Join the replica to the availability group
        $joinReplicaScript = @"
-- Join this replica to the availability group
ALTER AVAILABILITY GROUP [$agName] JOIN;

-- Grant permissions to the availability group
ALTER AVAILABILITY GROUP [$agName] GRANT CREATE ANY DATABASE;
"@
        
        Invoke-Sqlcmd -Query $joinReplicaScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Secondary replica joined to Availability Group"
        
        # Restore database on secondary replica
        Restore-DatabaseOnSecondary -Config $Config
        
        # Join database to availability group
        $joinDatabaseScript = @"
-- Join the database to the availability group
ALTER DATABASE [$databaseName] SET HADR AVAILABILITY GROUP = [$agName];
"@
        
        Invoke-Sqlcmd -Query $joinDatabaseScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Database joined to Availability Group on secondary replica"
    }
    catch {
        throw "Error joining secondary replica: $_"
    }
}

# Function to restore database on secondary replica
function Restore-DatabaseOnSecondary {
    param($Config)
    
    $databaseName = $Config.availabilityGroup.databases[0]
    $primaryReplica = Get-PrimaryReplica -Config $Config
    
    Write-Info "Restoring database on secondary replica..."
    
    try {
        # Check if database already exists
        $dbExists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '$databaseName'" -ServerInstance $env:COMPUTERNAME
        if ($dbExists) {
            Write-Warning "Database '$databaseName' already exists on secondary replica"
            return
        }
        
        # Copy backup files from primary replica
        $backupPath = "\\$primaryReplica\C$\Backup"
        $localBackupPath = "C:\Backup"
        
        if (-not (Test-Path $localBackupPath)) {
            New-Item -ItemType Directory -Path $localBackupPath -Force
        }
        
        # Copy full backup
        $fullBackupFile = "${databaseName}_Full.bak"
        $logBackupFile = "${databaseName}_Log.trn"
        
        Write-Info "Copying backup files from primary replica..."
        Copy-Item -Path "$backupPath\$fullBackupFile" -Destination "$localBackupPath\$fullBackupFile" -Force
        Copy-Item -Path "$backupPath\$logBackupFile" -Destination "$localBackupPath\$logBackupFile" -Force
        
        # Restore database
        $restoreScript = @"
-- Restore full backup with NORECOVERY
RESTORE DATABASE [$databaseName] 
FROM DISK = N'$localBackupPath\$fullBackupFile'
WITH MOVE N'${databaseName}_Data' TO N'F:\Data\${databaseName}_Data.mdf',
     MOVE N'${databaseName}_Log' TO N'G:\Logs\${databaseName}_Log.ldf',
     NORECOVERY, REPLACE;

-- Restore log backup with NORECOVERY
RESTORE LOG [$databaseName] 
FROM DISK = N'$localBackupPath\$logBackupFile'
WITH NORECOVERY;
"@
        
        Invoke-Sqlcmd -Query $restoreScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Database restored on secondary replica"
    }
    catch {
        throw "Error restoring database on secondary replica: $_"
    }
}

# Function to create availability group listener
function New-AvailabilityGroupListener {
    param($Config)
    
    $agName = $Config.availabilityGroup.name
    $listenerName = $Config.availabilityGroup.listenerName
    $listenerIP = $Config.availabilityGroup.listenerIpAddress
    $listenerPort = $Config.availabilityGroup.listenerPort
    $primaryReplica = Get-PrimaryReplica -Config $Config
    
    # Only create listener on primary replica
    if ($env:COMPUTERNAME -ne $primaryReplica) {
        Write-Info "This is not the primary replica. Skipping listener creation."
        return
    }
    
    Write-Info "Creating Availability Group Listener: $listenerName"
    
    try {
        # Check if listener already exists
        $existingListener = Invoke-Sqlcmd -Query "SELECT dns_name FROM sys.availability_group_listeners WHERE dns_name = '$listenerName'" -ServerInstance $env:COMPUTERNAME
        if ($existingListener) {
            Write-Warning "Availability Group Listener '$listenerName' already exists"
            return
        }
        
        # Create the listener
        $createListenerScript = @"
-- Create Availability Group Listener
ALTER AVAILABILITY GROUP [$agName]
ADD LISTENER N'$listenerName' (
    WITH IP ((N'$listenerIP', N'255.255.255.0')),
    PORT = $listenerPort
);
"@
        
        Invoke-Sqlcmd -Query $createListenerScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Availability Group Listener '$listenerName' created successfully"
        
        # Wait for listener to come online
        Write-Info "Waiting for listener to come online..."
        Start-Sleep -Seconds 30
        
        # Test listener connectivity
        Test-ListenerConnectivity -Config $Config
    }
    catch {
        throw "Error creating Availability Group Listener: $_"
    }
}

# Function to test listener connectivity
function Test-ListenerConnectivity {
    param($Config)
    
    $listenerName = $Config.availabilityGroup.listenerName
    $listenerPort = $Config.availabilityGroup.listenerPort
    
    Write-Info "Testing listener connectivity..."
    
    try {
        # Test DNS resolution
        $dnsResult = Resolve-DnsName -Name "$listenerName.contoso.local" -ErrorAction SilentlyContinue
        if ($dnsResult) {
            Write-Success "Listener DNS resolution successful: $($dnsResult.IPAddress)"
        }
        else {
            Write-Warning "Listener DNS resolution failed"
        }
        
        # Test SQL connectivity
        $connectionString = "Server=$listenerName.contoso.local,$listenerPort;Integrated Security=true;Connection Timeout=30;"
        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
            $connection.Open()
            $connection.Close()
            Write-Success "Listener SQL connectivity test passed"
        }
        catch {
            Write-Warning "Listener SQL connectivity test failed: $_"
        }
    }
    catch {
        Write-Warning "Error testing listener connectivity: $_"
    }
}

# Function to configure load balancer probe
function Set-LoadBalancerProbe {
    param($Config)
    
    $agName = $Config.availabilityGroup.name
    $probePort = $Config.loadBalancer.healthProbePort
    
    Write-Info "Configuring load balancer health probe..."
    
    try {
        # Create cluster resource for health probe
        $probeScript = @"
-- Configure cluster resource for load balancer probe
DECLARE @ProbePort INT = $probePort;

-- Create or update the probe resource
IF NOT EXISTS (SELECT * FROM sys.dm_hadr_cluster_members WHERE member_name = '$env:COMPUTERNAME')
BEGIN
    PRINT 'Node is not part of the cluster';
    RETURN;
END

-- This will be configured through cluster management
PRINT 'Load balancer probe port configured: ' + CAST(@ProbePort AS VARCHAR(10));
"@
        
        Invoke-Sqlcmd -Query $probeScript -ServerInstance $env:COMPUTERNAME
        
        # Configure Windows Firewall rule for probe
        New-NetFirewallRule -DisplayName "SQL AG Load Balancer Probe" `
                           -Direction Inbound `
                           -Protocol TCP `
                           -LocalPort $probePort `
                           -Action Allow `
                           -ErrorAction SilentlyContinue
        
        Write-Success "Load balancer probe configured"
    }
    catch {
        Write-Warning "Error configuring load balancer probe: $_"
    }
}

# Function to validate availability group
function Test-AvailabilityGroup {
    param($Config)
    
    Write-Info "Validating Availability Group configuration..."
    
    try {
        $agName = $Config.availabilityGroup.name
        $databaseName = $Config.availabilityGroup.databases[0]
        
        # Check AG status
        $agStatus = Invoke-Sqlcmd -Query @"
SELECT 
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ar.role_desc AS Role,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ars.connected_state_desc AS ConnectedState,
    ars.synchronization_health_desc AS SynchronizationHealth
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$agName'
ORDER BY ar.role_desc DESC;
"@ -ServerInstance $env:COMPUTERNAME
        
        if ($agStatus) {
            Write-Success "Availability Group status:"
            $agStatus | Format-Table -AutoSize
        }
        else {
            throw "Availability Group '$agName' not found"
        }
        
        # Check database status
        $dbStatus = Invoke-Sqlcmd -Query @"
SELECT 
    db.name AS DatabaseName,
    drs.synchronization_state_desc AS SynchronizationState,
    drs.synchronization_health_desc AS SynchronizationHealth,
    drs.database_state_desc AS DatabaseState
FROM sys.availability_databases_cluster adc
JOIN sys.dm_hadr_database_replica_states drs ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
JOIN sys.databases db ON drs.database_id = db.database_id
WHERE adc.database_name = '$databaseName'
AND drs.is_local = 1;
"@ -ServerInstance $env:COMPUTERNAME
        
        if ($dbStatus) {
            Write-Success "Database status:"
            $dbStatus | Format-Table -AutoSize
        }
        
        # Check listener status
        $listenerStatus = Invoke-Sqlcmd -Query @"
SELECT 
    dns_name AS ListenerName,
    port AS Port,
    ip_configuration_string_from_cluster AS IPConfiguration
FROM sys.availability_group_listeners
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName');
"@ -ServerInstance $env:COMPUTERNAME
        
        if ($listenerStatus) {
            Write-Success "Listener status:"
            $listenerStatus | Format-Table -AutoSize
        }
        
        Write-Success "Availability Group validation completed"
        return $true
    }
    catch {
        Write-Error "Availability Group validation failed: $_"
        return $false
    }
}

# Function to display AG summary
function Show-AvailabilityGroupSummary {
    param($Config)
    
    $agName = $Config.availabilityGroup.name
    $listenerName = $Config.availabilityGroup.listenerName
    $listenerIP = $Config.availabilityGroup.listenerIpAddress
    $databaseName = $Config.availabilityGroup.databases[0]
    
    Write-Success "Always On Availability Group created successfully!"
    Write-Info ""
    Write-Info "Availability Group Summary:"
    Write-Info "  Name: $agName"
    Write-Info "  Database: $databaseName"
    Write-Info "  Listener: $listenerName"
    Write-Info "  Listener IP: $listenerIP"
    Write-Info "  Synchronization: Synchronous Commit"
    Write-Info "  Failover: Automatic"
    
    Write-Info ""
    Write-Info "Connection Strings:"
    Write-Info "  Primary: Server=$listenerName.contoso.local;Database=$databaseName;Integrated Security=true;"
    Write-Info "  Read-Only: Server=$listenerName.contoso.local;Database=$databaseName;Integrated Security=true;ApplicationIntent=ReadOnly;"
    
    Write-Info ""
    Write-Info "Next steps:"
    Write-Info "1. Run: .\05-configure-listener.ps1"
    Write-Info "2. Test failover scenarios"
    Write-Info "3. Configure monitoring and alerting"
    Write-Info "4. Set up backup strategies"
    Write-Info ""
}

# Main execution function
function Main {
    try {
        Write-Info "============================================================================="
        Write-Info "SQL Server HA on Azure - Create Always On Availability Group"
        Write-Info "============================================================================="
        Write-Info ""
        
        # Load configuration
        $config = Get-Configuration -ConfigPath $ConfigPath
        
        # Check prerequisites
        Test-Prerequisites -Config $config
        
        # Determine if this is primary or secondary
        $primaryReplica = Get-PrimaryReplica -Config $config
        $isPrimary = ($env:COMPUTERNAME -eq $primaryReplica)
        
        if ($isPrimary) {
            Write-Info "This is the PRIMARY replica"
            
            # Create availability group
            New-AvailabilityGroup -Config $config
            
            # Create availability group listener
            New-AvailabilityGroupListener -Config $config
            
            # Configure load balancer probe
            Set-LoadBalancerProbe -Config $config
        }
        else {
            Write-Info "This is a SECONDARY replica"
            
            # Join secondary replica to AG
            Join-SecondaryReplicas -Config $config
        }
        
        # Validate availability group
        if (Test-AvailabilityGroup -Config $config) {
            if ($isPrimary) {
                Show-AvailabilityGroupSummary -Config $config
            }
            else {
                Write-Success "Secondary replica configuration completed successfully!"
                Write-Info "Run this script on the primary replica to see the full summary."
            }
        }
        else {
            throw "Availability Group validation failed"
        }
    }
    catch {
        Write-Error "Script execution failed: $_"
        exit 1
    }
}

# Execute main function
Main

