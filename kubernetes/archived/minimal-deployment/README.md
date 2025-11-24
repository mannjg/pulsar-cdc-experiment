# Minimal Pulsar 3.3.9 Deployment for microk8s

This is a minimal Apache Pulsar deployment suitable for development and testing on a local microk8s cluster.

## Components

- **ZooKeeper**: 1 replica for metadata storage
- **BookKeeper**: 1 replica for message storage
- **Broker**: 1 replica for message routing

## Prerequisites

- microk8s running
- At least 4GB of available memory
- Storage provisioner enabled in microk8s

Enable required addons:
```bash
microk8s enable storage dns
```

## Deployment

Deploy all components in order:

```bash
# Deploy in order
microk8s kubectl apply -f namespace.yaml
microk8s kubectl apply -f zookeeper.yaml
microk8s kubectl apply -f bookkeeper.yaml
microk8s kubectl apply -f init-cluster.yaml
microk8s kubectl apply -f broker.yaml
```

Or use the deployment script:
```bash
./deploy.sh
```

## Verify Deployment

Check pod status:
```bash
microk8s kubectl get pods -n pulsar -w
```

Check if initialization job completed:
```bash
microk8s kubectl get jobs -n pulsar
```

Check logs:
```bash
microk8s kubectl logs -n pulsar -l app=broker
```

## Access Pulsar

The broker is exposed via NodePort:
- Pulsar protocol: `localhost:30650` or `<node-ip>:30650`
- HTTP Admin API: `localhost:30080` or `<node-ip>:30080`

Test connection:
```bash
# Get cluster info
curl http://localhost:30080/admin/v2/clusters/local

# List tenants
curl http://localhost:30080/admin/v2/tenants
```

## Using Pulsar Client

From within the cluster:
```bash
microk8s kubectl exec -n pulsar broker-0 -- bin/pulsar-client produce persistent://public/default/test -m "Hello Pulsar" -n 10
microk8s kubectl exec -n pulsar broker-0 -- bin/pulsar-client consume persistent://public/default/test -s "test-sub" -n 10
```

From outside (requires pulsar-client installed):
```bash
# Produce messages
pulsar-client produce pulsar://localhost:30650/persistent/public/default/test -m "Hello Pulsar" -n 10

# Consume messages
pulsar-client consume pulsar://localhost:30650/persistent/public/default/test -s "test-sub" -n 10
```

## Cleanup

```bash
microk8s kubectl delete namespace pulsar
```

## Resource Configuration

This minimal deployment uses:
- ZooKeeper: 512MB memory, 5GB storage
- BookKeeper: 512MB memory, 15GB storage (5GB journal + 10GB ledgers)
- Broker: 512MB memory

Adjust resource requests/limits in the YAML files as needed for your use case.

## Notes

- This is a **development/testing** deployment - not suitable for production
- All components run with 1 replica
- No authentication or authorization configured
- No TLS/encryption configured
- Data persists in PersistentVolumes
