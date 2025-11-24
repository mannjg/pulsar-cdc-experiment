# Pulsar Functions

This directory contains Pulsar Functions used in the CDC pipeline.

## CDC Enrichment Function

Location: `cdc-enrichment/`

### Purpose

Processes CDC messages from Debezium and adds enrichment metadata.

### Files

- `cdc-enrichment-function.py` - Python function implementation
- `custom-runtime-options.json` - Runtime configuration including SecurityContext

### Function Configuration

**Input Topic:** `persistent://public/default/dbserver1.public.customers`
**Output Topic:** `persistent://public/default/dbserver1.public.customers-enriched`
**Runtime:** Python
**Processing Guarantees:** At-least-once

### Deployment

```bash
# From Pulsar toolset pod
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

### Custom Runtime Options

The `custom-runtime-options.json` file includes SecurityContext configuration that will be applied by the security customizer:

```json
{
  "clusterName": "pulsar",
  "jobNamespace": "pulsar",
  "podSecurityContext": {
    "runAsNonRoot": true,
    "runAsUser": 10000,
    "runAsGroup": 10000,
    "fsGroup": 10000
  },
  "containerSecurityContext": {
    "runAsNonRoot": true,
    "readOnlyRootFilesystem": false,
    "allowPrivilegeEscalation": false,
    "capabilities": {
      "drop": ["ALL"]
    }
  }
}
```

### Testing Locally

```bash
cd cdc-enrichment
python cdc-enrichment-function.py
```

### Monitoring

Check function status:
```bash
bin/pulsar-admin functions status --tenant public --namespace default --name cdc-enrichment
```

View logs:
```bash
kubectl logs pf-public-default-cdc-enrichment-0 -n pulsar
```

### Troubleshooting

1. **Function not processing messages**
   - Check if function is running: `kubectl get pods -n pulsar | grep cdc-enrichment`
   - Verify subscription is active: `bin/pulsar-admin topics stats persistent://public/default/dbserver1.public.customers`

2. **SecurityContext errors**
   - Verify the security customizer JAR is loaded in broker
   - Check broker logs for customizer errors

3. **Python import errors**
   - Ensure Python dependencies are available in the function runtime
   - Check function logs for specific import errors
