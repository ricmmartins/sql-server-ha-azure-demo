# =============================================================================
# SQL Server HA on Azure - Failover Clustering Installation Script
# =============================================================================
# This PowerShell script installs and configures Windows Server Failover
# Clustering on SQL Server VMs
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
Import-Module FailoverClusters -Force -ErrorAction SilentlyContinue

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
    
    # Check SQL Server installation
    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if (-not $sqlService) {
        throw "SQL Server service not found. Ensure SQL Server is installed."
    }
    
    Write-Success "Prerequisites check passed"
}

# Function to install Windows features
function Install-WindowsFeatures {
    Write-Info "Installing Windows Server Failover Clustering feature..."
    
    try {
        # Install Failover Clustering feature
        $feature = Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools
        
        if ($feature.Success) {
            Write-Success "Failover Clustering feature installed successfully"
            
            if ($feature.RestartNeeded -eq "Yes") {
                Write-Warning "A restart is required to complete the installation"
                return $true
            }
        }
        else {
            throw "Failed to install Failover Clustering feature"
        }
    }
    catch {
        throw "Error installing Windows features: $_"
    }
    
    return $false
}

# Function to configure firewall rules
function Set-FirewallRules {
    Write-Info "Configuring Windows Firewall rules for clustering..."
    
    try {
        # Enable Failover Cluster firewall rules
        Enable-NetFirewallRule -DisplayGroup "Failover Clusters"
        
        # Additional rules for SQL Server Always On
        New-NetFirewallRule -DisplayName "SQL Server Always On - Database Mirroring" `
                           -Direction Inbound `
                           -Protocol TCP `
                           -LocalPort 5022 `
                           -Action Allow `
                           -ErrorAction SilentlyContinue
        
        New-NetFirewallRule -DisplayName "SQL Server Always On - Health Probe" `
                           -Direction Inbound `
                           -Protocol TCP `
                           -LocalPort 59999 `
                           -Action Allow `
                           -ErrorAction SilentlyContinue
        
        Write-Success "Firewall rules configured successfully"
    }
    catch {
        Write-Warning "Error configuring firewall rules: $_"
    }
}

# Function to configure service accounts
function Set-ServiceAccounts {
    param($Config)
    
    Write-Info "Configuring service accounts..."
    
    try {
        # Configure SQL Server service account
        $sqlServiceAccount = $Config.serviceAccounts.sqlServiceAccount
        $sqlAgentAccount = $Config.serviceAccounts.sqlAgentAccount
        
        Write-Info "Setting SQL Server service account to: $sqlServiceAccount"
        
        # Stop services
        Stop-Service -Name "MSSQLSERVER" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "SQLSERVERAGENT" -Force -ErrorAction SilentlyContinue
        
        # Configure SQL Server service
        $sqlService = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'"
        if ($sqlService) {
            $result = $sqlService.Change($null, $null, $null, $null, $null, $null, $sqlServiceAccount, "P@ssw0rd123!")
            if ($result.ReturnValue -eq 0) {
                Write-Success "SQL Server service account configured"
            }
            else {
                Write-Warning "Failed to configure SQL Server service account. Return code: $($result.ReturnValue)"
            }
        }
        
        # Configure SQL Agent service
        $agentService = Get-WmiObject -Class Win32_Service -Filter "Name='SQLSERVERAGENT'"
        if ($agentService) {
            $result = $agentService.Change($null, $null, $null, $null, $null, $null, $sqlAgentAccount, "P@ssw0rd123!")
            if ($result.ReturnValue -eq 0) {
                Write-Success "SQL Agent service account configured"
            }
            else {
                Write-Warning "Failed to configure SQL Agent service account. Return code: $($result.ReturnValue)"
            }
        }
        
        # Start services
        Start-Service -Name "MSSQLSERVER"
        Start-Service -Name "SQLSERVERAGENT"
        
        Write-Success "Service accounts configured successfully"
    }
    catch {
        Write-Warning "Error configuring service accounts: $_"
    }
}

# Function to enable Always On Availability Groups
function Enable-AlwaysOnAG {
    Write-Info "Enabling Always On Availability Groups..."
    
    try {
        # Import SQL Server module
        Import-Module SqlServer -Force
        
        # Enable Always On
        Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force
        
        Write-Success "Always On Availability Groups enabled"
        
        # Restart SQL Server service to apply changes
        Write-Info "Restarting SQL Server service..."
        Restart-Service -Name "MSSQLSERVER" -Force
        Start-Sleep -Seconds 30
        Restart-Service -Name "SQLSERVERAGENT" -Force
        
        Write-Success "SQL Server services restarted"
    }
    catch {
        Write-Warning "Error enabling Always On: $_"
    }
}

# Function to configure SQL Server settings
function Set-SqlServerConfiguration {
    Write-Info "Configuring SQL Server settings for Always On..."
    
    try {
        # Import SQL Server module
        Import-Module SqlServer -Force
        
        # Configure SQL Server for Always On
        $sqlCommands = @"
-- Configure SQL Server for Always On
ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT = 'WSFC';

-- Set max server memory (adjust based on VM size - leaving 2GB for OS)
DECLARE @MaxMemoryMB INT = (SELECT (physical_memory_kb / 1024) - 2048 FROM sys.dm_os_sys_info);
EXEC sp_configure 'max server memory (MB)', @MaxMemoryMB;
RECONFIGURE;

-- Enable backup compression
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;

-- Configure database mail
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;

-- Set recovery model for system databases
ALTER DATABASE model SET RECOVERY FULL;

-- Configure tempdb for optimal performance
DECLARE @TempDBFiles INT = (SELECT cpu_count FROM sys.dm_os_sys_info);
IF @TempDBFiles > 8 SET @TempDBFiles = 8;

DECLARE @i INT = 1;
WHILE @i <= @TempDBFiles
BEGIN
    IF @i = 1
    BEGIN
        ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', SIZE = 1024MB, FILEGROWTH = 256MB);
    END
    ELSE
    BEGIN
        DECLARE @FileName NVARCHAR(50) = 'tempdev' + CAST(@i AS NVARCHAR(10));
        DECLARE @PhysicalName NVARCHAR(200) = 'F:\Data\tempdb' + CAST(@i AS NVARCHAR(10)) + '.mdf';
        
        ALTER DATABASE tempdb ADD FILE (
            NAME = @FileName,
            FILENAME = @PhysicalName,
            SIZE = 1024MB,
            FILEGROWTH = 256MB
        );
    END
    SET @i = @i + 1;
END

-- Configure tempdb log file
ALTER DATABASE tempdb MODIFY FILE (NAME = 'templog', SIZE = 512MB, FILEGROWTH = 128MB);

PRINT 'SQL Server configuration completed successfully';
"@
        
        Invoke-Sqlcmd -Query $sqlCommands -ServerInstance $env:COMPUTERNAME
        
        Write-Success "SQL Server configuration completed"
    }
    catch {
        Write-Warning "Error configuring SQL Server: $_"
    }
}

# Function to test cluster readiness
function Test-ClusterReadiness {
    param($Config)
    
    Write-Info "Testing cluster readiness..."
    
    try {
        # Get SQL Server node names
        $nodes = @()
        foreach ($node in $Config.sqlServers.nodes) {
            $nodes += $node.vmName
        }
        
        Write-Info "Testing cluster validation for nodes: $($nodes -join ', ')"
        
        # Test cluster configuration
        $testResult = Test-Cluster -Node $nodes -Include "Inventory", "Network", "System Configuration" -Verbose
        
        if ($testResult) {
            Write-Success "Cluster readiness test completed. Check the validation report for details."
        }
        else {
            Write-Warning "Cluster readiness test completed with warnings. Review the validation report."
        }
    }
    catch {
        Write-Warning "Error during cluster readiness test: $_"
    }
}

# Function to create database mirroring endpoint
function New-DatabaseMirroringEndpoint {
    Write-Info "Creating database mirroring endpoint..."
    
    try {
        $endpointScript = @"
-- Create database mirroring endpoint
IF NOT EXISTS (SELECT * FROM sys.endpoints WHERE name = 'Hadr_endpoint')
BEGIN
    CREATE ENDPOINT Hadr_endpoint
        AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
        FOR DATA_MIRRORING (
            ROLE = ALL,
            AUTHENTICATION = WINDOWS NEGOTIATE,
            ENCRYPTION = REQUIRED ALGORITHM AES
        );
    
    ALTER ENDPOINT Hadr_endpoint STATE = STARTED;
    
    PRINT 'Database mirroring endpoint created and started';
END
ELSE
BEGIN
    ALTER ENDPOINT Hadr_endpoint STATE = STARTED;
    PRINT 'Database mirroring endpoint already exists and is started';
END

-- Grant permissions to service accounts
DECLARE @sql NVARCHAR(MAX);
SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\sqlservice]';
EXEC sp_executesql @sql;

SET @sql = 'GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [CONTOSO\sqlagent]';
EXEC sp_executesql @sql;

PRINT 'Endpoint permissions granted';
"@
        
        Invoke-Sqlcmd -Query $endpointScript -ServerInstance $env:COMPUTERNAME
        
        Write-Success "Database mirroring endpoint created successfully"
    }
    catch {
        Write-Warning "Error creating database mirroring endpoint: $_"
    }
}

# Function to validate installation
function Test-Installation {
    Write-Info "Validating failover clustering installation..."
    
    try {
        # Check if Failover Clustering feature is installed
        $feature = Get-WindowsFeature -Name Failover-Clustering
        if ($feature.InstallState -ne "Installed") {
            throw "Failover Clustering feature is not installed"
        }
        
        # Check if Always On is enabled
        $alwaysOnEnabled = Invoke-Sqlcmd -Query "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsEnabled" -ServerInstance $env:COMPUTERNAME
        if ($alwaysOnEnabled.IsEnabled -ne 1) {
            Write-Warning "Always On Availability Groups is not enabled"
        }
        else {
            Write-Success "Always On Availability Groups is enabled"
        }
        
        # Check database mirroring endpoint
        $endpoint = Invoke-Sqlcmd -Query "SELECT name, state_desc FROM sys.endpoints WHERE type_desc = 'DATABASE_MIRRORING'" -ServerInstance $env:COMPUTERNAME
        if ($endpoint) {
            Write-Success "Database mirroring endpoint exists: $($endpoint.name) - $($endpoint.state_desc)"
        }
        else {
            Write-Warning "Database mirroring endpoint not found"
        }
        
        Write-Success "Installation validation completed"
    }
    catch {
        Write-Error "Installation validation failed: $_"
        return $false
    }
    
    return $true
}

# Main execution function
function Main {
    try {
        Write-Info "============================================================================="
        Write-Info "SQL Server HA on Azure - Failover Clustering Installation"
        Write-Info "============================================================================="
        Write-Info ""
        
        # Load configuration
        $config = Get-Configuration -ConfigPath $ConfigPath
        
        # Check prerequisites
        Test-Prerequisites
        
        # Install Windows features
        $restartRequired = Install-WindowsFeatures
        
        # Configure firewall rules
        Set-FirewallRules
        
        # Configure service accounts
        Set-ServiceAccounts -Config $config
        
        # Enable Always On Availability Groups
        Enable-AlwaysOnAG
        
        # Configure SQL Server settings
        Set-SqlServerConfiguration
        
        # Create database mirroring endpoint
        New-DatabaseMirroringEndpoint
        
        # Test cluster readiness
        Test-ClusterReadiness -Config $config
        
        # Validate installation
        if (Test-Installation) {
            Write-Success "Failover clustering installation completed successfully!"
            Write-Info ""
            Write-Info "Next steps:"
            Write-Info "1. Run this script on all SQL Server nodes"
            Write-Info "2. Run: .\02-create-wsfc-cluster.ps1"
            Write-Info "3. Verify cluster validation passes on all nodes"
            
            if ($restartRequired) {
                Write-Warning ""
                Write-Warning "IMPORTANT: A restart is required to complete the installation"
                Write-Warning "Please restart this server and run the script again if needed"
            }
        }
        else {
            throw "Installation validation failed"
        }
    }
    catch {
        Write-Error "Script execution failed: $_"
        exit 1
    }
}

# Execute main function
Main

