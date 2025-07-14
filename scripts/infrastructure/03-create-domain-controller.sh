#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Domain Controller Creation Script
# =============================================================================
# This script creates and configures the Active Directory Domain Controller
# required for Windows Server Failover Cluster
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
    local subnet_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    subnet_name=$(jq -r '.network.subnets.domain.name' "$CONFIG_FILE")
    
    log_info "Verifying prerequisites..."
    
    # Check resource group
    if ! az group show --name "$rg_name" --output none 2>/dev/null; then
        log_error "Resource group '$rg_name' does not exist"
        log_info "Please run: ./scripts/infrastructure/01-create-resource-group.sh first"
        exit 1
    fi
    
    # Check virtual network
    if ! az network vnet show --resource-group "$rg_name" --name "$vnet_name" --output none 2>/dev/null; then
        log_error "Virtual network '$vnet_name' does not exist"
        log_info "Please run: ./scripts/infrastructure/02-create-network.sh first"
        exit 1
    fi
    
    # Check domain subnet
    if ! az network vnet subnet show --resource-group "$rg_name" --vnet-name "$vnet_name" --name "$subnet_name" --output none 2>/dev/null; then
        log_error "Domain subnet '$subnet_name' does not exist"
        log_info "Please run: ./scripts/infrastructure/02-create-network.sh first"
        exit 1
    fi
    
    log_success "Prerequisites verified"
}

# Function to create domain controller VM
create_domain_controller_vm() {
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
    vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    vm_size=$(jq -r '.domainController.vmSize' "$CONFIG_FILE")
    admin_username=$(jq -r '.domainController.adminUsername' "$CONFIG_FILE")
    admin_password=$(jq -r '.domainController.adminPassword' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    subnet_name=$(jq -r '.network.subnets.domain.name' "$CONFIG_FILE")
    static_ip=$(jq -r '.domainController.staticIpAddress' "$CONFIG_FILE")
    location=$(jq -r '.deployment.location' "$CONFIG_FILE")
    
    log_info "Creating Domain Controller VM: $vm_name"
    
    # Check if VM already exists
    if az vm show --resource-group "$rg_name" --name "$vm_name" &> /dev/null; then
        log_warning "VM '$vm_name' already exists"
        return 0
    fi
    
    # Create the VM
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
    
    log_success "Domain Controller VM '$vm_name' created"
}

# Function to configure domain controller
configure_domain_controller() {
    local rg_name
    local vm_name
    local domain_name
    local domain_netbios_name
    local safe_mode_pwd
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    domain_netbios_name=$(jq -r '.domainController.domainNetbiosName' "$CONFIG_FILE")
    safe_mode_pwd=$(jq -r '.domainController.safeModePwd' "$CONFIG_FILE")
    
    log_info "Configuring Active Directory Domain Services on $vm_name"
    
    # Create PowerShell script for AD DS configuration
    local ps_script=$(cat << 'EOF'
# Install AD DS Role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Import AD DS Deployment module
Import-Module ADDSDeployment

# Install AD DS Forest
Install-ADDSForest `
    -DomainName $env:DOMAIN_NAME `
    -DomainNetbiosName $env:DOMAIN_NETBIOS_NAME `
    -SafeModeAdministratorPassword (ConvertTo-SecureString $env:SAFE_MODE_PWD -AsPlainText -Force) `
    -InstallDns:$true `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -Force:$true

# Configure DNS forwarders
Add-DnsServerForwarder -IPAddress 168.63.129.16 -PassThru

# Create service accounts for SQL Server
$securePassword = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force

New-ADUser -Name "sqlservice" -UserPrincipalName "sqlservice@$env:DOMAIN_NAME" -AccountPassword $securePassword -Enabled $true -PasswordNeverExpires $true
New-ADUser -Name "sqlagent" -UserPrincipalName "sqlagent@$env:DOMAIN_NAME" -AccountPassword $securePassword -Enabled $true -PasswordNeverExpires $true
New-ADUser -Name "clusterservice" -UserPrincipalName "clusterservice@$env:DOMAIN_NAME" -AccountPassword $securePassword -Enabled $true -PasswordNeverExpires $true

# Add service accounts to appropriate groups
Add-ADGroupMember -Identity "Domain Admins" -Members "sqlservice","sqlagent","clusterservice"

Write-Output "Active Directory Domain Services configuration completed"
EOF
)
    
    # Execute PowerShell script on the VM
    az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_script" \
        --parameters "DOMAIN_NAME=$domain_name" "DOMAIN_NETBIOS_NAME=$domain_netbios_name" "SAFE_MODE_PWD=$safe_mode_pwd" \
        --output table
    
    log_success "Active Directory Domain Services configured"
}

# Function to update DNS settings for VNet
update_vnet_dns() {
    local rg_name
    local vnet_name
    local dc_ip
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vnet_name=$(jq -r '.network.virtualNetworkName' "$CONFIG_FILE")
    dc_ip=$(jq -r '.domainController.staticIpAddress' "$CONFIG_FILE")
    
    log_info "Updating VNet DNS settings to use Domain Controller"
    
    # Wait for DC to be ready
    log_info "Waiting for Domain Controller to be ready..."
    sleep 120
    
    # Update VNet DNS servers
    az network vnet update \
        --resource-group "$rg_name" \
        --name "$vnet_name" \
        --dns-servers "$dc_ip" \
        --output table
    
    log_success "VNet DNS settings updated to use Domain Controller ($dc_ip)"
}

# Function to create domain users and groups
create_domain_accounts() {
    local rg_name
    local vm_name
    local domain_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    
    log_info "Creating additional domain accounts and groups"
    
    # Create PowerShell script for additional accounts
    local ps_script=$(cat << 'EOF'
# Wait for AD services to be fully ready
Start-Sleep -Seconds 60

# Import Active Directory module
Import-Module ActiveDirectory

# Create SQL Server service accounts with proper permissions
$securePassword = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force

# Create Install account for cluster setup
New-ADUser -Name "Install" -UserPrincipalName "Install@$env:DOMAIN_NAME" -AccountPassword $securePassword -Enabled $true -PasswordNeverExpires $true
Add-ADGroupMember -Identity "Domain Admins" -Members "Install"

# Create SQL Server Administrators group
New-ADGroup -Name "SQL Server Administrators" -GroupScope Global -GroupCategory Security
Add-ADGroupMember -Identity "SQL Server Administrators" -Members "sqlservice","Install"

# Grant service accounts necessary permissions
# Log on as a service right
$tempPath = "C:\temp"
if (!(Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath }

# Create security policy template
$securityTemplate = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeServiceLogonRight = *S-1-5-21-*-sqlservice,*S-1-5-21-*-sqlagent,*S-1-5-21-*-clusterservice
"@

$securityTemplate | Out-File -FilePath "$tempPath\security.inf" -Encoding Unicode

# Apply security template
secedit /configure /db "$tempPath\security.sdb" /cfg "$tempPath\security.inf" /areas USER_RIGHTS

Write-Output "Domain accounts and permissions configured successfully"
EOF
)
    
    # Execute PowerShell script on the VM
    az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_script" \
        --parameters "DOMAIN_NAME=$domain_name" \
        --output table
    
    log_success "Domain accounts and groups created"
}

# Function to validate domain controller
validate_domain_controller() {
    local rg_name
    local vm_name
    local domain_name
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    
    log_info "Validating Domain Controller configuration..."
    
    # Check VM status
    local vm_status
    vm_status=$(az vm get-instance-view --resource-group "$rg_name" --name "$vm_name" --query instanceView.statuses[1].displayStatus -o tsv)
    
    if [[ "$vm_status" != "VM running" ]]; then
        log_error "Domain Controller VM is not running: $vm_status"
        return 1
    fi
    
    # Test domain connectivity (basic validation)
    local ps_validation_script=$(cat << 'EOF'
try {
    # Test AD Web Services
    Get-ADDomain -Current LocalComputer | Select-Object Name, DomainMode, PDCEmulator
    
    # Test DNS resolution
    Resolve-DnsName -Name $env:DOMAIN_NAME -Type A
    
    # List service accounts
    Get-ADUser -Filter "Name -like 'sql*' -or Name -eq 'Install'" | Select-Object Name, Enabled
    
    Write-Output "Domain Controller validation successful"
    exit 0
} catch {
    Write-Error "Domain Controller validation failed: $_"
    exit 1
}
EOF
)
    
    # Execute validation script
    local validation_result
    validation_result=$(az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --command-id "RunPowerShellScript" \
        --scripts "$ps_validation_script" \
        --parameters "DOMAIN_NAME=$domain_name" \
        --query 'value[0].message' -o tsv 2>/dev/null || echo "FAILED")
    
    if [[ "$validation_result" == *"successful"* ]]; then
        log_success "Domain Controller validation passed"
        return 0
    else
        log_error "Domain Controller validation failed"
        return 1
    fi
}

# Function to display domain controller summary
display_dc_summary() {
    local rg_name
    local vm_name
    local domain_name
    local dc_ip
    
    rg_name=$(jq -r '.deployment.resourceGroupName' "$CONFIG_FILE")
    vm_name=$(jq -r '.domainController.vmName' "$CONFIG_FILE")
    domain_name=$(jq -r '.domainController.domainName' "$CONFIG_FILE")
    dc_ip=$(jq -r '.domainController.staticIpAddress' "$CONFIG_FILE")
    
    log_success "Domain Controller created and configured successfully!"
    echo
    log_info "Domain Controller Summary:"
    log_info "  VM Name: $vm_name"
    log_info "  Domain: $domain_name"
    log_info "  IP Address: $dc_ip"
    log_info "  Status: Ready for SQL Server deployment"
    echo
    log_info "Service Accounts Created:"
    log_info "  - CONTOSO\\Install (Domain Admin)"
    log_info "  - CONTOSO\\sqlservice (SQL Server Service)"
    log_info "  - CONTOSO\\sqlagent (SQL Server Agent)"
    log_info "  - CONTOSO\\clusterservice (Cluster Service)"
    echo
}

# Function to show next steps
show_next_steps() {
    log_info "Next steps:"
    log_info "1. Wait 5-10 minutes for domain replication to complete"
    log_info "2. Run: ./scripts/infrastructure/04-create-sql-vms.sh"
    log_info "3. Verify domain controller is accessible from other subnets"
    echo
    log_warning "Important: All subsequent VMs will automatically join this domain"
}

# Main execution function
main() {
    echo "============================================================================="
    echo "SQL Server HA on Azure - Domain Controller Creation"
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
    
    # Create domain controller VM
    create_domain_controller_vm
    
    # Configure domain controller
    configure_domain_controller
    
    # Update VNet DNS settings
    update_vnet_dns
    
    # Create domain accounts
    create_domain_accounts
    
    # Validate domain controller
    if validate_domain_controller; then
        display_dc_summary
        show_next_steps
    else
        log_error "Domain Controller validation failed"
        log_info "Check the VM logs in Azure Portal for more details"
        exit 1
    fi
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

