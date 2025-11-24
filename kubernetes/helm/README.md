# Helm Deployment

This directory contains Helm values for deploying Apache Pulsar with SecurityContext customization.

## Files

- `pulsar-values.yaml` - Complete Helm values for the deployment

## Deployment

### Prerequisites

- Kubernetes cluster
- Helm 3.x installed
- kubectl configured

### Steps

1. **Add Pulsar Helm repository**

   ```bash
   helm repo add apache https://pulsar.apache.org/charts
   helm repo update
   ```

2. **Create namespace**

   ```bash
   kubectl create namespace pulsar
   ```

3. **Deploy SecurityContext Customizer ConfigMap** (CRITICAL)

   Before installing Pulsar, you must create the ConfigMap containing the security customizer JAR:

   ```bash
   # If you have an existing ConfigMap export
   kubectl apply -f /path/to/pulsar-security-customizer-configmap.yaml -n pulsar

   # Or create from the built JAR
   kubectl create configmap pulsar-security-customizer \
     --from-file=pulsar-security-customizer-1.0.0.jar=../../security-customizer/target/pulsar-security-customizer-1.0.0.jar \
     -n pulsar
   ```

4. **Install Pulsar**

   ```bash
   helm install pulsar apache/pulsar \
     --namespace pulsar \
     --version 4.4.0 \
     --values pulsar-values.yaml
   ```

5. **Wait for deployment**

   ```bash
   kubectl wait --for=condition=ready pod -l app=pulsar --namespace pulsar --timeout=600s
   ```

6. **Verify deployment**

   ```bash
   kubectl get pods -n pulsar
   kubectl get statefulsets -n pulsar
   ```

## Configuration Highlights

### Security Customizer Integration

The values file configures the broker to use the custom SecurityContext customizer:

```yaml
broker:
  configData:
    PF_runtimeCustomizerClassName: "com.custom.pulsar.SecurityEnabledKubernetesManifestCustomizer"
    # SecurityContext settings
    PF_runtimeCustomizerConfig_podSecurityContext_runAsUser: "10000"
    # ... more configuration

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

### Kubernetes Runtime Factory

Configured to run Functions and Connectors as Kubernetes Pods:

```yaml
PF_functionRuntimeFactoryClassName: "org.apache.pulsar.functions.runtime.kubernetes.KubernetesRuntimeFactory"
PF_functionRuntimeFactoryConfigs_jobNamespace: "pulsar"
PF_functionRuntimeFactoryConfigs_pulsarDockerImageName: "apachepulsar/pulsar:3.3.9"
```

### Minimal Resource Configuration

Optimized for local testing with reduced resource requirements:

- ZooKeeper: 1 replica, 128Mi memory
- BookKeeper: 1 replica, 256Mi memory
- Broker: 1 replica, 256Mi memory
- Proxy: 1 replica, 128Mi memory

### Monitoring Disabled

Prometheus and Grafana are disabled for this minimal deployment:

```yaml
prometheus:
  enabled: false
grafana:
  enabled: false
monitoring:
  podMonitor:
    enabled: false
```

## Upgrading

To upgrade the Pulsar deployment with new values:

```bash
helm upgrade pulsar apache/pulsar \
  --namespace pulsar \
  --version 4.4.0 \
  --values pulsar-values.yaml
```

## Uninstalling

```bash
helm uninstall pulsar --namespace pulsar
kubectl delete namespace pulsar
```

## Troubleshooting

### Pods not starting

Check events:
```bash
kubectl get events -n pulsar --sort-by='.lastTimestamp'
```

Check pod logs:
```bash
kubectl logs <pod-name> -n pulsar
```

### SecurityContext errors

Verify the customizer ConfigMap exists:
```bash
kubectl get configmap pulsar-security-customizer -n pulsar
```

Verify the JAR is mounted in broker:
```bash
kubectl exec -n pulsar pulsar-broker-0 -- ls -la /pulsar/lib/ | grep security-customizer
```

### Functions/Connectors not getting SecurityContext

Check broker logs for customizer initialization:
```bash
kubectl logs pulsar-broker-0 -n pulsar | grep -i customizer
```

Verify the customizer class is configured:
```bash
kubectl exec -n pulsar pulsar-broker-0 -- \
  bin/pulsar-admin brokers get-all-dynamic-configurations | grep runtimeCustomizer
```

## References

- [Apache Pulsar Helm Chart](https://github.com/apache/pulsar-helm-chart)
- [Pulsar Configuration Reference](https://pulsar.apache.org/docs/reference-configuration/)
- [Helm Documentation](https://helm.sh/docs/)
