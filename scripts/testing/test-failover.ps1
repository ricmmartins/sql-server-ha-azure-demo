# ============================================================================================
# SQL Server HA on Azure - Failover Testing Script
# ============================================================================================
# This script tests failover scenarios for SQL Server Always On Availability Groups
# Author: Manus AI
# Version: 1.0.0
# ============================================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "config.json",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("manual", "automatic", "forced", "all")]
    [string]$FailoverType = "manual",
    
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
SQL Server HA on Azure - Failover Testing Script
============================================================================================

USAGE:
    .\test-failover.ps1 [OPTIONS]

DESCRIPTION:
    Tests various failover scenarios for SQL Server Always On Availability Groups

OPTIONS:
    -ConfigFile <path>      Path to configuration JSON file (default: config.json)
    -FailoverType <type>    Type of failover test: manual, automatic, forced, all
    -ValidateOnly           Validate configuration only, don't perform tests
    -Force                  Force tests without confirmation prompts
    -Help                   Show this help message

FAILOVER TYPES:
    manual                  Test manual failover scenarios
    automatic               Test automatic failover scenarios
    forced                  Test forced failover scenarios
    all                     Test all failover types

EXAMPLES:
    .\test-failover.ps1
    .\test-failover.ps1 -FailoverType manual
    .\test-failover.ps1 -ConfigFile "custom-config.json" -FailoverType all
    .\test-failover.ps1 -ValidateOnly

WARNING:
    Failover tests will temporarily affect availability and should only be run
    in non-production environments or during maintenance windows.

"@
    Write-Host $usage
}

function Initialize-Script {
    Write-LogPhase "Initializing Failover Testing"
    
    # Create logs directory
    $logsDir = Join-Path $PSScriptRoot "..\..\logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    
    # Set log file path
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:LogFile = Join-Path $logsDir "failover-test-$timestamp.log"
    
    Write-LogInfo "Failover testing started at $($script:StartTime)"
    Write-LogInfo "Log file: $($script:LogFile)"
    Write-LogInfo "Configuration file: $ConfigFile"
    Write-LogInfo "Failover type: $FailoverType"
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
    $requiredSections = @("availabilityGroup", "cluster", "sqlServers")
    foreach ($section in $requiredSections) {
        if (-not $script:Config.$section) {
            throw "Missing required configuration section: $section"
        }
    }
    
    Write-LogInfo "Configuration validation completed"
}

function Get-CurrentAGStatus {
    Write-LogPhase "Getting Current Availability Group Status"
    
    $agName = $script:Config.availabilityGroup.name
    $primaryReplica = $script:Config.sqlServers.nodes[0].vmName
    
    try {
        $connectionString = "Server=$primaryReplica;Integrated Security=True;Database=master"
        
        $query = @"
SELECT 
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnectedState,
    ars.synchronization_health_desc AS SynchronizationHealth,
    ars.last_connect_error_description AS LastError
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = '$agName'
ORDER BY ars.role_desc DESC, ar.replica_server_name
"@
        
        $agStatus = Invoke-Sqlcmd -ConnectionString $connectionString -Query $query
        
        if (-not $agStatus) {
            throw "Availability Group '$agName' not found"
        }
        
        Write-LogInfo "Current Availability Group Status:"
        foreach ($replica in $agStatus) {
            Write-LogInfo "  Replica: $($replica.ReplicaServerName)"
            Write-LogInfo "    Role: $($replica.Role)"
            Write-LogInfo "    State: $($replica.ConnectedState)"
            Write-LogInfo "    Health: $($replica.SynchronizationHealth)"
            Write-LogInfo "    Availability Mode: $($replica.AvailabilityMode)"
            Write-LogInfo "    Failover Mode: $($replica.FailoverMode)"
            if ($replica.LastError) {
                Write-LogWarning "    Last Error: $($replica.LastError)"
            }
            Write-LogInfo ""
        }
        
        return $agStatus
    }
    catch {
        throw "Failed to get Availability Group status: $($_.Exception.Message)"
    }
}

function Test-ConnectivityBeforeFailover {
    Write-LogPhase "Testing Connectivity Before Failover"
    
    $listenerName = $script:Config.availabilityGroup.listenerName
    $listenerPort = $script:Config.availabilityGroup.listenerPort
    
    try {
        # Test listener connectivity
        $connectionString = "Server=$listenerName,$listenerPort;Integrated Security=True;Database=master;Connection Timeout=10"
        $testQuery = "SELECT @@SERVERNAME AS ServerName, GETDATE() AS CurrentTime"
        
        $result = Invoke-Sqlcmd -ConnectionString $connectionString -Query $testQuery -QueryTimeout 10
        
        if ($result) {
            Write-LogInfo "Pre-failover connectivity test: PASSED"
            Write-LogInfo "  Connected to: $($result.ServerName)"
            Write-LogInfo "  Connection time: $($result.CurrentTime)"
            return $true
        } else {
            Write-LogError "Pre-failover connectivity test: FAILED"
            return $false
        }
    }
    catch {
        Write-LogError "Pre-failover connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-ManualFailover {
    Write-LogPhase "Testing Manual Failover"
    
    $agName = $script:Config.availabilityGroup.name
    
    try {
        # Get current primary and secondary replicas
        $agStatus = Get-CurrentAGStatus
        $primaryReplica = ($agStatus | Where-Object { $_.Role -eq "PRIMARY" }).ReplicaServerName
        $secondaryReplicas = $agStatus | Where-Object { $_.Role -eq "SECONDARY" -and $_.ConnectedState -eq "CONNECTED" }
        
        if (-not $primaryReplica) {
            throw "No primary replica found"
        }
        
        if ($secondaryReplicas.Count -eq 0) {
            throw "No connected secondary replicas found for failover"
        }
        
        $targetSecondary = $secondaryReplicas[0].ReplicaServerName
        
        Write-LogInfo "Current primary replica: $primaryReplica"
        Write-LogInfo "Target secondary replica: $targetSecondary"
        
        # Perform manual failover
        Write-LogInfo "Initiating manual failover to $targetSecondary..."
        
        $failoverQuery = "ALTER AVAILABILITY GROUP [$agName] FAILOVER"
        $connectionString = "Server=$targetSecondary;Integrated Security=True;Database=master"
        
        $failoverStart = Get-Date
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $failoverQuery -QueryTimeout 60
        $failoverEnd = Get-Date
        
        $failoverDuration = ($failoverEnd - $failoverStart).TotalSeconds
        Write-LogInfo "Failover command completed in $failoverDuration seconds"
        
        # Wait for failover to stabilize
        Write-LogInfo "Waiting for failover to stabilize..."
        Start-Sleep -Seconds 30
        
        # Verify failover
        $newAgStatus = Get-CurrentAGStatus
        $newPrimary = ($newAgStatus | Where-Object { $_.Role -eq "PRIMARY" }).ReplicaServerName
        
        if ($newPrimary -eq $targetSecondary) {
            Write-LogInfo "Manual failover successful!"
            Write-LogInfo "  New primary: $newPrimary"
            Write-LogInfo "  Failover duration: $failoverDuration seconds"
            
            # Test connectivity after failover
            if (Test-ConnectivityAfterFailover) {
                Write-LogInfo "Post-failover connectivity: PASSED"
            } else {
                Write-LogWarning "Post-failover connectivity: FAILED"
            }
            
            # Failback to original primary
            Write-LogInfo "Performing failback to original primary: $primaryReplica"
            Start-Sleep -Seconds 10
            
            $failbackQuery = "ALTER AVAILABILITY GROUP [$agName] FAILOVER"
            $failbackConnectionString = "Server=$primaryReplica;Integrated Security=True;Database=master"
            
            try {
                Invoke-Sqlcmd -ConnectionString $failbackConnectionString -Query $failbackQuery -QueryTimeout 60
                Start-Sleep -Seconds 20
                Write-LogInfo "Failback completed successfully"
            }
            catch {
                Write-LogWarning "Failback failed: $($_.Exception.Message)"
            }
            
            return $true
        } else {
            Write-LogError "Manual failover failed - primary is still: $newPrimary"
            return $false
        }
    }
    catch {
        Write-LogError "Manual failover test failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-AutomaticFailover {
    Write-LogPhase "Testing Automatic Failover Simulation"
    
    Write-LogWarning "Automatic failover testing requires simulating a failure condition"
    Write-LogWarning "This test will temporarily stop SQL Server service on the primary replica"
    
    $agName = $script:Config.availabilityGroup.name
    
    try {
        # Get current primary replica
        $agStatus = Get-CurrentAGStatus
        $primaryReplica = ($agStatus | Where-Object { $_.Role -eq "PRIMARY" }).ReplicaServerName
        $secondaryReplicas = $agStatus | Where-Object { $_.Role -eq "SECONDARY" -and $_.FailoverMode -eq "AUTOMATIC" }
        
        if (-not $primaryReplica) {
            throw "No primary replica found"
        }
        
        if ($secondaryReplicas.Count -eq 0) {
            Write-LogWarning "No secondary replicas configured for automatic failover"
            Write-LogInfo "Automatic failover test skipped"
            return $true
        }
        
        Write-LogInfo "Primary replica: $primaryReplica"
        Write-LogInfo "Secondary replicas with automatic failover:"
        foreach ($secondary in $secondaryReplicas) {
            Write-LogInfo "  - $($secondary.ReplicaServerName)"
        }
        
        # Simulate failure by stopping SQL Server service
        Write-LogInfo "Simulating failure by stopping SQL Server service on primary..."
        
        $stopStart = Get-Date
        Stop-Service -Name "MSSQLSERVER" -Force
        Write-LogInfo "SQL Server service stopped at $stopStart"
        
        # Wait for automatic failover to occur
        Write-LogInfo "Waiting for automatic failover to occur..."
        $maxWaitTime = 120  # 2 minutes
        $waitInterval = 5
        $totalWaited = 0
        $failoverDetected = $false
        
        while ($totalWaited -lt $maxWaitTime -and -not $failoverDetected) {
            Start-Sleep -Seconds $waitInterval
            $totalWaited += $waitInterval
            
            try {
                # Try to connect to a secondary replica to check status
                $secondaryReplica = $secondaryReplicas[0].ReplicaServerName
                $connectionString = "Server=$secondaryReplica;Integrated Security=True;Database=master"
                
                $statusQuery = @"
SELECT 
    replica_server_name,
    role_desc 
FROM sys.dm_hadr_availability_replica_states ars
INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
INNER JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$agName' AND role_desc = 'PRIMARY'
"@
                
                $currentPrimary = Invoke-Sqlcmd -ConnectionString $connectionString -Query $statusQuery -QueryTimeout 10
                
                if ($currentPrimary -and $currentPrimary.replica_server_name -ne $primaryReplica) {
                    $failoverDetected = $true
                    $newPrimary = $currentPrimary.replica_server_name
                    $failoverEnd = Get-Date
                    $failoverDuration = ($failoverEnd - $stopStart).TotalSeconds
                    
                    Write-LogInfo "Automatic failover detected!"
                    Write-LogInfo "  New primary: $newPrimary"
                    Write-LogInfo "  Failover duration: $failoverDuration seconds"
                }
            }
            catch {
                # Expected during failover transition
                Write-LogInfo "Waiting for failover to complete... ($totalWaited seconds)"
            }
        }
        
        # Restart SQL Server service on original primary
        Write-LogInfo "Restarting SQL Server service on original primary..."
        Start-Service -Name "MSSQLSERVER"
        Start-Sleep -Seconds 30
        
        if ($failoverDetected) {
            Write-LogInfo "Automatic failover test: PASSED"
            Write-LogInfo "Failover completed in $failoverDuration seconds"
            
            # Test connectivity after automatic failover
            if (Test-ConnectivityAfterFailover) {
                Write-LogInfo "Post-automatic-failover connectivity: PASSED"
            }
            
            return $true
        } else {
            Write-LogError "Automatic failover test: FAILED - No failover detected within $maxWaitTime seconds"
            return $false
        }
    }
    catch {
        Write-LogError "Automatic failover test failed: $($_.Exception.Message)"
        
        # Ensure SQL Server service is restarted
        try {
            Start-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
        }
        catch {
            Write-LogError "Failed to restart SQL Server service: $($_.Exception.Message)"
        }
        
        return $false
    }
}

function Test-ForcedFailover {
    Write-LogPhase "Testing Forced Failover"
    
    Write-LogWarning "Forced failover testing may result in data loss"
    Write-LogWarning "This test should only be performed in test environments"
    
    $agName = $script:Config.availabilityGroup.name
    
    try {
        # Get current AG status
        $agStatus = Get-CurrentAGStatus
        $primaryReplica = ($agStatus | Where-Object { $_.Role -eq "PRIMARY" }).ReplicaServerName
        $secondaryReplicas = $agStatus | Where-Object { $_.Role -eq "SECONDARY" }
        
        if (-not $primaryReplica) {
            throw "No primary replica found"
        }
        
        if ($secondaryReplicas.Count -eq 0) {
            throw "No secondary replicas found for forced failover"
        }
        
        $targetSecondary = $secondaryReplicas[0].ReplicaServerName
        
        Write-LogInfo "Testing forced failover scenario"
        Write-LogInfo "Primary replica: $primaryReplica"
        Write-LogInfo "Target secondary: $targetSecondary"
        
        # Perform forced failover with data loss
        Write-LogInfo "Initiating forced failover with potential data loss..."
        
        $forcedFailoverQuery = "ALTER AVAILABILITY GROUP [$agName] FORCE_FAILOVER_ALLOW_DATA_LOSS"
        $connectionString = "Server=$targetSecondary;Integrated Security=True;Database=master"
        
        $failoverStart = Get-Date
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $forcedFailoverQuery -QueryTimeout 60
        $failoverEnd = Get-Date
        
        $failoverDuration = ($failoverEnd - $failoverStart).TotalSeconds
        Write-LogInfo "Forced failover command completed in $failoverDuration seconds"
        
        # Wait for forced failover to stabilize
        Start-Sleep -Seconds 30
        
        # Verify forced failover
        $newConnectionString = "Server=$targetSecondary;Integrated Security=True;Database=master"
        $verifyQuery = @"
SELECT 
    replica_server_name,
    role_desc 
FROM sys.dm_hadr_availability_replica_states ars
INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
INNER JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name = '$agName' AND role_desc = 'PRIMARY'
"@
        
        $newPrimary = Invoke-Sqlcmd -ConnectionString $newConnectionString -Query $verifyQuery
        
        if ($newPrimary -and $newPrimary.replica_server_name -eq $targetSecondary) {
            Write-LogInfo "Forced failover successful!"
            Write-LogInfo "  New primary: $($newPrimary.replica_server_name)"
            Write-LogInfo "  Failover duration: $failoverDuration seconds"
            
            # Test connectivity after forced failover
            if (Test-ConnectivityAfterFailover) {
                Write-LogInfo "Post-forced-failover connectivity: PASSED"
            }
            
            # Resume data movement on original primary (now secondary)
            Write-LogInfo "Resuming data movement on original primary..."
            try {
                $resumeQuery = "ALTER DATABASE ALL SET HADR RESUME"
                $originalPrimaryConnection = "Server=$primaryReplica;Integrated Security=True;Database=master"
                Invoke-Sqlcmd -ConnectionString $originalPrimaryConnection -Query $resumeQuery -QueryTimeout 30
                Write-LogInfo "Data movement resumed on original primary"
            }
            catch {
                Write-LogWarning "Failed to resume data movement: $($_.Exception.Message)"
            }
            
            return $true
        } else {
            Write-LogError "Forced failover failed - could not verify new primary"
            return $false
        }
    }
    catch {
        Write-LogError "Forced failover test failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-ConnectivityAfterFailover {
    $listenerName = $script:Config.availabilityGroup.listenerName
    $listenerPort = $script:Config.availabilityGroup.listenerPort
    
    try {
        $connectionString = "Server=$listenerName,$listenerPort;Integrated Security=True;Database=master;Connection Timeout=15"
        $testQuery = "SELECT @@SERVERNAME AS ServerName, GETDATE() AS CurrentTime"
        
        $result = Invoke-Sqlcmd -ConnectionString $connectionString -Query $testQuery -QueryTimeout 15
        
        if ($result) {
            Write-LogInfo "Post-failover connectivity test: PASSED"
            Write-LogInfo "  Connected to: $($result.ServerName)"
            return $true
        } else {
            return $false
        }
    }
    catch {
        Write-LogError "Post-failover connectivity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Generate-FailoverReport {
    Write-LogPhase "Generating Failover Test Report"
    
    $reportFile = Join-Path (Split-Path $script:LogFile) "failover-test-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
    
    $reportContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>SQL Server HA - Failover Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 10px; border-radius: 5px; }
        .success { color: green; font-weight: bold; }
        .error { color: red; font-weight: bold; }
        .warning { color: orange; font-weight: bold; }
        .section { margin: 20px 0; padding: 10px; border-left: 3px solid #ccc; }
        pre { background-color: #f5f5f5; padding: 10px; border-radius: 3px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SQL Server HA - Failover Test Report</h1>
        <p><strong>Generated:</strong> $(Get-Date)</p>
        <p><strong>Test Type:</strong> $FailoverType</p>
        <p><strong>Configuration:</strong> $ConfigFile</p>
        <p><strong>Availability Group:</strong> $($script:Config.availabilityGroup.name)</p>
        <p><strong>Test Duration:</strong> $((Get-Date) - $script:StartTime)</p>
    </div>
    
    <div class="section">
        <h2>Test Results Summary</h2>
        <p>Detailed test results are available in the log file: <code>$($script:LogFile)</code></p>
    </div>
    
    <div class="section">
        <h2>Log Output</h2>
        <pre>$(Get-Content $script:LogFile -Raw)</pre>
    </div>
</body>
</html>
"@
    
    Set-Content -Path $reportFile -Value $reportContent
    Write-LogInfo "Failover test report generated: $reportFile"
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
        
        # Warning about failover tests
        Write-LogWarning "IMPORTANT: Failover tests will temporarily affect availability"
        Write-LogWarning "These tests should only be run in non-production environments"
        Write-LogWarning "or during planned maintenance windows"
        
        # Confirm execution unless forced
        if (-not $Force) {
            $confirmation = Read-Host "Do you want to proceed with failover testing? (y/N)"
            if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
                Write-LogInfo "Failover testing cancelled by user"
                return
            }
        }
        
        # Pre-test connectivity
        if (-not (Test-ConnectivityBeforeFailover)) {
            throw "Pre-test connectivity check failed"
        }
        
        $testResults = @{}
        
        # Execute tests based on type
        switch ($FailoverType) {
            "manual" {
                $testResults["Manual"] = Test-ManualFailover
            }
            "automatic" {
                $testResults["Automatic"] = Test-AutomaticFailover
            }
            "forced" {
                $testResults["Forced"] = Test-ForcedFailover
            }
            "all" {
                $testResults["Manual"] = Test-ManualFailover
                $testResults["Automatic"] = Test-AutomaticFailover
                $testResults["Forced"] = Test-ForcedFailover
            }
        }
        
        # Generate report
        Generate-FailoverReport
        
        # Summary
        $endTime = Get-Date
        $duration = $endTime - $script:StartTime
        
        Write-LogPhase "Failover Testing Completed"
        Write-LogInfo "Testing completed at $endTime"
        Write-LogInfo "Total duration: $($duration.ToString('hh\:mm\:ss'))"
        
        $passedTests = ($testResults.Values | Where-Object { $_ -eq $true }).Count
        $totalTests = $testResults.Count
        
        Write-LogInfo "Test Results Summary: $passedTests/$totalTests tests passed"
        
        foreach ($test in $testResults.GetEnumerator()) {
            $status = if ($test.Value) { "PASSED" } else { "FAILED" }
            Write-LogInfo "  $($test.Key) Failover: $status"
        }
        
        Write-LogInfo "Log file saved to: $($script:LogFile)"
        
        if ($passedTests -eq $totalTests) {
            Write-LogInfo "All failover tests completed successfully!"
        } else {
            Write-LogWarning "Some failover tests failed - review logs for details"
        }
    }
    catch {
        Write-LogError "Failover testing failed: $($_.Exception.Message)"
        Write-LogError "Stack trace: $($_.ScriptStackTrace)"
        exit 1
    }
}

# Execute main function
Main

