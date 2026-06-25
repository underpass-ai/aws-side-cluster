#!/usr/bin/env bash
set -euo pipefail

echo "Pre-change Calico status"
scripts/calico-status.sh

echo
echo "Creating Calico backup"
backup_dir="$(scripts/calico-backup.sh | tail -n 1)"
echo "Backup saved at $backup_dir"

echo
echo "Switching Calico node address autodetection to kubernetes=NodeInternalIP"
kubectl patch installation.operator.tigera.io default \
  --type=merge \
  -p '{"spec":{"calicoNetwork":{"nodeAddressAutodetectionV4":{"kubernetes":"NodeInternalIP","interface":null,"canReach":null,"cidrs":null,"firstFound":null,"skipInterface":null}}}}'

echo "Waiting for Tigera operator to reconcile"
kubectl wait tigerastatus.operator.tigera.io/calico --for=condition=Available --timeout=180s || true
kubectl -n calico-system rollout status daemonset/calico-node --timeout=180s || true

echo
echo "Post-change Calico status"
scripts/calico-status.sh

echo
echo "Rollback command: scripts/calico-rollback-enp211s0.sh"
