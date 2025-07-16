# SQL Server HA on Azure - Troubleshooting Guide

This guide provides solutions to common issues encountered when deploying and managing SQL Server High Availability on Azure.

## Table of Contents

1. [Deployment Issues](#deployment-issues)
2. [Network Connectivity Problems](#network-connectivity-problems)
3. [Cluster Configuration Issues](#cluster-configuration-issues)
4. [SQL Server Always On Issues](#sql-server-always-on-issues)
5. [Load Balancer Problems](#load-balancer-problems)
6. [Performance Issues](#performance-issues)
7. [Monitoring and Diagnostics](#monitoring-and-diagnostics)
8. [Common Error Messages](#common-error-messages)

## Deployment Issues

### Azure CLI Authentication Failures

**Problem:** Azure CLI commands fail with authentication errors.

**Symptoms:**
- "Please run 'az login' to setup account"
- "The subscription is not registered to use namespace"

**Solutions:**
1. **Re-authenticate with Azure CLI:**
   ```bash
   az login
   az account set --subscription "your-subscription-id"
   az account show
   ```

2. **Register required resource providers:**
   ```bash
   az provider register --namespace Microsoft.Compute
   az provider register --namespace Microsoft.Network
   az provider register --namespace Microsoft.Storage
   az provider register --namespace Microsoft.SqlVirtualMachine
   ```

3. **Check subscription permissions:**
   ```bash
   az role assignment list --assignee $(az account show --query user.name -o tsv)
   ```

### Resource Group Creation Failures

**Problem:** Cannot create resource group or resources.

**Symptoms:**
- "Location not available for subscription"
- "Quota exceeded"
- "Resource provider not registered"

**Solutions:**
1. **Check available locations:**
   ```bash
   az account list-locations --query "[].name" -o table
   ```

2. **Verify quota limits:**
   ```bash
   az vm list-usage --location "East US" -o table
   ```

3. **Use alternative regions:**
   ```bash
   # Update config.json with different location
   jq '.deployment.location = "West US 2"' config.json > config-updated.json
   ```

### VM Deployment Failures

**Problem:** Virtual machine creation fails.

**Symptoms:**
- "VM size not available"
- "Insufficient quota"
- "Image not found"

**Solutions:**
1. **Check VM size availability:**
   ```bash
   az vm list-sizes --location "East US" -o table
   ```

2. **Use smaller VM sizes for testing:**
   ```bash
   # Update VM sizes in config.json
   jq '.sqlServers.vmSize = "Standard_D2s_v3"' config.json > config-updated.json
   ```

3. **Verify SQL Server image availability:**
   ```bash
   az vm image list --publisher MicrosoftSQLServer --all -o table
   ```

## Network Connectivity Problems

### Cannot Connect to VMs

**Problem:** Unable to RDP or connect to virtual machines.

**Symptoms:**
- Connection timeouts
- "Network path not found"
- RDP connection refused

**Solutions:**
1. **Check VM status:**
   ```bash
   az vm show --resource-group "your-rg" --name "vm-name" --show-details
   ```

2. **Verify Network Security Group rules:**
   ```bash
   az network nsg rule list --resource-group "your-rg" --nsg-name "your-nsg" -o table
   ```

3. **Check public IP assignment:**
   ```bash
   az vm list-ip-addresses --resource-group "your-rg" -o table
   ```

4. **Test network connectivity:**
   ```bash
   # Test from local machine
   telnet vm-public-ip 3389
   ```

### DNS Resolution Issues

**Problem:** VMs cannot resolve domain names or each other.

**Symptoms:**
- "Name or service not known"
- Domain join failures
- SQL Server connection issues

**Solutions:**
1. **Check DNS settings on VMs:**
   ```powershell
   # On Windows VM
   Get-DnsClientServerAddress
   nslookup domain-controller-name
   ```

2. **Verify domain controller DNS:**
   ```powershell
   # On domain controller
   Get-DnsServerResourceRecord -ZoneName "contoso.local"
   ```

3. **Update DNS settings:**
   ```bash
   # Update NIC DNS settings
   az network nic update --resource-group "your-rg" --name "nic-name" --dns-servers "10.0.1.4"
   ```

### Firewall and Port Issues

**Problem:** Services cannot communicate due to firewall restrictions.

**Symptoms:**
- SQL Server connection failures
- Cluster communication errors
- Always On endpoint issues

**Solutions:**
1. **Check Windows Firewall:**
   ```powershell
   # On Windows VM
   Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*SQL*"}
   New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433
   ```

2. **Verify NSG rules:**
   ```bash
   az network nsg rule create --resource-group "your-rg" --nsg-name "your-nsg" \
     --name "AllowSQL" --priority 1100 --direction Inbound --access Allow \
     --protocol Tcp --destination-port-ranges 1433
   ```

3. **Test port connectivity:**
   ```powershell
   Test-NetConnection -ComputerName "target-server" -Port 1433
   ```

## Cluster Configuration Issues

### Windows Server Failover Cluster Creation Fails

**Problem:** Cannot create or join failover cluster.

**Symptoms:**
- "Cluster validation failed"
- "Node cannot be added to cluster"
- "Quorum configuration failed"

**Solutions:**
1. **Run cluster validation:**
   ```powershell
   Test-Cluster -Node "node1", "node2" -Include "Storage Spaces Direct", "Inventory", "Network", "System Configuration"
   ```

2. **Check cluster service:**
   ```powershell
   Get-Service ClusSvc
   Start-Service ClusSvc
   ```

3. **Verify cluster permissions:**
   ```powershell
   # Ensure cluster service account has proper permissions
   Get-ClusterAccess
   ```

4. **Configure cluster quorum:**
   ```powershell
   Set-ClusterQuorum -CloudWitness -AccountName "storageaccount" -AccessKey "key"
   ```

### Cluster Network Configuration Issues

**Problem:** Cluster networks not configured correctly.

**Symptoms:**
- "Network not available for cluster use"
- Cluster communication failures
- Split-brain scenarios

**Solutions:**
1. **Check cluster networks:**
   ```powershell
   Get-ClusterNetwork
   Get-ClusterNetworkInterface
   ```

2. **Configure cluster network roles:**
   ```powershell
   (Get-ClusterNetwork "Cluster Network 1").Role = "ClusterAndClient"
   (Get-ClusterNetwork "Cluster Network 2").Role = "ClientAccess"
   ```

3. **Set cluster network priorities:**
   ```powershell
   (Get-ClusterNetwork "Cluster Network 1").Metric = 1000
   (Get-ClusterNetwork "Cluster Network 2").Metric = 2000
   ```

## SQL Server Always On Issues

### Always On Availability Groups Not Enabled

**Problem:** Cannot create availability groups.

**Symptoms:**
- "Always On Availability Groups feature is disabled"
- "Availability group creation failed"

**Solutions:**
1. **Enable Always On feature:**
   ```powershell
   # Using SQL Server Configuration Manager or PowerShell
   Enable-SqlAlwaysOn -ServerInstance "SERVERNAME" -Force
   ```

2. **Restart SQL Server service:**
   ```powershell
   Restart-Service MSSQLSERVER
   ```

3. **Verify Always On status:**
   ```sql
   SELECT SERVERPROPERTY('IsHadrEnabled') AS IsAlwaysOnEnabled
   ```

### Availability Group Creation Failures

**Problem:** Cannot create availability group or add databases.

**Symptoms:**
- "Database not in full recovery model"
- "Database backup not found"
- "Endpoint not accessible"

**Solutions:**
1. **Set database to full recovery model:**
   ```sql
   ALTER DATABASE [YourDatabase] SET RECOVERY FULL
   ```

2. **Create full backup:**
   ```sql
   BACKUP DATABASE [YourDatabase] TO DISK = 'C:\Backup\YourDatabase.bak'
   BACKUP LOG [YourDatabase] TO DISK = 'C:\Backup\YourDatabase.trn'
   ```

3. **Check Always On endpoints:**
   ```sql
   SELECT name, port, state_desc FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING'
   ```

4. **Create or fix endpoint:**
   ```sql
   CREATE ENDPOINT [Hadr_endpoint]
   AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
   FOR DATA_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES)
   
   ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED
   ```

### Synchronization Issues

**Problem:** Databases not synchronizing between replicas.

**Symptoms:**
- "Not Synchronizing" status
- "Synchronization Health: Not Healthy"
- Data lag between primary and secondary

**Solutions:**
1. **Check synchronization status:**
   ```sql
   SELECT 
       ag.name AS AvailabilityGroupName,
       ar.replica_server_name,
       drs.database_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc
   FROM sys.dm_hadr_database_replica_states drs
   INNER JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
   INNER JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
   ```

2. **Resume data movement:**
   ```sql
   ALTER DATABASE [YourDatabase] SET HADR RESUME
   ```

3. **Check for blocking or long-running transactions:**
   ```sql
   SELECT * FROM sys.dm_exec_requests WHERE blocking_session_id > 0
   ```

4. **Verify network connectivity between replicas:**
   ```powershell
   Test-NetConnection -ComputerName "secondary-replica" -Port 5022
   ```

## Load Balancer Problems

### Listener Not Accessible

**Problem:** Cannot connect to availability group listener.

**Symptoms:**
- Connection timeouts to listener
- "Network path not found"
- Applications cannot connect

**Solutions:**
1. **Check listener configuration:**
   ```sql
   SELECT 
       agl.name AS ListenerName,
       agl.port,
       aglic.ip_address,
       aglic.state_desc
   FROM sys.availability_group_listeners agl
   INNER JOIN sys.availability_group_listener_ip_addresses aglic ON agl.listener_id = aglic.listener_id
   ```

2. **Verify load balancer configuration:**
   ```bash
   az network lb show --resource-group "your-rg" --name "your-lb"
   az network lb rule list --resource-group "your-rg" --lb-name "your-lb" -o table
   ```

3. **Check probe configuration:**
   ```bash
   az network lb probe list --resource-group "your-rg" --lb-name "your-lb" -o table
   ```

4. **Test probe port:**
   ```powershell
   # On SQL Server nodes
   Test-NetConnection -ComputerName "localhost" -Port 59999
   ```

### Load Balancer Health Probe Failures

**Problem:** Load balancer shows unhealthy backend instances.

**Symptoms:**
- Backend instances marked as unhealthy
- Traffic not distributed properly
- Intermittent connection failures

**Solutions:**
1. **Configure probe port on cluster resource:**
   ```powershell
   Get-ClusterResource "AG_Listener_Name" | Set-ClusterParameter -Name ProbePort -Value 59999
   Stop-ClusterResource "AG_Listener_Name"
   Start-ClusterResource "AG_Listener_Name"
   ```

2. **Check Windows Firewall for probe port:**
   ```powershell
   New-NetFirewallRule -DisplayName "Load Balancer Probe" -Direction Inbound -Protocol TCP -LocalPort 59999
   ```

3. **Verify backend pool configuration:**
   ```bash
   az network lb address-pool list --resource-group "your-rg" --lb-name "your-lb" -o table
   ```

## Performance Issues

### Slow Query Performance

**Problem:** Queries running slower than expected.

**Symptoms:**
- High query execution times
- Blocking and deadlocks
- CPU or memory pressure

**Solutions:**
1. **Check wait statistics:**
   ```sql
   SELECT TOP 10 
       wait_type,
       wait_time_ms,
       waiting_tasks_count
   FROM sys.dm_os_wait_stats
   ORDER BY wait_time_ms DESC
   ```

2. **Identify expensive queries:**
   ```sql
   SELECT TOP 10
       qs.total_elapsed_time / qs.execution_count AS avg_elapsed_time,
       qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
       qs.execution_count,
       SUBSTRING(qt.text, (qs.statement_start_offset/2)+1,
           ((CASE qs.statement_end_offset
               WHEN -1 THEN DATALENGTH(qt.text)
               ELSE qs.statement_end_offset
           END - qs.statement_start_offset)/2)+1) AS statement_text
   FROM sys.dm_exec_query_stats qs
   CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
   ORDER BY avg_elapsed_time DESC
   ```

3. **Check for blocking:**
   ```sql
   SELECT 
       blocking_session_id,
       session_id,
       wait_type,
       wait_resource,
       wait_time
   FROM sys.dm_exec_requests
   WHERE blocking_session_id > 0
   ```

### High Replication Latency

**Problem:** Data takes too long to replicate to secondary replicas.

**Symptoms:**
- High send queue size
- High redo queue size
- Synchronization lag

**Solutions:**
1. **Monitor replication performance:**
   ```sql
   SELECT 
       ar.replica_server_name,
       drs.database_name,
       drs.log_send_queue_size,
       drs.log_send_rate,
       drs.redo_queue_size,
       drs.redo_rate
   FROM sys.dm_hadr_database_replica_states drs
   INNER JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
   ```

2. **Check network bandwidth:**
   ```powershell
   # Test network throughput between replicas
   Test-NetConnection -ComputerName "secondary-replica" -Port 5022 -InformationLevel Detailed
   ```

3. **Optimize log backup frequency:**
   ```sql
   -- Increase log backup frequency
   BACKUP LOG [YourDatabase] TO DISK = 'NUL'
   ```

4. **Consider asynchronous mode for distant replicas:**
   ```sql
   ALTER AVAILABILITY GROUP [YourAG]
   MODIFY REPLICA ON 'SecondaryReplica'
   WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT)
   ```

## Monitoring and Diagnostics

### Enable Extended Events

Monitor Always On Availability Groups with Extended Events:

```sql
CREATE EVENT SESSION [AlwaysOn_health] ON SERVER 
ADD EVENT sqlserver.alwayson_ddl_executed,
ADD EVENT sqlserver.availability_group_lease_expired,
ADD EVENT sqlserver.availability_replica_automatic_failover_validation,
ADD EVENT sqlserver.availability_replica_manager_state_change,
ADD EVENT sqlserver.error_reported(
    WHERE ([error_number]=(9691) OR [error_number]=(35204) OR [error_number]=(9693) OR [error_number]=(26024) OR [error_number]=(28047) OR [error_number]=(26023) OR [error_number]=(9692) OR [error_number]=(28034) OR [error_number]=(28036) OR [error_number]=(28048) OR [error_number]=(28080) OR [error_number]=(28091) OR [error_number]=(26022) OR [error_number]=(9642) OR [error_number]=(35201) OR [error_number]=(35202) OR [error_number]=(35206) OR [error_number]=(35207) OR [error_number]=(26069) OR [error_number]=(26070) OR [error_number]=(41404) OR [error_number]=(41405) OR [error_number]=(41325) OR [error_number]=(41326)))
ADD TARGET package0.event_file(SET filename=N'AlwaysOn_health.xel',max_file_size=(5),max_rollover_files=(4))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)

ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START
```

### Performance Counters

Monitor these key performance counters:

```powershell
# PowerShell script to collect performance counters
$counters = @(
    "\SQLServer:Availability Replica(*)\Bytes Sent to Replica/sec",
    "\SQLServer:Availability Replica(*)\Bytes Sent to Transport/sec",
    "\SQLServer:Availability Replica(*)\Sends to Replica/sec",
    "\SQLServer:Availability Replica(*)\Sends to Transport/sec",
    "\SQLServer:Database Replica(*)\Log Bytes Received/sec",
    "\SQLServer:Database Replica(*)\Log Send Queue",
    "\SQLServer:Database Replica(*)\Redo Queue",
    "\SQLServer:Database Replica(*)\Transaction Delay"
)

Get-Counter -Counter $counters -SampleInterval 5 -MaxSamples 12
```

## Common Error Messages

### Error 1418: The server network address cannot be reached

**Cause:** Network connectivity issues between replicas.

**Solution:**
1. Check firewall settings
2. Verify endpoint configuration
3. Test network connectivity
4. Check DNS resolution

### Error 35250: The connection to the primary replica is not active

**Cause:** Primary replica is not accessible.

**Solution:**
1. Check primary replica status
2. Verify network connectivity
3. Check cluster status
4. Review Always On configuration

### Error 19456: Failed to generate a user instance of SQL Server

**Cause:** SQL Server service account issues.

**Solution:**
1. Verify service account permissions
2. Check SQL Server service status
3. Review event logs
4. Restart SQL Server service

### Error 41131: Availability group is not ready for automatic failover

**Cause:** Synchronization issues or configuration problems.

**Solution:**
1. Check synchronization status
2. Verify failover mode settings
3. Ensure all replicas are healthy
4. Review cluster configuration

## Getting Help

### Log Files to Check

1. **Windows Event Logs:**
   - Application Log
   - System Log
   - Failover Clustering Log

2. **SQL Server Error Logs:**
   - SQL Server Error Log
   - SQL Server Agent Log
   - Always On Extended Events

3. **Azure Activity Logs:**
   - Resource Group Activity Log
   - VM Boot Diagnostics
   - Network Security Group Flow Logs

### Useful Commands for Diagnostics

```bash
# Azure CLI diagnostics
az vm boot-diagnostics get-boot-log --resource-group "your-rg" --name "vm-name"
az network watcher flow-log show --resource-group "your-rg" --name "flow-log-name"

# PowerShell diagnostics
Get-EventLog -LogName Application -Source "MSSQLSERVER" -Newest 50
Get-ClusterLog -Destination "C:\Temp\ClusterLog"
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-FailoverClustering/Operational'; Level=2,3}
```

### Support Resources

- [Microsoft SQL Server Documentation](https://docs.microsoft.com/en-us/sql/)
- [Azure SQL Virtual Machines Documentation](https://docs.microsoft.com/en-us/azure/azure-sql/virtual-machines/)
- [Windows Server Failover Clustering Documentation](https://docs.microsoft.com/en-us/windows-server/failover-clustering/)
- [Azure Support](https://azure.microsoft.com/en-us/support/)

---

For additional support, please review the logs and error messages, then consult the appropriate documentation or contact Microsoft Support with specific error details and log files.

