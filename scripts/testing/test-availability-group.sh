#!/bin/bash

# =============================================================================
# SQL Server HA on Azure - Availability Group Testing Script
# =============================================================================
# This script tests the SQL Server Always On Availability Group functionality
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
LOG_FILE="${LOG_DIR}/ag-test-${TIMESTAMP}.log"

# Create logs directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Test configuration
TEST_DATABASE="AGTestDB"
TEST_TABLE="TestTable"
TEST_TIMEOUT=300  # 5 minutes

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
SQL Server HA on Azure - Availability Group Testing Script
=============================================================================

Usage: $0 [OPTIONS]

Test SQL Server Always On Availability Group functionality

OPTIONS:
    -c, --config FILE       Configuration file path (default: config.json)
    -t, --test-type TYPE    Test type: basic, failover, performance, all (default: all)
    -d, --database NAME     Test database name (default: AGTestDB)
    -v, --verbose           Verbose output
    -h, --help              Show this help message

TEST TYPES:
    basic                   Basic connectivity and replication tests
    failover                Failover and recovery tests
    performance             Performance and latency tests
    all                     Run all test types

EXAMPLES:
    $0                                  Run all tests with default config
    $0 -t basic                         Run basic tests only
    $0 -c custom.json -t failover       Run failover tests with custom config
    $0 -d MyTestDB -v                   Run tests with custom database and verbose output

EOF
}

parse_arguments() {
    TEST_TYPE="all"
    VERBOSE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--test-type)
                TEST_TYPE="$2"
                shift 2
                ;;
            -d|--database)
                TEST_DATABASE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
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
    
    if ! command -v sqlcmd &> /dev/null; then
        missing_deps+=("sqlcmd")
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
    
    # Extract configuration values
    RESOURCE_GROUP=$(jq -r '.deployment.resourceGroupName' "${CONFIG_FILE}")
    AG_NAME=$(jq -r '.availabilityGroup.name' "${CONFIG_FILE}")
    LISTENER_NAME=$(jq -r '.availabilityGroup.listenerName' "${CONFIG_FILE}")
    LISTENER_PORT=$(jq -r '.availabilityGroup.listenerPort' "${CONFIG_FILE}")
    SQL_NODES=($(jq -r '.sqlServers.nodes[].vmName' "${CONFIG_FILE}"))
    ADMIN_USERNAME=$(jq -r '.sqlServers.adminUsername' "${CONFIG_FILE}")
    ADMIN_PASSWORD=$(jq -r '.sqlServers.adminPassword' "${CONFIG_FILE}")
    
    log_success "Configuration validated successfully"
    log_info "Resource Group: ${RESOURCE_GROUP}"
    log_info "Availability Group: ${AG_NAME}"
    log_info "Listener: ${LISTENER_NAME}:${LISTENER_PORT}"
    log_info "SQL Nodes: ${SQL_NODES[*]}"
}

get_node_status() {
    log_phase "Getting Node Status"
    
    for node in "${SQL_NODES[@]}"; do
        log_info "Checking status of node: ${node}"
        
        # Get VM status from Azure
        local vm_status=$(az vm show \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${node}" \
            --show-details \
            --query "powerState" \
            --output tsv 2>/dev/null || echo "Unknown")
        
        log_info "  VM Status: ${vm_status}"
        
        # Test SQL Server connectivity
        if test_sql_connectivity "${node}"; then
            log_success "  SQL Server: Online"
        else
            log_warning "  SQL Server: Offline or unreachable"
        fi
    done
}

test_sql_connectivity() {
    local server="$1"
    local timeout=10
    
    if [[ "${VERBOSE}" == "true" ]]; then
        log_info "Testing SQL connectivity to ${server}..."
    fi
    
    # Test using sqlcmd
    if timeout "${timeout}" sqlcmd -S "${server}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" -Q "SELECT @@SERVERNAME" -h -1 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

test_listener_connectivity() {
    log_phase "Testing Listener Connectivity"
    
    log_info "Testing connectivity to listener: ${LISTENER_NAME}:${LISTENER_PORT}"
    
    # Test network connectivity
    if timeout 10 bash -c "</dev/tcp/${LISTENER_NAME}/${LISTENER_PORT}" 2>/dev/null; then
        log_success "Network connectivity: PASSED"
    else
        log_error "Network connectivity: FAILED"
        return 1
    fi
    
    # Test SQL Server connectivity through listener
    if test_sql_connectivity "${LISTENER_NAME}"; then
        log_success "SQL Server connectivity through listener: PASSED"
        
        # Get current primary replica
        local primary_replica=$(sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
            -Q "SELECT replica_server_name FROM sys.dm_hadr_availability_replica_states WHERE role_desc = 'PRIMARY'" \
            -h -1 2>/dev/null | tr -d '[:space:]')
        
        if [[ -n "${primary_replica}" ]]; then
            log_info "Current primary replica: ${primary_replica}"
        fi
        
        return 0
    else
        log_error "SQL Server connectivity through listener: FAILED"
        return 1
    fi
}

get_availability_group_status() {
    log_phase "Getting Availability Group Status"
    
    local primary_node="${SQL_NODES[0]}"
    
    log_info "Querying AG status from primary node: ${primary_node}"
    
    # Get AG status
    local ag_query="
    SELECT 
        ag.name AS AvailabilityGroup,
        ar.replica_server_name AS Replica,
        ar.availability_mode_desc AS AvailabilityMode,
        ar.failover_mode_desc AS FailoverMode,
        ars.role_desc AS Role,
        ars.connected_state_desc AS ConnectedState,
        ars.synchronization_health_desc AS SynchronizationHealth,
        ars.last_connect_error_description AS LastError
    FROM sys.availability_groups ag
    INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    INNER JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
    WHERE ag.name = '${AG_NAME}'
    ORDER BY ar.replica_server_name
    "
    
    local ag_status=$(sqlcmd -S "${primary_node}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${ag_query}" -s "," 2>/dev/null || echo "")
    
    if [[ -n "${ag_status}" ]]; then
        log_info "Availability Group Status:"
        echo "${ag_status}" | while IFS=',' read -r ag replica mode failover role state health error; do
            if [[ "${replica}" != "Replica" && -n "${replica}" ]]; then
                log_info "  Replica: ${replica}"
                log_info "    Role: ${role}"
                log_info "    State: ${state}"
                log_info "    Health: ${health}"
                log_info "    Mode: ${mode}"
                log_info "    Failover: ${failover}"
                if [[ -n "${error}" && "${error}" != "NULL" ]]; then
                    log_warning "    Last Error: ${error}"
                fi
                echo ""
            fi
        done
    else
        log_error "Could not retrieve Availability Group status"
        return 1
    fi
}

create_test_database() {
    log_phase "Creating Test Database"
    
    log_info "Creating test database: ${TEST_DATABASE}"
    
    # Create database on primary replica
    local create_db_query="
    IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = '${TEST_DATABASE}')
    BEGIN
        CREATE DATABASE [${TEST_DATABASE}]
        ALTER DATABASE [${TEST_DATABASE}] SET RECOVERY FULL
    END
    "
    
    if sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${create_db_query}" >/dev/null 2>&1; then
        log_success "Test database created successfully"
    else
        log_error "Failed to create test database"
        return 1
    fi
    
    # Add database to availability group
    log_info "Adding database to availability group..."
    
    local add_db_query="
    IF NOT EXISTS (
        SELECT database_name 
        FROM sys.availability_databases_cluster 
        WHERE database_name = '${TEST_DATABASE}'
    )
    BEGIN
        ALTER AVAILABILITY GROUP [${AG_NAME}] ADD DATABASE [${TEST_DATABASE}]
    END
    "
    
    if sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${add_db_query}" >/dev/null 2>&1; then
        log_success "Database added to availability group"
    else
        log_warning "Could not add database to availability group (may already exist)"
    fi
    
    # Wait for synchronization
    log_info "Waiting for database synchronization..."
    sleep 10
}

test_data_replication() {
    log_phase "Testing Data Replication"
    
    log_info "Testing data replication across replicas"
    
    # Create test table and insert data
    local create_table_query="
    USE [${TEST_DATABASE}]
    IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[${TEST_TABLE}]'))
    BEGIN
        CREATE TABLE [${TEST_TABLE}] (
            ID int IDENTITY(1,1) PRIMARY KEY,
            TestData nvarchar(100),
            CreatedDate datetime2 DEFAULT GETDATE()
        )
    END
    "
    
    if sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${create_table_query}" >/dev/null 2>&1; then
        log_success "Test table created"
    else
        log_error "Failed to create test table"
        return 1
    fi
    
    # Insert test data
    local test_data="Test data inserted at $(date)"
    local insert_query="
    USE [${TEST_DATABASE}]
    INSERT INTO [${TEST_TABLE}] (TestData) VALUES ('${test_data}')
    "
    
    if sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${insert_query}" >/dev/null 2>&1; then
        log_success "Test data inserted on primary"
    else
        log_error "Failed to insert test data"
        return 1
    fi
    
    # Wait for replication
    log_info "Waiting for replication to complete..."
    sleep 15
    
    # Verify data on all replicas
    local replication_success=true
    
    for node in "${SQL_NODES[@]}"; do
        log_info "Verifying data replication on node: ${node}"
        
        local select_query="
        USE [${TEST_DATABASE}]
        SELECT COUNT(*) FROM [${TEST_TABLE}] WHERE TestData = '${test_data}'
        "
        
        local count=$(sqlcmd -S "${node}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
            -Q "${select_query}" -h -1 2>/dev/null | tr -d '[:space:]' || echo "0")
        
        if [[ "${count}" == "1" ]]; then
            log_success "  Data replicated successfully to ${node}"
        else
            log_error "  Data replication failed to ${node} (count: ${count})"
            replication_success=false
        fi
    done
    
    if [[ "${replication_success}" == "true" ]]; then
        log_success "Data replication test: PASSED"
        return 0
    else
        log_error "Data replication test: FAILED"
        return 1
    fi
}

test_basic_functionality() {
    log_phase "Running Basic Functionality Tests"
    
    local tests_passed=0
    local total_tests=4
    
    # Test 1: Node status
    if get_node_status; then
        ((tests_passed++))
    fi
    
    # Test 2: Listener connectivity
    if test_listener_connectivity; then
        ((tests_passed++))
    fi
    
    # Test 3: AG status
    if get_availability_group_status; then
        ((tests_passed++))
    fi
    
    # Test 4: Data replication
    create_test_database
    if test_data_replication; then
        ((tests_passed++))
    fi
    
    log_info "Basic tests completed: ${tests_passed}/${total_tests} passed"
    
    if [[ ${tests_passed} -eq ${total_tests} ]]; then
        log_success "All basic tests PASSED"
        return 0
    else
        log_error "Some basic tests FAILED"
        return 1
    fi
}

test_failover_functionality() {
    log_phase "Running Failover Tests"
    
    log_warning "Failover tests will temporarily affect availability"
    log_warning "These tests should only be run in non-production environments"
    
    # Get current primary replica
    local current_primary=$(sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "SELECT replica_server_name FROM sys.dm_hadr_availability_replica_states WHERE role_desc = 'PRIMARY'" \
        -h -1 2>/dev/null | tr -d '[:space:]')
    
    if [[ -z "${current_primary}" ]]; then
        log_error "Could not determine current primary replica"
        return 1
    fi
    
    log_info "Current primary replica: ${current_primary}"
    
    # Find secondary replica for failover
    local target_secondary=""
    for node in "${SQL_NODES[@]}"; do
        if [[ "${node}" != "${current_primary}" ]]; then
            target_secondary="${node}"
            break
        fi
    done
    
    if [[ -z "${target_secondary}" ]]; then
        log_error "Could not find secondary replica for failover test"
        return 1
    fi
    
    log_info "Target secondary replica: ${target_secondary}"
    
    # Perform manual failover
    log_info "Initiating manual failover to ${target_secondary}..."
    
    local failover_query="ALTER AVAILABILITY GROUP [${AG_NAME}] FAILOVER"
    
    if sqlcmd -S "${target_secondary}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${failover_query}" >/dev/null 2>&1; then
        log_success "Failover command executed"
    else
        log_error "Failover command failed"
        return 1
    fi
    
    # Wait for failover to complete
    log_info "Waiting for failover to complete..."
    sleep 30
    
    # Verify new primary
    local new_primary=$(sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "SELECT replica_server_name FROM sys.dm_hadr_availability_replica_states WHERE role_desc = 'PRIMARY'" \
        -h -1 2>/dev/null | tr -d '[:space:]')
    
    if [[ "${new_primary}" == "${target_secondary}" ]]; then
        log_success "Failover successful - new primary: ${new_primary}"
        
        # Test connectivity after failover
        if test_listener_connectivity; then
            log_success "Listener connectivity after failover: PASSED"
        else
            log_error "Listener connectivity after failover: FAILED"
            return 1
        fi
        
        # Failback to original primary
        log_info "Failing back to original primary: ${current_primary}"
        
        if sqlcmd -S "${current_primary}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
            -Q "${failover_query}" >/dev/null 2>&1; then
            log_success "Failback completed"
            sleep 15
        else
            log_warning "Failback failed - manual intervention may be required"
        fi
        
        return 0
    else
        log_error "Failover failed - primary is still: ${new_primary}"
        return 1
    fi
}

test_performance() {
    log_phase "Running Performance Tests"
    
    log_info "Testing performance and latency"
    
    # Test connection time
    local start_time=$(date +%s%N)
    if test_sql_connectivity "${LISTENER_NAME}"; then
        local end_time=$(date +%s%N)
        local connection_time=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds
        log_info "Connection time: ${connection_time}ms"
    else
        log_error "Performance test failed - could not connect"
        return 1
    fi
    
    # Test query performance
    local query_start=$(date +%s%N)
    local query_result=$(sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "SELECT COUNT(*) FROM sys.databases" -h -1 2>/dev/null | tr -d '[:space:]')
    local query_end=$(date +%s%N)
    local query_time=$(( (query_end - query_start) / 1000000 ))
    
    log_info "Query execution time: ${query_time}ms"
    log_info "Query result: ${query_result} databases"
    
    # Test replication latency
    if [[ -n "${TEST_DATABASE}" ]]; then
        log_info "Testing replication latency..."
        
        local latency_test_data="Latency test at $(date +%s%N)"
        local insert_start=$(date +%s%N)
        
        sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
            -Q "USE [${TEST_DATABASE}]; INSERT INTO [${TEST_TABLE}] (TestData) VALUES ('${latency_test_data}')" \
            >/dev/null 2>&1
        
        # Check replication on secondary
        local replicated=false
        local max_wait=30
        local wait_count=0
        
        while [[ ${wait_count} -lt ${max_wait} && "${replicated}" == "false" ]]; do
            for node in "${SQL_NODES[@]}"; do
                local count=$(sqlcmd -S "${node}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
                    -Q "USE [${TEST_DATABASE}]; SELECT COUNT(*) FROM [${TEST_TABLE}] WHERE TestData = '${latency_test_data}'" \
                    -h -1 2>/dev/null | tr -d '[:space:]' || echo "0")
                
                if [[ "${count}" == "1" ]]; then
                    local replication_end=$(date +%s%N)
                    local replication_latency=$(( (replication_end - insert_start) / 1000000 ))
                    log_info "Replication latency to ${node}: ${replication_latency}ms"
                    replicated=true
                fi
            done
            
            if [[ "${replicated}" == "false" ]]; then
                sleep 1
                ((wait_count++))
            fi
        done
        
        if [[ "${replicated}" == "false" ]]; then
            log_warning "Replication latency test timed out"
        fi
    fi
    
    log_success "Performance tests completed"
    return 0
}

cleanup_test_resources() {
    log_phase "Cleaning Up Test Resources"
    
    log_info "Removing test database: ${TEST_DATABASE}"
    
    # Remove database from availability group first
    local remove_db_query="
    IF EXISTS (
        SELECT database_name 
        FROM sys.availability_databases_cluster 
        WHERE database_name = '${TEST_DATABASE}'
    )
    BEGIN
        ALTER AVAILABILITY GROUP [${AG_NAME}] REMOVE DATABASE [${TEST_DATABASE}]
    END
    "
    
    sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${remove_db_query}" >/dev/null 2>&1 || true
    
    # Wait for removal to complete
    sleep 10
    
    # Drop database
    local drop_db_query="
    IF EXISTS (SELECT name FROM sys.databases WHERE name = '${TEST_DATABASE}')
    BEGIN
        DROP DATABASE [${TEST_DATABASE}]
    END
    "
    
    sqlcmd -S "${LISTENER_NAME}" -U "${ADMIN_USERNAME}" -P "${ADMIN_PASSWORD}" \
        -Q "${drop_db_query}" >/dev/null 2>&1 || true
    
    log_success "Test resources cleaned up"
}

generate_test_report() {
    log_phase "Generating Test Report"
    
    local report_file="${LOG_DIR}/ag-test-report-${TIMESTAMP}.html"
    
    cat > "${report_file}" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>SQL Server HA - Availability Group Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 10px; border-radius: 5px; }
        .success { color: green; font-weight: bold; }
        .error { color: red; font-weight: bold; }
        .warning { color: orange; font-weight: bold; }
        .section { margin: 20px 0; padding: 10px; border-left: 3px solid #ccc; }
        pre { background-color: #f5f5f5; padding: 10px; border-radius: 3px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SQL Server HA - Availability Group Test Report</h1>
        <p><strong>Generated:</strong> $(date)</p>
        <p><strong>Test Type:</strong> ${TEST_TYPE}</p>
        <p><strong>Configuration:</strong> ${CONFIG_FILE}</p>
        <p><strong>Availability Group:</strong> ${AG_NAME}</p>
        <p><strong>Listener:</strong> ${LISTENER_NAME}:${LISTENER_PORT}</p>
    </div>
    
    <div class="section">
        <h2>Test Results Summary</h2>
        <p>Detailed test results are available in the log file: <code>${LOG_FILE}</code></p>
    </div>
    
    <div class="section">
        <h2>Log Output</h2>
        <pre>$(cat "${LOG_FILE}")</pre>
    </div>
</body>
</html>
EOF
    
    log_success "Test report generated: ${report_file}"
}

main() {
    log_phase "SQL Server HA - Availability Group Testing Started"
    log_info "Test started at $(date)"
    log_info "Log file: ${LOG_FILE}"
    
    parse_arguments "$@"
    check_dependencies
    validate_configuration
    
    local overall_success=true
    
    case "${TEST_TYPE}" in
        basic)
            if ! test_basic_functionality; then
                overall_success=false
            fi
            ;;
        failover)
            if ! test_failover_functionality; then
                overall_success=false
            fi
            ;;
        performance)
            if ! test_performance; then
                overall_success=false
            fi
            ;;
        all)
            if ! test_basic_functionality; then
                overall_success=false
            fi
            if ! test_failover_functionality; then
                overall_success=false
            fi
            if ! test_performance; then
                overall_success=false
            fi
            ;;
        *)
            log_error "Invalid test type: ${TEST_TYPE}"
            show_usage
            exit 1
            ;;
    esac
    
    # Cleanup
    cleanup_test_resources
    
    # Generate report
    generate_test_report
    
    log_phase "Availability Group Testing Completed"
    log_info "Test completed at $(date)"
    log_info "Log file saved to: ${LOG_FILE}"
    
    if [[ "${overall_success}" == "true" ]]; then
        log_success "All tests PASSED"
        exit 0
    else
        log_error "Some tests FAILED"
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"

