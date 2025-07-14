# =============================================================================
# SQL Server HA on Azure - Enable Always On Availability Groups Script
# =============================================================================
# This PowerShell script enables and configures Always On Availability Groups
# on all SQL Server instances in the cluster
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
    
    # Check if cluster exists
    $clusterName = $Config.cluster.clusterName
    try {
        $cluster = Get-Cluster -Name $clusterName
        Write-Success "Cluster '$clusterName' found and accessible"
    }
    catch {
        throw "Cluster '$clusterName' not found or not accessible. Run 02-create-wsfc-cluster.ps1 first."
    }
    
    # Check SQL Server service
    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if (-not $sqlService) {
        throw "SQL Server service not found"
    }
    
    if ($sqlService.Status -ne "Running") {
        Write-Info "Starting SQL Server service..."
        Start-Service -Name "MSSQLSERVER"
        Start-Sleep -Seconds 30
    }
    
    Write-Success "Prerequisites check passed"
}

# Function to enable Always On Availability Groups
function Enable-AlwaysOnAvailabilityGroups {
    param($Config)
    
    Write-Info "Enabling Always On Availability Groups..."
    
    try {
        # Check if Always On is already enabled
        $alwaysOnStatus = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $env:COMPUTERNAME
        
        if ($alwaysOnStatus.IsEnabled -eq 1) {
            Write-Success "Always On Availability Groups is already enabled"
            return
        }
        
        # Enable Always On
        Write-Info "Enabling Always On Availability Groups on $env:COMPUTERNAME"
        Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force
        
        Write-Success "Always On Availability Groups enabled"
        
        # Restart SQL Server service
        Write-Info "Restarting SQL Server service to apply changes..."
        Restart-Service -Name "MSSQLSERVER" -Force
        Start-Sleep -Seconds 60
        
        # Restart SQL Agent service
        Restart-Service -Name "SQLSERVERAGENT" -Force
        Start-Sleep -Seconds 30
        
        Write-Success "SQL Server services restarted"
        
        # Verify Always On is enabled
        $alwaysOnStatus = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $env:COMPUTERNAME
        if ($alwaysOnStatus.IsEnabled -eq 1) {
            Write-Success "Always On Availability Groups is now enabled"
        }
        else {
            throw "Failed to enable Always On Availability Groups"
        }
    }
    catch {
        throw "Error enabling Always On Availability Groups: $_"
    }
}

# Function to configure database mirroring endpoint
function Set-DatabaseMirroringEndpoint {
    param($Config)
    
    Write-Info "Configuring database mirroring endpoint..."
    
    try {
        $endpointScript = @"
-- Create or configure database mirroring endpoint
IF NOT EXISTS (SELECT * FROM sys.endpoints WHERE name = 'Hadr_endpoint')
BEGIN
    CREATE ENDPOINT Hadr_endpoint
        AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
        FOR DATA_MIRRORING (
            ROLE = ALL,
            AUTHENTICATION = WINDOWS NEGOTIATE,
            ENCRYPTION = REQUIRED ALGORITHM AES
        );
    
    PRINT 'Database mirroring endpoint created';
END
ELSE
BEGIN
    -- Ensure endpoint is properly configured
    ALTER ENDPOINT Hadr_endpoint
        AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
        FOR DATA_MIRRORING (
            ROLE = ALL,
            AUTHENTICATION = WINDOWS NEGOTIATE,
            ENCRYPTION = REQUIRED ALGORITHM AES
        );
    
    PRINT 'Database mirroring endpoint updated';
END

-- Start the endpoint
ALTER ENDPOINT Hadr_endpoint STATE = STARTED;

-- Grant permissions to service accounts
DECLARE @sql NVARCHAR(MAX);

-- Grant to SQL Service account
SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\sqlservice]';
EXEC sp_executesql @sql;

-- Grant to SQL Agent account
SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\sqlagent]';
EXEC sp_executesql @sql;

-- Grant to cluster service account
SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\clusterservice]';
EXEC sp_executesql @sql;

-- Grant to Install account
SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\Install]';
EXEC sp_executesql @sql;

PRINT 'Endpoint permissions granted to service accounts';

-- Verify endpoint status
SELECT 
    name,
    protocol_desc,
    type_desc,
    state_desc,
    port
FROM sys.tcp_endpoints 
WHERE type_desc = 'DATABASE_MIRRORING';
"@
        
        Invoke-Sqlcmd -Query $endpointScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Database mirroring endpoint configured successfully"
    }
    catch {
        throw "Error configuring database mirroring endpoint: $_"
    }
}

# Function to configure SQL Server for Always On
function Set-SqlServerAlwaysOnConfiguration {
    param($Config)
    
    Write-Info "Configuring SQL Server for Always On..."
    
    try {
        $configScript = @"
-- Configure SQL Server for Always On Availability Groups
ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT = 'WSFC';

-- Enable contained databases (optional but recommended)
EXEC sp_configure 'contained database authentication', 1;
RECONFIGURE;

-- Configure backup compression
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;

-- Set max server memory (leave 2GB for OS)
DECLARE @MaxMemoryMB INT;
SELECT @MaxMemoryMB = (physical_memory_kb / 1024) - 2048 
FROM sys.dm_os_sys_info;

EXEC sp_configure 'max server memory (MB)', @MaxMemoryMB;
RECONFIGURE;

-- Configure cost threshold for parallelism
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;

-- Configure max degree of parallelism
DECLARE @MaxDOP INT;
SELECT @MaxDOP = CASE 
    WHEN cpu_count <= 8 THEN cpu_count
    ELSE 8
END
FROM sys.dm_os_sys_info;

EXEC sp_configure 'max degree of parallelism', @MaxDOP;
RECONFIGURE;

-- Enable optimize for ad hoc workloads
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;

-- Configure remote admin connections
EXEC sp_configure 'remote admin connections', 1;
RECONFIGURE;

-- Set model database to FULL recovery
ALTER DATABASE model SET RECOVERY FULL;

PRINT 'SQL Server configuration for Always On completed';
"@
        
        Invoke-Sqlcmd -Query $configScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "SQL Server configured for Always On"
    }
    catch {
        throw "Error configuring SQL Server for Always On: $_"
    }
}

# Function to create sample database
function New-SampleDatabase {
    param($Config)
    
    Write-Info "Creating sample database for Always On demonstration..."
    
    try {
        $databaseName = $Config.availabilityGroup.databases[0]
        
        $createDbScript = @"
-- Check if database already exists
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = '$databaseName')
BEGIN
    -- Create the database
    CREATE DATABASE [$databaseName]
    ON (
        NAME = '${databaseName}_Data',
        FILENAME = 'F:\Data\${databaseName}_Data.mdf',
        SIZE = 1024MB,
        FILEGROWTH = 256MB
    )
    LOG ON (
        NAME = '${databaseName}_Log',
        FILENAME = 'G:\Logs\${databaseName}_Log.ldf',
        SIZE = 256MB,
        FILEGROWTH = 64MB
    );
    
    PRINT 'Database $databaseName created';
END
ELSE
BEGIN
    PRINT 'Database $databaseName already exists';
END

-- Set recovery model to FULL (required for Always On)
ALTER DATABASE [$databaseName] SET RECOVERY FULL;

-- Create some sample tables and data
USE [$databaseName];

-- Create sample table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SampleData')
BEGIN
    CREATE TABLE SampleData (
        ID INT IDENTITY(1,1) PRIMARY KEY,
        Name NVARCHAR(100) NOT NULL,
        Description NVARCHAR(500),
        CreatedDate DATETIME2 DEFAULT GETDATE(),
        ModifiedDate DATETIME2 DEFAULT GETDATE()
    );
    
    -- Insert sample data
    INSERT INTO SampleData (Name, Description)
    VALUES 
        ('Sample Record 1', 'This is a sample record for Always On demonstration'),
        ('Sample Record 2', 'Another sample record to test replication'),
        ('Sample Record 3', 'Third sample record for testing purposes');
    
    PRINT 'Sample table and data created';
END

-- Take a full backup (required before adding to AG)
DECLARE @BackupPath NVARCHAR(500) = 'C:\Backup\${databaseName}_Full.bak';
BACKUP DATABASE [$databaseName] TO DISK = @BackupPath
WITH FORMAT, INIT, COMPRESSION;

PRINT 'Full backup completed: ' + @BackupPath;

-- Take a log backup
SET @BackupPath = 'C:\Backup\${databaseName}_Log.trn';
BACKUP LOG [$databaseName] TO DISK = @BackupPath
WITH FORMAT, INIT, COMPRESSION;

PRINT 'Log backup completed: ' + @BackupPath;
"@
        
        Invoke-Sqlcmd -Query $createDbScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Sample database '$databaseName' created and backed up"
    }
    catch {
        throw "Error creating sample database: $_"
    }
}

# Function to test Always On configuration
function Test-AlwaysOnConfiguration {
    param($Config)
    
    Write-Info "Testing Always On configuration..."
    
    try {
        # Test Always On status
        $alwaysOnStatus = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $env:COMPUTERNAME
        if ($alwaysOnStatus.IsEnabled -ne 1) {
            throw "Always On is not enabled"
        }
        
        # Test cluster connectivity
        $clusterStatus = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsClustered') AS IsClustered" -ServerInstance $env:COMPUTERNAME
        if ($clusterStatus.IsClustered -ne 1) {
            throw "SQL Server is not part of a cluster"
        }
        
        # Test endpoint status
        $endpointStatus = Invoke-Sqlcmd -Query "SELECT name, state_desc FROM sys.endpoints WHERE type_desc = 'DATABASE_MIRRORING'" -ServerInstance $env:COMPUTERNAME
        if (-not $endpointStatus -or $endpointStatus.state_desc -ne "STARTED") {
            throw "Database mirroring endpoint is not started"
        }
        
        # Test sample database
        $databaseName = $Config.availabilityGroup.databases[0]
        $dbStatus = Invoke-Sqlcmd -Query "SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = '$databaseName'" -ServerInstance $env:COMPUTERNAME
        if (-not $dbStatus) {
            throw "Sample database '$databaseName' not found"
        }
        if ($dbStatus.recovery_model_desc -ne "FULL") {
            throw "Sample database is not in FULL recovery model"
        }
        
        Write-Success "Always On configuration test passed"
        return $true
    }
    catch {
        Write-Error "Always On configuration test failed: $_"
        return $false
    }
}

# Function to display configuration summary
function Show-ConfigurationSummary {
    param($Config)
    
    Write-Success "Always On Availability Groups enabled successfully!"
    Write-Info ""
    Write-Info "Configuration Summary:"
    Write-Info "  Server: $env:COMPUTERNAME"
    Write-Info "  Always On: Enabled"
    Write-Info "  Cluster: $($Config.cluster.clusterName)"
    Write-Info "  Endpoint: Hadr_endpoint (Port 5022)"
    Write-Info "  Sample Database: $($Config.availabilityGroup.databases[0])"
    
    # Display endpoint information
    $endpoint = Invoke-Sqlcmd -Query "SELECT name, state_desc, port FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING'" -ServerInstance $env:COMPUTERNAME
    if ($endpoint) {
        Write-Info "  Endpoint Status: $($endpoint.state_desc)"
        Write-Info "  Endpoint Port: $($endpoint.port)"
    }
    
    Write-Info ""
    Write-Info "Next steps:"
    Write-Info "1. Run this script on all SQL Server nodes"
    Write-Info "2. Run: .\04-create-availability-group.ps1"
    Write-Info "3. Verify endpoint connectivity between nodes"
    Write-Info ""
}

# Function to enable Always On on remote nodes
function Enable-AlwaysOnOnRemoteNodes {
    param($Config)
    
    Write-Info "Enabling Always On on remote nodes..."
    
    try {
        foreach ($node in $Config.sqlServers.nodes) {
            $nodeName = $node.vmName
            
            if ($nodeName -ne $env:COMPUTERNAME) {
                Write-Info "Enabling Always On on remote node: $nodeName"
                
                # Create remote session
                $session = New-PSSession -ComputerName $nodeName -Credential (Get-Credential -Message "Enter credentials for $nodeName")
                
                if ($session) {
                    # Copy this script to remote node and execute
                    $scriptBlock = {
                        param($ConfigPath)
                        
                        # Import SQL Server module
                        Import-Module SqlServer -Force
                        
                        # Enable Always On
                        Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force
                        
                        # Restart services
                        Restart-Service -Name "MSSQLSERVER" -Force
                        Start-Sleep -Seconds 60
                        Restart-Service -Name "SQLSERVERAGENT" -Force
                        
                        return "Always On enabled on $env:COMPUTERNAME"
                    }
                    
                    $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $ConfigPath
                    Write-Success $result
                    
                    Remove-PSSession $session
                }
                else {
                    Write-Warning "Could not create remote session to $nodeName"
                }
            }
        }
    }
    catch {
        Write-Warning "Error enabling Always On on remote nodes: $_"
        Write-Info "You may need to run this script manually on each node"
    }
}

# Main execution function
function Main {
    try {
        Write-Info "============================================================================="
        Write-Info "SQL Server HA on Azure - Enable Always On Availability Groups"
        Write-Info "============================================================================="
        Write-Info ""
        
        # Load configuration
        $config = Get-Configuration -ConfigPath $ConfigPath
        
        # Check prerequisites
        Test-Prerequisites -Config $config
        
        # Enable Always On Availability Groups
        Enable-AlwaysOnAvailabilityGroups -Config $config
        
        # Configure database mirroring endpoint
        Set-DatabaseMirroringEndpoint -Config $config
        
        # Configure SQL Server for Always On
        Set-SqlServerAlwaysOnConfiguration -Config $config
        
        # Create sample database
        New-SampleDatabase -Config $config
        
        # Test configuration
        if (Test-AlwaysOnConfiguration -Config $config) {
            Show-ConfigurationSummary -Config $config
            
            # Optionally enable on remote nodes
            if ($Force) {
                Enable-AlwaysOnOnRemoteNodes -Config $config
            }
            else {
                Write-Info "To enable Always On on all nodes automatically, use the -Force parameter"
                Write-Info "Otherwise, run this script manually on each SQL Server node"
            }
        }
        else {
            throw "Always On configuration validation failed"
        }
    }
    catch {
        Write-Error "Script execution failed: $_"
        exit 1
    }
}

# Execute main function
Main

