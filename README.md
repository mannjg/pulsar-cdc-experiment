# Pulsar CDC Experiment

A complete implementation of Change Data Capture (CDC) using Apache Pulsar, Debezium, and Kubernetes with custom SecurityContext enforcement.

## Overview

This project demonstrates a full CDC pipeline that:
1. Captures changes from PostgreSQL using Debezium
2. Streams changes through Apache Pulsar
3. Enriches messages using Pulsar Functions
4. Runs with proper SecurityContext constraints in Kubernetes

The key innovation is a **custom Kubernetes Manifest Customizer** that adds SecurityContext to Pulsar Functions and Connectors running in Kubernetes, addressing a gap in the default Pulsar configuration.

## Architecture

```
PostgreSQL
    ↓
Debezium Connector (Pulsar Source)
    ↓
Pulsar Topic: dbserver1.public.customers
    ↓
CDC Enrichment Function (Python)
    ↓
Pulsar Topic: dbserver1.public.customers-enriched
```

### Key Components

1. **Security Customizer** (`security-customizer/`)
   - Custom Java implementation of `KubernetesManifestCustomizer`
   - Adds Pod and Container SecurityContext to Pulsar Functions/Connectors
   - Enforces non-root execution, dropped capabilities, and fsGroup settings

2. **CDC Enrichment Function** (`functions/cdc-enrichment/`)
   - Python-based Pulsar Function
   - Processes CDC messages from Debezium
   - Adds enrichment metadata to messages

3. **Kubernetes Deployment** (`kubernetes/`)
   - Helm-based Pulsar deployment with custom values
   - PostgreSQL deployment for CDC source
   - Debezium connector configuration

4. **Connectors** (`connectors/`)
   - Debezium PostgreSQL connector (NAR file)

## Quick Start

### Prerequisites

- Kubernetes cluster (tested on microk8s)
- Helm 3.x
- kubectl configured for your cluster

### Deployment

1. **Deploy the SecurityContext Customizer ConfigMap**

   First, create the ConfigMap containing the customizer JAR:
   ```bash
   # Export the customizer ConfigMap from running cluster
   kubectl get configmap pulsar-security-customizer -n pulsar -o yaml > customizer-configmap.yaml

   # Or build from source (see security-customizer/README.md)
   cd security-customizer
   mvn clean package
   # Then create ConfigMap with the JAR
   ```

2. **Install Pulsar via Helm**

   ```bash
   # Add Apache Pulsar Helm repository
   helm repo add apache https://pulsar.apache.org/charts
   helm repo update

   # Create namespace
   kubectl create namespace pulsar

   # Apply the security customizer ConfigMap
   kubectl apply -f <path-to-customizer-configmap.yaml> -n pulsar

   # Install Pulsar with custom values
   helm install pulsar apache/pulsar \
     --namespace pulsar \
     --version 4.4.0 \
     --values kubernetes/helm/pulsar-values.yaml

   # Wait for all pods to be ready
   kubectl wait --for=condition=ready pod -l app=pulsar --namespace pulsar --timeout=300s
   ```

3. **Deploy PostgreSQL**

   ```bash
   kubectl apply -f kubernetes/manifests/postgres-debezium.yaml -n pulsar
   ```

4. **Create Debezium Source Connector**

   ```bash
   # Access the toolset pod
   kubectl exec -it pulsar-toolset-0 -n pulsar -- bash

   # Upload the connector NAR if not already present
   # (The connector should be in /pulsar/connectors/)

   # Create the connector from the configuration
   bin/pulsar-admin sources create \
     --source-config-file /path/to/debezium-connector-config.yaml
   ```

5. **Deploy CDC Enrichment Function**

   ```bash
   # From the toolset pod
   bin/pulsar-admin functions create \
     --py /path/to/cdc-enrichment-function.py \
     --classname cdc_enrichment_function.CDCEnrichmentFunction \
     --tenant public \
     --namespace default \
     --name cdc-enrichment \
     --inputs persistent://public/default/dbserver1.public.customers \
     --output persistent://public/default/dbserver1.public.customers-enriched \
     --custom-runtime-options-file /path/to/custom-runtime-options.json
   ```

## Directory Structure

```
pulsar-cdc-experiment/
├── README.md                          # This file
├── docs/                              # Documentation
│   ├── setup-guide.md                 # Original setup guide
│   ├── KUBERNETES_STATEFULSET_CUSTOMIZATION_GUIDE.md
│   └── architecture.md                # Architecture deep-dive
├── security-customizer/               # Custom SecurityContext implementation
│   ├── src/                           # Java source code
│   ├── pom.xml                        # Maven configuration
│   ├── target/                        # Built JAR files
│   └── README.md                      # Build and usage instructions
├── functions/                         # Pulsar Functions
│   └── cdc-enrichment/                # CDC enrichment function
│       ├── cdc-enrichment-function.py # Python function code
│       └── custom-runtime-options.json # Runtime configuration
├── kubernetes/                        # Kubernetes configurations
│   ├── helm/                          # Helm values
│   │   └── pulsar-values.yaml         # Complete Pulsar Helm values
│   ├── manifests/                     # K8s manifests
│   │   ├── postgres-debezium.yaml     # PostgreSQL deployment
│   │   └── debezium-connector.yaml    # Connector configuration
│   └── archived/                      # Reference materials
│       ├── minimal-deployment/        # Minimal K8s deployment (superseded)
│       ├── standalone-patches/        # Individual patch files
│       ├── connector-configs/         # Alternative config formats
│       └── helm-backups/              # Backup Helm values
├── connectors/                        # Pulsar connectors
│   └── pulsar-io-debezium-postgres-3.3.2.nar
└── scripts/                           # Deployment scripts (future)
```

## Configuration Details

### SecurityContext Settings

The custom manifest customizer applies the following SecurityContext:

**Pod Security Context:**
- `runAsNonRoot: true`
- `runAsUser: 10000`
- `runAsGroup: 10000`
- `fsGroup: 10000`

**Container Security Context:**
- `runAsNonRoot: true`
- `readOnlyRootFilesystem: false`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`

### Helm Values Highlights

Key settings in `kubernetes/helm/pulsar-values.yaml`:

```yaml
broker:
  configData:
    # Enable Kubernetes runtime
    PF_functionRuntimeFactoryClassName: "org.apache.pulsar.functions.runtime.kubernetes.KubernetesRuntimeFactory"

    # Configure custom security customizer
    PF_runtimeCustomizerClassName: "com.custom.pulsar.SecurityEnabledKubernetesManifestCustomizer"

    # SecurityContext configuration
    PF_runtimeCustomizerConfig_podSecurityContext_runAsUser: "10000"
    # ... (see full file for all settings)

  # Mount the customizer JAR
  extraVolumes:
  - name: security-customizer
    configMap:
      name: pulsar-security-customizer
  extraVolumeMounts:
  - name: security-customizer
    mountPath: /pulsar/lib/pulsar-security-customizer-1.0.0.jar
    subPath: pulsar-security-customizer-1.0.0.jar
```

## Known Issues

### Debezium Connector Jackson Library Incompatibility

The Debezium PostgreSQL connector currently fails with a Jackson library version incompatibility:

```
java.lang.NoSuchMethodError: 'boolean com.fasterxml.jackson.databind.util.NativeImageUtil.isInNativeImage()'
```

**Root Cause:** Kafka Connect 3.9.0 (used by Debezium) requires Jackson 2.17.2 features that are not available in Pulsar 3.3.9's bundled Jackson version.

**Workaround Options:**
1. Downgrade Debezium connector to an older version compatible with Jackson in Pulsar 3.3.9
2. Upgrade Pulsar to a version with newer Jackson libraries
3. Use custom class loading to isolate Jackson versions

See `docs/troubleshooting.md` for more details.

## Technology Stack

- **Apache Pulsar**: 3.3.9
- **Pulsar Helm Chart**: 4.4.0
- **Kubernetes**: 1.29+ (tested on microk8s)
- **Debezium**: 3.3.2 (Postgres connector)
- **PostgreSQL**: 16 (with logical replication)
- **Java**: 17 (for security customizer)
- **Python**: 3.x (for functions)

## Development

### Building the Security Customizer

```bash
cd security-customizer
mvn clean package
# JAR will be in target/pulsar-security-customizer-1.0.0.jar
```

### Testing Functions Locally

```bash
cd functions/cdc-enrichment
python cdc-enrichment-function.py
```

## Contributing

This is an experimental project for learning and demonstration purposes. Contributions and suggestions are welcome!

## License

[Specify your license]

## References

- [Apache Pulsar Documentation](https://pulsar.apache.org/docs/)
- [Debezium Documentation](https://debezium.io/documentation/)
- [Pulsar Functions](https://pulsar.apache.org/docs/functions-overview/)
- [Kubernetes SecurityContext](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)

## Contact

[Your contact information]
