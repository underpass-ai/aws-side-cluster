#!/usr/bin/env bash
# Invocado por terraform (null_resource.wg_sync) tras crear/cambiar instancias.
# Fija los endpoints WireGuard PC->EC2 en bucle (sudo wg, NOPASSWD) y espera a
# que EXPECT_READY nodos del pool lleguen a Ready. Hace el join autocontenido.
set -uo pipefail

WG_INTERFACE="${WG_INTERFACE:-aws-workers}"
NODE_SELECTOR="${NODE_SELECTOR:-underpass.ai/node-pool=aws-poc}"
EXPECT_READY="${EXPECT_READY:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-600}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

running_workers() {
  aws --region "${AWS_REGION:-eu-south-2}" ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-side-cluster" "Name=tag:Role,Values=worker" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null
}

# Si no hay workers arrancados (p.ej. apply con el pool parado por el gateway),
# no hay join que esperar: sincroniza lo que haya y sal en exito.
rw="$(running_workers)"; rw="${rw:-0}"
if [ "$rw" = "0" ]; then
  echo "wg-sync-and-wait: 0 workers running; nada que esperar (ok)"
  WG_INTERFACE="$WG_INTERFACE" scripts/wg-sync-ec2-endpoints.sh >/dev/null 2>&1 || true
  exit 0
fi

ready_count() {
  kubectl --request-timeout=8s get nodes -l "$NODE_SELECTOR" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c True
}

deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  WG_INTERFACE="$WG_INTERFACE" scripts/wg-sync-ec2-endpoints.sh >/dev/null 2>&1 || true
  r="$(ready_count)"; r="${r:-0}"
  echo "wg-sync-and-wait: ready=${r}/${EXPECT_READY}"
  if [ "$EXPECT_READY" -gt 0 ] && [ "$r" -ge "$EXPECT_READY" ]; then
    echo "wg-sync-and-wait: nodos Ready, ok"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    if [ "$EXPECT_READY" -gt 0 ]; then
      echo "wg-sync-and-wait: TIMEOUT esperando ${EXPECT_READY} nodos Ready (ready=${r})" >&2
      exit 1
    fi
    exit 0
  fi
  sleep 15
done
