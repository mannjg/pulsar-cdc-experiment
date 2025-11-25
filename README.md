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

### Automated Installation (Recommended)

The easiest way to install the Pulsar CDC experiment is using the automated installation script:

```bash
# Run the automated installation
./scripts/install.sh

# Verify the installation
./scripts/verify.sh

# Test the CDC pipeline
kubectl exec -n pulsar $(kubectl get pods -n pulsar -l app=postgres -o jsonpath='{.items[0].metadata.name}') -- \
  psql -U postgres -d inventory -c "INSERT INTO customers (name, email) VALUES ('Test User', 'test@example.com');"
```

**That's it!** The installation script will:
- ✅ Check prerequisites (kubectl, helm, cluster connectivity)
- ✅ Create the pulsar namespace
- ✅ Deploy the security customizer ConfigMap
- ✅ Install Pulsar 4.0.2 via Helm
- ✅ Deploy PostgreSQL with CDC configuration
- ✅ Create the Debezium source connector
- ✅ Deploy the CDC enrichment function
- ✅ Verify all components are running

For detailed installation instructions, troubleshooting, and manual installation steps, see [INSTALL.md](INSTALL.md).

### Prerequisites

- **Kubernetes cluster** (1.29+, tested on microk8s)
- **Helm 3.x**
- **kubectl** configured for your cluster
- **4 CPU cores, 8 GB RAM minimum** (16 GB recommended)

### Cleanup

To remove the installation completely:

```bash
./scripts/cleanup.sh
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

**Root Cause:** Kafka Connect 3.9.0 (used by Debezium) requires Jackson 2.17.2 features that were not available in Pulsar 3.3.9's bundled Jackson version.

**Resolution:** This project has been upgraded to Pulsar 4.0.2, which includes Jackson 2.17.2+ and resolves the compatibility issue. The Debezium connector 3.3.2 now works without modifications.

See `docs/troubleshooting.md` for more details on the original issue and resolution.

## Technology Stack

- **Apache Pulsar**: 4.0.2
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
# pulsar-cdc-experiment
