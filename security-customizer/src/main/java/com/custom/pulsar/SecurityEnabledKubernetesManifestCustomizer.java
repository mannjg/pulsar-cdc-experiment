package com.custom.pulsar;

import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import io.kubernetes.client.openapi.models.*;
import org.apache.pulsar.functions.proto.Function;
import org.apache.pulsar.functions.runtime.kubernetes.BasicKubernetesManifestCustomizer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Type;
import java.util.*;

/**
 * Extended Kubernetes Manifest Customizer that adds SecurityContext support
 * for Pulsar Functions and Source/Sink Connectors.
 *
 * Extends BasicKubernetesManifestCustomizer to add:
 * - podSecurityContext: Security settings for the entire Pod
 * - containerSecurityContext: Security settings for individual containers
 */
public class SecurityEnabledKubernetesManifestCustomizer extends BasicKubernetesManifestCustomizer {

    private static final Logger log = LoggerFactory.getLogger(SecurityEnabledKubernetesManifestCustomizer.class);
    private static final Gson gson = new com.google.gson.GsonBuilder()
            .registerTypeAdapter(CapabilitiesOpts.class, new CapabilitiesDeserializer())
            .create();

    private SecurityRuntimeOpts globalSecurityOpts;

    @Override
    public void initialize(Map<String, Object> config) {
        super.initialize(config);

        // Parse global security options from config
        if (config != null && !config.isEmpty()) {
            try {
                String json = gson.toJson(config);
                globalSecurityOpts = gson.fromJson(json, SecurityRuntimeOpts.class);
                log.info("Initialized SecurityEnabledKubernetesManifestCustomizer with global security options");
            } catch (Exception e) {
                log.warn("Failed to parse global security options: {}", e.getMessage());
                globalSecurityOpts = new SecurityRuntimeOpts();
            }
        } else {
            globalSecurityOpts = new SecurityRuntimeOpts();
        }
    }

    @Override
    public V1StatefulSet customizeStatefulSet(Function.FunctionDetails funcDetails, V1StatefulSet statefulSet) {
        // First apply basic customizations from parent
        statefulSet = super.customizeStatefulSet(funcDetails, statefulSet);

        // Parse function-specific security options
        SecurityRuntimeOpts functionSecurityOpts = parseFunctionSecurityOpts(funcDetails);

        // Merge global and function-specific options (function takes precedence)
        SecurityRuntimeOpts mergedOpts = mergeSecurityOpts(globalSecurityOpts, functionSecurityOpts);

        // Apply security context if configured
        if (mergedOpts.hasPodSecurityContext() || mergedOpts.hasContainerSecurityContext()) {
            applySecurityContext(statefulSet, mergedOpts);
            log.info("Applied security context to StatefulSet: {}", statefulSet.getMetadata().getName());
        }

        return statefulSet;
    }

    private SecurityRuntimeOpts parseFunctionSecurityOpts(Function.FunctionDetails funcDetails) {
        if (funcDetails == null || funcDetails.getCustomRuntimeOptions() == null || funcDetails.getCustomRuntimeOptions().isEmpty()) {
            return new SecurityRuntimeOpts();
        }

        try {
            String customRuntimeOptions = funcDetails.getCustomRuntimeOptions();
            return gson.fromJson(customRuntimeOptions, SecurityRuntimeOpts.class);
        } catch (Exception e) {
            log.warn("Failed to parse function security options: {}", e.getMessage());
            return new SecurityRuntimeOpts();
        }
    }

    private SecurityRuntimeOpts mergeSecurityOpts(SecurityRuntimeOpts global, SecurityRuntimeOpts function) {
        SecurityRuntimeOpts merged = new SecurityRuntimeOpts();

        // Merge podSecurityContext
        if (function.podSecurityContext != null) {
            merged.podSecurityContext = function.podSecurityContext;
        } else if (global.podSecurityContext != null) {
            merged.podSecurityContext = global.podSecurityContext;
        }

        // Merge containerSecurityContext
        if (function.containerSecurityContext != null) {
            merged.containerSecurityContext = function.containerSecurityContext;
        } else if (global.containerSecurityContext != null) {
            merged.containerSecurityContext = global.containerSecurityContext;
        }

        return merged;
    }

    private void applySecurityContext(V1StatefulSet statefulSet, SecurityRuntimeOpts opts) {
        if (statefulSet.getSpec() == null || statefulSet.getSpec().getTemplate() == null) {
            log.warn("StatefulSet spec or template is null, cannot apply security context");
            return;
        }

        V1PodSpec podSpec = statefulSet.getSpec().getTemplate().getSpec();
        if (podSpec == null) {
            log.warn("PodSpec is null, cannot apply security context");
            return;
        }

        // Apply Pod Security Context
        if (opts.podSecurityContext != null) {
            V1PodSecurityContext podSecurityContext = buildPodSecurityContext(opts.podSecurityContext);
            podSpec.setSecurityContext(podSecurityContext);
            log.debug("Applied pod security context: {}", podSecurityContext);
        }

        // Apply Container Security Context to all containers
        if (opts.containerSecurityContext != null) {
            V1SecurityContext containerSecurityContext = buildContainerSecurityContext(opts.containerSecurityContext);

            // Apply to main containers
            if (podSpec.getContainers() != null) {
                for (V1Container container : podSpec.getContainers()) {
                    container.setSecurityContext(containerSecurityContext);
                    log.debug("Applied container security context to container: {}", container.getName());
                }
            }

            // Also apply to init containers if any
            if (podSpec.getInitContainers() != null) {
                for (V1Container initContainer : podSpec.getInitContainers()) {
                    initContainer.setSecurityContext(containerSecurityContext);
                    log.debug("Applied container security context to init container: {}", initContainer.getName());
                }
            }
        }
    }

    private V1PodSecurityContext buildPodSecurityContext(PodSecurityContextOpts opts) {
        V1PodSecurityContext ctx = new V1PodSecurityContext();

        if (opts.runAsUser != null) {
            ctx.setRunAsUser(opts.runAsUser);
        }

        if (opts.runAsGroup != null) {
            ctx.setRunAsGroup(opts.runAsGroup);
        }

        if (opts.fsGroup != null) {
            ctx.setFsGroup(opts.fsGroup);
        }

        if (opts.runAsNonRoot != null) {
            ctx.setRunAsNonRoot(opts.runAsNonRoot);
        }

        if (opts.supplementalGroups != null && !opts.supplementalGroups.isEmpty()) {
            ctx.setSupplementalGroups(opts.supplementalGroups);
        }

        if (opts.fsGroupChangePolicy != null) {
            ctx.setFsGroupChangePolicy(opts.fsGroupChangePolicy);
        }

        if (opts.seccompProfile != null) {
            ctx.setSeccompProfile(buildSeccompProfile(opts.seccompProfile));
        }

        if (opts.seLinuxOptions != null) {
            ctx.setSeLinuxOptions(buildSELinuxOptions(opts.seLinuxOptions));
        }

        return ctx;
    }

    private V1SecurityContext buildContainerSecurityContext(ContainerSecurityContextOpts opts) {
        V1SecurityContext ctx = new V1SecurityContext();

        if (opts.runAsUser != null) {
            ctx.setRunAsUser(opts.runAsUser);
        }

        if (opts.runAsGroup != null) {
            ctx.setRunAsGroup(opts.runAsGroup);
        }

        if (opts.runAsNonRoot != null) {
            ctx.setRunAsNonRoot(opts.runAsNonRoot);
        }

        if (opts.readOnlyRootFilesystem != null) {
            ctx.setReadOnlyRootFilesystem(opts.readOnlyRootFilesystem);
        }

        if (opts.allowPrivilegeEscalation != null) {
            ctx.setAllowPrivilegeEscalation(opts.allowPrivilegeEscalation);
        }

        if (opts.privileged != null) {
            ctx.setPrivileged(opts.privileged);
        }

        if (opts.capabilities != null) {
            ctx.setCapabilities(buildCapabilities(opts.capabilities));
        }

        if (opts.seccompProfile != null) {
            ctx.setSeccompProfile(buildSeccompProfile(opts.seccompProfile));
        }

        if (opts.seLinuxOptions != null) {
            ctx.setSeLinuxOptions(buildSELinuxOptions(opts.seLinuxOptions));
        }

        if (opts.procMount != null) {
            ctx.setProcMount(opts.procMount);
        }

        return ctx;
    }

    private V1Capabilities buildCapabilities(CapabilitiesOpts opts) {
        V1Capabilities caps = new V1Capabilities();

        if (opts.add != null && !opts.add.isEmpty()) {
            caps.setAdd(opts.add);
        }

        if (opts.drop != null && !opts.drop.isEmpty()) {
            caps.setDrop(opts.drop);
        }

        return caps;
    }

    private V1SeccompProfile buildSeccompProfile(SeccompProfileOpts opts) {
        V1SeccompProfile profile = new V1SeccompProfile();

        if (opts.type != null) {
            profile.setType(opts.type);
        }

        if (opts.localhostProfile != null) {
            profile.setLocalhostProfile(opts.localhostProfile);
        }

        return profile;
    }

    private V1SELinuxOptions buildSELinuxOptions(SELinuxOptionsOpts opts) {
        V1SELinuxOptions seLinux = new V1SELinuxOptions();

        if (opts.level != null) {
            seLinux.setLevel(opts.level);
        }

        if (opts.role != null) {
            seLinux.setRole(opts.role);
        }

        if (opts.type != null) {
            seLinux.setType(opts.type);
        }

        if (opts.user != null) {
            seLinux.setUser(opts.user);
        }

        return seLinux;
    }

    // Configuration classes

    public static class SecurityRuntimeOpts {
        public PodSecurityContextOpts podSecurityContext;
        public ContainerSecurityContextOpts containerSecurityContext;

        public boolean hasPodSecurityContext() {
            return podSecurityContext != null;
        }

        public boolean hasContainerSecurityContext() {
            return containerSecurityContext != null;
        }
    }

    public static class PodSecurityContextOpts {
        public Long runAsUser;
        public Long runAsGroup;
        public Long fsGroup;
        public Boolean runAsNonRoot;
        public List<Long> supplementalGroups;
        public String fsGroupChangePolicy;
        public SeccompProfileOpts seccompProfile;
        public SELinuxOptionsOpts seLinuxOptions;
    }

    public static class ContainerSecurityContextOpts {
        public Long runAsUser;
        public Long runAsGroup;
        public Boolean runAsNonRoot;
        public Boolean readOnlyRootFilesystem;
        public Boolean allowPrivilegeEscalation;
        public Boolean privileged;
        public CapabilitiesOpts capabilities;
        public SeccompProfileOpts seccompProfile;
        public SELinuxOptionsOpts seLinuxOptions;
        public String procMount;
    }

    public static class CapabilitiesOpts {
        public List<String> add;
        public List<String> drop;
    }

    public static class SeccompProfileOpts {
        public String type;
        public String localhostProfile;
    }

    public static class SELinuxOptionsOpts {
        public String level;
        public String role;
        public String type;
        public String user;
    }

    /**
     * Custom deserializer for CapabilitiesOpts that handles multiple input formats:
     * 1. Map format from Pulsar indexed properties: {0: "ALL"} -> ["ALL"]
     * 2. Proper array format: ["ALL", "NET_ADMIN"] -> ["ALL", "NET_ADMIN"]
     * 3. Single string value: "ALL" -> ["ALL"]
     */
    private static class CapabilitiesDeserializer implements com.google.gson.JsonDeserializer<CapabilitiesOpts> {
        @Override
        public CapabilitiesOpts deserialize(com.google.gson.JsonElement json, Type typeOfT,
                                            com.google.gson.JsonDeserializationContext context)
                throws com.google.gson.JsonParseException {
            CapabilitiesOpts caps = new CapabilitiesOpts();

            if (json.isJsonObject()) {
                com.google.gson.JsonObject obj = json.getAsJsonObject();

                // Handle 'add' field
                if (obj.has("add")) {
                    caps.add = parseField(obj.get("add"));
                }

                // Handle 'drop' field
                if (obj.has("drop")) {
                    caps.drop = parseField(obj.get("drop"));
                }
            }

            return caps;
        }

        private List<String> parseField(com.google.gson.JsonElement element) {
            if (element.isJsonArray()) {
                // Proper array format: ["ALL", "NET_ADMIN"]
                List<String> result = new ArrayList<>();
                for (com.google.gson.JsonElement item : element.getAsJsonArray()) {
                    result.add(item.getAsString());
                }
                return result;
            } else if (element.isJsonObject()) {
                // Map format from Pulsar indexed properties: {0: "ALL", 1: "NET_ADMIN"}
                // Extract values sorted by numeric keys
                com.google.gson.JsonObject obj = element.getAsJsonObject();
                java.util.TreeMap<Integer, String> sortedMap = new java.util.TreeMap<>();
                for (Map.Entry<String, com.google.gson.JsonElement> entry : obj.entrySet()) {
                    try {
                        int index = Integer.parseInt(entry.getKey());
                        sortedMap.put(index, entry.getValue().getAsString());
                    } catch (NumberFormatException e) {
                        log.warn("Ignoring non-numeric key in capabilities: {}", entry.getKey());
                    }
                }
                return new ArrayList<>(sortedMap.values());
            } else if (element.isJsonPrimitive()) {
                // Single string value: "ALL"
                return Collections.singletonList(element.getAsString());
            }
            return Collections.emptyList();
        }
    }
}
