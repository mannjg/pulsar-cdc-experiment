#!/bin/bash
# Pulsar CDC Experiment - Automated Installation Script
# This script performs a complete, hands-free installation of the Pulsar CDC experiment

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="pulsar"
HELM_RELEASE_NAME="pulsar"
PULSAR_CHART_VERSION="3.9.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Print functions
print_header() {
    echo -e "\n${BLUE}===================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}===================================================================${NC}\n"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Poll for pod readiness with detailed status reporting
# Usage: wait_for_pods <label-selector> <component-name> <timeout-seconds>
wait_for_pods() {
    local label="$1"
    local component="$2"
    local timeout="${3:-600}"
    local interval=5
    local elapsed=0
    
    print_info "Waiting for $component (timeout: ${timeout}s)..."
    
    while [ $elapsed -lt $timeout ]; do
        # Get pod status
        local pod_status=$(kubectl get pods -n "$NAMESPACE" -l "$label" -o jsonpath='{range .items[*]}{.metadata.name}:{.status.phase}:{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
        
        if [ -z "$pod_status" ]; then
            print_info "  No pods found yet for $component, waiting... (${elapsed}s/${timeout}s)"
        else
            local all_ready=true
            local status_msg=""
            
            while IFS=: read -r pod_name phase ready_status; do
                if [ -n "$pod_name" ]; then
                    if [ "$phase" = "Running" ] && [ "$ready_status" = "True" ]; then
                        status_msg="${status_msg}  ✓ $pod_name: Running and Ready\n"
                    elif [ "$phase" = "Failed" ] || [ "$phase" = "CrashLoopBackOff" ]; then
                        print_error "$component pod $pod_name is in $phase state"
                        print_error "Check logs with: kubectl logs -n $NAMESPACE $pod_name"
                        print_error "Check events with: kubectl describe pod -n $NAMESPACE $pod_name"
                        exit 1
                    else
                        all_ready=false
                        status_msg="${status_msg}  ⏳ $pod_name: Phase=$phase, Ready=$ready_status\n"
                    fi
                fi
            done <<< "$pod_status"
            
            if [ "$all_ready" = true ]; then
                print_success "$component is ready"
                echo -e "$status_msg"
                return 0
            else
                if [ $((elapsed % 15)) -eq 0 ]; then
                    echo -e "$status_msg"
                fi
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for $component after ${timeout}s"
    print_error "Current pod status:"
    kubectl get pods -n "$NAMESPACE" -l "$label"
    print_error ""
    print_error "Recent events:"
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
    exit 1
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    local all_good=true
    
    if command_exists kubectl; then
        print_success "kubectl is installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    else
        print_error "kubectl is not installed"
        all_good=false
    fi
    
    if command_exists helm; then
        print_success "helm is installed: $(helm version --short)"
    else
        print_error "helm is not installed"
        all_good=false
    fi
    
    if command_exists microk8s; then
        print_success "microk8s is installed"
        # Check if microk8s is running
        if microk8s status --wait-ready --timeout=5 >/dev/null 2>&1; then
            print_success "microk8s is running"
        else
            print_warning "microk8s is not running. Attempting to start..."
            microk8s start
            sleep 5
        fi
    else
        print_warning "microk8s not detected, assuming generic Kubernetes cluster"
    fi
    
    # Test kubectl connectivity
    if kubectl cluster-info >/dev/null 2>&1; then
        print_success "kubectl can connect to cluster"
    else
        print_error "kubectl cannot connect to cluster"
        all_good=false
    fi
    
    if [ "$all_good" = false ]; then
        print_error "Prerequisites check failed. Please install missing components."
        exit 1
    fi
    
    print_success "All prerequisites satisfied"
}

# Create namespace
create_namespace() {
    print_header "Creating Namespace"
    
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_info "Namespace $NAMESPACE already exists"
    else
        kubectl create namespace "$NAMESPACE"
        print_success "Created namespace: $NAMESPACE"
    fi
}

# Create security customizer ConfigMap
create_security_customizer_configmap() {
    print_header "Creating Security Customizer ConfigMap"
    
    local jar_path="$PROJECT_ROOT/security-customizer/target/pulsar-security-customizer-1.0.0.jar"
    
    if [ ! -f "$jar_path" ]; then
        print_error "Security customizer JAR not found at: $jar_path"
        print_info "Please build the security customizer first:"
        print_info "  cd $PROJECT_ROOT/security-customizer"
        print_info "  mvn clean package"
        exit 1
    fi
    
    # Check if ConfigMap exists
    if kubectl get configmap pulsar-security-customizer -n "$NAMESPACE" >/dev/null 2>&1; then
        print_info "ConfigMap already exists, deleting and recreating..."
        kubectl delete configmap pulsar-security-customizer -n "$NAMESPACE"
    fi
    
    kubectl create configmap pulsar-security-customizer \
        --from-file=pulsar-security-customizer-1.0.0.jar="$jar_path" \
        -n "$NAMESPACE"
    
    print_success "Created security customizer ConfigMap"
}

# Deploy JAR artifact server (nginx)
deploy_jar_server() {
    print_header "Deploying JAR Artifact Server"

    local jar_path="$PROJECT_ROOT/security-customizer/target/pulsar-security-customizer-1.0.0.jar"
    local jar_server_manifest="$PROJECT_ROOT/kubernetes/manifests/jar-server.yaml"

    if [ ! -f "$jar_path" ]; then
        print_error "Security customizer JAR not found at: $jar_path"
        exit 1
    fi

    if [ ! -f "$jar_server_manifest" ]; then
        print_error "JAR server manifest not found at: $jar_server_manifest"
        exit 1
    fi

    # Create jar-server-content ConfigMap from JAR files
    print_info "Creating jar-server-content ConfigMap..."
    if kubectl get configmap jar-server-content -n "$NAMESPACE" >/dev/null 2>&1; then
        print_info "ConfigMap already exists, deleting and recreating..."
        kubectl delete configmap jar-server-content -n "$NAMESPACE"
    fi

    kubectl create configmap jar-server-content \
        --from-file=pulsar-security-customizer-1.0.0.jar="$jar_path" \
        -n "$NAMESPACE"

    print_success "Created jar-server-content ConfigMap"

    # Deploy jar-server manifest
    print_info "Deploying jar-server..."
    if kubectl get deployment jar-server -n "$NAMESPACE" >/dev/null 2>&1; then
        print_info "JAR server already deployed, reapplying manifest..."
        kubectl apply -f "$jar_server_manifest"
    else
        kubectl apply -f "$jar_server_manifest"
    fi

    print_success "JAR server manifest applied"

    # Wait for jar-server to be ready
    wait_for_pods "app=jar-server" "JAR Server" 300

    print_success "JAR server is ready"
}

# Add Helm repository
add_helm_repo() {
    print_header "Configuring Helm Repository"
    
    if helm repo list | grep -q "apache.*pulsar.apache.org/charts"; then
        print_info "Apache Pulsar Helm repository already added"
    else
        helm repo add apache https://pulsar.apache.org/charts
        print_success "Added Apache Pulsar Helm repository"
    fi
    
    helm repo update
    print_success "Updated Helm repositories"
}

# Install Pulsar via Helm
install_pulsar() {
    print_header "Installing Apache Pulsar via Helm"
    
    local values_file="$PROJECT_ROOT/kubernetes/helm/pulsar-values.yaml"
    
    if [ ! -f "$values_file" ]; then
        print_error "Helm values file not found at: $values_file"
        exit 1
    fi
    
    # Check if release already exists
    if helm list -n "$NAMESPACE" | grep -q "^$HELM_RELEASE_NAME"; then
        print_warning "Pulsar is already installed. Use 'helm upgrade' to update or './scripts/cleanup.sh' to start fresh."
        print_info "Proceeding with the rest of the installation..."
        return
    fi
    
    print_info "Installing Pulsar (this may take several minutes)..."
    helm install "$HELM_RELEASE_NAME" apache/pulsar \
        --namespace "$NAMESPACE" \
        --version "$PULSAR_CHART_VERSION" \
        --values "$values_file" \
        --timeout 15m
    
    print_success "Pulsar Helm release installed"
}

# Wait for Pulsar pods to be ready
wait_for_pulsar() {
    print_header "Waiting for Pulsar Pods to be Ready"
    
    wait_for_pods "component=zookeeper" "ZooKeeper" 600
    wait_for_pods "component=bookie" "BookKeeper" 600
    wait_for_pods "component=broker" "Broker" 600
    wait_for_pods "component=proxy" "Proxy" 600
    
    print_success "All Pulsar components are ready"
}

# Deploy PostgreSQL
deploy_postgres() {
    print_header "Deploying PostgreSQL"
    
    local postgres_manifest="$PROJECT_ROOT/kubernetes/manifests/postgres-debezium.yaml"
    
    if [ ! -f "$postgres_manifest" ]; then
        print_error "PostgreSQL manifest not found at: $postgres_manifest"
        exit 1
    fi
    
    # Check if already deployed
    if kubectl get deployment postgres -n "$NAMESPACE" >/dev/null 2>&1; then
        print_info "PostgreSQL already deployed"
    else
        kubectl apply -f "$postgres_manifest" -n "$NAMESPACE"
        print_success "PostgreSQL manifest applied"
    fi
    
    wait_for_pods "app=postgres" "PostgreSQL" 600
    
    # Initialize database schema
    print_info "Initializing PostgreSQL schema..."
    local postgres_pod=$(kubectl get pod -n "$NAMESPACE" -l app=postgres -o jsonpath='{.items[0].metadata.name}')
    
    # Wait a moment for PostgreSQL to be fully ready
    sleep 5
    
    # Create customers table (idempotent)
    if kubectl exec -n "$NAMESPACE" "$postgres_pod" -- psql -U postgres -d inventory -c "CREATE TABLE IF NOT EXISTS customers (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) NOT NULL UNIQUE, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" >/dev/null 2>&1; then
        print_success "PostgreSQL schema initialized"
    else
        print_warning "PostgreSQL schema initialization failed, but continuing (table may already exist)"
    fi
}

# Copy Debezium connector to broker
# Once in /pulsar/connectors/, it becomes available via builtin://debezium-postgres
copy_debezium_connector() {
    print_header "Copying Debezium Connector to Broker"

    local connector_path="$PROJECT_ROOT/connectors/pulsar-io-debezium-postgres-3.3.2.nar"
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$broker_pod" ]; then
        print_error "Could not find broker pod"
        exit 1
    fi

    if [ ! -f "$connector_path" ]; then
        print_error "Debezium connector NAR not found at: $connector_path"
        exit 1
    fi

    print_info "Copying connector to broker pod: $broker_pod"
    kubectl cp "$connector_path" \
        "$NAMESPACE/$broker_pod:/pulsar/connectors/pulsar-io-debezium-postgres-3.3.2.nar"

    print_success "Debezium connector copied"

    # Verify connector is available via builtin:// protocol
    print_info "Verifying debezium-postgres connector is available..."
    sleep 2  # Give Pulsar a moment to scan the connectors directory

    if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        curl -s http://localhost:8080/admin/v2/functions/connectors 2>/dev/null | grep -q "debezium-postgres"; then
        print_success "✓ Connector verified and available via builtin://debezium-postgres"
    else
        print_warning "⚠ Connector not yet registered (may take a few seconds)"
        print_info "You can verify later with: kubectl exec -n $NAMESPACE $broker_pod -- curl -s http://localhost:8080/admin/v2/functions/connectors"
    fi
}

# Create Debezium source connector
create_debezium_connector() {
    print_header "Creating Debezium Source Connector"
    
    local connector_config="$PROJECT_ROOT/kubernetes/manifests/debezium-postgres-connector.yaml"
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}')
    
    if [ ! -f "$connector_config" ]; then
        print_error "Connector configuration not found at: $connector_config"
        exit 1
    fi
    
    # Copy config to broker first (needed for both create and update)
    print_info "Copying connector configuration to broker..."
    kubectl cp "$connector_config" \
        "$NAMESPACE/$broker_pod:/pulsar/conf/debezium-postgres-connector.yaml"
    
    # Check if connector already exists
    print_info "Checking if connector already exists..."
    if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        bin/pulsar-admin sources get --tenant public --namespace default --name debezium-postgres-source >/dev/null 2>&1; then
        print_info "Connector already exists, updating..."
        kubectl exec -n "$NAMESPACE" "$broker_pod" -- bin/pulsar-admin sources update --source-config-file /pulsar/conf/debezium-postgres-connector.yaml || true
    else
        # Create the connector (schema type configured in YAML)
        print_info "Creating Debezium connector..."
        kubectl exec -n "$NAMESPACE" "$broker_pod" -- bin/pulsar-admin sources create --source-config-file /pulsar/conf/debezium-postgres-connector.yaml
    fi
    
    print_success "Debezium connector created"
    
    # Wait for connector pod to be ready
    print_info "Waiting for connector pod to be ready..."
    sleep 5  # Give k8s a moment to schedule the pod
    wait_for_pods "component=source,tenant=public,namespace=default" "Debezium Connector" 600
}

# Ensure CDC output topic exists with correct schema
# Wait for the connector to initialize and create the topic naturally during snapshot
ensure_cdc_topic_ready() {
    print_header "Ensuring CDC Output Topic is Ready"

    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}')
    local output_topic="persistent://public/default/dbserver1.public.customers"

    # Don't insert test data - let the connector create the topic during its snapshot
    # This ensures the topic is created with the connector's configured schema (JSON)
    print_info "Waiting for Debezium connector to complete initial snapshot and create output topic..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        # Check connector logs for successful initialization
        local connector_pod=$(kubectl get pod -n "$NAMESPACE" -l component=source,name=debezium-postgres-source -o jsonpath='{.items[0].metadata.name}')
        if [ -n "$connector_pod" ]; then
            if kubectl logs -n "$NAMESPACE" "$connector_pod" --tail=100 2>/dev/null | grep -q "Processing messages"; then
                # Check if topic was created
                if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
                    bin/pulsar-admin topics list public/default 2>/dev/null | grep -q "dbserver1.public.customers"; then
                    print_success "Output topic created: $output_topic"
                    print_success "Debezium connector is processing messages"
                    return 0
                fi
            fi
        fi

        attempt=$((attempt + 1))
        if [ $((attempt % 5)) -eq 0 ]; then
            print_info "Still waiting for connector initialization... (${attempt}/${max_attempts})"
        fi
        sleep 2
    done

    print_warning "Connector not fully initialized after ${max_attempts} attempts, but continuing..."
    print_info "The connector will create the topic during snapshot or on first data change"
}

# Deploy CDC enrichment function
deploy_cdc_function() {
    print_header "Deploying CDC Enrichment Function"
    
    local function_py="$PROJECT_ROOT/functions/cdc-enrichment/cdc_enrichment_function.py"
    local runtime_config="$PROJECT_ROOT/functions/cdc-enrichment/custom-runtime-options.json"
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}')
    
    if [ ! -f "$function_py" ]; then
        print_error "Function Python file not found at: $function_py"
        exit 1
    fi
    
    if [ ! -f "$runtime_config" ]; then
        print_error "Runtime configuration not found at: $runtime_config"
        exit 1
    fi
    
    # Copy function files to broker
    print_info "Copying function files to broker..."
    kubectl cp "$function_py" \
        "$NAMESPACE/$broker_pod:/pulsar/conf/cdc_enrichment_function.py"
    kubectl cp "$runtime_config" \
        "$NAMESPACE/$broker_pod:/pulsar/conf/custom-runtime-options.json"
    
    # Read custom runtime options
    local runtime_opts='{"clusterName":"pulsar","jobNamespace":"pulsar","extractLabels":{"app":"cdc-enrichment-function","component":"function"},"statefulSetName":"cdc-enrichment"}'
    
    # Check if function already exists
    print_info "Checking if function already exists..."
    if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
        bin/pulsar-admin functions get --tenant public --namespace default --name cdc-enrichment >/dev/null 2>&1; then
        print_info "Function already exists, updating..."
        kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin functions update \
            --py /pulsar/conf/cdc_enrichment_function.py \
            --classname cdc_enrichment_function.CDCEnrichmentFunction \
            --tenant public \
            --namespace default \
            --name cdc-enrichment \
            --inputs persistent://public/default/dbserver1.public.customers \
            --output persistent://public/default/dbserver1.public.customers-enriched \
            --custom-runtime-options "$runtime_opts" || true
    else
        # Create the function
        print_info "Creating CDC enrichment function..."
        kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin functions create \
            --py /pulsar/conf/cdc_enrichment_function.py \
            --classname cdc_enrichment_function.CDCEnrichmentFunction \
            --tenant public \
            --namespace default \
            --name cdc-enrichment \
            --inputs persistent://public/default/dbserver1.public.customers \
            --output persistent://public/default/dbserver1.public.customers-enriched \
            --custom-runtime-options "$runtime_opts"
    fi
    
    print_success "CDC enrichment function deployed"
    
    # Wait for function pod to be ready
    print_info "Waiting for function pod to be ready..."
    sleep 5  # Give k8s a moment to schedule the pod
    wait_for_pods "component=function,tenant=public,namespace=default" "CDC Enrichment Function" 600
}

# Display deployment status
display_status() {
    print_header "Deployment Status"
    
    echo -e "${BLUE}Pulsar Pods:${NC}"
    kubectl get pods -n "$NAMESPACE" -l app=pulsar
    
    echo -e "\n${BLUE}PostgreSQL:${NC}"
    kubectl get pods -n "$NAMESPACE" -l app=postgres
    
    echo -e "\n${BLUE}Debezium Connector:${NC}"
    local connector_pod=$(kubectl get pods -n "$NAMESPACE" -l component=source 2>/dev/null | grep debezium-postgres-source | awk '{print $1}' || echo "Not found yet")
    if [ "$connector_pod" != "Not found yet" ]; then
        kubectl get pod "$connector_pod" -n "$NAMESPACE"
    else
        echo "Connector pod is still being created..."
    fi
    
    echo -e "\n${BLUE}CDC Enrichment Function:${NC}"
    local function_pod=$(kubectl get pods -n "$NAMESPACE" -l component=function 2>/dev/null | grep cdc-enrichment | awk '{print $1}' || echo "Not found yet")
    if [ "$function_pod" != "Not found yet" ]; then
        kubectl get pod "$function_pod" -n "$NAMESPACE"
    else
        echo "Function pod is still being created..."
    fi
}

# Display next steps
display_next_steps() {
    print_header "Installation Complete!"
    
    echo -e "${GREEN}The Pulsar CDC experiment has been successfully installed.${NC}\n"
    
    echo -e "${BLUE}Next Steps:${NC}"
    echo -e "  1. Verify the installation:"
    echo -e "     ${YELLOW}./scripts/verify.sh${NC}"
    echo -e ""
    echo -e "  2. Test the CDC pipeline by inserting data into PostgreSQL:"
    echo -e "     ${YELLOW}kubectl exec -n $NAMESPACE <postgres-pod> -- psql -U postgres -d inventory -c \"INSERT INTO customers (name, email) VALUES ('Test User', 'test@example.com');\"${NC}"
    echo -e ""
    echo -e "  3. Monitor connector status:"
    echo -e "     ${YELLOW}kubectl logs -n $NAMESPACE <connector-pod> -f${NC}"
    echo -e ""
    echo -e "  4. Monitor function status:"
    echo -e "     ${YELLOW}kubectl logs -n $NAMESPACE <function-pod> -f${NC}"
    echo -e ""
    echo -e "  5. Consume messages from the enriched topic:"
    echo -e "     ${YELLOW}kubectl exec -n $NAMESPACE <broker-pod> -- bin/pulsar-client consume persistent://public/default/dbserver1.public.customers-enriched -s test-sub -n 0${NC}"
    echo -e ""
    echo -e "${BLUE}Documentation:${NC}"
    echo -e "  - Installation Guide: ${YELLOW}INSTALL.md${NC}"
    echo -e "  - Architecture: ${YELLOW}docs/architecture.md${NC}"
    echo -e "  - Troubleshooting: ${YELLOW}docs/troubleshooting.md${NC}"
    echo -e ""
    echo -e "${BLUE}Cleanup:${NC}"
    echo -e "  To remove the installation: ${YELLOW}./scripts/cleanup.sh${NC}"
}

# Main installation flow
main() {
    print_header "Pulsar CDC Experiment - Automated Installation"
    print_info "Starting installation at $(date)"
    
    check_prerequisites
    create_namespace
    create_security_customizer_configmap
    deploy_jar_server
    add_helm_repo
    install_pulsar
    wait_for_pulsar
    deploy_postgres
    # copy_debezium_connector  # Not needed - using built-in connector
    create_debezium_connector
    ensure_cdc_topic_ready
    deploy_cdc_function
    display_status
    display_next_steps
    
    print_info "Installation completed at $(date)"
}

# Run main function
main "$@"
