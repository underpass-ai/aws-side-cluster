#!/usr/bin/env bash
set -euo pipefail

backup_root="${BACKUP_ROOT:-backups/calico}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$backup_root/$timestamp"

mkdir -p "$backup_dir"

kubectl get installation.operator.tigera.io default >/dev/null

capture() {
  local name="$1"
  shift
  echo "Capturing $name"
  "$@" > "$backup_dir/$name" 2> "$backup_dir/$name.stderr" || true
}

capture_json() {
  local name="$1"
  shift
  echo "Capturing $name"
  "$@" -o json | jq 'del(
    .metadata.managedFields,
    .metadata.resourceVersion,
    .metadata.uid,
    .metadata.generation,
    .metadata.creationTimestamp,
    .status
  )' > "$backup_dir/$name" 2> "$backup_dir/$name.stderr" || true
}

capture_json "installation.default.json" kubectl get installation.operator.tigera.io default
capture "installation.default.yaml" kubectl get installation.operator.tigera.io default -o yaml
capture "ippools.yaml" kubectl get ippools.crd.projectcalico.org -o yaml
capture "felixconfigurations.yaml" kubectl get felixconfigurations.crd.projectcalico.org -o yaml
capture "bgpconfigurations.yaml" kubectl get bgpconfigurations.crd.projectcalico.org -o yaml
capture "bgppeers.yaml" kubectl get bgppeers.crd.projectcalico.org -o yaml
capture "tigera-status.yaml" kubectl get tigerastatuses.operator.tigera.io -o yaml
capture "calico-pods.txt" kubectl -n calico-system get pods -o wide
capture "calico-daemonset.yaml" kubectl -n calico-system get daemonset calico-node -o yaml
capture "calico-kube-controllers.yaml" kubectl -n calico-system get deployment calico-kube-controllers -o yaml
capture "nodes.txt" kubectl get nodes -o wide
capture "metallb-pods.txt" kubectl -n metallb-system get pods -o wide
capture "ingress-service.txt" kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide

current_autodetection="$(kubectl get installation.operator.tigera.io default -o jsonpath='{.spec.calicoNetwork.nodeAddressAutodetectionV4}' || true)"
printf '%s\n' "$current_autodetection" > "$backup_dir/nodeAddressAutodetectionV4.txt"

echo "$backup_dir"
