#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - SQL Server VMs Creation Script
# =============================================================================
# This script creates the SQL Server virtual machines for the Always On
# Availability Group configuration
# Author: Manus AI
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config.json"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Please install jq to continue."
        exit 1
    fi
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is required but not installed. Please install Azure CLI to continue."
        exit 1
    fi
}

# Function to load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "Invalid JSON in configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    log_success "Configuration loaded successfully"
}

# Function to check Azure CLI context
check_azure_context() {
    log_info "Checking Azure CLI context..."
    
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI. Please run 'az login' first."
        exit 1
    fi
    
    local current_subscription
    current_subscription=$(az account show --query id -o tsv)
    local target_subscription
    target_subscription=$(jq -r '.deployment.subscriptionId' "$CONFIG_FILE")
    
    if [[ "$current_subscription" != "$target_subscription" ]]; then
        az account set --subscription "$target_subscription"
    fi
    
    log_success "Azure CLI context verified"
}

# Function to verify prerequisites
verify_prerequisites() {
    local rg_name
    local vnet_name
    local dc_vm_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    dc_vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    
    log_info "Verifying prerequisites..."
    
    # Check resource group
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_error "Resource group '$rg_name' does not exist"
        exit 1
    fi
    
    # Check virtual network
    if ! az network vnet show --resource-group "$rg_name" --name "$vnet_name" --output none 2>/dev/null; then
        log_error "Virtual network '$vnet_name' does not exist"
        exit 1
    fi
    
    # Check domain controller
    if ! az vm show --resource-group "$rg_name" --name "$dc_vm_name" --output none 2>/dev/null; then
        log_error "Domain controller '$dc_vm_name' does not exist"
        log_info "Please run: ./scripts/infrastructure/03-create-domain-controller.sh first"
        exit 1
    fi
    
    # Verify domain controller is running
    local dc_status
    dc_status=$(az vm get-instance-view --resource-group "$rg_name" --name "$dc_vm_name" --query instanceView.statuses[1].displayStatus -o tsv)
    
    if [[ "$dc_status" != "VM running" ]]; then
        log_error "Domain controller is not running: $dc_status"
        exit 1
    fi
    
    log_success "Prerequisites verified"
}

# Function to create availability set
create_availability_set() {
    local rg_name
    local location
    local availability_option
    local availability_set_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    availability_option=$(jq -r '.sqlServers.availabilityOption' "$CONFIG_FILE")
    availability_set_name="sql-ha-availability-set"
    
    # Only create availability set if not using availability zones
    if [[ "$availability_option" == "AvailabilitySet" ]]; then
        log_info "Creating Availability Set: $availability_set_name"
        
        if az vm availability-set show --resource-group "$rg_name" --name "$availability_set_name" &> /dev/null; then
            log_warning "Availability Set '$availability_set_name' already exists"
        else
            az vm availability-set create \
                --resource-group "$rg_name" \
                --name "$availability_set_name" \
                --location "$location" \
                --platform-fault-domain-count 2 \
                --platform-update-domain-count 5 \
                --output table
            
            log_success "Availability Set '$availability_set_name' created"
        fi
    else
        log_info "Using Availability Zones - skipping Availability Set creation"
    fi
}

# Function to create SQL Server VM
create_sql_server_vm() {
    local node_index="$1"
    local rg_name
    local vm_name
    local vm_size
    local admin_username
    local admin_password
    local sql_version
    local vnet_name
    local static_ip
    local availability_option
    local availability_zone
    local location
    local subnet_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r ".sqlServers.nodes[$node_index].vmName" "$CONFIG_FILE")
    vm_size=$(jq -r '.sqlServers.vmSize' "$CONFIG_FILE")
    admin_username=$(jq -r '.sqlServers.adminUsername' "$CONFIG_FILE")
    admin_password=$(jq -r '.sqlServers.adminPassword' "$CONFIG_FILE")
    sql_version=$(jq -r '.sqlServers.sqlServerVersion' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    static_ip=$(jq -r ".sqlServers.nodes[$node_index].staticIpAddress" "$CONFIG_FILE")
    availability_option=$(jq -r '.sqlServers.availabilityOption' "$CONFIG_FILE")
    availability_zone=$(jq -r ".sqlServers.nodes[$node_index].availabilityZone" "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    # Determine subnet name based on node
    if [[ $node_index -eq 0 ]]; then
        subnet_name=$(jq -r '.network.subnets.sql1.name' "$CONFIG_FILE")
    else
        subnet_name=$(jq -r '.network.subnets.sql2.name' "$CONFIG_FILE")
    fi
    
    log_info "Creating SQL Server VM: $vm_name"
    
    # Check if VM already exists
    if az vm show --resource-group "$rg_name" --name "$vm_name" &> /dev/null; then
        log_warning "VM '$vm_name' already exists"
        return 0
    fi
    
    # Build VM creation command
    local vm_create_cmd="az vm create \
        --resource-group $rg_name \
        --name $vm_name \
        --size $vm_size \
        --image $sql_version \
        --admin-username $admin_username \
        --admin-password $admin_password \
        --vnet-name $vnet_name \
        --subnet $subnet_name \
        --private-ip-address $static_ip \
        --public-ip-address \"\" \
        --nsg \"\" \
        --location $location"
    
    # Add availability configuration
    if [[ "$availability_option" == "AvailabilityZones" ]]; then
        vm_create_cmd+=" --zone $availability_zone"
    elif [[ "$availability_option" == "AvailabilitySet" ]]; then
        vm_create_cmd+=" --availability-set sql-ha-availability-set"
    fi
    
    vm_create_cmd+=" --output table"
    
    # Execute VM creation
    eval "$vm_create_cmd"
    
    log_success "SQL Server VM '$vm_name' created"
}

# Function to attach data disks to SQL Server VM
attach_data_disks() {
    local node_index="$1"
    local rg_name
    local vm_name
    local location
    local disks_count
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r ".sqlServers.nodes[$node_index].vmName" "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    disks_count=$(jq '.sqlServers.storageConfiguration.dataDisks | length' "$CONFIG_FILE")
    
    log_info "Attaching data disks to $vm_name"
    
    for ((i=0; i<disks_count; i++)); do
        local disk_name
        local disk_size
        local storage_type
        local caching
        
        disk_name="${vm_name}-$(jq -r ".sqlServers.storageConfiguration.dataDisks[$i].name" "$CONFIG_FILE")"
        disk_size=$(jq -r ".sqlServers.storageConfiguration.dataDisks[$i].diskSizeGB" "$CONFIG_FILE")
        storage_type=$(jq -r ".sqlServers.storageConfiguration.dataDisks[$i].storageAccountType" "$CONFIG_FILE")
        caching=$(jq -r ".sqlServers.storageConfiguration.dataDisks[$i].caching" "$CONFIG_FILE")
        
        log_info "Creating and attaching disk: $disk_name"
        
        # Create managed disk
        az disk create \
            --resource-group "$rg_name" \
            --name "$disk_name" \
            --size-gb "$disk_size" \
            --sku "$storage_type" \
            --location "$location" \
            --output none
        
        # Attach disk to VM
        az vm disk attach \
            --resource-group "$rg_name" \
            --vm-name "$vm_name" \
            --name "$disk_name" \
            --caching "$caching" \
            --output none
        
        log_success "Disk '$disk_name' attached to $vm_name"
    done
}

# Function to configure SQL Server VM
configure_sql_server_vm() {
    local node_index="$1"
    local rg_name
    local vm_name
    local domain_name
    local domain_admin
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r ".sqlServers.nodes[$node_index].vmName" "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    domain_admin="CONTOSO\\Install"
    
    log_info "Configuring SQL Server on $vm_name"
    
    # Create PowerShell script for SQL Server configuration
    local ps_script=$(cat << 'EOF'
# Configure Windows Features
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -All
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

# Initialize and format data disks
$disks = Get-Disk | Where-Object {$_.PartitionStyle -eq 'RAW'}
$diskIndex = 0

foreach ($disk in $disks) {
    $diskIndex++
    $driveLetter = if ($diskIndex -eq 1) { "F" } else { "G" }
    $label = if ($diskIndex -eq 1) { "SQLData" } else { "SQLLogs" }
    
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter
    Format-Volume -DriveLetter $driveLetter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false
}

# Create SQL Server directories
New-Item -ItemType Directory -Path "F:\Data" -Force
New-Item -ItemType Directory -Path "G:\Logs" -Force
New-Item -ItemType Directory -Path "C:\Backup" -Force

# Configure SQL Server service accounts
$sqlServiceAccount = "CONTOSO\sqlservice"
$sqlAgentAccount = "CONTOSO\sqlagent"

# Set SQL Server service to use domain account
$service = Get-WmiObject -Class Win32_Service -Filter "Name='MSSQLSERVER'"
if ($service) {
    $service.Change($null, $null, $null, $null, $null, $null, $sqlServiceAccount, "P@ssw0rd123!")
}

# Set SQL Agent service to use domain account
$agentService = Get-WmiObject -Class Win32_Service -Filter "Name='SQLSERVERAGENT'"
if ($agentService) {
    $agentService.Change($null, $null, $null, $null, $null, $null, $sqlAgentAccount, "P@ssw0rd123!")
}

# Configure SQL Server for Always On
Import-Module SqlServer -Force

# Enable Always On Availability Groups
Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force

# Configure SQL Server settings
Invoke-Sqlcmd -Query "
    -- Configure SQL Server for Always On
    ALTER SERVER CONFIGURATION SET HADR CLUSTER CONTEXT = 'WSFC';
    
    -- Set max server memory (adjust based on VM size)
    EXEC sp_configure 'max server memory (MB)', 12288;
    RECONFIGURE;
    
    -- Enable backup compression
    EXEC sp_configure 'backup compression default', 1;
    RECONFIGURE;
    
    -- Configure database mail (optional)
    EXEC sp_configure 'Database Mail XPs', 1;
    RECONFIGURE;
"

# Restart SQL Server services to apply changes
Restart-Service -Name "MSSQLSERVER" -Force
Start-Sleep -Seconds 30
Restart-Service -Name "SQLSERVERAGENT" -Force

Write-Output "SQL Server configuration completed on $env:COMPUTERNAME"
EOF
)
    
    # Execute PowerShell script on the VM
    az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_script" \
        --output table
    
    log_success "SQL Server configured on $vm_name"
}

# Function to join VM to domain
join_vm_to_domain() {
    local node_index="$1"
    local rg_name
    local vm_name
    local domain_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r ".sqlServers.nodes[$node_index].vmName" "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    
    log_info "Joining $vm_name to domain $domain_name"
    
    # Create PowerShell script for domain join
    local ps_script=$(cat << 'EOF'
# Configure DNS to point to domain controller
$adapter = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses "10.0.1.10"

# Wait for DNS to propagate
Start-Sleep -Seconds 30

# Join domain
$domain = $env:DOMAIN_NAME
$username = "CONTOSO\Install"
$password = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $password)

try {
    Add-Computer -DomainName $domain -Credential $credential -Restart -Force
    Write-Output "Successfully joined domain $domain"
} catch {
    Write-Error "Failed to join domain: $_"
    exit 1
}
EOF
)
    
    # Execute domain join script
    az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_script" \
        --parameters "DOMAIN_NAME=$domain_name" \
        --output table
    
    log_success "$vm_name joined to domain $domain_name"
    
    # Wait for VM to restart after domain join
    log_info "Waiting for $vm_name to restart after domain join..."
    sleep 120
}

# Function to register SQL VMs with SQL IaaS Agent Extension
register_sql_iaas_extension() {
    local node_index="$1"
    local rg_name
    local vm_name
    local sql_edition
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r ".sqlServers.nodes[$node_index].vmName" "$CONFIG_FILE")
    sql_edition=$(jq -r '.sqlServers.sqlServerEdition' "$CONFIG_FILE")
    
    log_info "Registering $vm_name with SQL IaaS Agent Extension"
    
    # Register with SQL VM resource provider
    az sql vm create \
        --name "$vm_name" \
        --resource-group "$rg_name" \
        --location "$(jq -r '.deployment.location' "$CONFIG_FILE")" \
        --license-type "PAYG" \
        --sql-mgmt-type "Full" \
        --output table
    
    log_success "$vm_name registered with SQL IaaS Agent Extension"
}

# Function to validate SQL Server VMs
validate_sql_server_vms() {
    local rg_name
    local nodes_count
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
    log_info "Validating SQL Server VMs..."
    
    for ((i=0; i<nodes_count; i++)); do
        local vm_name
        local vm_status
        
        vm_name=$(jq -r ".sqlServers.nodes[$i].vmName" "$CONFIG_FILE")
        
        # Check VM status
        vm_status=$(az vm get-instance-view --resource-group "$rg_name" --name "$vm_name" --query instanceView.statuses[1].displayStatus -o tsv)
        
        if [[ "$vm_status" != "VM running" ]]; then
            log_error "VM '$vm_name' is not running: $vm_status"
            return 1
        fi
        
        # Check SQL VM registration
        if ! az sql vm show --name "$vm_name" --resource-group "$rg_name" --output none 2>/dev/null; then
            log_error "SQL VM '$vm_name' is not registered with SQL IaaS Agent Extension"
            return 1
        fi
        
        log_success "VM '$vm_name' validation passed"
    done
    
    log_success "All SQL Server VMs validated successfully"
    return 0
}

# Function to display SQL VMs summary
display_sql_vms_summary() {
    local rg_name
    local nodes_count
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
    log_success "SQL Server VMs created and configured successfully!"
    echo
    log_info "SQL Server VMs Summary:"
    
    for ((i=0; i<nodes_count; i++)); do
        local vm_name
        local static_ip
        local role
        local availability_zone
        
        vm_name=$(jq -r ".sqlServers.nodes[$i].vmName" "$CONFIG_FILE")
        static_ip=$(jq -r ".sqlServers.nodes[$i].staticIpAddress" "$CONFIG_FILE")
        role=$(jq -r ".sqlServers.nodes[$i].role" "$CONFIG_FILE")
        availability_zone=$(jq -r ".sqlServers.nodes[$i].availabilityZone" "$CONFIG_FILE")
        
        log_info "  VM: $vm_name"
        log_info "    Role: $role"
        log_info "    IP: $static_ip"
        log_info "    Zone: $availability_zone"
        log_info "    Status: Domain-joined and SQL configured"
        echo
    done
}

# Function to show next steps
show_next_steps() {
    log_info "Next steps:"
    log_info "1. Run: ./scripts/infrastructure/05-create-load-balancer.sh"
    log_info "2. Verify SQL Server services are running on both VMs"
    log_info "3. Test domain connectivity from both SQL VMs"
    log_info "4. Proceed with Windows Server Failover Cluster configuration"
    echo
    log_warning "Important: VMs have been restarted after domain join"
    log_warning "Allow 5-10 minutes for all services to fully start"
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - SQL Server VMs Creation"
    echo "============================================================================="
    echo
    
    # Check dependencies
    check_dependencies
    
    # Load configuration
    load_config
    
    # Check Azure context
    check_azure_context
    
    # Verify prerequisites
    verify_prerequisites
    
    # Create availability set if needed
    create_availability_set
    
    # Get number of SQL Server nodes
    local nodes_count
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
    # Create SQL Server VMs
    for ((i=0; i<nodes_count; i++)); do
        create_sql_server_vm "$i"
        attach_data_disks "$i"
        join_vm_to_domain "$i"
        configure_sql_server_vm "$i"
        register_sql_iaas_extension "$i"
    done
    
    # Validate all VMs
    if validate_sql_server_vms; then
        display_sql_vms_summary
        show_next_steps
    else
        log_error "SQL Server VMs validation failed"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

