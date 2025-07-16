#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Network Infrastructure Creation Script
# =============================================================================
# This script creates the virtual network, subnets, and network security groups
# for the SQL Server HA deployment
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

# Function to check Azure CLI login and subscription
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

# Function to verify resource group exists
verify_resource_group() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    log_info "Verifying resource group exists: $rg_name"
    
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_error "Resource group '$rg_name' does not exist"
        log_info "Please run: ./scripts/infrastructure/01-create-resource-group.sh first"
        exit 1
    fi
    
    log_success "Resource group verified"
}

# Function to create network security group
create_network_security_group() {
    local rg_name
    local nsg_name
    local location
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    nsg_name=$(jq -r '.network.networkSecurityGroup.name' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating Network Security Group: $nsg_name"
    
    # Check if NSG already exists
    if az network nsg show --resource-group "$rg_name" --name "$nsg_name" &> /dev/null; then
        log_warning "Network Security Group '$nsg_name' already exists"
    else
        az network nsg create \
            --resource-group "$rg_name" \
            --name "$nsg_name" \
            --location "$location" \
            --output table
        
        log_success "Network Security Group '$nsg_name' created"
    fi
    
    # Create NSG rules
    create_nsg_rules "$rg_name" "$nsg_name"
}

# Function to create NSG rules
create_nsg_rules() {
    local rg_name="$1"
    local nsg_name="$2"
    
    log_info "Creating Network Security Group rules..."
    
    # Get rules from config
    local rules_count
    rules_count=$(jq '.network.networkSecurityGroup.rules | length' "$CONFIG_FILE")
    
    for ((i=0; i<rules_count; i++)); do
        local rule_name
        local priority
        local direction
        local access
        local protocol
        local source_port_range
        local dest_port_range
        local source_address_prefix
        local dest_address_prefix
        
        rule_name=$(jq -r ".network.networkSecurityGroup.rules[$i].name" "$CONFIG_FILE")
        priority=$(jq -r ".network.networkSecurityGroup.rules[$i].priority" "$CONFIG_FILE")
        direction=$(jq -r ".network.networkSecurityGroup.rules[$i].direction" "$CONFIG_FILE")
        access=$(jq -r ".network.networkSecurityGroup.rules[$i].access" "$CONFIG_FILE")
        protocol=$(jq -r ".network.networkSecurityGroup.rules[$i].protocol" "$CONFIG_FILE")
        source_port_range=$(jq -r ".network.networkSecurityGroup.rules[$i].sourcePortRange" "$CONFIG_FILE")
        dest_port_range=$(jq -r ".network.networkSecurityGroup.rules[$i].destinationPortRange" "$CONFIG_FILE")
        source_address_prefix=$(jq -r ".network.networkSecurityGroup.rules[$i].sourceAddressPrefix" "$CONFIG_FILE")
        dest_address_prefix=$(jq -r ".network.networkSecurityGroup.rules[$i].destinationAddressPrefix" "$CONFIG_FILE")
        
        log_info "Creating NSG rule: $rule_name"
        
        # Check if rule already exists
        if az network nsg rule show --resource-group "$rg_name" --nsg-name "$nsg_name" --name "$rule_name" &> /dev/null; then
            log_warning "NSG rule '$rule_name' already exists, skipping"
        else
            az network nsg rule create \
                --resource-group "$rg_name" \
                --nsg-name "$nsg_name" \
                --name "$rule_name" \
                --priority "$priority" \
                --direction "$direction" \
                --access "$access" \
                --protocol "$protocol" \
                --source-port-ranges "$source_port_range" \
                --destination-port-ranges "$dest_port_range" \
                --source-address-prefixes "$source_address_prefix" \
                --destination-address-prefixes "$dest_address_prefix" \
                --output none
            
            log_success "NSG rule '$rule_name' created"
        fi
    done
}

# Function to create virtual network
create_virtual_network() {
    local rg_name
    local vnet_name
    local address_space
    local location
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    address_space=$(jq -r '.network.addressSpace' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating Virtual Network: $vnet_name"
    
    # Check if VNet already exists
    if az network vnet show --resource-group "$rg_name" --name "$vnet_name" &> /dev/null; then
        log_warning "Virtual Network '$vnet_name' already exists"
    else
        az network vnet create \
            --resource-group "$rg_name" \
            --name "$vnet_name" \
            --address-prefixes "$address_space" \
            --location "$location" \
            --output table
        
        log_success "Virtual Network '$vnet_name' created"
    fi
}

# Function to create subnets
create_subnets() {
    local rg_name
    local vnet_name
    local nsg_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    nsg_name=$(jq -r '.network.networkSecurityGroup.name' "$CONFIG_FILE")
    
    log_info "Creating subnets..."
    
    # Get subnet names from config
    local subnet_keys
    subnet_keys=$(jq -r '.network.subnets | keys[]' "$CONFIG_FILE")
    
    while IFS= read -r subnet_key; do
        local subnet_name
        local address_prefix
        
        subnet_name=$(jq -r ".network.subnets.$subnet_key.name" "$CONFIG_FILE")
        address_prefix=$(jq -r ".network.subnets.$subnet_key.addressPrefix" "$CONFIG_FILE")
        
        log_info "Creating subnet: $subnet_name ($address_prefix)"
        
        # Check if subnet already exists
        if az network vnet subnet show --resource-group "$rg_name" --vnet-name "$vnet_name" --name "$subnet_name" &> /dev/null; then
            log_warning "Subnet '$subnet_name' already exists"
        else
            az network vnet subnet create \
                --resource-group "$rg_name" \
                --vnet-name "$vnet_name" \
                --name "$subnet_name" \
                --address-prefixes "$address_prefix" \
                --network-security-group "$nsg_name" \
                --output table
            
            log_success "Subnet '$subnet_name' created"
        fi
    done <<< "$subnet_keys"
}

# Function to create public IP for load balancer (if needed)
create_public_ip() {
    local rg_name
    local location
    local public_ip_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    public_ip_name="sql-ha-public-ip"
    
    log_info "Creating public IP for external access: $public_ip_name"
    
    # Check if public IP already exists
    if az network public-ip show --resource-group "$rg_name" --name "$public_ip_name" &> /dev/null; then
        log_warning "Public IP '$public_ip_name' already exists"
    else
        az network public-ip create \
            --resource-group "$rg_name" \
            --name "$public_ip_name" \
            --location "$location" \
            --allocation-method Static \
            --sku Standard \
            --output table
        
        log_success "Public IP '$public_ip_name' created"
    fi
}

# Function to validate network creation
validate_network_creation() {
    local rg_name
    local vnet_name
    local nsg_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    nsg_name=$(jq -r '.network.networkSecurityGroup.name' "$CONFIG_FILE")
    
    log_info "Validating network infrastructure..."
    
    # Check VNet
    if ! az network vnet show --resource-group "$rg_name" --name "$vnet_name" --output none 2>/dev/null; then
        log_error "Virtual Network validation failed"
        return 1
    fi
    
    # Check NSG
    if ! az network nsg show --resource-group "$rg_name" --name "$nsg_name" --output none 2>/dev/null; then
        log_error "Network Security Group validation failed"
        return 1
    fi
    
    # Check subnets
    local subnet_keys
    subnet_keys=$(jq -r '.network.subnets | keys[]' "$CONFIG_FILE")
    
    while IFS= read -r subnet_key; do
        local subnet_name
        subnet_name=$(jq -r ".network.subnets.$subnet_key.name" "$CONFIG_FILE")
        
        if ! az network vnet subnet show --resource-group "$rg_name" --vnet-name "$vnet_name" --name "$subnet_name" --output none 2>/dev/null; then
            log_error "Subnet '$subnet_name' validation failed"
            return 1
        fi
    done <<< "$subnet_keys"
    
    log_success "Network infrastructure validation passed"
    return 0
}

# Function to display network summary
display_network_summary() {
    local rg_name
    local vnet_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    
    log_success "Network infrastructure created successfully!"
    echo
    log_info "Network Summary:"
    
    # Display VNet info
    local vnet_info
    vnet_info=$(az network vnet show --resource-group "$rg_name" --name "$vnet_name" --query '{name:name,addressSpace:addressSpace.addressPrefixes[0],location:location}' -o table)
    echo "$vnet_info"
    
    echo
    log_info "Subnets:"
    
    # Display subnet info
    az network vnet subnet list --resource-group "$rg_name" --vnet-name "$vnet_name" --query '[].{Name:name,AddressPrefix:addressPrefix,NSG:networkSecurityGroup.id}' -o table
    
    echo
}

# Function to show next steps
show_next_steps() {
    echo
    log_info "Next steps:"
    log_info "1. Run: ./scripts/infrastructure/03-create-domain-controller.sh"
    log_info "2. Review the network configuration in Azure Portal"
    log_info "3. Verify NSG rules are appropriate for your security requirements"
    echo
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - Network Infrastructure Creation"
    echo "============================================================================="
    echo
    
    # Check dependencies
    check_dependencies
    
    # Load configuration
    load_config
    
    # Check Azure context
    check_azure_context
    
    # Verify resource group exists
    verify_resource_group
    
    # Create network security group
    create_network_security_group
    
    # Create virtual network
    create_virtual_network
    
    # Create subnets
    create_subnets
    
    # Create public IP
    create_public_ip
    
    # Validate creation
    if validate_network_creation; then
        display_network_summary
        show_next_steps
    else
        log_error "Network infrastructure validation failed"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

