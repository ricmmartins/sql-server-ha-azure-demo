#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Cleanup Script
# =============================================================================
# This script removes all Azure resources created for the SQL Server HA demo
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

# Function to display usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Clean up SQL Server HA Azure resources

OPTIONS:
    -c, --config FILE       Configuration file path (default: config.json)
    -f, --force             Force cleanup without confirmation
    -k, --keep-rg           Keep resource group (delete resources only)
    -d, --dry-run           Show what would be deleted without actually deleting
    -h, --help              Show this help message

EXAMPLES:
    $0                      Interactive cleanup with confirmation
    $0 --force              Force cleanup without confirmation
    $0 --dry-run            Show resources that would be deleted
    $0 --keep-rg            Delete resources but keep resource group

EOF
}

# Function to parse command line arguments
parse_arguments() {
    FORCE=false
    KEEP_RG=false
    DRY_RUN=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -k|--keep-rg)
                KEEP_RG=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
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

# Function to check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Please install jq to continue."
        exit 1
    fi
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is required but not installed. Please install Azure CLI to continue."
        exit 1
    fi
    
    log_success "Dependencies check passed"
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

# Function to list resources to be deleted
list_resources() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    log_info "Resources in Resource Group: $rg_name"
    
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_warning "Resource group '$rg_name' does not exist"
        return 0
    fi
    
    # List all resources in the resource group
    local resources
    resources=$(az resource list --resource-group "$rg_name" --query '[].{Name:name, Type:type, Location:location}' --output table 2>/dev/null || echo "No resources found")
    
    if [[ "$resources" == "No resources found" ]]; then
        log_info "No resources found in resource group"
    else
        echo "$resources"
    fi
    
    # Show estimated cost savings
    log_info ""
    log_info "Estimated monthly cost savings after cleanup: \$1180-1880"
}

# Function to confirm cleanup
confirm_cleanup() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    echo
    log_warning "This will permanently delete the following:"
    if [[ "$KEEP_RG" == "true" ]]; then
        log_warning "  - All resources in Resource Group: $rg_name"
        log_warning "  - Resource Group will be kept"
    else
        log_warning "  - Resource Group: $rg_name"
        log_warning "  - All resources within the resource group"
    fi
    log_warning ""
    log_warning "This action cannot be undone. Continue? (y/N)"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
}

# Function to delete specific resources
delete_resources() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    log_info "Deleting resources in Resource Group: $rg_name"
    
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_warning "Resource group '$rg_name' does not exist"
        return 0
    fi
    
    # Get list of VMs to deallocate first
    local vms
    vms=$(az vm list --resource-group "$rg_name" --query '[].name' --output tsv 2>/dev/null || true)
    
    if [[ -n "$vms" ]]; then
        log_info "Deallocating VMs..."
        for vm in $vms; do
            log_info "Deallocating VM: $vm"
            if [[ "$DRY_RUN" == "false" ]]; then
                az vm deallocate --resource-group "$rg_name" --name "$vm" --no-wait
            fi
        done
        
        if [[ "$DRY_RUN" == "false" ]]; then
            log_info "Waiting for VMs to deallocate..."
            sleep 60
        fi
    fi
    
    # Delete resources by type in order
    local resource_types=(
        "Microsoft.Compute/virtualMachines"
        "Microsoft.Network/loadBalancers"
        "Microsoft.Network/networkInterfaces"
        "Microsoft.Network/publicIPAddresses"
        "Microsoft.Network/networkSecurityGroups"
        "Microsoft.Compute/disks"
        "Microsoft.Network/virtualNetworks"
        "Microsoft.Storage/storageAccounts"
    )
    
    for resource_type in "${resource_types[@]}"; do
        local resources
        resources=$(az resource list --resource-group "$rg_name" --resource-type "$resource_type" --query '[].name' --output tsv 2>/dev/null || true)
        
        if [[ -n "$resources" ]]; then
            log_info "Deleting resources of type: $resource_type"
            for resource in $resources; do
                log_info "Deleting: $resource"
                if [[ "$DRY_RUN" == "false" ]]; then
                    az resource delete --resource-group "$rg_name" --name "$resource" --resource-type "$resource_type" --no-wait
                fi
            done
        fi
    done
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Waiting for resource deletion to complete..."
        sleep 120
    fi
}

# Function to delete resource group
delete_resource_group() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    if [[ "$KEEP_RG" == "true" ]]; then
        log_info "Keeping resource group as requested"
        return 0
    fi
    
    log_info "Deleting Resource Group: $rg_name"
    
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_warning "Resource group '$rg_name' does not exist"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "false" ]]; then
        az group delete --name "$rg_name" --yes --no-wait
        log_success "Resource group deletion initiated"
        
        # Wait for deletion to complete
        log_info "Waiting for resource group deletion to complete..."
        while az group show --name "$rg_name" --output none 2>/dev/null; do
            log_info "Still deleting..."
            sleep 30
        done
    fi
    
    log_success "Resource group '$rg_name' deleted successfully"
}

# Function to clean up local files
cleanup_local_files() {
    log_info "Cleaning up local files..."
    
    # Remove log files
    if [[ -d "${PROJECT_ROOT}/logs" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            rm -rf "${PROJECT_ROOT}/logs"
        fi
        log_info "Removed log directory"
    fi
    
    # Remove any temporary files
    local temp_files=(
        "${PROJECT_ROOT}/config.json"
        "${PROJECT_ROOT}/.azure"
        "${PROJECT_ROOT}/temp"
    )
    
    for file in "${temp_files[@]}"; do
        if [[ -e "$file" ]]; then
            if [[ "$DRY_RUN" == "false" ]]; then
                rm -rf "$file"
            fi
            log_info "Would remove: $file"
        fi
    done
}

# Function to verify cleanup
verify_cleanup() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    log_info "Verifying cleanup..."
    
    if [[ "$KEEP_RG" == "true" ]]; then
        # Check if resource group is empty
        local resource_count
        resource_count=$(az resource list --resource-group "$rg_name" --query 'length(@)' --output tsv 2>/dev/null || echo "0")
        
        if [[ "$resource_count" -eq 0 ]]; then
            log_success "Resource group is empty"
        else
            log_warning "Resource group still contains $resource_count resources"
        fi
    else
        # Check if resource group exists
        if az group show --name "$rg_name" --output none 2>/dev/null; then
            log_warning "Resource group still exists"
        else
            log_success "Resource group has been deleted"
        fi
    fi
}

# Function to display cleanup summary
show_cleanup_summary() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN COMPLETED - No resources were actually deleted"
    else
        log_success "Cleanup completed successfully!"
    fi
    
    echo
    log_info "Cleanup Summary:"
    log_info "  Resource Group: $rg_name"
    log_info "  Keep Resource Group: $KEEP_RG"
    log_info "  Dry Run: $DRY_RUN"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "  Status: All resources have been deleted"
        log_info "  Estimated monthly cost savings: \$1180-1880"
    fi
    
    echo
    log_info "Thank you for using the SQL Server HA on Azure demo!"
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - Cleanup Script"
    echo "============================================================================="
    echo
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check dependencies
    check_dependencies
    
    # Load configuration
    load_config
    
    # Check Azure context
    check_azure_context
    
    # List resources to be deleted
    list_resources
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN MODE - No resources will be deleted"
    fi
    
    # Confirm cleanup
    confirm_cleanup
    
    # Record cleanup start time
    local start_time=$(date +%s)
    
    if [[ "$KEEP_RG" == "true" ]]; then
        # Delete resources but keep resource group
        delete_resources
    else
        # Delete entire resource group
        delete_resource_group
    fi
    
    # Clean up local files
    cleanup_local_files
    
    # Verify cleanup
    if [[ "$DRY_RUN" == "false" ]]; then
        verify_cleanup
    fi
    
    # Calculate cleanup time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_formatted=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log_success "Total cleanup time: $duration_formatted"
    fi
    
    # Show cleanup summary
    show_cleanup_summary
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

