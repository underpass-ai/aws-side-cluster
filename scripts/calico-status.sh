#!/usr/bin/env bash
set -euo pipefail

echo "== Nodes =="
kubectl get nodes -o wide

echo
echo "== Calico autodetection =="
kubectl get installation.operator.tigera.io default -o jsonpath='{.spec.calicoNetwork.nodeAddressAutodetectionV4}'
echo

echo
echo "== Tigera status =="
kubectl get tigerastatuses.operator.tigera.io

echo
echo "== Calico pods =="
kubectl -n calico-system get pods -o wide

echo
echo "== MetalLB ingress =="
kubectl -n metallb-system get pods -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
