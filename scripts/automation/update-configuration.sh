#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Configuration Update Script
# =============================================================================
# This script updates the configuration of an existing SQL Server HA deployment
# Author: Manus AI
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Script directory and configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config.json"
LOG_DIR="${PROJECT_ROOT}/logs"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="${LOG_DIR}/config-update-${TIMESTAMP}.log"

# Create logs directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Logging functions
log_info() {
    echo "[INFO] $1" | tee -a "${LOG_FILE}"
}

log_success() {
    echo "[SUCCESS] $1" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo "[WARNING] $1" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[ERROR] $1" | tee -a "${LOG_FILE}"
}

log_phase() {
    echo ""
    echo "============================================================================="
    echo "$1"
    echo "============================================================================="
    echo ""
} | tee -a "${LOG_FILE}"

show_usage() {
    cat << EOF
=============================================================================
SQL Server HA on Azure - Configuration Update Script
=============================================================================

Usage: $0 [OPTIONS]

Update configuration of existing SQL Server HA deployment on Azure

OPTIONS:
    -c, --config FILE       Configuration file path (default: config.json)
    -t, --target TYPE       Update target: network, sql, cluster, all (default: all)
    -v, --validate-only     Validate configuration changes only
    -f, --force             Force update without confirmation
    -h, --help              Show this help message

UPDATE TARGETS:
    network                 Update network configuration
    sql                     Update SQL Server configuration
    cluster                 Update cluster configuration
    all                     Update all components

EXAMPLES:
    $0                                  Update all components with default config
    $0 -c custom.json                   Update with custom configuration
    $0 -t network                       Update network configuration only
    $0 --validate-only                  Validate configuration changes only
    $0 -f                               Force update without confirmation

EOF
}

parse_arguments() {
    UPDATE_TARGET="all"
    VALIDATE_ONLY=false
    FORCE_UPDATE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--target)
                UPDATE_TARGET="$2"
                shift 2
                ;;
            -v|--validate-only)
                VALIDATE_ONLY=true
                shift
                ;;
            -f|--force)
                FORCE_UPDATE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    # Check required tools
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v az &> /dev/null; then
        missing_deps+=("azure-cli")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing dependencies and try again"
        exit 1
    fi
    
    log_success "All dependencies are available"
}

validate_configuration() {
    log_info "Validating configuration file: ${CONFIG_FILE}"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "${CONFIG_FILE}" 2>/dev/null; then
        log_error "Invalid JSON syntax in configuration file"
        exit 1
    fi
    
    # Check required sections
    local required_sections=("deployment" "network" "sqlServers" "cluster")
    for section in "${required_sections[@]}"; do
        if ! jq -e ".${section}" "${CONFIG_FILE}" >/dev/null 2>&1; then
            log_error "Missing required section: ${section}"
            exit 1
        fi
    done
    
    log_success "Configuration file is valid"
}

get_current_deployment_info() {
    log_info "Getting current deployment information..."
    
    RESOURCE_GROUP=$(jq -r '.deployment.resourceGroupName' "${CONFIG_FILE}")
    SUBSCRIPTION_ID=$(jq -r '.deployment.subscriptionId' "${CONFIG_FILE}")
    LOCATION=$(jq -r '.deployment.location' "${CONFIG_FILE}")
    
    # Set Azure subscription
    az account set --subscription "${SUBSCRIPTION_ID}"
    
    # Check if resource group exists
    if ! az group show --name "${RESOURCE_GROUP}" >/dev/null 2>&1; then
        log_error "Resource group '${RESOURCE_GROUP}' not found"
        log_info "Please ensure the deployment exists before updating configuration"
        exit 1
    fi
    
    log_success "Found existing deployment in resource group: ${RESOURCE_GROUP}"
}

update_network_configuration() {
    log_phase "Updating Network Configuration"
    
    local vnet_name=$(jq -r '.network.virtualNetworkName' "${CONFIG_FILE}")
    local address_space=$(jq -r '.network.addressSpace' "${CONFIG_FILE}")
    
    log_info "Updating virtual network: ${vnet_name}"
    
    # Update network security group rules
    local nsg_name=$(jq -r '.network.networkSecurityGroup.name' "${CONFIG_FILE}")
    
    # Get existing NSG rules and update if necessary
    log_info "Updating network security group rules..."
    
    # Example: Update RDP access rule
    local rdp_source=$(jq -r '.network.networkSecurityGroup.rules[] | select(.name=="AllowRDP") | .sourceAddressPrefix' "${CONFIG_FILE}")
    
    if [[ "${rdp_source}" != "null" ]]; then
        az network nsg rule update \
            --resource-group "${RESOURCE_GROUP}" \
            --nsg-name "${nsg_name}" \
            --name "AllowRDP" \
            --source-address-prefixes "${rdp_source}" \
            --output none
        
        log_success "Updated RDP access rule"
    fi
    
    log_success "Network configuration updated successfully"
}

update_sql_configuration() {
    log_phase "Updating SQL Server Configuration"
    
    local sql_nodes=$(jq -r '.sqlServers.nodes | length' "${CONFIG_FILE}")
    
    log_info "Updating configuration for ${sql_nodes} SQL Server nodes"
    
    # Update SQL Server VM configurations
    for ((i=0; i<sql_nodes; i++)); do
        local vm_name=$(jq -r ".sqlServers.nodes[${i}].vmName" "${CONFIG_FILE}")
        local vm_size=$(jq -r '.sqlServers.vmSize' "${CONFIG_FILE}")
        
        log_info "Checking VM size for ${vm_name}..."
        
        local current_size=$(az vm show \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${vm_name}" \
            --query "hardwareProfile.vmSize" \
            --output tsv)
        
        if [[ "${current_size}" != "${vm_size}" ]]; then
            log_info "Updating VM size from ${current_size} to ${vm_size}..."
            
            # Deallocate VM
            az vm deallocate \
                --resource-group "${RESOURCE_GROUP}" \
                --name "${vm_name}" \
                --output none
            
            # Resize VM
            az vm resize \
                --resource-group "${RESOURCE_GROUP}" \
                --name "${vm_name}" \
                --size "${vm_size}" \
                --output none
            
            # Start VM
            az vm start \
                --resource-group "${RESOURCE_GROUP}" \
                --name "${vm_name}" \
                --output none
            
            log_success "Updated VM size for ${vm_name}"
        else
            log_info "VM size for ${vm_name} is already correct"
        fi
    done
    
    log_success "SQL Server configuration updated successfully"
}

update_cluster_configuration() {
    log_phase "Updating Cluster Configuration"
    
    local cluster_name=$(jq -r '.cluster.name' "${CONFIG_FILE}")
    local ag_name=$(jq -r '.availabilityGroup.name' "${CONFIG_FILE}")
    
    log_info "Updating cluster configuration for: ${cluster_name}"
    log_info "Updating availability group configuration for: ${ag_name}"
    
    # Update load balancer configuration
    local lb_name=$(jq -r '.loadBalancer.name' "${CONFIG_FILE}")
    local listener_port=$(jq -r '.availabilityGroup.listenerPort' "${CONFIG_FILE}")
    
    log_info "Updating load balancer configuration..."
    
    # Update load balancing rule port if changed
    az network lb rule update \
        --resource-group "${RESOURCE_GROUP}" \
        --lb-name "${lb_name}" \
        --name "SQLRule" \
        --frontend-port "${listener_port}" \
        --backend-port "${listener_port}" \
        --output none
    
    log_success "Cluster configuration updated successfully"
}

confirm_update() {
    if [[ "${FORCE_UPDATE}" == "true" ]]; then
        return 0
    fi
    
    echo ""
    echo "============================================================================="
    echo "CONFIGURATION UPDATE CONFIRMATION"
    echo "============================================================================="
    echo "Resource Group: ${RESOURCE_GROUP}"
    echo "Update Target: ${UPDATE_TARGET}"
    echo "Configuration File: ${CONFIG_FILE}"
    echo ""
    echo "This will update the existing deployment configuration."
    echo "Some operations may require VM restarts."
    echo ""
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Update cancelled by user"
        exit 0
    fi
}

main() {
    log_phase "SQL Server HA Configuration Update Started"
    log_info "Update started at $(date)"
    log_info "Log file: ${LOG_FILE}"
    
    parse_arguments "$@"
    check_dependencies
    validate_configuration
    get_current_deployment_info
    
    if [[ "${VALIDATE_ONLY}" == "true" ]]; then
        log_success "Configuration validation completed successfully"
        exit 0
    fi
    
    confirm_update
    
    case "${UPDATE_TARGET}" in
        network)
            update_network_configuration
            ;;
        sql)
            update_sql_configuration
            ;;
        cluster)
            update_cluster_configuration
            ;;
        all)
            update_network_configuration
            update_sql_configuration
            update_cluster_configuration
            ;;
        *)
            log_error "Invalid update target: ${UPDATE_TARGET}"
            show_usage
            exit 1
            ;;
    esac
    
    log_phase "Configuration Update Completed Successfully"
    log_success "Update completed at $(date)"
    log_info "Log file saved to: ${LOG_FILE}"
    
    echo ""
    echo "============================================================================="
    echo "NEXT STEPS"
    echo "============================================================================="
    echo "1. Verify the updated configuration is working correctly"
    echo "2. Test SQL Server connectivity and availability group functionality"
    echo "3. Update monitoring and alerting configurations if necessary"
    echo "4. Document the configuration changes for future reference"
    echo ""
}

# Execute main function with all arguments
main "$@"

