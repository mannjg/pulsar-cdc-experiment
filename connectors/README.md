# Pulsar Connectors

This directory contains Pulsar connector archives (NAR files).

## Debezium PostgreSQL Connector

**File:** `pulsar-io-debezium-postgres-3.3.2.nar`
**Size:** ~44 MB
**Version:** 3.3.2

### Overview

This connector enables Change Data Capture (CDC) from PostgreSQL databases using Debezium. It captures row-level changes from PostgreSQL's Write-Ahead Log (WAL) and streams them to Pulsar topics.

### Configuration

The connector is configured via `../kubernetes/manifests/debezium-postgres-connector.yaml`.

Key settings:
- **Database:** PostgreSQL with logical replication enabled
- **Plugin:** pgoutput (PostgreSQL native replication protocol)
- **Snapshot Mode:** initial (take initial snapshot, then stream changes)
- **Tables:** Configurable via `table.include.list`

### Deployment

1. **Upload the NAR file to Pulsar**

   Option A - Via kubectl:
   ```bash
   kubectl cp pulsar-io-debezium-postgres-3.3.2.nar \
     pulsar-toolset-0:/tmp/ -n pulsar
   ```

   Option B - Pre-install in Pulsar image:
   - Build a custom Pulsar image with the NAR in `/pulsar/connectors/`
   - Update the broker image in Helm values

2. **Create the connector**

   ```bash
   # From toolset pod
   kubectl exec -it pulsar-toolset-0 -n pulsar -- bash

   # Create connector
   bin/pulsar-admin sources create \
     --archive /path/to/pulsar-io-debezium-postgres-3.3.2.nar \
     --tenant public \
     --namespace default \
     --name debezium-postgres-source \
     --destination-topic-name persistent://public/default/debezium-postgres-customers \
     --source-config '{
       "database.hostname": "postgres.pulsar.svc.cluster.local",
       "database.port": "5432",
       "database.user": "postgres",
       "database.password": "postgres",
       "database.dbname": "inventory",
       "database.server.name": "dbserver1",
       "plugin.name": "pgoutput",
       "table.include.list": "public.customers",
       "snapshot.mode": "initial"
     }' \
     --custom-runtime-options '{
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
         "capabilities": {"drop": ["ALL"]}
       }
     }'
   ```

3. **Verify the connector**

   ```bash
   # Check status
   bin/pulsar-admin sources status \
     --tenant public \
     --namespace default \
     --name debezium-postgres-source

   # Check Pod
   kubectl get pods -n pulsar | grep debezium-postgres-source
   ```

### Monitoring

**Check connector logs:**
```bash
kubectl logs pf-public-default-debezium-postgres-source-0 -n pulsar --tail=100
```

**Check connector metrics:**
```bash
bin/pulsar-admin sources status \
  --tenant public \
  --namespace default \
  --name debezium-postgres-source
```

**Monitor topic:**
```bash
# Check messages in the topic
bin/pulsar-client consume \
  persistent://public/default/debezium-postgres-customers \
  -s test-consumer -n 0
```

### Known Issues

#### Jackson Library Incompatibility

The 3.3.2 connector currently has a Jackson library version conflict with Pulsar 3.3.9:

```
java.lang.NoSuchMethodError: 'boolean com.fasterxml.jackson.databind.util.NativeImageUtil.isInNativeImage()'
```

**Workaround:**
- Consider using Debezium connector version 2.x which has better compatibility with Pulsar 3.3.9
- Or upgrade to Pulsar 4.x which includes newer Jackson libraries

### PostgreSQL Requirements

PostgreSQL must be configured for logical replication:

```sql
-- In postgresql.conf
wal_level = logical
max_wal_senders = 4
max_replication_slots = 4

-- Restart PostgreSQL after configuration change

-- Grant replication permissions
ALTER ROLE postgres WITH REPLICATION;

-- Verify settings
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
```

### Supported Operations

- **INSERT** - Captured as `op: "c"` (create)
- **UPDATE** - Captured as `op: "u"` (update)
- **DELETE** - Captured as `op: "d"` (delete)
- **Initial Snapshot** - Captured as `op: "r"` (read)

### Message Format

Debezium produces messages in this structure:

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
  "op": "c",
  "ts_ms": 1637012345678
}
```

### Troubleshooting

1. **Connector fails to start**
   - Check PostgreSQL is accessible from the connector Pod
   - Verify database credentials
   - Ensure logical replication is enabled

2. **No messages appearing**
   - Verify replication slot is created: `SELECT * FROM pg_replication_slots;`
   - Check if tables match `table.include.list` pattern
   - Review connector logs for errors

3. **Connector Pod in CrashLoopBackOff**
   - Check logs: `kubectl logs pf-public-default-debezium-postgres-source-0 -n pulsar`
   - Verify SecurityContext settings
   - Check for library compatibility issues

4. **SecurityContext errors**
   - Verify security customizer is properly configured in broker
   - Check that `customRuntimeOptions` JSON is valid

## References

- [Debezium PostgreSQL Connector Documentation](https://debezium.io/documentation/reference/connectors/postgresql.html)
- [Pulsar IO Connectors](https://pulsar.apache.org/docs/io-overview/)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
