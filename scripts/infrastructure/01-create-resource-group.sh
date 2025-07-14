#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Resource Group Creation Script
# =============================================================================
# This script creates the Azure resource group for the SQL Server HA deployment
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

# Function to check if jq is installed
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
        log_info "Please copy examples/config-template.json to config.json and update with your values"
        exit 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "Invalid JSON in configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    log_success "Configuration loaded successfully"
}

# Function to check Azure CLI login status
check_azure_login() {
    log_info "Checking Azure CLI login status..."
    
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI. Please run 'az login' first."
        exit 1
    fi
    
    local current_subscription
    current_subscription=$(az account show --query id -o tsv)
    local target_subscription
    target_subscription=$(jq -r '.deployment.subscriptionId' "$CONFIG_FILE")
    
    if [[ "$current_subscription" != "$target_subscription" ]]; then
        log_warning "Current subscription ($current_subscription) doesn't match target ($target_subscription)"
        log_info "Setting subscription to: $target_subscription"
        az account set --subscription "$target_subscription"
    fi
    
    log_success "Azure CLI authentication verified"
}

# Function to create resource group
create_resource_group() {
    local rg_name
    local location
    local tags
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating resource group: $rg_name in $location"
    
    # Check if resource group already exists
    if az group show --name "$rg_name" &> /dev/null; then
        log_warning "Resource group '$rg_name' already exists"
        
        # Ask user if they want to continue
        read -p "Do you want to continue with existing resource group? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled by user"
            exit 0
        fi
    else
        # Create the resource group
        az group create \
            --name "$rg_name" \
            --location "$location" \
            --output table
        
        log_success "Resource group '$rg_name' created successfully"
    fi
    
    # Apply tags to resource group
    log_info "Applying tags to resource group..."
    
    local tag_args=""
    while IFS= read -r key; do
        local value
        value=$(jq -r ".deployment.tags[\"$key\"]" "$CONFIG_FILE")
        tag_args+="$key=$value "
    done < <(jq -r '.deployment.tags | keys[]' "$CONFIG_FILE")
    
    if [[ -n "$tag_args" ]]; then
        az group update \
            --name "$rg_name" \
            --tags $tag_args \
            --output table
        
        log_success "Tags applied successfully"
    fi
}

# Function to create deployment metadata
create_deployment_metadata() {
    local rg_name
    local deployment_name
    local timestamp
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    deployment_name=$(jq -r '.deployment.deploymentName' "$CONFIG_FILE")
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_info "Creating deployment metadata..."
    
    # Create a deployment tag to track this deployment
    az group update \
        --name "$rg_name" \
        --tags DeploymentName="$deployment_name" \
                DeploymentTimestamp="$timestamp" \
                DeploymentScript="01-create-resource-group.sh" \
        --output none
    
    log_success "Deployment metadata created"
}

# Function to validate resource group creation
validate_resource_group() {
    local rg_name
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    
    log_info "Validating resource group creation..."
    
    if az group show --name "$rg_name" --output none 2>/dev/null; then
        local rg_location
        local rg_state
        
        rg_location=$(az group show --name "$rg_name" --query location -o tsv)
        rg_state=$(az group show --name "$rg_name" --query properties.provisioningState -o tsv)
        
        log_success "Resource group validation passed:"
        log_info "  Name: $rg_name"
        log_info "  Location: $rg_location"
        log_info "  State: $rg_state"
        
        return 0
    else
        log_error "Resource group validation failed"
        return 1
    fi
}

# Function to display next steps
show_next_steps() {
    log_success "Resource group creation completed successfully!"
    echo
    log_info "Next steps:"
    log_info "1. Run: ./scripts/infrastructure/02-create-network.sh"
    log_info "2. Review the created resource group in Azure Portal"
    log_info "3. Verify the applied tags and metadata"
    echo
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - Resource Group Creation"
    echo "============================================================================="
    echo
    
    # Check dependencies
    check_dependencies
    
    # Load configuration
    load_config
    
    # Check Azure login
    check_azure_login
    
    # Create resource group
    create_resource_group
    
    # Create deployment metadata
    create_deployment_metadata
    
    # Validate creation
    if validate_resource_group; then
        show_next_steps
    else
        log_error "Resource group creation validation failed"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

