#!/bin/bash
# Pulsar CDC Experiment - Verification Script
# This script verifies that all components are properly installed and functioning

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="pulsar"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Print functions
print_header() {
    echo -e "\n${BLUE}===================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}===================================================================${NC}\n"
}

print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

print_pass() {
    echo -e "${GREEN}  ✓ PASS:${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
    echo -e "${RED}  ✗ FAIL:${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Verify namespace exists
verify_namespace() {
    print_header "Verifying Namespace"
    print_test "Checking if namespace '$NAMESPACE' exists"
    
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_pass "Namespace '$NAMESPACE' exists"
    else
        print_fail "Namespace '$NAMESPACE' does not exist"
        return 1
    fi
}

# Verify Pulsar pods
verify_pulsar_pods() {
    print_header "Verifying Pulsar Pods"
    
    local components=("zookeeper" "bookie" "broker" "proxy")
    
    for component in "${components[@]}"; do
        print_test "Checking $component pods"
        
        local pod_count=$(kubectl get pods -n "$NAMESPACE" -l component="$component" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        
        if [ "$pod_count" -gt 0 ]; then
            print_pass "$component has $pod_count running pod(s)"
        else
            print_fail "$component has no running pods"
        fi
    done
}

# Verify security customizer (jar-server and init container approach)
verify_security_customizer() {
    print_header "Verifying Security Customizer"
    
    # Check jar-server deployment
    print_test "Checking if jar-server deployment exists"
    if kubectl get deployment jar-server -n "$NAMESPACE" >/dev/null 2>&1; then
        print_pass "JAR server deployment exists"
        
        # Check deployment readiness
        print_test "Checking jar-server deployment readiness"
        local ready_replicas=$(kubectl get deployment jar-server -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" -gt 0 ]; then
            print_pass "JAR server has $ready_replicas ready replica(s)"
        else
            print_fail "JAR server has no ready replicas"
        fi
    else
        print_fail "JAR server deployment does not exist"
    fi
    
    # Check if jar-server is serving the artifact
    print_test "Checking if jar-server is serving artifacts"
    local jar_server_pod=$(kubectl get pod -l app=jar-server -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$jar_server_pod" ]; then
        if kubectl exec -n "$NAMESPACE" "$jar_server_pod" -- ls /usr/share/nginx/html/libs/pulsar-security-customizer-1.0.0.jar >/dev/null 2>&1; then
            print_pass "Security customizer JAR is available in jar-server"
        else
            print_fail "Security customizer JAR not found in jar-server"
        fi
        
        # Check health endpoint
        print_test "Checking jar-server health endpoint"
        if kubectl exec -n "$NAMESPACE" "$jar_server_pod" -- curl -s http://localhost/health 2>/dev/null | grep -q "healthy"; then
            print_pass "JAR server health endpoint is responding"
        else
            print_fail "JAR server health endpoint not responding"
        fi
    else
        print_fail "Could not find jar-server pod"
    fi
    
    # Check broker init container completion
    print_test "Checking broker init container status"
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$broker_pod" ]; then
        local init_status=$(kubectl get pod "$broker_pod" -n "$NAMESPACE" -o jsonpath='{.status.initContainerStatuses[?(@.name=="download-broker-artifacts")].state.terminated.reason}' 2>/dev/null || echo "")
        
        if [ "$init_status" = "Completed" ]; then
            print_pass "Broker init container completed successfully"
        else
            print_warning "Broker init container status: $init_status (expected: Completed)"
        fi
    else
        print_fail "Could not find broker pod"
    fi
    
    # Check if JAR is mounted in broker
    print_test "Checking if security customizer is mounted in broker"
    if [ -n "$broker_pod" ]; then
        if kubectl exec -n "$NAMESPACE" "$broker_pod" -- ls /pulsar/lib/pulsar-security-customizer-1.0.0.jar >/dev/null 2>&1; then
            print_pass "Security customizer JAR is mounted in broker"
        else
            print_fail "Security customizer JAR not found in broker"
        fi
    else
        print_fail "Could not find broker pod"
    fi
    
    # Check broker logs for customizer initialization
    print_test "Checking broker logs for customizer initialization"
    if [ -n "$broker_pod" ]; then
        if kubectl logs -n "$NAMESPACE" "$broker_pod" --tail=500 2>/dev/null | grep -q "SecurityEnabledKubernetesManifestCustomizer"; then
            print_pass "Customizer appears in broker logs"
        else
            print_warning "Customizer not found in recent broker logs (may have started earlier)"
        fi
    fi
}

# Verify PostgreSQL
verify_postgres() {
    print_header "Verifying PostgreSQL"
    
    print_test "Checking PostgreSQL pods"
    local postgres_pod=$(kubectl get pods -n "$NAMESPACE" -l app=postgres --field-selector=status.phase=Running --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -n "$postgres_pod" ]; then
        print_pass "PostgreSQL pod is running: $postgres_pod"
        
        # Check database connectivity
        print_test "Checking database connectivity"
        if kubectl exec -n "$NAMESPACE" "$postgres_pod" -- psql -U postgres -d inventory -c "SELECT 1;" >/dev/null 2>&1; then
            print_pass "Database is accessible"
        else
            print_fail "Cannot connect to database"
        fi
        
        # Check if customers table exists
        print_test "Checking if customers table exists"
        if kubectl exec -n "$NAMESPACE" "$postgres_pod" -- psql -U postgres -d inventory -c "\dt" 2>/dev/null | grep -q "customers"; then
            print_pass "Customers table exists"
        else
            print_fail "Customers table does not exist"
        fi
        
        # Check replication settings
        print_test "Checking WAL level"
        local wal_level=$(kubectl exec -n "$NAMESPACE" "$postgres_pod" -- psql -U postgres -d inventory -t -c "SHOW wal_level;" 2>/dev/null | tr -d ' \n')
        if [ "$wal_level" = "logical" ]; then
            print_pass "WAL level is set to 'logical'"
        else
            print_fail "WAL level is '$wal_level', expected 'logical'"
        fi
    else
        print_fail "PostgreSQL pod not found or not running"
    fi
}

# Verify Debezium connector
verify_debezium_connector() {
    print_header "Verifying Debezium Connector"
    
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$broker_pod" ]; then
        print_fail "Could not find broker pod"
        return 1
    fi
    
    # Check connector status
    print_test "Checking Debezium connector status"
    if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        bin/pulsar-admin sources get --tenant public --namespace default --name debezium-postgres-source >/dev/null 2>&1; then
        print_pass "Debezium connector exists"
        
        # Get detailed status
        local status=$(kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin sources status --tenant public --namespace default --name debezium-postgres-source 2>/dev/null)
        
        if echo "$status" | grep -q "\"running\" : true"; then
            print_pass "Connector is running"
        else
            print_warning "Connector may not be running yet"
        fi
    else
        print_fail "Debezium connector does not exist"
        return 1
    fi
    
    # Check connector pod
    print_test "Checking connector pod"
    local connector_pod=$(kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep debezium-postgres-source | grep Running | awk '{print $1}' | head -1)
    
    if [ -n "$connector_pod" ]; then
        print_pass "Connector pod is running: $connector_pod"
        
        # Check pod SecurityContext
        print_test "Checking connector pod SecurityContext"
        local security_context=$(kubectl get pod "$connector_pod" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A 5 "securityContext:")
        
        if echo "$security_context" | grep -q "runAsUser: 10000"; then
            print_pass "Connector pod has explicit SecurityContext with runAsUser: 10000"
        else
            print_warning "SecurityContext not explicitly set in pod spec (may be inherited from container image)"
        fi
        
        # Verify user inside container
        print_test "Checking user ID inside connector pod"
        local uid=$(kubectl exec -n "$NAMESPACE" "$connector_pod" -- id -u 2>/dev/null || echo "")
        if [ "$uid" = "10000" ]; then
            print_pass "Connector pod runs as user 10000 (non-root)"
        else
            print_fail "Connector pod runs as user $uid, expected 10000"
        fi
    else
        print_warning "Connector pod not found or not running yet"
    fi
}

# Verify CDC enrichment function
verify_cdc_function() {
    print_header "Verifying CDC Enrichment Function"
    
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$broker_pod" ]; then
        print_fail "Could not find broker pod"
        return 1
    fi
    
    # Check function status
    print_test "Checking CDC enrichment function status"
    if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        bin/pulsar-admin functions get --tenant public --namespace default --name cdc-enrichment >/dev/null 2>&1; then
        print_pass "CDC enrichment function exists"
        
        # Get detailed status
        local status=$(kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin functions status --tenant public --namespace default --name cdc-enrichment 2>/dev/null)
        
        if echo "$status" | grep -q "\"running\" : true"; then
            print_pass "Function is running"
        else
            print_warning "Function may not be running yet"
        fi
    else
        print_fail "CDC enrichment function does not exist"
        return 1
    fi
    
    # Check function pod
    print_test "Checking function pod"
    local function_pod=$(kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep cdc-enrichment | grep Running | awk '{print $1}' | head -1)
    
    if [ -n "$function_pod" ]; then
        print_pass "Function pod is running: $function_pod"
        
        # Check pod SecurityContext
        print_test "Checking function pod SecurityContext"
        local security_context=$(kubectl get pod "$function_pod" -n "$NAMESPACE" -o yaml 2>/dev/null | grep -A 5 "securityContext:")
        
        if echo "$security_context" | grep -q "runAsUser: 10000"; then
            print_pass "Function pod has explicit SecurityContext with runAsUser: 10000"
        else
            print_warning "SecurityContext not explicitly set in pod spec (may be inherited from container image)"
        fi
        
        # Verify user inside container
        print_test "Checking user ID inside function pod"
        local uid=$(kubectl exec -n "$NAMESPACE" "$function_pod" -- id -u 2>/dev/null || echo "")
        if [ "$uid" = "10000" ]; then
            print_pass "Function pod runs as user 10000 (non-root)"
        else
            print_fail "Function pod runs as user $uid, expected 10000"
        fi
    else
        print_warning "Function pod not found or not running yet"
    fi
}

# Verify topics
verify_topics() {
    print_header "Verifying Pulsar Topics"
    
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$broker_pod" ]; then
        print_fail "Could not find broker pod"
        return 1
    fi
    
    # List topics
    print_test "Listing topics in public/default namespace"
    local topics=$(kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        bin/pulsar-admin topics list public/default 2>/dev/null)
    
    if [ -n "$topics" ]; then
        print_pass "Topics exist in public/default namespace"
        
        # Check for CDC topics
        if echo "$topics" | grep -q "dbserver1.public.customers"; then
            print_pass "Source topic 'dbserver1.public.customers' exists"
        else
            print_info "Source topic not created yet (will be created when connector receives first CDC event)"
        fi
        
        if echo "$topics" | grep -q "dbserver1.public.customers-enriched"; then
            print_pass "Enriched topic 'dbserver1.public.customers-enriched' exists"
        else
            print_info "Enriched topic not created yet (will be created when function processes first message)"
        fi
    else
        print_info "No topics found yet (topics will be created automatically)"
    fi
}

# Test end-to-end CDC pipeline
test_cdc_pipeline() {
    print_header "Testing End-to-End CDC Pipeline"
    
    local postgres_pod=$(kubectl get pods -n "$NAMESPACE" -l app=postgres --field-selector=status.phase=Running --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$postgres_pod" ] || [ -z "$broker_pod" ]; then
        print_warning "Skipping end-to-end test (PostgreSQL or broker not available)"
        return
    fi
    
    print_test "Inserting test data into PostgreSQL"
    local test_email="test-$(date +%s)@example.com"
    if kubectl exec -n "$NAMESPACE" "$postgres_pod" -- \
        psql -U postgres -d inventory -c "INSERT INTO customers (name, email) VALUES ('Test User', '$test_email');" >/dev/null 2>&1; then
        print_pass "Test data inserted successfully"
        
        print_info "Waiting 10 seconds for CDC pipeline to process..."
        sleep 10
        
        # Check if messages appear in source topic
        print_test "Checking for messages in source topic"
        local messages=$(kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            timeout 10 bin/pulsar-client consume persistent://public/default/dbserver1.public.customers \
            -s test-verification-sub -n 1 -p Earliest 2>/dev/null | grep -c "customers" || echo "0")
        
        if [ "$messages" -gt 0 ]; then
            print_pass "Messages found in source topic"
        else
            print_warning "No messages in source topic yet (may take longer for first message)"
        fi
    else
        print_fail "Could not insert test data"
    fi
}

# Generate summary report
generate_summary() {
    print_header "Verification Summary"
    
    echo -e "${BLUE}Total Tests:${NC} $TESTS_TOTAL"
    echo -e "${GREEN}Tests Passed:${NC} $TESTS_PASSED"
    echo -e "${RED}Tests Failed:${NC} $TESTS_FAILED"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "\n${GREEN}✓ All verification tests passed!${NC}"
        echo -e "${GREEN}The Pulsar CDC experiment appears to be properly installed.${NC}"
        return 0
    else
        echo -e "\n${YELLOW}⚠ Some verification tests failed.${NC}"
        echo -e "${YELLOW}Please review the failures above and check:${NC}"
        echo -e "  - Pod logs: kubectl logs -n $NAMESPACE <pod-name>"
        echo -e "  - Pod status: kubectl describe pod -n $NAMESPACE <pod-name>"
        echo -e "  - Recent events: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
        return 1
    fi
}

# Main verification flow
main() {
    print_header "Pulsar CDC Experiment - Verification"
    print_info "Starting verification at $(date)"
    
    verify_namespace
    verify_pulsar_pods
    verify_security_customizer
    verify_postgres
    verify_debezium_connector
    verify_cdc_function
    verify_topics
    test_cdc_pipeline
    
    generate_summary
    
    local exit_code=$?
    print_info "Verification completed at $(date)"
    exit $exit_code
}

# Run main function
main "$@"
