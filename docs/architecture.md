# Architecture Overview

## System Architecture

This document provides a deep-dive into the architecture of the Pulsar CDC Experiment.

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                      │
│  ┌──────────────┐                                                   │
│  │ PostgreSQL   │                                                   │
│  │              │                                                   │
│  │ - WAL enabled│                                                   │
│  │ - Replication│                                                   │
│  └──────┬───────┘                                                   │
│         │                                                           │
│         │ WAL Stream                                                │
│         ↓                                                           │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Debezium PostgreSQL Source Connector                      │     │
│  │ (StatefulSet: pf-public-default-debezium-postgres-source)│     │
│  │                                                            │     │
│  │ - Reads WAL via pgoutput plugin                           │     │
│  │ - Converts to Pulsar messages                             │     │
│  │ - Applies SecurityContext (via customizer)                │     │
│  └──────┬─────────────────────────────────────────────────────┘     │
│         │                                                           │
│         │ CDC Events                                                │
│         ↓                                                           │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Pulsar Broker                                             │     │
│  │                                                            │     │
│  │ Topic: persistent://public/default/                       │     │
│  │        dbserver1.public.customers                          │     │
│  │                                                            │     │
│  │ - Stores messages in BookKeeper                           │     │
│  │ - Routes to function subscribers                          │     │
│  └──────┬─────────────────────────────────────────────────────┘     │
│         │                                                           │
│         │ Subscription                                              │
│         ↓                                                           │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ CDC Enrichment Function (Python)                          │     │
│  │ (StatefulSet: pf-public-default-cdc-enrichment)           │     │
│  │                                                            │     │
│  │ - Processes each CDC message                              │     │
│  │ - Adds enrichment metadata                                │     │
│  │ - Applies SecurityContext (via customizer)                │     │
│  └──────┬─────────────────────────────────────────────────────┘     │
│         │                                                           │
│         │ Enriched Events                                           │
│         ↓                                                           │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Pulsar Broker                                             │     │
│  │                                                            │     │
│  │ Topic: persistent://public/default/                       │     │
│  │        dbserver1.public.customers-enriched                 │     │
│  │                                                            │     │
│  │ - Enriched messages available for consumption             │     │
│  └──────────────────────────────────────────────────────────────┘     │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Security Customizer (JAR in Broker)                       │     │
│  │                                                            │     │
│  │ - Loaded as library in broker classpath                   │     │
│  │ - Intercepts Function/Connector Pod manifests             │     │
│  │ - Injects SecurityContext before creation                 │     │
│  └──────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

## Security Customizer Deep Dive

### The Problem

By default, Pulsar Functions and Connectors running in Kubernetes (via `KubernetesRuntimeFactory`) do not have SecurityContext configured in their Pod/Container specs. This can be problematic in environments with:

- Pod Security Policies (PSP)
- Pod Security Admission (PSA)
- Security-conscious clusters requiring non-root execution
- Compliance requirements (PCI-DSS, SOC2, etc.)

### The Solution

Pulsar provides a `KubernetesManifestCustomizer` interface that allows modification of Pod manifests before they are submitted to Kubernetes. Our implementation:

```java
public class SecurityEnabledKubernetesManifestCustomizer
    implements KubernetesManifestCustomizer {

    @Override
    public void customize(String component, V1Pod pod,
                         Map<String, Object> config) {
        // Extract SecurityContext configuration from broker config
        // Apply to Pod spec
        // Apply to Container specs
    }
}
```

### Configuration Flow

1. **Broker Configuration** (via Helm values):
   ```yaml
   broker:
     configData:
       PF_runtimeCustomizerClassName: "com.custom.pulsar.SecurityEnabledKubernetesManifestCustomizer"
       PF_runtimeCustomizerConfig_podSecurityContext_runAsUser: "10000"
       # ... more config
   ```

2. **JAR Mounted** (via ConfigMap):
   ```yaml
   broker:
     extraVolumes:
     - configMap:
         name: pulsar-security-customizer
       name: security-customizer
     extraVolumeMounts:
     - mountPath: /pulsar/lib/pulsar-security-customizer-1.0.0.jar
       subPath: pulsar-security-customizer-1.0.0.jar
   ```

3. **Runtime Invocation**:
   - When creating a Function or Connector, the broker's Functions Worker calls the customizer
   - The customizer reads config from `PF_runtimeCustomizerConfig_*` properties
   - The customizer modifies the V1Pod object
   - The modified Pod is submitted to Kubernetes

### Applied SecurityContext

**Pod Level:**
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10000
  runAsGroup: 10000
  fsGroup: 10000
```

**Container Level:**
```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: false  # Pulsar requires write access for temp files
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
```

## CDC Pipeline

### PostgreSQL Configuration

PostgreSQL must be configured for logical replication:

```sql
-- In postgresql.conf
wal_level = logical
max_wal_senders = 4
max_replication_slots = 4

-- Enable replication
ALTER SYSTEM SET wal_level TO logical;
```

### Debezium Connector

The connector uses PostgreSQL's native `pgoutput` plugin (no external plugins required):

```yaml
configs:
  database.hostname: "postgres.pulsar.svc.cluster.local"
  database.port: "5432"
  plugin.name: "pgoutput"
  snapshot.mode: "initial"
  table.include.list: "public.customers"
```

**Key Settings:**
- `snapshot.mode: initial` - Takes initial snapshot, then streams changes
- `plugin.name: pgoutput` - Uses PostgreSQL's built-in replication protocol
- `customRuntimeOptions` - JSON with SecurityContext configuration

### CDC Enrichment Function

The Python function processes each message:

```python
def process(input, context):
    # Parse Debezium message
    value = json.loads(input)

    # Add enrichment
    value['metadata'] = {
        'processed_at': int(time.time() * 1000),
        'enriched': True,
        'function_name': context.get_function_name()
    }

    return json.dumps(value)
```

**Runtime Configuration:**
- Declared as Python runtime
- Input: `persistent://public/default/dbserver1.public.customers`
- Output: `persistent://public/default/dbserver1.public.customers-enriched`
- Custom runtime options include SecurityContext settings

## Kubernetes Runtime

### Functions Worker Configuration

The broker is configured to use Kubernetes runtime:

```yaml
PF_functionRuntimeFactoryClassName: org.apache.pulsar.functions.runtime.kubernetes.KubernetesRuntimeFactory
PF_functionRuntimeFactoryConfigs_jobNamespace: pulsar
PF_functionRuntimeFactoryConfigs_pulsarDockerImageName: apachepulsar/pulsar:4.0.2
```

### StatefulSet Pattern

Functions and Connectors are deployed as StatefulSets:

```
pf-public-default-debezium-postgres-source-0
pf-public-default-cdc-enrichment-0
```

Each StatefulSet:
- Runs a single Pod (replicas=1)
- Has a stable network identity
- Includes SecurityContext (thanks to customizer)
- Mounts Pulsar configuration

### RBAC Configuration

Functions require Kubernetes permissions:

```yaml
functions:
  rbac:
    limit_to_namespace: true  # Restrict to pulsar namespace only
```

This creates:
- ServiceAccount: `pulsar-functions-worker`
- Role: Permissions for Pod/StatefulSet management
- RoleBinding: Links ServiceAccount to Role

## Data Flow

### CDC Message Structure

Debezium produces messages in this format:

```json
{
  "before": null,
  "after": {
    "id": 1,
    "name": "John Doe",
    "email": "john@example.com"
  },
  "source": {
    "version": "2.4.0.Final",
    "connector": "postgresql",
    "name": "dbserver1",
    "ts_ms": 1637012345678,
    "snapshot": "false",
    "db": "inventory",
    "schema": "public",
    "table": "customers"
  },
  "op": "c",  // c=create, u=update, d=delete, r=read
  "ts_ms": 1637012345678
}
```

### Enriched Message Structure

After the function processes it:

```json
{
  "before": null,
  "after": {
    "id": 1,
    "name": "John Doe",
    "email": "john@example.com"
  },
  "source": { ... },
  "op": "c",
  "ts_ms": 1637012345678,
  "metadata": {
    "processed_at": 1637012346789,
    "enriched": true,
    "function_name": "cdc-enrichment"
  }
}
```

## Deployment Architecture

### Minimal Configuration

The deployment uses minimal resources for local testing:

| Component | Replicas | Memory | CPU |
|-----------|----------|--------|-----|
| ZooKeeper | 1 | 128Mi | 50m |
| BookKeeper | 1 | 256Mi | 50m |
| Broker | 1 | 256Mi | 50m |
| Proxy | 1 | 128Mi | 50m |
| Connector | 1 | dynamic | dynamic |
| Function | 1 | dynamic | dynamic |

### Storage

Uses a single common volume for BookKeeper:

```yaml
volumes:
  useSingleCommonVolume: true
  journal:
    size: 5Gi
  ledgers:
    size: 10Gi
```

### Quorum Settings

Reduced for single BookKeeper setup:

```yaml
managedLedgerDefaultEnsembleSize: "1"
managedLedgerDefaultWriteQuorum: "1"
managedLedgerDefaultAckQuorum: "1"
```

## Monitoring and Debugging

### Checking Connector Status

```bash
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin sources status \
  --tenant public --namespace default \
  --name debezium-postgres-source
```

### Checking Function Status

```bash
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin functions status \
  --tenant public --namespace default \
  --name cdc-enrichment
```

### Verifying SecurityContext

```bash
# Check connector Pod
kubectl get statefulset pf-public-default-debezium-postgres-source \
  -n pulsar -o yaml | grep -A 10 securityContext

# Check function Pod
kubectl get statefulset pf-public-default-cdc-enrichment \
  -n pulsar -o yaml | grep -A 10 securityContext
```

### Viewing Logs

```bash
# Connector logs
kubectl logs pf-public-default-debezium-postgres-source-0 -n pulsar

# Function logs
kubectl logs pf-public-default-cdc-enrichment-0 -n pulsar
```

## Future Enhancements

1. **Multi-replica deployment** - Scale connectors and functions
2. **Message validation** - Schema registry integration
3. **Dead letter queue** - Handle processing failures
4. **Metrics and monitoring** - Prometheus/Grafana dashboards
5. **Automated testing** - CI/CD pipeline for deployment
6. **Multi-table CDC** - Expand beyond single table
7. **Filtering and routing** - Content-based routing of CDC messages

## References

- [Pulsar Functions Architecture](https://pulsar.apache.org/docs/functions-overview/)
- [Debezium PostgreSQL Connector](https://debezium.io/documentation/reference/connectors/postgresql.html)
- [Kubernetes SecurityContext](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [KubernetesManifestCustomizer Interface](https://github.com/apache/pulsar/blob/master/pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/KubernetesManifestCustomizer.java)
