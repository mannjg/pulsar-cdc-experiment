#!/bin/bash
set -e

echo "Deploying minimal Pulsar 3.3.9 to microk8s..."

# Create namespace
echo "Creating namespace..."
microk8s kubectl apply -f namespace.yaml

# Deploy ZooKeeper
echo "Deploying ZooKeeper..."
microk8s kubectl apply -f zookeeper.yaml

# Wait for ZooKeeper to be ready
echo "Waiting for ZooKeeper to be ready..."
microk8s kubectl wait --for=condition=ready pod -l app=zookeeper -n pulsar --timeout=300s

# Initialize BookKeeper metadata
echo "Initializing BookKeeper metadata..."
microk8s kubectl apply -f init-bookkeeper.yaml

# Wait for BookKeeper init job to complete
echo "Waiting for BookKeeper initialization..."
microk8s kubectl wait --for=condition=complete job/bookkeeper-init -n pulsar --timeout=300s

# Deploy BookKeeper
echo "Deploying BookKeeper..."
microk8s kubectl apply -f bookkeeper.yaml

# Wait for BookKeeper to be ready
echo "Waiting for BookKeeper to be ready..."
microk8s kubectl wait --for=condition=ready pod -l app=bookkeeper -n pulsar --timeout=300s

# Initialize cluster metadata
echo "Initializing cluster metadata..."
microk8s kubectl apply -f init-cluster.yaml

# Wait for init job to complete
echo "Waiting for cluster initialization..."
microk8s kubectl wait --for=condition=complete job/pulsar-init -n pulsar --timeout=300s

# Deploy Broker
echo "Deploying Broker..."
microk8s kubectl apply -f broker.yaml

# Wait for Broker to be ready
echo "Waiting for Broker to be ready..."
microk8s kubectl wait --for=condition=ready pod -l app=broker -n pulsar --timeout=300s

echo ""
echo "Deployment complete!"
echo ""
echo "Check status with:"
echo "  microk8s kubectl get pods -n pulsar"
echo ""
echo "Access Pulsar at:"
echo "  Pulsar protocol: pulsar://localhost:30650"
echo "  HTTP Admin API: http://localhost:30080"
echo ""
echo "Test connection:"
echo "  curl http://localhost:30080/admin/v2/clusters/local"
