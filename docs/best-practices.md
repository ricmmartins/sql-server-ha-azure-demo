# SQL Server HA on Azure - Best Practices Guide

This guide outlines best practices for deploying, configuring, and maintaining SQL Server High Availability solutions on Azure.

## Table of Contents

1. [Planning and Design](#planning-and-design)
2. [Azure Infrastructure Best Practices](#azure-infrastructure-best-practices)
3. [SQL Server Configuration](#sql-server-configuration)
4. [Always On Availability Groups](#always-on-availability-groups)
5. [Security Best Practices](#security-best-practices)
6. [Performance Optimization](#performance-optimization)
7. [Monitoring and Maintenance](#monitoring-and-maintenance)
8. [Backup and Recovery](#backup-and-recovery)
9. [Cost Optimization](#cost-optimization)
10. [Operational Excellence](#operational-excellence)

## Planning and Design

### Capacity Planning

**Right-size your VMs:**
- Start with recommended VM sizes based on workload requirements
- Use Azure VM sizing recommendations for SQL Server workloads
- Consider memory-optimized VMs (E-series) for OLTP workloads
- Use compute-optimized VMs (F-series) for CPU-intensive workloads

**Storage Planning:**
- Use Premium SSD for data and log files
- Separate data, log, and tempdb on different drives
- Size storage based on IOPS and throughput requirements
- Plan for growth with appropriate storage scaling

**Network Design:**
- Use dedicated subnets for different tiers (domain, SQL, witness)
- Implement proper network security groups
- Plan for cross-region connectivity if needed
- Consider ExpressRoute for hybrid scenarios

### High Availability Design Patterns

**Multi-Region Deployment:**
```
Primary Region (East US):
├── Primary Replica (Synchronous)
├── Secondary Replica (Synchronous)
└── Witness Server

Secondary Region (West US):
└── DR Replica (Asynchronous)
```

**Single Region with Availability Zones:**
```
Region (East US):
├── Zone 1: Primary Replica
├── Zone 2: Secondary Replica
└── Zone 3: Witness Server
```

## Azure Infrastructure Best Practices

### Virtual Machine Configuration

**VM Sizing Guidelines:**
- **Development/Test:** Standard_D2s_v3 or Standard_D4s_v3
- **Production OLTP:** Standard_E4s_v3 to Standard_E64s_v3
- **Data Warehouse:** Standard_M series for large memory requirements
- **Always use SSD-based VM sizes (s-series)**

**VM Configuration:**
```bash
# Recommended VM configuration
az vm create \
  --resource-group "sql-ha-rg" \
  --name "sql-vm-01" \
  --size "Standard_E8s_v3" \
  --image "MicrosoftSQLServer:sql2022-ws2022:enterprise:latest" \
  --admin-username "azureuser" \
  --generate-ssh-keys \
  --storage-sku "Premium_LRS" \
  --os-disk-size-gb 128 \
  --data-disk-sizes-gb 1023 1023 512 \
  --accelerated-networking true \
  --availability-set "sql-avset"
```

### Storage Best Practices

**Disk Configuration:**
- **OS Disk:** Premium SSD, 128 GB minimum
- **Data Disk:** Premium SSD, size based on requirements
- **Log Disk:** Premium SSD, 25-30% of data disk size
- **TempDB Disk:** Premium SSD or local SSD

**Storage Layout:**
```
C:\ - OS (Premium SSD, 128 GB)
D:\ - TempDB (Local SSD or Premium SSD)
E:\ - Data Files (Premium SSD, striped if multiple disks)
F:\ - Log Files (Premium SSD)
G:\ - Backup (Standard SSD or Premium SSD)
```

**Disk Striping for Performance:**
```powershell
# Create striped volume for data files
New-StoragePool -FriendlyName "DataPool" -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
New-VirtualDisk -FriendlyName "DataDisk" -StoragePoolFriendlyName "DataPool" -Size 2TB -ResiliencySettingName Simple -NumberOfColumns 2
Initialize-Disk -VirtualDisk (Get-VirtualDisk -FriendlyName "DataDisk")
New-Partition -DiskNumber 2 -UseMaximumSize -DriveLetter E
Format-Volume -DriveLetter E -FileSystem NTFS -AllocationUnitSize 64KB -NewFileSystemLabel "Data"
```

### Network Configuration

**Subnet Design:**
```json
{
  "virtualNetwork": {
    "addressSpace": "10.0.0.0/16",
    "subnets": {
      "domain": "10.0.1.0/24",
      "sql-primary": "10.0.2.0/24",
      "sql-secondary": "10.0.3.0/24",
      "witness": "10.0.4.0/24",
      "management": "10.0.10.0/24"
    }
  }
}
```

**Network Security Groups:**
```bash
# Create NSG with minimal required rules
az network nsg create --resource-group "sql-ha-rg" --name "sql-nsg"

# Allow RDP (restrict source IP ranges in production)
az network nsg rule create --resource-group "sql-ha-rg" --nsg-name "sql-nsg" \
  --name "AllowRDP" --priority 1000 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 3389 --source-address-prefixes "10.0.0.0/16"

# Allow SQL Server
az network nsg rule create --resource-group "sql-ha-rg" --nsg-name "sql-nsg" \
  --name "AllowSQL" --priority 1100 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 1433 --source-address-prefixes "10.0.0.0/16"

# Allow Always On endpoint
az network nsg rule create --resource-group "sql-ha-rg" --nsg-name "sql-nsg" \
  --name "AllowAGEndpoint" --priority 1200 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 5022 --source-address-prefixes "10.0.0.0/16"
```

## SQL Server Configuration

### Instance Configuration

**SQL Server Settings:**
```sql
-- Configure max server memory (leave 2-4 GB for OS)
EXEC sp_configure 'max server memory (MB)', 28672; -- For 32 GB VM
RECONFIGURE;

-- Enable backup compression
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;

-- Configure max degree of parallelism
EXEC sp_configure 'max degree of parallelism', 4; -- Adjust based on cores
RECONFIGURE;

-- Configure cost threshold for parallelism
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;

-- Enable optimize for ad hoc workloads
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;
```

**TempDB Configuration:**
```sql
-- Configure TempDB files (1 file per core, up to 8 files)
ALTER DATABASE tempdb MODIFY FILE (NAME = 'tempdev', SIZE = 1024MB, FILEGROWTH = 256MB);
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev2', FILENAME = 'D:\TempDB\tempdb2.mdf', SIZE = 1024MB, FILEGROWTH = 256MB);
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev3', FILENAME = 'D:\TempDB\tempdb3.mdf', SIZE = 1024MB, FILEGROWTH = 256MB);
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev4', FILENAME = 'D:\TempDB\tempdb4.mdf', SIZE = 1024MB, FILEGROWTH = 256MB);

-- Configure TempDB log file
ALTER DATABASE tempdb MODIFY FILE (NAME = 'templog', SIZE = 256MB, FILEGROWTH = 64MB);
```

### Database Configuration

**Database Settings for Always On:**
```sql
-- Set database to full recovery model
ALTER DATABASE [YourDatabase] SET RECOVERY FULL;

-- Configure auto-growth settings
ALTER DATABASE [YourDatabase] MODIFY FILE (NAME = 'YourDatabase', FILEGROWTH = 256MB);
ALTER DATABASE [YourDatabase] MODIFY FILE (NAME = 'YourDatabase_Log', FILEGROWTH = 64MB);

-- Enable page verification
ALTER DATABASE [YourDatabase] SET PAGE_VERIFY CHECKSUM;

-- Configure auto-close and auto-shrink (disable for production)
ALTER DATABASE [YourDatabase] SET AUTO_CLOSE OFF;
ALTER DATABASE [YourDatabase] SET AUTO_SHRINK OFF;
```

## Always On Availability Groups

### Replica Configuration

**Primary Replica Settings:**
```sql
-- Create availability group with proper settings
CREATE AVAILABILITY GROUP [AG-Production]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
    FAILURE_CONDITION_LEVEL = 3,
    HEALTH_CHECK_TIMEOUT = 30000
)
FOR DATABASE [Database1], [Database2]
REPLICA ON 
    'SQL-PRIMARY' WITH (
        ENDPOINT_URL = 'TCP://sql-primary.contoso.local:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        BACKUP_PRIORITY = 30,
        SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY)
    ),
    'SQL-SECONDARY' WITH (
        ENDPOINT_URL = 'TCP://sql-secondary.contoso.local:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        BACKUP_PRIORITY = 50,
        SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY)
    ),
    'SQL-DR' WITH (
        ENDPOINT_URL = 'TCP://sql-dr.contoso.local:5022',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        BACKUP_PRIORITY = 10,
        SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY)
    );
```

**Listener Configuration:**
```sql
-- Create listener with proper IP configuration
ALTER AVAILABILITY GROUP [AG-Production]
ADD LISTENER 'AG-Listener' (
    WITH IP (('10.0.2.100', '255.255.255.0'), ('10.0.3.100', '255.255.255.0')),
    PORT = 1433
);
```

### Endpoint Security

**Create secure endpoints:**
```sql
-- Create endpoint with Windows authentication
CREATE ENDPOINT [Hadr_endpoint]
AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
FOR DATA_MIRRORING (
    ROLE = ALL,
    AUTHENTICATION = WINDOWS NEGOTIATE,
    ENCRYPTION = REQUIRED ALGORITHM AES
);

ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;

-- Grant permissions to service account
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [CONTOSO\SQLService];
```

## Security Best Practices

### Authentication and Authorization

**Service Accounts:**
- Use dedicated domain service accounts for SQL Server services
- Follow principle of least privilege
- Use Managed Service Accounts where possible
- Regularly rotate service account passwords

**SQL Server Security:**
```sql
-- Disable sa account
ALTER LOGIN sa DISABLE;

-- Create dedicated admin account
CREATE LOGIN [CONTOSO\SQLAdmins] FROM WINDOWS;
ALTER SERVER ROLE sysadmin ADD MEMBER [CONTOSO\SQLAdmins];

-- Create application login with minimal permissions
CREATE LOGIN [AppUser] WITH PASSWORD = 'StrongPassword123!';
CREATE USER [AppUser] FOR LOGIN [AppUser];
ALTER ROLE db_datareader ADD MEMBER [AppUser];
ALTER ROLE db_datawriter ADD MEMBER [AppUser];
```

### Network Security

**Firewall Configuration:**
```powershell
# Configure Windows Firewall
New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
New-NetFirewallRule -DisplayName "SQL Browser" -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow
New-NetFirewallRule -DisplayName "Always On Endpoint" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow
```

**SSL/TLS Configuration:**
```sql
-- Force encryption for connections
EXEC xp_instance_regwrite 
    N'HKEY_LOCAL_MACHINE', 
    N'SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib', 
    N'ForceEncryption', 
    REG_DWORD, 
    1;
```

### Data Protection

**Transparent Data Encryption (TDE):**
```sql
-- Create master key
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'StrongPassword123!';

-- Create certificate
CREATE CERTIFICATE TDECert WITH SUBJECT = 'TDE Certificate';

-- Create database encryption key
USE [YourDatabase];
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDECert;

-- Enable TDE
ALTER DATABASE [YourDatabase] SET ENCRYPTION ON;
```

## Performance Optimization

### Storage Performance

**Disk Configuration:**
- Use Premium SSD for all SQL Server files
- Separate data, log, and tempdb on different disks
- Use disk striping for large databases
- Enable read caching for data disks
- Disable caching for log disks

**File Placement:**
```sql
-- Optimal file placement
ALTER DATABASE [YourDatabase] 
MODIFY FILE (NAME = 'YourDatabase', FILENAME = 'E:\Data\YourDatabase.mdf');

ALTER DATABASE [YourDatabase] 
MODIFY FILE (NAME = 'YourDatabase_Log', FILENAME = 'F:\Logs\YourDatabase.ldf');

-- Add multiple data files for large databases
ALTER DATABASE [YourDatabase] 
ADD FILE (NAME = 'YourDatabase_Data2', FILENAME = 'E:\Data\YourDatabase_Data2.ndf', SIZE = 1GB, FILEGROWTH = 256MB);
```

### Query Performance

**Index Maintenance:**
```sql
-- Create index maintenance plan
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql = @sql + 
    'ALTER INDEX ' + i.name + ' ON ' + SCHEMA_NAME(t.schema_id) + '.' + t.name + 
    CASE 
        WHEN avg_fragmentation_in_percent > 30 THEN ' REBUILD;' + CHAR(13)
        WHEN avg_fragmentation_in_percent > 10 THEN ' REORGANIZE;' + CHAR(13)
        ELSE ''
    END
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE avg_fragmentation_in_percent > 10 AND i.index_id > 0;

EXEC sp_executesql @sql;
```

**Statistics Maintenance:**
```sql
-- Update statistics with full scan
EXEC sp_MSforeachtable 'UPDATE STATISTICS ? WITH FULLSCAN';

-- Enable auto-update statistics asynchronously
ALTER DATABASE [YourDatabase] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
```

### Memory Optimization

**Buffer Pool Configuration:**
```sql
-- Monitor buffer pool usage
SELECT 
    DB_NAME(database_id) AS DatabaseName,
    COUNT(*) * 8 / 1024 AS BufferPoolSizeMB
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY BufferPoolSizeMB DESC;

-- Configure max server memory appropriately
-- Leave 2-4 GB for OS, more for large VMs
EXEC sp_configure 'max server memory (MB)', 28672; -- For 32 GB VM
RECONFIGURE;
```

## Monitoring and Maintenance

### Performance Monitoring

**Key Performance Counters:**
```powershell
# PowerShell script to monitor key counters
$counters = @(
    "\SQLServer:Buffer Manager\Page life expectancy",
    "\SQLServer:Buffer Manager\Buffer cache hit ratio",
    "\SQLServer:SQL Statistics\Batch Requests/sec",
    "\SQLServer:SQL Statistics\SQL Compilations/sec",
    "\SQLServer:Locks(_Total)\Lock Waits/sec",
    "\SQLServer:Access Methods\Page Splits/sec",
    "\SQLServer:Availability Replica(*)\Bytes Sent to Replica/sec",
    "\SQLServer:Database Replica(*)\Log Send Queue",
    "\SQLServer:Database Replica(*)\Redo Queue"
)

Get-Counter -Counter $counters -SampleInterval 60 -MaxSamples 1440 | 
Export-Counter -Path "C:\PerfLogs\SQLPerf_$(Get-Date -Format 'yyyyMMdd').blg"
```

**Always On Monitoring:**
```sql
-- Monitor AG health
SELECT 
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ars.role_desc AS Role,
    ars.connected_state_desc AS ConnectedState,
    ars.synchronization_health_desc AS SynchronizationHealth,
    drs.database_name AS DatabaseName,
    drs.synchronization_state_desc AS SynchronizationState,
    drs.log_send_queue_size AS LogSendQueueKB,
    drs.redo_queue_size AS RedoQueueKB
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON ar.replica_id = drs.replica_id
ORDER BY ag.name, ar.replica_server_name, drs.database_name;
```

### Automated Maintenance

**Maintenance Plan Tasks:**
```sql
-- Create maintenance plan for index optimization
DECLARE @MaintenanceSQL NVARCHAR(MAX) = '
-- Update statistics
EXEC sp_updatestats;

-- Rebuild/reorganize indexes
EXEC sp_MSforeachtable ''
    DECLARE @fragmentation FLOAT;
    SELECT @fragmentation = avg_fragmentation_in_percent 
    FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(''''?''''), NULL, NULL, ''''LIMITED'''')
    WHERE index_id = 1;
    
    IF @fragmentation > 30
        ALTER INDEX ALL ON ? REBUILD;
    ELSE IF @fragmentation > 10
        ALTER INDEX ALL ON ? REORGANIZE;
'';

-- Backup databases
BACKUP DATABASE [YourDatabase] TO DISK = ''C:\Backup\YourDatabase_'' + CONVERT(VARCHAR, GETDATE(), 112) + ''.bak''
WITH COMPRESSION, CHECKSUM, INIT;
';

-- Schedule via SQL Agent job
EXEC msdb.dbo.sp_add_job 
    @job_name = 'Weekly Maintenance',
    @enabled = 1;

EXEC msdb.dbo.sp_add_jobstep
    @job_name = 'Weekly Maintenance',
    @step_name = 'Maintenance Tasks',
    @command = @MaintenanceSQL;

EXEC msdb.dbo.sp_add_schedule
    @schedule_name = 'Weekly Sunday',
    @freq_type = 8,
    @freq_interval = 1,
    @freq_recurrence_factor = 1,
    @active_start_time = 020000;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = 'Weekly Maintenance',
    @schedule_name = 'Weekly Sunday';
```

## Backup and Recovery

### Backup Strategy

**Full Backup Strategy:**
```sql
-- Full backup weekly
BACKUP DATABASE [YourDatabase] 
TO DISK = 'C:\Backup\YourDatabase_Full_' + CONVERT(VARCHAR, GETDATE(), 112) + '.bak'
WITH COMPRESSION, CHECKSUM, INIT;

-- Differential backup daily
BACKUP DATABASE [YourDatabase] 
TO DISK = 'C:\Backup\YourDatabase_Diff_' + CONVERT(VARCHAR, GETDATE(), 112) + '.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT;

-- Transaction log backup every 15 minutes
BACKUP LOG [YourDatabase] 
TO DISK = 'C:\Backup\YourDatabase_Log_' + CONVERT(VARCHAR, GETDATE(), 112) + '_' + REPLACE(CONVERT(VARCHAR, GETDATE(), 108), ':', '') + '.trn'
WITH COMPRESSION, CHECKSUM, INIT;
```

**Backup to Azure Storage:**
```sql
-- Create credential for Azure storage
CREATE CREDENTIAL [https://yourstorageaccount.blob.core.windows.net/backups]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = 'your-sas-token';

-- Backup to Azure Blob Storage
BACKUP DATABASE [YourDatabase]
TO URL = 'https://yourstorageaccount.blob.core.windows.net/backups/YourDatabase.bak'
WITH COMPRESSION, CHECKSUM, INIT;
```

### Recovery Planning

**Recovery Time Objective (RTO) and Recovery Point Objective (RPO):**
- **RTO Target:** < 5 minutes for automatic failover
- **RPO Target:** < 1 minute for synchronous replicas
- **Cross-region RPO:** < 15 minutes for asynchronous replicas

**Disaster Recovery Procedures:**
```sql
-- Manual failover to DR site
ALTER AVAILABILITY GROUP [AG-Production] 
FAILOVER TO 'SQL-DR';

-- Forced failover with data loss (emergency only)
ALTER AVAILABILITY GROUP [AG-Production] 
FORCE_FAILOVER_ALLOW_DATA_LOSS TO 'SQL-DR';
```

## Cost Optimization

### Right-sizing Resources

**VM Cost Optimization:**
- Use Azure Hybrid Benefit for Windows Server and SQL Server licenses
- Consider Reserved Instances for predictable workloads
- Use Azure Spot VMs for development/test environments
- Implement auto-shutdown for non-production VMs

**Storage Cost Optimization:**
- Use Standard SSD for non-critical workloads
- Implement lifecycle management for backups
- Use Azure Blob Storage cool/archive tiers for long-term retention
- Monitor and optimize storage usage regularly

### Licensing Optimization

**SQL Server Licensing:**
```bash
# Apply Azure Hybrid Benefit
az sql vm update \
  --resource-group "sql-ha-rg" \
  --name "sql-vm-01" \
  --license-type "AHUB"

# Configure SQL Server license type
az vm update \
  --resource-group "sql-ha-rg" \
  --name "sql-vm-01" \
  --set "storageProfile.imageReference.sku=enterprise"
```

### Monitoring Costs

**Cost Monitoring Queries:**
```bash
# Get cost analysis for resource group
az consumption usage list \
  --start-date "2024-01-01" \
  --end-date "2024-01-31" \
  --resource-group "sql-ha-rg" \
  --output table

# Set up budget alerts
az consumption budget create \
  --resource-group "sql-ha-rg" \
  --budget-name "sql-ha-budget" \
  --amount 1000 \
  --time-grain "Monthly" \
  --time-period start="2024-01-01" end="2024-12-31"
```

## Operational Excellence

### Documentation Standards

**Maintain Documentation:**
- Keep architecture diagrams updated
- Document all configuration changes
- Maintain runbooks for common procedures
- Document disaster recovery procedures

**Change Management:**
- Use version control for scripts and configurations
- Implement change approval processes
- Test changes in non-production environments
- Maintain rollback procedures

### Automation

**Infrastructure as Code:**
```bash
# Use ARM templates or Bicep for deployment
az deployment group create \
  --resource-group "sql-ha-rg" \
  --template-file "main.bicep" \
  --parameters "@parameters.json"
```

**Configuration Management:**
```powershell
# Use PowerShell DSC for configuration management
Configuration SQLServerConfig {
    Import-DscResource -ModuleName SqlServerDsc
    
    Node $AllNodes.NodeName {
        SqlServerConfiguration MaxServerMemory {
            ServerName = $Node.ServerName
            InstanceName = 'MSSQLSERVER'
            OptionName = 'max server memory (MB)'
            OptionValue = $Node.MaxMemory
        }
    }
}
```

### Continuous Improvement

**Regular Reviews:**
- Monthly performance reviews
- Quarterly capacity planning
- Annual architecture reviews
- Regular security assessments

**Performance Baselines:**
- Establish performance baselines
- Monitor trends over time
- Identify optimization opportunities
- Plan for capacity growth

---

Following these best practices will help ensure your SQL Server High Availability deployment on Azure is secure, performant, cost-effective, and maintainable. Regular review and updates of these practices are essential as Azure services and SQL Server features continue to evolve.

