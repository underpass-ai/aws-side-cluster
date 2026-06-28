#!/usr/bin/env bash
# Invocado por terraform (null_resource.wg_sync) tras crear/cambiar instancias.
# Fija los endpoints WireGuard PC->EC2 (sudo wg, NOPASSWD) en bucle y espera a
# que TODOS los workers AWS arrancados (pool t4g y/o pool GPU) lleguen a Ready.
# Self-contained y pool-agnostico: cuenta instancias EC2 arrancadas y nodos
# Ready cuyo nombre es de un worker AWS (aws-worker-* / aws-gpu-worker-*).
set -uo pipefail

WG_INTERFACE="${WG_INTERFACE:-aws-workers}"
WAIT_SECONDS="${WAIT_SECONDS:-1200}"   # el pool GPU tarda (driver DKMS + reboot + modelos)
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

running_workers() {
  aws --region "${AWS_REGION:-eu-south-2}" ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-side-cluster" "Name=tag:Role,Values=worker" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null
}

ready_workers() {
  kubectl --request-timeout=8s get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -E '^aws-(worker|gpu-worker)-' | grep -c ' True'
}

rw="$(running_workers)"; rw="${rw:-0}"
# Sin workers arrancados (p.ej. apply con el pool parado por el gateway): nada que esperar.
if [ "$rw" = "0" ]; then
  echo "wg-sync-and-wait: 0 workers running; nada que esperar (ok)"
  WG_INTERFACE="$WG_INTERFACE" scripts/wg-sync-ec2-endpoints.sh >/dev/null 2>&1 || true
  exit 0
fi

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  WG_INTERFACE="$WG_INTERFACE" scripts/wg-sync-ec2-endpoints.sh >/dev/null 2>&1 || true
  r="$(ready_workers)"; r="${r:-0}"
  echo "wg-sync-and-wait: workers Ready=${r}/${rw}"
  if [ "$r" -ge "$rw" ]; then
    echo "wg-sync-and-wait: todos los workers arrancados estan Ready, ok"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "wg-sync-and-wait: TIMEOUT esperando workers Ready (Ready=${r}/${rw})" >&2
    exit 1
  fi
  sleep 15
done
