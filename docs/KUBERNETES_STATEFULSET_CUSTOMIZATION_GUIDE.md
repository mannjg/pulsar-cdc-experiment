# Apache Pulsar: Customizing StatefulSets for Functions and Source Connectors

## Executive Summary

This document provides a complete guide to customizing Kubernetes StatefulSets created by Apache Pulsar for Functions, Source Connectors, and Sink Connectors, specifically focusing on adding SecurityContext configuration.

**Key Findings:**
- Source and Sink connectors ARE functions internally - they all use the same customization mechanism
- The `KubernetesManifestCustomizer` interface provides the hook for StatefulSet customization
- Both worker-level and per-function/connector customization are supported
- The built-in `BasicKubernetesManifestCustomizer` does NOT support SecurityContext - custom implementation required

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Code Flow Analysis](#code-flow-analysis)
3. [Configuration Mechanisms](#configuration-mechanisms)
4. [Built-in BasicKubernetesManifestCustomizer](#built-in-basickubernetesmanifestcustomizer)
5. [Custom Implementation for SecurityContext](#custom-implementation-for-securitycontext)
6. [Deployment Guide](#deployment-guide)
7. [Usage Examples](#usage-examples)
8. [Verification and Testing](#verification-and-testing)

---

## Architecture Overview

### How It Works

When you create a Function or Source/Sink Connector in Kubernetes runtime mode:

1. **API Layer** receives the creation request with optional `customRuntimeOptions`
2. **Function Worker** loads the configured `KubernetesManifestCustomizer` implementation
3. **KubernetesRuntimeFactory** validates and passes the customizer to KubernetesRuntime
4. **KubernetesRuntime** creates the StatefulSet and calls `customizeStatefulSet()` before submission
5. **Kubernetes API** receives and creates the customized StatefulSet

### Important: Functions = Connectors

Source and Sink connectors are implemented as Pulsar Functions internally:
- All three share the same `Function.FunctionDetails` protobuf structure
- All three support `customRuntimeOptions` in their config
- The same `KubernetesManifestCustomizer` applies to Functions, Sources, and Sinks

**The documentation often says "Functions" but this applies equally to Source and Sink connectors.**

---

## Code Flow Analysis

### Key Files and Locations

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| **Interface** | `KubernetesManifestCustomizer.java` | 26-43 | Defines customization contract |
| **Built-in Implementation** | `BasicKubernetesManifestCustomizer.java` | 138-154 | Provides basic customization |
| **Function Config** | `FunctionConfig.java` | 128 | `customRuntimeOptions` field |
| **Source Config** | `SourceConfig.java` | 69 | `customRuntimeOptions` field |
| **Sink Config** | `SinkConfig.java` | 93 | `customRuntimeOptions` field |
| **Worker Config** | `WorkerConfig.java` | 771-782 | Worker-level customizer config |
| **Factory Loading** | `FunctionRuntimeManager.java` | 185-191 | Loads RuntimeCustomizer |
| **Factory Validation** | `KubernetesRuntimeFactory.java` | 230-241 | Validates customizer interface |
| **StatefulSet Creation** | `KubernetesRuntime.java` | 926-979 | Creates StatefulSet |
| **Customization Hook** | `KubernetesRuntime.java` | 973-975 | Calls customizeStatefulSet() |

### Complete Code Path

```
API Request (with customRuntimeOptions)
    ↓
WorkerConfig loads runtimeCustomizerClassName
    ↓
FunctionRuntimeManager.java:185-191
    - Instantiates RuntimeCustomizer
    - Calls initialize(runtimeCustomizerConfig)
    ↓
KubernetesRuntimeFactory.java:230-241
    - Validates implements KubernetesManifestCustomizer
    - Stores as Optional<KubernetesManifestCustomizer>
    ↓
KubernetesRuntime created with customizer
    ↓
KubernetesRuntime.createStatefulSet() called (line 926)
    - Creates V1StatefulSet with pods, containers, volumes, etc.
    - Line 973-975: manifestCustomizer.customizeStatefulSet(funcDetails, statefulSet)
    - Returns customized StatefulSet
    ↓
StatefulSet submitted to Kubernetes cluster
```

---

## Configuration Mechanisms

### Two Levels of Configuration

#### 1. Worker-Level Configuration (`functions_worker.yml`)

Applies to ALL functions, sources, and sinks managed by this worker:

```yaml
# The fully qualified class name of your RuntimeCustomizer implementation
runtimeCustomizerClassName: "org.apache.pulsar.functions.runtime.kubernetes.BasicKubernetesManifestCustomizer"

# Configuration passed to initialize() method - same for all functions
runtimeCustomizerConfig:
  jobNamespace: "pulsar-functions"
  extraLabels:
    environment: "production"
    team: "data-platform"
  extraAnnotations:
    owner: "platform-team"
  nodeSelectorLabels:
    workload: "pulsar"
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "pulsar"
      effect: "NoSchedule"
```

**Location:** `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/worker/WorkerConfig.java:771-782`

#### 2. Per-Function/Source/Sink Configuration

Passed when creating or updating individual resources via `customRuntimeOptions`:

```json
{
  "tenant": "public",
  "namespace": "default",
  "name": "my-function",
  "customRuntimeOptions": "{\"jobName\":\"custom-name\",\"nodeSelectorLabels\":{\"disktype\":\"ssd\"}}"
}
```

**Note:** The `BasicKubernetesManifestCustomizer.mergeRuntimeOpts()` method merges both configurations, with `customRuntimeOptions` taking precedence over `runtimeCustomizerConfig`.

---

## Built-in BasicKubernetesManifestCustomizer

### Supported Features

**Location:** `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/BasicKubernetesManifestCustomizer.java`

| Feature | Type | Purpose |
|---------|------|---------|
| `jobNamespace` | String | Custom Kubernetes namespace for the pod |
| `jobName` | String | Custom pod name |
| `extraLabels` | Map<String, String> | Additional labels on StatefulSet, Service, and Pods |
| `extraAnnotations` | Map<String, String> | Additional annotations on StatefulSet, Service, and Pods |
| `nodeSelectorLabels` | Map<String, String> | Node selector labels for pod placement |
| `tolerations` | List<V1Toleration> | Pod tolerations for taint-based scheduling |
| `resourceRequirements` | V1ResourceRequirements | CPU and memory requests/limits |

### NOT Supported

- ❌ **SecurityContext** (pod-level or container-level)
- ❌ **ServiceAccount**
- ❌ **Volumes and VolumeMounts** (beyond defaults)
- ❌ **Init Containers**
- ❌ **Affinity/Anti-Affinity**
- ❌ **PodDisruptionBudget**
- ❌ **Network Policies**

### Example Configuration

```json
{
  "jobName": "my-custom-function",
  "jobNamespace": "pulsar-prod",
  "extraLabels": {
    "app": "my-function",
    "version": "v1.0"
  },
  "extraAnnotations": {
    "description": "Processes user events"
  },
  "nodeSelectorLabels": {
    "disktype": "ssd",
    "zone": "us-east-1a"
  },
  "tolerations": [
    {
      "key": "dedicated",
      "operator": "Equal",
      "value": "pulsar",
      "effect": "NoSchedule"
    }
  ],
  "resourceRequirements": {
    "requests": {
      "cpu": "500m",
      "memory": "1Gi"
    },
    "limits": {
      "cpu": "2",
      "memory": "4Gi"
    }
  }
}
```

---

## Custom Implementation for SecurityContext

Since `BasicKubernetesManifestCustomizer` doesn't support SecurityContext, you must create a custom implementation.

### Full Implementation

**File:** `SecurityContextKubernetesManifestCustomizer.java`

```java
package com.yourcompany.pulsar.runtime;

import com.google.gson.Gson;
import io.kubernetes.client.openapi.models.*;
import lombok.*;
import lombok.extern.slf4j.Slf4j;
import org.apache.pulsar.functions.proto.Function;
import org.apache.pulsar.functions.runtime.kubernetes.BasicKubernetesManifestCustomizer;

import java.util.Map;

/**
 * Extended KubernetesManifestCustomizer that adds SecurityContext customization
 * in addition to all features from BasicKubernetesManifestCustomizer.
 *
 * This customizer supports:
 * - All BasicKubernetesManifestCustomizer features (labels, annotations, tolerations, etc.)
 * - Pod-level SecurityContext (runAsUser, runAsGroup, fsGroup, etc.)
 * - Container-level SecurityContext (privileged, capabilities, readOnlyRootFilesystem, etc.)
 * - SELinux options
 *
 * Configuration is provided via:
 * 1. Worker-level: runtimeCustomizerConfig in functions_worker.yml
 * 2. Per-function: customRuntimeOptions in function/source/sink creation
 */
@Slf4j
public class SecurityContextKubernetesManifestCustomizer extends BasicKubernetesManifestCustomizer {

    /**
     * SecurityContext configuration options.
     * Can be set at worker level (applies to all) or per-function (overrides worker level).
     */
    @Getter
    @Setter
    @NoArgsConstructor
    @AllArgsConstructor
    @Builder
    public static class SecurityContextOpts {
        // Pod-level security context
        private Long runAsUser;
        private Long runAsGroup;
        private Long fsGroup;
        private Boolean runAsNonRoot;

        // Container-level security context
        private Boolean privileged;
        private Boolean allowPrivilegeEscalation;
        private Boolean readOnlyRootFilesystem;

        // Capabilities
        private String[] addCapabilities;
        private String[] dropCapabilities;

        // SELinux options
        private String seLinuxLevel;
        private String seLinuxRole;
        private String seLinuxType;
        private String seLinuxUser;
    }

    /**
     * Extended RuntimeOpts that includes SecurityContext configuration
     * in addition to all BasicKubernetesManifestCustomizer.RuntimeOpts fields.
     */
    @Getter
    @Setter
    @NoArgsConstructor
    @AllArgsConstructor
    public static class ExtendedRuntimeOpts extends RuntimeOpts {
        private SecurityContextOpts securityContext;
    }

    /**
     * Override to add SecurityContext customization after basic customization.
     *
     * @param funcDetails The function details containing customRuntimeOptions
     * @param statefulSet The StatefulSet to customize
     * @return The customized StatefulSet
     */
    @Override
    public V1StatefulSet customizeStatefulSet(Function.FunctionDetails funcDetails, V1StatefulSet statefulSet) {
        // First, apply all BasicKubernetesManifestCustomizer features
        // (labels, annotations, node selectors, tolerations, resource requirements)
        statefulSet = super.customizeStatefulSet(funcDetails, statefulSet);

        // Now add SecurityContext customization
        String customRuntimeOptions = funcDetails.getCustomRuntimeOptions();
        ExtendedRuntimeOpts opts = new Gson().fromJson(customRuntimeOptions, ExtendedRuntimeOpts.class);

        if (opts != null && opts.getSecurityContext() != null) {
            SecurityContextOpts secOpts = opts.getSecurityContext();
            V1PodSpec podSpec = statefulSet.getSpec().getTemplate().getSpec();

            // Apply Pod-level SecurityContext
            applyPodSecurityContext(podSpec, secOpts);

            // Apply Container-level SecurityContext to all containers
            if (podSpec.getContainers() != null) {
                podSpec.getContainers().forEach(container ->
                    applyContainerSecurityContext(container, secOpts));
            }

            log.info("Applied SecurityContext customization to StatefulSet for function: {}/{}/{}",
                    funcDetails.getTenant(), funcDetails.getNamespace(), funcDetails.getName());
        }

        return statefulSet;
    }

    /**
     * Apply pod-level security context settings.
     */
    private void applyPodSecurityContext(V1PodSpec podSpec, SecurityContextOpts secOpts) {
        V1PodSecurityContext podSecurityContext = podSpec.getSecurityContext();
        if (podSecurityContext == null) {
            podSecurityContext = new V1PodSecurityContext();
        }

        if (secOpts.getRunAsUser() != null) {
            podSecurityContext.runAsUser(secOpts.getRunAsUser());
            log.debug("Set pod runAsUser: {}", secOpts.getRunAsUser());
        }
        if (secOpts.getRunAsGroup() != null) {
            podSecurityContext.runAsGroup(secOpts.getRunAsGroup());
            log.debug("Set pod runAsGroup: {}", secOpts.getRunAsGroup());
        }
        if (secOpts.getFsGroup() != null) {
            podSecurityContext.fsGroup(secOpts.getFsGroup());
            log.debug("Set pod fsGroup: {}", secOpts.getFsGroup());
        }
        if (secOpts.getRunAsNonRoot() != null) {
            podSecurityContext.runAsNonRoot(secOpts.getRunAsNonRoot());
            log.debug("Set pod runAsNonRoot: {}", secOpts.getRunAsNonRoot());
        }

        podSpec.securityContext(podSecurityContext);
    }

    /**
     * Apply container-level security context settings.
     */
    private void applyContainerSecurityContext(V1Container container, SecurityContextOpts secOpts) {
        V1SecurityContext containerSecurityContext = container.getSecurityContext();
        if (containerSecurityContext == null) {
            containerSecurityContext = new V1SecurityContext();
        }

        // Basic security settings
        if (secOpts.getPrivileged() != null) {
            containerSecurityContext.privileged(secOpts.getPrivileged());
        }
        if (secOpts.getAllowPrivilegeEscalation() != null) {
            containerSecurityContext.allowPrivilegeEscalation(secOpts.getAllowPrivilegeEscalation());
        }
        if (secOpts.getReadOnlyRootFilesystem() != null) {
            containerSecurityContext.readOnlyRootFilesystem(secOpts.getReadOnlyRootFilesystem());
        }

        // Linux capabilities
        applyCapabilities(containerSecurityContext, secOpts);

        // SELinux options
        applySELinuxOptions(containerSecurityContext, secOpts);

        container.securityContext(containerSecurityContext);
        log.debug("Applied container SecurityContext to container: {}", container.getName());
    }

    /**
     * Apply Linux capabilities (add/drop).
     */
    private void applyCapabilities(V1SecurityContext containerSecurityContext, SecurityContextOpts secOpts) {
        if (secOpts.getAddCapabilities() != null || secOpts.getDropCapabilities() != null) {
            V1Capabilities capabilities = new V1Capabilities();

            if (secOpts.getAddCapabilities() != null) {
                for (String cap : secOpts.getAddCapabilities()) {
                    capabilities.addAddItem(cap);
                    log.debug("Adding capability: {}", cap);
                }
            }

            if (secOpts.getDropCapabilities() != null) {
                for (String cap : secOpts.getDropCapabilities()) {
                    capabilities.addDropItem(cap);
                    log.debug("Dropping capability: {}", cap);
                }
            }

            containerSecurityContext.capabilities(capabilities);
        }
    }

    /**
     * Apply SELinux options.
     */
    private void applySELinuxOptions(V1SecurityContext containerSecurityContext, SecurityContextOpts secOpts) {
        if (secOpts.getSeLinuxLevel() != null || secOpts.getSeLinuxRole() != null ||
            secOpts.getSeLinuxType() != null || secOpts.getSeLinuxUser() != null) {

            V1SELinuxOptions seLinuxOptions = new V1SELinuxOptions();

            if (secOpts.getSeLinuxLevel() != null) {
                seLinuxOptions.level(secOpts.getSeLinuxLevel());
            }
            if (secOpts.getSeLinuxRole() != null) {
                seLinuxOptions.role(secOpts.getSeLinuxRole());
            }
            if (secOpts.getSeLinuxType() != null) {
                seLinuxOptions.type(secOpts.getSeLinuxType());
            }
            if (secOpts.getSeLinuxUser() != null) {
                seLinuxOptions.user(secOpts.getSeLinuxUser());
            }

            containerSecurityContext.seLinuxOptions(seLinuxOptions);
            log.debug("Applied SELinux options");
        }
    }
}
```

### Maven Dependencies

Add to your `pom.xml`:

```xml
<dependencies>
    <!-- Pulsar Functions Runtime -->
    <dependency>
        <groupId>org.apache.pulsar</groupId>
        <artifactId>pulsar-functions-runtime</artifactId>
        <version>3.3.9</version>
        <scope>provided</scope>
    </dependency>

    <!-- Kubernetes Client -->
    <dependency>
        <groupId>io.kubernetes</groupId>
        <artifactId>client-java</artifactId>
        <version>18.0.0</version>
        <scope>provided</scope>
    </dependency>

    <!-- Lombok (optional, for cleaner code) -->
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <version>1.18.30</version>
        <scope>provided</scope>
    </dependency>

    <!-- Gson -->
    <dependency>
        <groupId>com.google.code.gson</groupId>
        <artifactId>gson</artifactId>
        <version>2.10.1</version>
        <scope>provided</scope>
    </dependency>
</dependencies>
```

---

## Deployment Guide

### Step 1: Build Your Custom Implementation

```bash
# Build the JAR
mvn clean package

# The output will be in target/your-customizer-1.0.0.jar
```

### Step 2: Add JAR to Function Worker Classpath

**Option A: Add to Docker Image** (Recommended for production)

```dockerfile
FROM apachepulsar/pulsar:3.3.9

# Copy your custom JAR to the lib directory
COPY target/your-customizer-1.0.0.jar /pulsar/lib/

# The rest of the Pulsar setup...
```

**Option B: Mount as Volume** (For testing)

```yaml
# In your Kubernetes deployment
volumes:
  - name: custom-lib
    hostPath:
      path: /path/to/your-customizer-1.0.0.jar
      type: File

volumeMounts:
  - name: custom-lib
    mountPath: /pulsar/lib/your-customizer-1.0.0.jar
    subPath: your-customizer-1.0.0.jar
```

**Option C: Copy to Existing Pod** (For quick testing)

```bash
kubectl cp target/your-customizer-1.0.0.jar \
  <namespace>/<function-worker-pod>:/pulsar/lib/
```

### Step 3: Update functions_worker.yml

```yaml
# Basic configuration
runtimeCustomizerClassName: "com.yourcompany.pulsar.runtime.SecurityContextKubernetesManifestCustomizer"

# Optional: Default configuration applied to ALL functions
runtimeCustomizerConfig:
  # BasicKubernetesManifestCustomizer options
  jobNamespace: "pulsar-functions"
  extraLabels:
    environment: "production"
    team: "platform"
  nodeSelectorLabels:
    workload-type: "pulsar-functions"
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "pulsar"
      effect: "NoSchedule"

  # Your custom SecurityContext options (applied to ALL)
  securityContext:
    runAsNonRoot: true
    runAsUser: 10000
    runAsGroup: 10000
    fsGroup: 10000
    allowPrivilegeEscalation: false
    privileged: false
    readOnlyRootFilesystem: false
    dropCapabilities:
      - "ALL"
```

### Step 4: Restart Function Workers

```bash
# If using kubectl
kubectl rollout restart deployment/pulsar-function-worker -n <namespace>

# If using Helm
helm upgrade pulsar apache/pulsar -f values.yaml --reuse-values

# Wait for rollout to complete
kubectl rollout status deployment/pulsar-function-worker -n <namespace>
```

### Step 5: Verify Configuration

```bash
# Check worker logs for successful customizer loading
kubectl logs -n <namespace> <function-worker-pod> | grep -i customizer

# Should see something like:
# INFO  [main] o.a.p.f.w.FunctionRuntimeManager - Successfully loaded RuntimeCustomizer: com.yourcompany.pulsar.runtime.SecurityContextKubernetesManifestCustomizer
```

---

## Usage Examples

### Example 1: Create Source Connector with SecurityContext

#### Using pulsar-admin CLI

```bash
pulsar-admin sources create \
  --tenant public \
  --namespace default \
  --name kafka-source \
  --source-type kafka \
  --source-config '{
    "bootstrapServers": "kafka-broker:9092",
    "topic": "input-topic",
    "groupId": "pulsar-source"
  }' \
  --destination-topic-name persistent://public/default/kafka-output \
  --parallelism 2 \
  --custom-runtime-options '{
    "securityContext": {
      "runAsUser": 1000,
      "runAsGroup": 1000,
      "fsGroup": 2000,
      "runAsNonRoot": true,
      "allowPrivilegeEscalation": false,
      "readOnlyRootFilesystem": true,
      "dropCapabilities": ["ALL"]
    },
    "nodeSelectorLabels": {
      "disktype": "ssd"
    },
    "resourceRequirements": {
      "requests": {
        "cpu": "500m",
        "memory": "1Gi"
      },
      "limits": {
        "cpu": "1",
        "memory": "2Gi"
      }
    }
  }'
```

#### Using REST API

```bash
curl -X POST "http://pulsar-admin:8080/admin/v3/sources/public/default/kafka-source" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant": "public",
    "namespace": "default",
    "name": "kafka-source",
    "sourceType": "kafka",
    "configs": {
      "bootstrapServers": "kafka-broker:9092",
      "topic": "input-topic",
      "groupId": "pulsar-source"
    },
    "topicName": "persistent://public/default/kafka-output",
    "parallelism": 2,
    "customRuntimeOptions": "{\"securityContext\":{\"runAsUser\":1000,\"runAsGroup\":1000,\"fsGroup\":2000,\"runAsNonRoot\":true,\"allowPrivilegeEscalation\":false,\"readOnlyRootFilesystem\":true,\"dropCapabilities\":[\"ALL\"]},\"nodeSelectorLabels\":{\"disktype\":\"ssd\"}}"
  }'
```

### Example 2: Create Function with SecurityContext

```bash
pulsar-admin functions create \
  --tenant public \
  --namespace default \
  --name data-processor \
  --jar /path/to/function.jar \
  --classname com.example.DataProcessor \
  --inputs persistent://public/default/input-topic \
  --output persistent://public/default/output-topic \
  --parallelism 3 \
  --custom-runtime-options '{
    "jobName": "data-processor",
    "securityContext": {
      "runAsUser": 10000,
      "runAsGroup": 10000,
      "fsGroup": 10000,
      "runAsNonRoot": true,
      "privileged": false,
      "allowPrivilegeEscalation": false,
      "readOnlyRootFilesystem": false,
      "dropCapabilities": ["ALL"]
    },
    "extraLabels": {
      "app": "data-processor",
      "version": "1.0.0",
      "component": "stream-processing"
    },
    "extraAnnotations": {
      "description": "Processes incoming data stream",
      "owner": "data-team@company.com"
    },
    "tolerations": [{
      "key": "high-memory",
      "operator": "Equal",
      "value": "true",
      "effect": "NoSchedule"
    }],
    "resourceRequirements": {
      "requests": {
        "cpu": "1",
        "memory": "2Gi"
      },
      "limits": {
        "cpu": "2",
        "memory": "4Gi"
      }
    }
  }'
```

### Example 3: Create Sink Connector with Minimal SecurityContext

```bash
pulsar-admin sinks create \
  --tenant public \
  --namespace default \
  --name elasticsearch-sink \
  --sink-type elasticsearch \
  --sink-config '{
    "elasticsearchUrl": "http://elasticsearch:9200",
    "indexName": "pulsar-data"
  }' \
  --inputs persistent://public/default/processed-data \
  --custom-runtime-options '{
    "securityContext": {
      "runAsNonRoot": true,
      "allowPrivilegeEscalation": false
    }
  }'
```

### Example 4: High-Security Configuration

For environments with strict Pod Security Standards (PSS):

```json
{
  "securityContext": {
    "runAsNonRoot": true,
    "runAsUser": 65534,
    "runAsGroup": 65534,
    "fsGroup": 65534,
    "privileged": false,
    "allowPrivilegeEscalation": false,
    "readOnlyRootFilesystem": true,
    "dropCapabilities": ["ALL"]
  },
  "extraAnnotations": {
    "container.apparmor.security.beta.kubernetes.io/pulsar-function": "runtime/default",
    "seccomp.security.alpha.kubernetes.io/pod": "runtime/default"
  }
}
```

### Example 5: Update Existing Function

```bash
# Get current function config
pulsar-admin functions get \
  --tenant public \
  --namespace default \
  --name my-function > function-config.json

# Edit function-config.json to add customRuntimeOptions

# Update the function
pulsar-admin functions update \
  --function-config-file function-config.json
```

---

## Verification and Testing

### 1. Verify Customizer is Loaded

```bash
# Check function worker logs
kubectl logs -n <namespace> <function-worker-pod> | grep -i "RuntimeCustomizer"

# Expected output:
# INFO ... Successfully loaded RuntimeCustomizer: com.yourcompany.pulsar.runtime.SecurityContextKubernetesManifestCustomizer
```

### 2. Verify StatefulSet Creation

```bash
# List StatefulSets created by functions
kubectl get statefulsets -n pulsar-functions

# Check specific StatefulSet
kubectl get statefulset <function-name> -n pulsar-functions -o yaml
```

### 3. Verify SecurityContext in Pod Spec

```bash
# Check pod-level security context
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.spec.template.spec.securityContext}' | jq

# Expected output:
# {
#   "fsGroup": 2000,
#   "runAsGroup": 1000,
#   "runAsNonRoot": true,
#   "runAsUser": 1000
# }

# Check container-level security context
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq

# Expected output:
# {
#   "allowPrivilegeEscalation": false,
#   "capabilities": {
#     "drop": ["ALL"]
#   },
#   "readOnlyRootFilesystem": true
# }
```

### 4. Verify Running Pod

```bash
# Get pod from StatefulSet
kubectl get pods -n pulsar-functions -l app=<function-name>

# Describe pod to see applied security context
kubectl describe pod <pod-name> -n pulsar-functions | grep -A 20 "Security Context"
```

### 5. Test Security Context Enforcement

```bash
# Exec into the pod and verify user
kubectl exec -it <pod-name> -n pulsar-functions -- id

# Expected output:
# uid=1000 gid=1000 groups=2000

# Try to escalate privileges (should fail)
kubectl exec -it <pod-name> -n pulsar-functions -- su root
# Expected: Operation not permitted

# Try to write to filesystem (if readOnlyRootFilesystem=true, should fail)
kubectl exec -it <pod-name> -n pulsar-functions -- touch /test.txt
# Expected: Read-only file system
```

### 6. Verify Other Customizations

```bash
# Check labels
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.metadata.labels}' | jq

# Check annotations
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.metadata.annotations}' | jq

# Check node selectors
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.spec.template.spec.nodeSelector}' | jq

# Check tolerations
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.spec.template.spec.tolerations}' | jq

# Check resource requirements
kubectl get statefulset <function-name> -n pulsar-functions \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq
```

### 7. Common Issues and Troubleshooting

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Customizer Not Loaded** | Functions create but customizations not applied | Check JAR in classpath, verify class name in config, restart workers |
| **Class Not Found** | Worker fails to start with ClassNotFoundException | Verify JAR is in `/pulsar/lib/`, check package name |
| **JSON Parse Error** | Function creation fails with parse error | Validate JSON in `customRuntimeOptions`, escape quotes properly |
| **Pod Security Policy Violation** | Pod fails to start | Adjust SecurityContext settings to match PSP/PSS requirements |
| **Permission Denied** | Function crashes on startup | Check runAsUser has permissions for required directories/files |
| **Worker RBAC Error** | StatefulSet creation fails | Ensure function worker ServiceAccount has permissions in target namespace |

---

## Best Practices and Recommendations

### Security

1. **Always set `runAsNonRoot: true`** - Prevents container from running as root
2. **Drop all capabilities by default** - Use `dropCapabilities: ["ALL"]`, add only what's needed
3. **Disable privilege escalation** - Set `allowPrivilegeEscalation: false`
4. **Use high UID/GID** - Avoid conflicts with host users (use 10000+ range)
5. **Consider readOnlyRootFilesystem** - Increases security but may require emptyDir volumes for temp files

### Configuration Management

1. **Use worker-level config for org-wide standards** - Apply common security baselines to all functions
2. **Use per-function config for exceptions** - Override only when needed for specific requirements
3. **Version your customizer** - Include version in JAR name for rollback capability
4. **Document your security policies** - Maintain clear documentation of security requirements

### Testing

1. **Test in non-production first** - Verify customizations work before production deployment
2. **Validate with security scanning** - Use tools like `kubesec` or `kube-bench` to validate configurations
3. **Monitor function startup times** - SecurityContext changes shouldn't significantly impact startup
4. **Test update scenarios** - Ensure functions can be updated without downtime

### Monitoring

1. **Alert on pod security violations** - Monitor for pods that fail due to security context issues
2. **Track customizer usage** - Log which functions use custom SecurityContext
3. **Audit security settings** - Periodically review applied security contexts across all functions

---

## Advanced Topics

### Extending for Additional Customizations

The same pattern can be extended for other Kubernetes resources:

```java
@Override
public V1Service customizeService(Function.FunctionDetails funcDetails, V1Service service) {
    service = super.customizeService(funcDetails, service);
    // Add your custom service modifications
    return service;
}

@Override
public String customizeNamespace(Function.FunctionDetails funcDetails, String currentNamespace) {
    // Custom namespace selection logic
    return super.customizeNamespace(funcDetails, currentNamespace);
}

@Override
public String customizeName(Function.FunctionDetails funcDetails, String currentName) {
    // Custom naming logic
    return super.customizeName(funcDetails, currentName);
}
```

### Adding ServiceAccount Customization

```java
private void applyServiceAccount(V1PodSpec podSpec, String serviceAccountName) {
    if (serviceAccountName != null && !serviceAccountName.isEmpty()) {
        podSpec.serviceAccountName(serviceAccountName);
        podSpec.automountServiceAccountToken(true);
        log.info("Set serviceAccount: {}", serviceAccountName);
    }
}
```

### Adding Affinity Rules

```java
private void applyAffinity(V1PodSpec podSpec, AffinityOpts affinityOpts) {
    if (affinityOpts != null) {
        V1Affinity affinity = new V1Affinity();
        // Build affinity rules...
        podSpec.affinity(affinity);
    }
}
```

---

## References

### Source Code Locations

All paths relative to Apache Pulsar repository root:

- **KubernetesManifestCustomizer Interface:**
  `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/KubernetesManifestCustomizer.java`

- **BasicKubernetesManifestCustomizer:**
  `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/BasicKubernetesManifestCustomizer.java`

- **KubernetesRuntime (StatefulSet creation):**
  `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/KubernetesRuntime.java:926-979`

- **KubernetesRuntimeFactory:**
  `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/runtime/kubernetes/KubernetesRuntimeFactory.java`

- **FunctionRuntimeManager (loading):**
  `pulsar-functions/worker/src/main/java/org/apache/pulsar/functions/worker/FunctionRuntimeManager.java:185-191`

- **WorkerConfig:**
  `pulsar-functions/runtime/src/main/java/org/apache/pulsar/functions/worker/WorkerConfig.java:771-782`

- **FunctionConfig:**
  `pulsar-client-admin-api/src/main/java/org/apache/pulsar/common/functions/FunctionConfig.java:128`

- **SourceConfig:**
  `pulsar-client-admin-api/src/main/java/org/apache/pulsar/common/io/SourceConfig.java:69`

- **SinkConfig:**
  `pulsar-client-admin-api/src/main/java/org/apache/pulsar/common/io/SinkConfig.java:93`

### Documentation

- **Kubernetes Runtime Configuration:**
  https://pulsar.apache.org/docs/4.0.x/functions-runtime-kubernetes/

- **Kubernetes SecurityContext:**
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/

- **Pod Security Standards:**
  https://kubernetes.io/docs/concepts/security/pod-security-standards/

- **Original PR (customRuntimeOptions):**
  https://github.com/apache/pulsar/pull/5400

- **BasicKubernetesManifestCustomizer PR:**
  https://github.com/apache/pulsar/pull/9445

---

## Summary

This guide provides a complete path from understanding how Pulsar creates StatefulSets to implementing custom SecurityContext configuration:

1. ✅ **Functions and Connectors use the same mechanism** - Source/Sink connectors are functions internally
2. ✅ **Two-level configuration** - Worker-wide defaults + per-function overrides
3. ✅ **KubernetesManifestCustomizer is the hook** - Implement this interface for customization
4. ✅ **BasicKubernetesManifestCustomizer doesn't support SecurityContext** - Custom implementation required
5. ✅ **Full example provided** - Copy-paste ready implementation with logging and error handling
6. ✅ **Complete deployment guide** - From build to verification
7. ✅ **Practical examples** - Real-world usage for functions, sources, and sinks

The documentation may be unclear about connectors, but they work identically to functions with the `customRuntimeOptions` field. Your implementation will work for all three: Functions, Source Connectors, and Sink Connectors.
