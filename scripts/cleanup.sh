#!/bin/bash
# Pulsar CDC Experiment - Cleanup Script
# This script removes all components installed by the install.sh script

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

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Confirm cleanup
confirm_cleanup() {
    print_header "Pulsar CDC Experiment - Cleanup"
    
    echo -e "${RED}WARNING: This will delete ALL components of the Pulsar CDC experiment!${NC}"
    echo -e "${YELLOW}The following will be removed:${NC}"
    echo -e "  - Helm release: $HELM_RELEASE_NAME"
    echo -e "  - Namespace: $NAMESPACE (and all resources within)"
    echo -e "  - All persistent volume claims"
    echo -e "  - All data in PostgreSQL and Pulsar"
    echo ""
    
    read -p "Are you sure you want to proceed? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
}

# Delete CDC enrichment function
delete_cdc_function() {
    print_header "Deleting CDC Enrichment Function"
    
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$broker_pod" ]; then
        print_info "Attempting to delete function via pulsar-admin..."
        if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin functions delete --tenant public --namespace default --name cdc-enrichment 2>/dev/null; then
            print_success "Function deleted via pulsar-admin"
        else
            print_info "Function may not exist or already deleted"
        fi
    else
        print_info "Broker pod not found, skipping function deletion"
    fi
}

# Delete Debezium connector
delete_debezium_connector() {
    print_header "Deleting Debezium Connector"
    
    local broker_pod=$(kubectl get pod -n "$NAMESPACE" -l component=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$broker_pod" ]; then
        print_info "Attempting to delete connector via pulsar-admin..."
        if kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
            bin/pulsar-admin sources delete --tenant public --namespace default --name debezium-postgres-source 2>/dev/null; then
            print_success "Connector deleted via pulsar-admin"
        else
            print_info "Connector may not exist or already deleted"
        fi
    else
        print_info "Broker pod not found, skipping connector deletion"
    fi
}

# Delete JAR artifact server
delete_jar_server() {
    print_header "Deleting JAR Artifact Server"

    # Delete jar-server resources
    local jar_server_manifest="$PROJECT_ROOT/kubernetes/manifests/jar-server.yaml"

    if [ -f "$jar_server_manifest" ]; then
        print_info "Deleting jar-server manifest resources..."
        kubectl delete -f "$jar_server_manifest" -n "$NAMESPACE" --ignore-not-found=true
        print_success "JAR server resources deleted"
    else
        print_info "JAR server manifest not found, skipping"
    fi

    # Delete artifact content ConfigMaps
    if kubectl get configmap jar-server-content -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete configmap jar-server-content -n "$NAMESPACE"
        print_success "Artifact content ConfigMap deleted"
    else
        print_info "Artifact content ConfigMap not found"
    fi

    # Delete nginx config ConfigMap (if it wasn't deleted by manifest)
    if kubectl get configmap jar-server-nginx-config -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete configmap jar-server-nginx-config -n "$NAMESPACE"
        print_success "Nginx config ConfigMap deleted"
    else
        print_info "Nginx config ConfigMap not found"
    fi
}

# Delete PostgreSQL
delete_postgres() {
    print_header "Deleting PostgreSQL"
    
    if kubectl get deployment postgres -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete deployment postgres -n "$NAMESPACE"
        print_success "PostgreSQL deployment deleted"
    else
        print_info "PostgreSQL deployment not found"
    fi
    
    if kubectl get service postgres -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete service postgres -n "$NAMESPACE"
        print_success "PostgreSQL service deleted"
    else
        print_info "PostgreSQL service not found"
    fi
}

# Delete JAR server
delete_jar_server() {
    print_header "Deleting JAR Artifact Server"

    if kubectl get deployment jar-server -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete deployment jar-server -n "$NAMESPACE" --ignore-not-found=true
        print_success "JAR server deployment deleted"
    else
        print_info "JAR server deployment not found"
    fi

    if kubectl get service jar-server -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete service jar-server -n "$NAMESPACE" --ignore-not-found=true
        print_success "JAR server service deleted"
    else
        print_info "JAR server service not found"
    fi

    if kubectl get configmap jar-server-nginx-config -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete configmap jar-server-nginx-config -n "$NAMESPACE" --ignore-not-found=true
        print_success "JAR server nginx ConfigMap deleted"
    else
        print_info "JAR server nginx ConfigMap not found"
    fi

    if kubectl get configmap jar-server-content -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl delete configmap jar-server-content -n "$NAMESPACE" --ignore-not-found=true
        print_success "JAR server content ConfigMap deleted"
    else
        print_info "JAR server content ConfigMap not found"
    fi
}

# Delete function and connector StatefulSets
delete_compute_resources() {
    print_header "Deleting Function and Connector Resources"
    
    print_info "Deleting function StatefulSets..."
    kubectl delete statefulsets -n "$NAMESPACE" -l compute-type=function --ignore-not-found=true
    
    print_info "Deleting connector StatefulSets..."
    kubectl delete statefulsets -n "$NAMESPACE" -l compute-type=source --ignore-not-found=true
    
    print_info "Deleting function and connector pods..."
    kubectl delete pods -n "$NAMESPACE" -l compute-type --ignore-not-found=true
    
    print_success "Compute resources deleted"
}

# Uninstall Pulsar Helm release
uninstall_pulsar() {
    print_header "Uninstalling Pulsar Helm Release"
    
    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^$HELM_RELEASE_NAME"; then
        print_info "Uninstalling Helm release: $HELM_RELEASE_NAME"
        helm uninstall "$HELM_RELEASE_NAME" --namespace "$NAMESPACE" --wait --timeout 5m
        print_success "Helm release uninstalled"
    else
        print_info "Helm release not found"
    fi
}

# Delete PVCs
delete_pvcs() {
    print_header "Deleting Persistent Volume Claims"
    
    local pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}')
    
    if [ -n "$pvcs" ]; then
        print_info "Deleting all PVCs in namespace $NAMESPACE..."
        kubectl delete pvc --all -n "$NAMESPACE"
        print_success "All PVCs deleted"
    else
        print_info "No PVCs found"
    fi
}

# Delete namespace
delete_namespace() {
    print_header "Deleting Namespace"
    
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_info "Deleting namespace: $NAMESPACE"
        kubectl delete namespace "$NAMESPACE" --timeout=5m
        print_success "Namespace deleted"
    else
        print_info "Namespace not found"
    fi
}

# Clean up any leftover resources
clean_leftovers() {
    print_header "Cleaning Up Leftover Resources"
    
    # Check for any ClusterRoleBindings related to the namespace
    print_info "Checking for ClusterRoleBindings..."
    local crbs=$(kubectl get clusterrolebindings -o json 2>/dev/null | \
        jq -r ".items[] | select(.subjects[]?.namespace==\"$NAMESPACE\") | .metadata.name" 2>/dev/null || echo "")
    
    if [ -n "$crbs" ]; then
        echo "$crbs" | while read -r crb; do
            print_info "Deleting ClusterRoleBinding: $crb"
            kubectl delete clusterrolebinding "$crb" --ignore-not-found=true
        done
        print_success "ClusterRoleBindings cleaned up"
    else
        print_info "No ClusterRoleBindings to clean up"
    fi
}

# Display completion message
display_completion() {
    print_header "Cleanup Complete"
    
    echo -e "${GREEN}The Pulsar CDC experiment has been successfully removed.${NC}\n"
    
    echo -e "${BLUE}What was removed:${NC}"
    echo -e "  ✓ CDC enrichment function"
    echo -e "  ✓ Debezium connector"
    echo -e "  ✓ PostgreSQL database"
    echo -e "  ✓ Pulsar Helm release"
    echo -e "  ✓ All persistent volume claims"
    echo -e "  ✓ Namespace: $NAMESPACE"
    echo -e ""
    
    echo -e "${BLUE}To reinstall:${NC}"
    echo -e "  ${YELLOW}./scripts/install.sh${NC}"
    echo -e ""
}

# Main cleanup flow
main() {
    confirm_cleanup
    
    print_info "Starting cleanup at $(date)"
    
    delete_cdc_function
    delete_debezium_connector
    delete_compute_resources
    delete_postgres
    delete_jar_server
    uninstall_pulsar
    delete_pvcs
    delete_namespace
    clean_leftovers
    display_completion
    
    print_info "Cleanup completed at $(date)"
}

# Run main function
main "$@"
