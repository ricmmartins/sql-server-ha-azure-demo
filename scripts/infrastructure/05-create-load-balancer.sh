#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Load Balancer Creation Script
# =============================================================================
# This script creates the Azure Load Balancer for the Always On Availability
# Group listener in single subnet configuration
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
    local nodes_count
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
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
    
    # Check SQL Server VMs
    for ((i=0; i<nodes_count; i++)); do
        local vm_name
        vm_name=$(jq -r ".sqlServers.nodes[$i].vmName" "$CONFIG_FILE")
        
        if ! az vm show --resource-group "$rg_name" --name "$vm_name" --output none 2>/dev/null; then
            log_error "SQL Server VM '$vm_name' does not exist"
            log_info "Please run: ./scripts/infrastructure/04-create-sql-vms.sh first"
            exit 1
        fi
        
        # Check if VM is running
        local vm_status
        vm_status=$(az vm get-instance-view --resource-group "$rg_name" --name "$vm_name" --query instanceView.statuses[1].displayStatus -o tsv)
        
        if [[ "$vm_status" != "VM running" ]]; then
            log_error "SQL Server VM '$vm_name' is not running: $vm_status"
            exit 1
        fi
    done
    
    log_success "Prerequisites verified"
}

# Function to create load balancer
create_load_balancer() {
    local rg_name
    local lb_name
    local location
    local vnet_name
    local subnet_name
    local frontend_ip
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    subnet_name=$(jq -r '.network.subnets.sql1.name' "$CONFIG_FILE")
    frontend_ip=$(jq -r '.loadBalancer.frontendIpAddress' "$CONFIG_FILE")
    
    log_info "Creating Load Balancer: $lb_name"
    
    # Check if load balancer already exists
    if az network lb show --resource-group "$rg_name" --name "$lb_name" &> /dev/null; then
        log_warning "Load Balancer '$lb_name' already exists"
        return 0
    fi
    
    # Create the load balancer
    az network lb create \
        --resource-group "$rg_name" \
        --name "$lb_name" \
        --location "$location" \
        --sku Standard \
        --vnet-name "$vnet_name" \
        --subnet "$subnet_name" \
        --frontend-ip-name "LoadBalancerFrontEnd" \
        --private-ip-address "$frontend_ip" \
        --private-ip-address-version IPv4 \
        --output table
    
    log_success "Load Balancer '$lb_name' created"
}

# Function to create backend pool
create_backend_pool() {
    local rg_name
    local lb_name
    local backend_pool_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    backend_pool_name=$(jq -r '.loadBalancer.backendPoolName' "$CONFIG_FILE")
    
    log_info "Creating Backend Pool: $backend_pool_name"
    
    # Check if backend pool already exists
    if az network lb address-pool show --resource-group "$rg_name" --lb-name "$lb_name" --name "$backend_pool_name" &> /dev/null; then
        log_warning "Backend Pool '$backend_pool_name' already exists"
        return 0
    fi
    
    # Create backend pool
    az network lb address-pool create \
        --resource-group "$rg_name" \
        --lb-name "$lb_name" \
        --name "$backend_pool_name" \
        --output table
    
    log_success "Backend Pool '$backend_pool_name' created"
}

# Function to add VMs to backend pool
add_vms_to_backend_pool() {
    local rg_name
    local lb_name
    local backend_pool_name
    local nodes_count
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    backend_pool_name=$(jq -r '.loadBalancer.backendPoolName' "$CONFIG_FILE")
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
    log_info "Adding SQL Server VMs to Backend Pool"
    
    for ((i=0; i<nodes_count; i++)); do
        local vm_name
        local nic_name
        
        vm_name=$(jq -r ".sqlServers.nodes[$i].vmName" "$CONFIG_FILE")
        
        # Get NIC name for the VM
        nic_name=$(az vm show --resource-group "$rg_name" --name "$vm_name" --query 'networkProfile.networkInterfaces[0].id' -o tsv | xargs basename)
        
        log_info "Adding $vm_name (NIC: $nic_name) to backend pool"
        
        # Add NIC to backend pool
        az network nic ip-config address-pool add \
            --resource-group "$rg_name" \
            --nic-name "$nic_name" \
            --ip-config-name "ipconfig1" \
            --lb-name "$lb_name" \
            --address-pool "$backend_pool_name" \
            --output none
        
        log_success "$vm_name added to backend pool"
    done
}

# Function to create health probe
create_health_probe() {
    local rg_name
    local lb_name
    local probe_name
    local probe_port
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    probe_name=$(jq -r '.loadBalancer.healthProbeName' "$CONFIG_FILE")
    probe_port=$(jq -r '.loadBalancer.healthProbePort' "$CONFIG_FILE")
    
    log_info "Creating Health Probe: $probe_name"
    
    # Check if health probe already exists
    if az network lb probe show --resource-group "$rg_name" --lb-name "$lb_name" --name "$probe_name" &> /dev/null; then
        log_warning "Health Probe '$probe_name' already exists"
        return 0
    fi
    
    # Create health probe
    az network lb probe create \
        --resource-group "$rg_name" \
        --lb-name "$lb_name" \
        --name "$probe_name" \
        --protocol Tcp \
        --port "$probe_port" \
        --interval 5 \
        --threshold 2 \
        --output table
    
    log_success "Health Probe '$probe_name' created"
}

# Function to create load balancing rule
create_load_balancing_rule() {
    local rg_name
    local lb_name
    local rule_name
    local backend_pool_name
    local probe_name
    local listener_port
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    rule_name=$(jq -r '.loadBalancer.loadBalancingRuleName' "$CONFIG_FILE")
    backend_pool_name=$(jq -r '.loadBalancer.backendPoolName' "$CONFIG_FILE")
    probe_name=$(jq -r '.loadBalancer.healthProbeName' "$CONFIG_FILE")
    listener_port=$(jq -r '.availabilityGroup.listenerPort' "$CONFIG_FILE")
    
    log_info "Creating Load Balancing Rule: $rule_name"
    
    # Check if load balancing rule already exists
    if az network lb rule show --resource-group "$rg_name" --lb-name "$lb_name" --name "$rule_name" &> /dev/null; then
        log_warning "Load Balancing Rule '$rule_name' already exists"
        return 0
    fi
    
    # Create load balancing rule
    az network lb rule create \
        --resource-group "$rg_name" \
        --lb-name "$lb_name" \
        --name "$rule_name" \
        --protocol Tcp \
        --frontend-port "$listener_port" \
        --backend-port "$listener_port" \
        --frontend-ip-name "LoadBalancerFrontEnd" \
        --backend-pool-name "$backend_pool_name" \
        --probe-name "$probe_name" \
        --load-distribution SourceIP \
        --floating-ip true \
        --output table
    
    log_success "Load Balancing Rule '$rule_name' created"
}

# Function to create witness VM
create_witness_vm() {
    local rg_name
    local vm_name
    local vm_size
    local admin_username
    local admin_password
    local vnet_name
    local subnet_name
    local static_ip
    local location
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.witness.vmName' "$CONFIG_FILE")
    vm_size=$(jq -r '.witness.vmSize' "$CONFIG_FILE")
    admin_username=$(jq -r '.witness.adminUsername' "$CONFIG_FILE")
    admin_password=$(jq -r '.witness.adminPassword' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    subnet_name=$(jq -r '.network.subnets.witness.name' "$CONFIG_FILE")
    static_ip=$(jq -r '.witness.staticIpAddress' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating File Share Witness VM: $vm_name"
    
    # Check if VM already exists
    if az vm show --resource-group "$rg_name" --name "$vm_name" &> /dev/null; then
        log_warning "Witness VM '$vm_name' already exists"
        return 0
    fi
    
    # Create the witness VM
    az vm create \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --size "$vm_size" \
        --image "Win2022Datacenter" \
        --admin-username "$admin_username" \
        --admin-password "$admin_password" \
        --vnet-name "$vnet_name" \
        --subnet "$subnet_name" \
        --private-ip-address "$static_ip" \
        --public-ip-address "" \
        --nsg "" \
        --location "$location" \
        --output table
    
    log_success "Witness VM '$vm_name' created"
    
    # Configure witness VM
    configure_witness_vm
}

# Function to configure witness VM
configure_witness_vm() {
    local rg_name
    local vm_name
    local domain_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.witness.vmName' "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    
    log_info "Configuring File Share Witness on $vm_name"
    
    # Create PowerShell script for witness configuration
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
    Add-Computer -DomainName $domain -Credential $credential -Force
    Write-Output "Successfully joined domain $domain"
} catch {
    Write-Error "Failed to join domain: $_"
}

# Create file share for cluster witness
$sharePath = "C:\QWitness"
New-Item -ItemType Directory -Path $sharePath -Force

# Create the share
New-SmbShare -Name "QWitness" -Path $sharePath -FullAccess "CONTOSO\Install","CONTOSO\clusterservice"

# Set NTFS permissions
$acl = Get-Acl $sharePath
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("CONTOSO\Install","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$acl.SetAccessRule($accessRule)
$accessRule2 = New-Object System.Security.AccessControl.FileSystemAccessRule("CONTOSO\clusterservice","FullControl","ContainerInherit,ObjectInherit","None","Allow")
$acl.SetAccessRule($accessRule2)
Set-Acl -Path $sharePath -AclObject $acl

Write-Output "File share witness configured successfully"

# Restart to complete domain join
Restart-Computer -Force
EOF
)
    
    # Execute PowerShell script on the witness VM
    az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_script" \
        --parameters "DOMAIN_NAME=$domain_name" \
        --output table
    
    log_success "File Share Witness configured on $vm_name"
}

# Function to create storage account for cloud witness
create_storage_account() {
    local rg_name
    local storage_account_name
    local location
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    storage_account_name=$(jq -r '.storage.storageAccountName' "$CONFIG_FILE" | sed 's/{uniqueString}/'"$(date +%s | tail -c 6)"'/')
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating Storage Account for Cloud Witness: $storage_account_name"
    
    # Check if storage account already exists
    if az storage account show --resource-group "$rg_name" --name "$storage_account_name" &> /dev/null; then
        log_warning "Storage Account '$storage_account_name' already exists"
        return 0
    fi
    
    # Create storage account
    az storage account create \
        --resource-group "$rg_name" \
        --name "$storage_account_name" \
        --location "$location" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --access-tier Hot \
        --https-only true \
        --output table
    
    # Get storage account key
    local storage_key
    storage_key=$(az storage account keys list --resource-group "$rg_name" --account-name "$storage_account_name" --query '[0].value' -o tsv)
    
    log_success "Storage Account '$storage_account_name' created"
    log_info "Storage Account Key: $storage_key"
    log_info "Use this key for cluster cloud witness configuration"
}

# Function to validate load balancer configuration
validate_load_balancer() {
    local rg_name
    local lb_name
    local backend_pool_name
    local probe_name
    local rule_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    backend_pool_name=$(jq -r '.loadBalancer.backendPoolName' "$CONFIG_FILE")
    probe_name=$(jq -r '.loadBalancer.healthProbeName' "$CONFIG_FILE")
    rule_name=$(jq -r '.loadBalancer.loadBalancingRuleName' "$CONFIG_FILE")
    
    log_info "Validating Load Balancer configuration..."
    
    # Check load balancer
    if ! az network lb show --resource-group "$rg_name" --name "$lb_name" --output none 2>/dev/null; then
        log_error "Load Balancer validation failed"
        return 1
    fi
    
    # Check backend pool
    if ! az network lb address-pool show --resource-group "$rg_name" --lb-name "$lb_name" --name "$backend_pool_name" --output none 2>/dev/null; then
        log_error "Backend Pool validation failed"
        return 1
    fi
    
    # Check health probe
    if ! az network lb probe show --resource-group "$rg_name" --lb-name "$lb_name" --name "$probe_name" --output none 2>/dev/null; then
        log_error "Health Probe validation failed"
        return 1
    fi
    
    # Check load balancing rule
    if ! az network lb rule show --resource-group "$rg_name" --lb-name "$lb_name" --name "$rule_name" --output none 2>/dev/null; then
        log_error "Load Balancing Rule validation failed"
        return 1
    fi
    
    log_success "Load Balancer validation passed"
    return 0
}

# Function to display load balancer summary
display_load_balancer_summary() {
    local rg_name
    local lb_name
    local frontend_ip
    local listener_port
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    lb_name=$(jq -r '.loadBalancer.name' "$CONFIG_FILE")
    frontend_ip=$(jq -r '.loadBalancer.frontendIpAddress' "$CONFIG_FILE")
    listener_port=$(jq -r '.availabilityGroup.listenerPort' "$CONFIG_FILE")
    
    log_success "Load Balancer and supporting infrastructure created successfully!"
    echo
    log_info "Load Balancer Summary:"
    log_info "  Name: $lb_name"
    log_info "  Frontend IP: $frontend_ip"
    log_info "  Listener Port: $listener_port"
    log_info "  Backend Pool: Contains both SQL Server VMs"
    log_info "  Health Probe: Configured for Always On AG"
    echo
    log_info "Supporting Infrastructure:"
    log_info "  File Share Witness: $(jq -r '.witness.vmName' "$CONFIG_FILE")"
    log_info "  Cloud Witness: Storage account created"
    echo
}

# Function to show next steps
show_next_steps() {
    log_info "Next steps:"
    log_info "1. Run: ./scripts/sql-config/01-install-failover-clustering.ps1"
    log_info "2. Verify load balancer configuration in Azure Portal"
    log_info "3. Test connectivity to witness file share"
    log_info "4. Proceed with Windows Server Failover Cluster setup"
    echo
    log_warning "Infrastructure setup is complete!"
    log_warning "Next phase: SQL Server and Always On configuration"
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - Load Balancer and Supporting Infrastructure"
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
    
    # Create load balancer
    create_load_balancer
    
    # Create backend pool
    create_backend_pool
    
    # Add VMs to backend pool
    add_vms_to_backend_pool
    
    # Create health probe
    create_health_probe
    
    # Create load balancing rule
    create_load_balancing_rule
    
    # Create witness VM
    create_witness_vm
    
    # Create storage account for cloud witness
    create_storage_account
    
    # Validate configuration
    if validate_load_balancer; then
        display_load_balancer_summary
        show_next_steps
    else
        log_error "Load Balancer validation failed"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

