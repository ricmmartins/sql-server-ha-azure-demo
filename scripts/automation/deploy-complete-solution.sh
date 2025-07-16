#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Master Deployment Script
# =============================================================================
# This script orchestrates the complete deployment of SQL Server High
# Availability infrastructure on Azure using Azure CLI
# Author: Manus AI
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config.json"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/deployment-$(date +%Y%m%d-%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE"
}

log_success() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
}

log_phase() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${PURPLE}[PHASE]${NC} $message" | tee -a "$LOG_FILE"
}

# Function to display usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy SQL Server High Availability infrastructure on Azure

OPTIONS:
    -c, --config FILE       Configuration file path (default: config.json)
    -s, --skip-infra        Skip infrastructure deployment
    -p, --skip-sql          Skip SQL Server configuration
    -t, --test-only         Run tests only (no deployment)
    -v, --validate-only     Validate configuration only
    -f, --force             Force deployment (skip confirmations)
    -h, --help              Show this help message

EXAMPLES:
    $0                      Full deployment with default config
    $0 -c custom.json       Deploy with custom configuration
    $0 --skip-infra         Skip infrastructure, configure SQL only
    $0 --test-only          Run validation tests only
    $0 --validate-only      Validate configuration and exit

EOF
}

# Function to parse command line arguments
parse_arguments() {
    SKIP_INFRA=false
    SKIP_SQL=false
    TEST_ONLY=false
    VALIDATE_ONLY=false
    FORCE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--skip-infra)
                SKIP_INFRA=true
                shift
                ;;
            -p|--skip-sql)
                SKIP_SQL=true
                shift
                ;;
            -t|--test-only)
                TEST_ONLY=true
                shift
                ;;
            -v|--validate-only)
                VALIDATE_ONLY=true
                shift
                ;;
            -f|--force)
                FORCE=true
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
    
    local missing_deps=()
    
    # Check required tools
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v az &> /dev/null; then
        missing_deps+=("azure-cli")
    fi
    
    if ! command -v ssh &> /dev/null; then
        missing_deps+=("ssh")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing dependencies and try again"
        exit 1
    fi
    
    log_success "All dependencies are available"
}

# Function to validate configuration
validate_configuration() {
    log_info "Validating configuration file: $CONFIG_FILE"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Please copy examples/config-template.json to config.json and customize it"
        exit 1
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "Invalid JSON in configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    # Validate required fields
    local required_fields=(
        ".deployment.subscriptionId"
        ".deployment.resourceGroupName"
        ".deployment.location"
        ".network.virtualNetworkName"
        ".domainController.vmName"
        ".sqlServers.nodes"
        ".cluster.clusterName"
        ".availabilityGroup.name"
    )
    
    for field in "${required_fields[@]}"; do
        if ! jq -e "$field" "$CONFIG_FILE" >/dev/null 2>&1; then
            log_error "Missing required configuration field: $field"
            exit 1
        fi
    done
    
    log_success "Configuration validation passed"
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
        log_info "Switching to target subscription: $target_subscription"
        az account set --subscription "$target_subscription"
    fi
    
    local subscription_name
    subscription_name=$(az account show --query name -o tsv)
    log_success "Azure CLI context verified - Subscription: $subscription_name"
}

# Function to create log directory
setup_logging() {
    mkdir -p "$LOG_DIR"
    log_info "Deployment started at $(date)"
    log_info "Log file: $LOG_FILE"
}

# Function to display deployment summary
show_deployment_summary() {
    local rg_name
    local location
    local cluster_name
    local ag_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    cluster_name=$(jq -r '.cluster.clusterName' "$CONFIG_FILE")
    ag_name=$(jq -r '.availabilityGroup.name' "$CONFIG_FILE")
    
    log_info "Deployment Summary:"
    log_info "  Resource Group: $rg_name"
    log_info "  Location: $location"
    log_info "  Cluster: $cluster_name"
    log_info "  Availability Group: $ag_name"
    log_info "  Configuration: $CONFIG_FILE"
    log_info "  Skip Infrastructure: $SKIP_INFRA"
    log_info "  Skip SQL Config: $SKIP_SQL"
    log_info "  Test Only: $TEST_ONLY"
    log_info "  Validate Only: $VALIDATE_ONLY"
}

# Function to confirm deployment
confirm_deployment() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    echo
    log_warning "This will deploy SQL Server HA infrastructure to Azure."
    log_warning "This may incur Azure charges. Continue? (y/N)"
    read -r response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled by user"
        exit 0
    fi
}

# Function to deploy infrastructure
deploy_infrastructure() {
    if [[ "$SKIP_INFRA" == "true" ]]; then
        log_info "Skipping infrastructure deployment"
        return 0
    fi
    
    log_phase "PHASE 1: Infrastructure Deployment"
    
    local infra_scripts=(
        "01-create-resource-group.sh"
        "02-create-network.sh"
        "03-create-domain-controller.sh"
        "04-create-sql-vms.sh"
        "05-create-load-balancer.sh"
    )
    
    for script in "${infra_scripts[@]}"; do
        local script_path="${PROJECT_ROOT}/scripts/infrastructure/$script"
        
        if [[ -f "$script_path" ]]; then
            log_info "Executing: $script"
            
            if bash "$script_path"; then
                log_success "Completed: $script"
            else
                log_error "Failed: $script"
                return 1
            fi
        else
            log_error "Script not found: $script_path"
            return 1
        fi
        
        # Add delay between scripts for Azure resource provisioning
        log_info "Waiting for Azure resources to stabilize..."
        sleep 30
    done
    
    log_success "Infrastructure deployment completed"
}

# Function to configure SQL Server
configure_sql_server() {
    if [[ "$SKIP_SQL" == "true" ]]; then
        log_info "Skipping SQL Server configuration"
        return 0
    fi
    
    log_phase "PHASE 2: SQL Server Configuration"
    
    # Get SQL Server node information
    local nodes_count
    nodes_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    
    log_info "Configuring SQL Server on $nodes_count nodes"
    
    # Note: PowerShell scripts need to be executed on the VMs
    # This would typically be done through Azure VM Run Command or remote PowerShell
    log_info "SQL Server configuration requires PowerShell scripts to be executed on VMs"
    log_info "Please run the following scripts on each SQL Server VM:"
    log_info "1. scripts/sql-config/01-install-failover-clustering.ps1"
    log_info "2. scripts/sql-config/02-create-wsfc-cluster.ps1"
    log_info "3. scripts/sql-config/03-enable-always-on.ps1"
    log_info "4. scripts/sql-config/04-create-availability-group.ps1"
    
    log_warning "SQL Server configuration requires manual execution on VMs"
    log_info "Use the provided PowerShell scripts in scripts/sql-config/"
}

# Function to run tests
run_tests() {
    log_phase "PHASE 3: Testing and Validation"
    
    local test_script="${PROJECT_ROOT}/scripts/testing/test-deployment.sh"
    
    if [[ -f "$test_script" ]]; then
        log_info "Running deployment tests..."
        
        if bash "$test_script"; then
            log_success "All tests passed"
        else
            log_error "Some tests failed"
            return 1
        fi
    else
        log_warning "Test script not found: $test_script"
    fi
}

# Function to display next steps
show_next_steps() {
    local rg_name
    local listener_name
    local listener_ip
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    listener_name=$(jq -r '.availabilityGroup.listenerName' "$CONFIG_FILE")
    listener_ip=$(jq -r '.availabilityGroup.listenerIpAddress' "$CONFIG_FILE")
    
    log_success "Deployment completed successfully!"
    echo
    log_info "Next Steps:"
    log_info "1. Connect to SQL Server VMs and run PowerShell configuration scripts"
    log_info "2. Test SQL Server connectivity through the listener: $listener_name ($listener_ip)"
    log_info "3. Configure monitoring and alerting"
    log_info "4. Set up backup strategies"
    log_info "5. Test failover scenarios"
    echo
    log_info "Resources created in Resource Group: $rg_name"
    log_info "View resources in Azure Portal: https://portal.azure.com"
    echo
    log_info "For cleanup, run: ./scripts/automation/cleanup.sh"
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    log_error "Deployment failed with exit code: $exit_code"
    log_info "Check the log file for details: $LOG_FILE"
    
    if [[ "$FORCE" != "true" ]]; then
        log_warning "Do you want to run cleanup? (y/N)"
        read -r response
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log_info "Running cleanup..."
            bash "${PROJECT_ROOT}/scripts/automation/cleanup.sh" || true
        fi
    fi
    
    exit $exit_code
}

# Function to estimate costs
estimate_costs() {
    local vm_count
    local vm_size
    local location
    
    vm_count=$(jq '.sqlServers.nodes | length' "$CONFIG_FILE")
    vm_size=$(jq -r '.sqlServers.vmSize' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Estimated Monthly Costs (approximate):"
    log_info "  SQL Server VMs ($vm_count x $vm_size): \$800-1200"
    log_info "  Domain Controller VM: \$100-150"
    log_info "  Witness VM: \$50-80"
    log_info "  Storage (Premium SSD): \$200-400"
    log_info "  Load Balancer: \$20-30"
    log_info "  Network: \$10-20"
    log_info "  Total Estimated: \$1180-1880 per month"
    echo
    log_warning "Actual costs may vary based on usage and region"
    log_info "Use Azure Pricing Calculator for accurate estimates"
}

# Main execution function
main() {
    # Set up error handling
    trap handle_error ERR
    
    echo "============================================================================="
    echo "SQL Server HA on Azure - Master Deployment Script"
    echo "============================================================================="
    echo
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Set up logging
    setup_logging
    
    # Check dependencies
    check_dependencies
    
    # Validate configuration
    validate_configuration
    
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log_success "Configuration validation completed successfully"
        exit 0
    fi
    
    # Check Azure context
    check_azure_context
    
    # Show deployment summary
    show_deployment_summary
    
    # Estimate costs
    estimate_costs
    
    if [[ "$TEST_ONLY" == "true" ]]; then
        run_tests
        exit 0
    fi
    
    # Confirm deployment
    confirm_deployment
    
    # Record deployment start time
    local start_time=$(date +%s)
    
    # Deploy infrastructure
    if ! deploy_infrastructure; then
        log_error "Infrastructure deployment failed"
        exit 1
    fi
    
    # Configure SQL Server
    configure_sql_server
    
    # Run tests
    run_tests
    
    # Calculate deployment time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_formatted=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))
    
    log_success "Total deployment time: $duration_formatted"
    
    # Show next steps
    show_next_steps
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

