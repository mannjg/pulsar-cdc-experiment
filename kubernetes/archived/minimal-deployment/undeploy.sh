#!/bin/bash
set -e

echo "Removing Pulsar deployment from microk8s..."

# Delete namespace (this will delete all resources)
microk8s kubectl delete namespace pulsar

echo ""
echo "Pulsar deployment removed!"
echo ""
echo "Note: PersistentVolumes may still exist. To delete them manually:"
echo "  microk8s kubectl get pv"
echo "  microk8s kubectl delete pv <pv-name>"
