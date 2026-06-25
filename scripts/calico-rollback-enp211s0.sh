#!/usr/bin/env bash
set -euo pipefail

echo "Rolling Calico node address autodetection back to interface=enp211s0"

kubectl patch installation.operator.tigera.io default \
  --type=merge \
  -p '{"spec":{"calicoNetwork":{"nodeAddressAutodetectionV4":{"interface":"enp211s0","kubernetes":null,"canReach":null,"cidrs":null,"firstFound":null,"skipInterface":null}}}}'

echo "Waiting for Tigera operator to reconcile"
kubectl wait tigerastatus.operator.tigera.io/calico --for=condition=Available --timeout=180s || true
kubectl -n calico-system rollout status daemonset/calico-node --timeout=180s || true

scripts/calico-status.sh
