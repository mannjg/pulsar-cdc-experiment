# Pulsar CDC Experiment - Installation Guide

This guide provides comprehensive instructions for installing the Pulsar CDC Experiment with full automation via Helm.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Installation Steps](#detailed-installation-steps)
- [Verification](#verification)
- [Testing the CDC Pipeline](#testing-the-cdc-pipeline)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Overview

The installation process has been fully automated to enable hands-free deployment with a single command. The installation includes:

- **Apache Pulsar 4.0.2** - Streaming platform with Functions Worker
- **Security Customizer** - Custom Kubernetes manifest customizer for SecurityContext enforcement
- **PostgreSQL** - Source database with logical replication enabled
- **Debezium Connector** - CDC connector for PostgreSQL
- **CDC Enrichment Function** - Python-based Pulsar Function for message enrichment

**Key Features:**
- ✅ Fully automated installation with `./scripts/install.sh`
- ✅ No manual intervention required
- ✅ Upgraded to Pulsar 4.0.2 (resolves Jackson library compatibility)
- ✅ Automated verification with `./scripts/verify.sh`
- ✅ Easy cleanup with `./scripts/cleanup.sh`

## Prerequisites

### Required Software

1. **Kubernetes Cluster**
   - Version: 1.29+ recommended
   - This guide is optimized for **microk8s**
   - Other Kubernetes distributions should work but may require adjustments

2. **kubectl**
   - Version: 1.29+ recommended
   - Must be configured to access your cluster

3. **Helm**
   - Version: 3.x required
   - Used to deploy Apache Pulsar

4. **Java 17 and Maven** (optional, only for rebuilding)
   - Required only if you need to rebuild the security customizer
   - Pre-built JAR is included: `security-customizer/target/pulsar-security-customizer-1.0.0.jar`

### microk8s Setup

If using microk8s (recommended):

```bash
# Install microk8s
sudo snap install microk8s --classic

# Add your user to the microk8s group
sudo usermod -a -G microk8s $USER
sudo chown -R $USER ~/.kube
newgrp microk8s

# Enable required addons
microk8s enable dns storage

# Optional: Enable helm3 addon or install helm separately
microk8s enable helm3

# Verify microk8s is running
microk8s status --wait-ready

# Configure kubectl alias (optional but recommended)
alias kubectl='microk8s kubectl'
alias helm='microk8s helm3'
```

### Resource Requirements

**Minimum:**
- 4 CPU cores
- 8 GB RAM
- 20 GB storage

**Recommended for Production:**
- 8+ CPU cores
- 16+ GB RAM
- 100+ GB storage

### Verify Prerequisites

```bash
# Check kubectl
kubectl version --client

# Check Helm
helm version

# Check cluster connectivity
kubectl cluster-info

# Check available resources
kubectl top nodes
```

## Quick Start

For a hands-free installation, simply run:

```bash
# Clone the repository (if not already done)
cd /path/to/pulsar-cdc-experiment

# Run the automated installation script
./scripts/install.sh

# Verify the installation
./scripts/verify.sh

# Test the CDC pipeline (see "Testing the CDC Pipeline" section below)
```

That's it! The installation script will:
1. ✅ Check all prerequisites
2. ✅ Create the namespace
3. ✅ Deploy the security customizer
4. ✅ Install Pulsar via Helm
5. ✅ Wait for all Pulsar components to be ready
6. ✅ Deploy PostgreSQL
7. ✅ Create the Debezium connector
8. ✅ Deploy the CDC enrichment function
9. ✅ Display deployment status

## Detailed Installation Steps

If you prefer to understand what happens during installation or need to troubleshoot, here's a breakdown of each step.

### Step 1: Check Prerequisites

The installation script automatically checks:
- ✓ kubectl is installed and configured
- ✓ helm is installed
- ✓ Kubernetes cluster is accessible
- ✓ microk8s is running (if detected)

```bash
kubectl cluster-info
helm version
```

### Step 2: Create Namespace

Creates the `pulsar` namespace if it doesn't exist:

```bash
kubectl create namespace pulsar
```

### Step 3: Deploy Security Customizer

The security customizer JAR is packaged in a Kubernetes ConfigMap:

```bash
kubectl create configmap pulsar-security-customizer \
  --from-file=pulsar-security-customizer-1.0.0.jar=security-customizer/target/pulsar-security-customizer-1.0.0.jar \
  -n pulsar
```

**What it does:**
- The JAR extends Pulsar's `BasicKubernetesManifestCustomizer`
- Automatically injects SecurityContext into Function and Connector pods
- Enforces non-root execution (UID 10000)
- Drops all capabilities for enhanced security

### Step 4: Add Helm Repository

Adds the Apache Pulsar Helm chart repository:

```bash
helm repo add apache https://pulsar.apache.org/charts
helm repo update
```

### Step 5: Install Pulsar via Helm

Installs Pulsar using the custom values file:

```bash
helm install pulsar apache/pulsar \
  --namespace pulsar \
  --version 4.4.0 \
  --values kubernetes/helm/pulsar-values.yaml \
  --timeout 15m
```

**Key configuration highlights:**
- **Pulsar Version:** 4.0.2 (includes Jackson 2.17.2+ for Debezium compatibility)
- **Minimal Resources:** Optimized for local testing
- **Functions Worker:** Enabled with Kubernetes runtime
- **Security Customizer:** Loaded via ConfigMap volume mount
- **Custom Property:** `PF_kubernetesManifestCustomizerClassName` (Pulsar 4.x syntax)

### Step 6: Wait for Pulsar Components

The script waits for all Pulsar pods to be ready:

```bash
# Wait for each component
kubectl wait --for=condition=ready pod -l component=zookeeper --namespace pulsar --timeout=300s
kubectl wait --for=condition=ready pod -l component=bookkeeper --namespace pulsar --timeout=300s
kubectl wait --for=condition=ready pod -l component=broker --namespace pulsar --timeout=300s
kubectl wait --for=condition=ready pod -l component=proxy --namespace pulsar --timeout=300s
```

**Typical startup time:** 3-5 minutes

### Step 7: Deploy PostgreSQL

Deploys PostgreSQL with CDC-ready configuration:

```bash
kubectl apply -f kubernetes/manifests/postgres-debezium.yaml -n pulsar
kubectl wait --for=condition=ready pod -l app=postgres --namespace pulsar --timeout=300s
```

**PostgreSQL configuration:**
- **Image:** debezium/example-postgres:2.1
- **WAL Level:** logical (required for CDC)
- **Database:** inventory
- **Sample Table:** customers (pre-populated)

### Step 8: Deploy Debezium Connector

Copies the Debezium connector NAR to the broker and creates the source connector:

```bash
# Copy connector NAR to broker
kubectl cp connectors/pulsar-io-debezium-postgres-3.3.2.nar \
  pulsar/pulsar-broker-0:/pulsar/connectors/

# Create the connector
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin sources create \
  --source-config-file /pulsar/conf/debezium-postgres-connector.yaml
```

**Connector configuration:**
- **Name:** debezium-postgres-source
- **Database:** postgres://postgres:5432/inventory
- **Table Whitelist:** public.customers
- **Output Topic:** persistent://public/default/dbserver1.public.customers

**What happens:**
- Pulsar creates a StatefulSet for the connector
- Security customizer injects SecurityContext
- Connector pod runs as user 10000 (non-root)
- Debezium begins capturing CDC events from PostgreSQL

### Step 9: Deploy CDC Enrichment Function

Copies the Python function and creates it via pulsar-admin:

```bash
# Copy function files to broker
kubectl cp functions/cdc-enrichment/cdc-enrichment-function.py \
  pulsar/pulsar-broker-0:/pulsar/conf/

kubectl cp functions/cdc-enrichment/custom-runtime-options.json \
  pulsar/pulsar-broker-0:/pulsar/conf/

# Create the function
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin functions create \
  --py /pulsar/conf/cdc-enrichment-function.py \
  --classname cdc_enrichment_function.CDCEnrichmentFunction \
  --tenant public --namespace default --name cdc-enrichment \
  --inputs persistent://public/default/dbserver1.public.customers \
  --output persistent://public/default/dbserver1.public.customers-enriched \
  --custom-runtime-options-file /pulsar/conf/custom-runtime-options.json
```

**Function configuration:**
- **Language:** Python
- **Input Topic:** dbserver1.public.customers
- **Output Topic:** dbserver1.public.customers-enriched
- **Processing:** Adds enrichment metadata to CDC messages

**What happens:**
- Pulsar creates a StatefulSet for the function
- Security customizer injects SecurityContext
- Function pod runs as user 10000 (non-root)
- Function processes CDC messages and outputs enriched versions

### Step 10: Verify Installation

Check that all components are running:

```bash
kubectl get pods -n pulsar
```

Expected output:
```
NAME                                                    READY   STATUS    RESTARTS   AGE
pulsar-bookie-0                                         1/1     Running   0          5m
pulsar-broker-0                                         1/1     Running   0          5m
pulsar-proxy-0                                          1/1     Running   0          5m
pulsar-zookeeper-0                                      1/1     Running   0          5m
postgres-xxx-xxx                                        1/1     Running   0          3m
pf-public-default-debezium-postgres-source-0           1/1     Running   0          2m
pf-public-default-cdc-enrichment-0                     1/1     Running   0          1m
```

## Verification

Run the automated verification script:

```bash
./scripts/verify.sh
```

The verification script checks:

1. **Namespace** - Confirms `pulsar` namespace exists
2. **Pulsar Pods** - All core components are running
3. **Security Customizer** - ConfigMap exists and JAR is mounted
4. **Broker Logs** - Customizer initialization appears in logs
5. **PostgreSQL** - Database is accessible, tables exist, WAL level is logical
6. **Debezium Connector** - Connector exists, pod is running with SecurityContext
7. **CDC Function** - Function exists, pod is running with SecurityContext
8. **User ID Check** - Pods run as user 10000 (non-root)
9. **Topics** - Pulsar topics are created
10. **End-to-End Test** - Inserts test data and verifies CDC pipeline

**Expected output:**
```
==================================================================
  Verification Summary
==================================================================

Total Tests: 25
Tests Passed: 25
Tests Failed: 0

✓ All verification tests passed!
The Pulsar CDC experiment appears to be properly installed.
```

## Testing the CDC Pipeline

### 1. Get Pod Names

```bash
# Get PostgreSQL pod name
PG_POD=$(kubectl get pods -n pulsar -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# Get broker pod name
BROKER_POD=$(kubectl get pods -n pulsar -l component=broker -o jsonpath='{.items[0].metadata.name}')

echo "PostgreSQL: $PG_POD"
echo "Broker: $BROKER_POD"
```

### 2. Insert Test Data

```bash
kubectl exec -n pulsar $PG_POD -- \
  psql -U postgres -d inventory -c \
  "INSERT INTO customers (name, email) VALUES ('Alice Smith', 'alice@example.com');"
```

### 3. Consume from Source Topic

```bash
kubectl exec -n pulsar $BROKER_POD -- \
  bin/pulsar-client consume persistent://public/default/dbserver1.public.customers \
  -s test-subscription -n 1 -p Earliest
```

**Expected output:**
- You should see a JSON message containing the CDC event from Debezium
- Includes `before`, `after`, `op` (operation type), and `ts_ms` (timestamp)

### 4. Consume from Enriched Topic

```bash
kubectl exec -n pulsar $BROKER_POD -- \
  bin/pulsar-client consume persistent://public/default/dbserver1.public.customers-enriched \
  -s test-enriched-subscription -n 1 -p Earliest
```

**Expected output:**
- JSON message with original CDC data
- **Plus enrichment metadata:** `operation_label`, `processing_timestamp`, `data_quality_score`

### 5. Monitor Logs

```bash
# Connector logs
kubectl logs -n pulsar pf-public-default-debezium-postgres-source-0 -f

# Function logs
kubectl logs -n pulsar pf-public-default-cdc-enrichment-0 -f

# Broker logs
kubectl logs -n pulsar pulsar-broker-0 -f
```

## Troubleshooting

### Installation Fails During Helm Install

**Issue:** Helm install times out or fails

**Solutions:**
```bash
# Check cluster resources
kubectl top nodes
kubectl describe nodes

# Check for pending pods
kubectl get pods -n pulsar

# Check pod events
kubectl get events -n pulsar --sort-by='.lastTimestamp'

# Delete and retry
./scripts/cleanup.sh
./scripts/install.sh
```

### Security Customizer Not Loading

**Issue:** Pods don't have SecurityContext applied

**Check:**
```bash
# Verify ConfigMap exists
kubectl get configmap pulsar-security-customizer -n pulsar

# Check broker logs for customizer
kubectl logs -n pulsar pulsar-broker-0 | grep SecurityEnabledKubernetesManifestCustomizer

# Verify JAR is mounted
kubectl exec -n pulsar pulsar-broker-0 -- ls -la /pulsar/lib/ | grep security-customizer
```

**Solution:**
- Ensure the property name is `PF_kubernetesManifestCustomizerClassName` (Pulsar 4.x)
- Restart broker: `kubectl delete pod pulsar-broker-0 -n pulsar`

### Debezium Connector Fails to Start

**Issue:** Connector pod crashes or shows errors

**Check:**
```bash
# Get connector status
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin sources status --tenant public --namespace default --name debezium-postgres-source

# Check connector logs
kubectl logs -n pulsar pf-public-default-debezium-postgres-source-0
```

**Common Issues:**
- **Jackson library error:** Verify Pulsar is version 4.0.2 or later
- **PostgreSQL connection:** Verify PostgreSQL pod is running and accessible
- **WAL level:** Ensure PostgreSQL has `wal_level=logical`

### Function Not Processing Messages

**Issue:** Messages in source topic but not in enriched topic

**Check:**
```bash
# Get function status
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin functions status --tenant public --namespace default --name cdc-enrichment

# Check function logs
kubectl logs -n pulsar pf-public-default-cdc-enrichment-0
```

**Solution:**
- Verify input and output topics are correct
- Check function pod is running: `kubectl get pods -n pulsar -l compute-type=function`
- Restart function: `kubectl delete pod pf-public-default-cdc-enrichment-0 -n pulsar`

### Pods Stuck in Pending

**Issue:** Pods remain in `Pending` state

**Check:**
```bash
kubectl describe pod <pod-name> -n pulsar
```

**Common causes:**
- Insufficient resources (CPU/memory)
- PVC not bound (storage class issue)
- Node selector mismatch

**Solution:**
```bash
# Check PVCs
kubectl get pvc -n pulsar

# Check available storage classes
kubectl get storageclass

# For microk8s, ensure storage is enabled
microk8s enable storage
```

### Permission Denied Errors

**Issue:** Pods crash with permission denied errors

**Check:**
```bash
# Verify SecurityContext
kubectl get pod <pod-name> -n pulsar -o yaml | grep -A 10 securityContext

# Check user inside pod
kubectl exec -n pulsar <pod-name> -- id
```

**Expected:**
- `uid=10000`
- `gid=10000`
- `groups=10000`

## Cleanup

To completely remove the installation:

```bash
./scripts/cleanup.sh
```

**This will delete:**
- CDC enrichment function
- Debezium connector
- PostgreSQL deployment
- Pulsar Helm release
- All persistent volume claims
- The `pulsar` namespace
- All associated resources

**Warning:** This is destructive and will delete all data!

## Next Steps

After successful installation:

1. **Read the Architecture Documentation**
   - `docs/architecture.md` - Detailed architecture overview
   - `docs/setup-guide.md` - Component-level setup details

2. **Explore the CDC Pipeline**
   - Modify the enrichment function (`functions/cdc-enrichment/cdc-enrichment-function.py`)
   - Add more tables to capture in Debezium connector config
   - Create additional functions for different processing logic

3. **Production Considerations**
   - Increase resource allocations in `kubernetes/helm/pulsar-values.yaml`
   - Enable monitoring (Prometheus/Grafana)
   - Configure persistent storage with appropriate storage class
   - Set up backup and disaster recovery
   - Review security settings and RBAC

4. **Scale the Deployment**
   - Increase replica counts for BookKeeper, Broker, and Proxy
   - Add more ZooKeeper nodes for HA
   - Configure BookKeeper rack awareness

## Support

- **Issues:** Check existing issues or create new ones in the project repository
- **Documentation:** See `docs/` directory for detailed documentation
- **Logs:** Always check pod logs when troubleshooting: `kubectl logs -n pulsar <pod-name>`

## Version Information

- **Pulsar:** 4.0.2
- **Helm Chart:** 4.4.0
- **Debezium:** 3.3.2
- **PostgreSQL:** 16
- **Kubernetes:** 1.29+ (tested on microk8s)
