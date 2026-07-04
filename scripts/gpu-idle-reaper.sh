#!/usr/bin/env bash
# gpu-idle-reaper — apaga las EC2 GPU cuando sus vLLM llevan IDLE_SECONDS sin
# peticiones (medido en Prometheus, no en HTTP del demand-gateway: el trafico
# LLM del llm-gateway in-cluster es invisible para aquel).
#
# Regla: instancia(s) del pool GPU running + fuera del GRACE post-arranque +
# sum(vllm:num_requests_running de los modelos del nodo GPU) == 0 sostenido
# IDLE_SECONDS -> stop-instances. "Sin datos" cuenta como idle (los pods aun
# no sirven = nadie los usa); el GRACE cubre boot + join + carga de modelos.
#
# Disenado como systemd user timer (cada 60s). Estado en
# ~/.local/state/gpu-idle-reaper/; cada apagado queda en events.log con
# timestamps (evidencia para la metrica idle_shutdown_seconds del experimento
# "Disposable Compute, Persistent Evidence").
set -euo pipefail

IDLE_SECONDS=${IDLE_SECONDS:-300}
GRACE_SECONDS=${GRACE_SECONDS:-600}
TAG_KEY=${TAG_KEY:-underpass.ai/node-pool}
TAG_VALUE=${TAG_VALUE:-aws-gpu}
MODELS_REGEX=${MODELS_REGEX:-phi4-mini-aws|smollm3-aws}
AWS_REGION=${AWS_REGION:-eu-south-2}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/gpu-idle-reaper
IDLE_FILE="$STATE_DIR/idle_since"
EVENTS_LOG="$STATE_DIR/events.log"

mkdir -p "$STATE_DIR"
now=$(date +%s)
log() { echo "$(date -Is) $*"; }
evidence() { echo "$(date -Is) $*" >> "$EVENTS_LOG"; }

# --- 1. instancias GPU running (descubiertas por tag; el ID cambia en replace)
mapfile -t running < <(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,LaunchTime]' --output text)

if [ ${#running[@]} -eq 0 ] || [ -z "${running[0]:-}" ]; then
  rm -f "$IDLE_FILE"
  log "no hay instancias GPU running; nada que hacer"
  exit 0
fi

ids=(); newest_launch=0
for line in "${running[@]}"; do
  ids+=("$(cut -f1 <<<"$line")")
  lt=$(date -d "$(cut -f2 <<<"$line")" +%s)
  [ "$lt" -gt "$newest_launch" ] && newest_launch=$lt
done

# --- 2. gracia post-arranque (boot + join + carga de modelos)
age=$(( now - newest_launch ))
if [ "$age" -lt "$GRACE_SECONDS" ]; then
  rm -f "$IDLE_FILE"
  log "en GRACE post-arranque (${age}s < ${GRACE_SECONDS}s); no evaluar idle"
  exit 0
fi

# --- 3. actividad segun Prometheus
PROM=$(kubectl -n monitoring get svc kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$PROM" ]; then
  log "AVISO: no pude resolver Prometheus; no actuo (fail-safe: no apagar a ciegas)"
  exit 0
fi
busy=$(curl -sG --max-time 10 "http://$PROM:9090/api/v1/query" \
  --data-urlencode "query=sum(vllm:num_requests_running{model_name=~\"$MODELS_REGEX\"})" \
  | jq -r '.data.result[0].value[1] // "0"')
busy=${busy%.*}; busy=${busy:-0}

if [ "$busy" -gt 0 ]; then
  rm -f "$IDLE_FILE"
  log "GPU en uso (num_requests_running=$busy); reset idle"
  exit 0
fi

# --- 4. contabilidad de idle
if [ ! -f "$IDLE_FILE" ]; then
  echo "$now" > "$IDLE_FILE"
  log "idle detectado; arranca el contador (0/${IDLE_SECONDS}s)"
  exit 0
fi
idle_since=$(cat "$IDLE_FILE")
idle_for=$(( now - idle_since ))
if [ "$idle_for" -lt "$IDLE_SECONDS" ]; then
  log "idle ${idle_for}/${IDLE_SECONDS}s; aun no"
  exit 0
fi

# --- 5. apagado + evidencia
log "idle ${idle_for}s >= ${IDLE_SECONDS}s -> stop ${ids[*]}"
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "${ids[@]}" >/dev/null
evidence "idle_shutdown instances=${ids[*]} idle_for=${idle_for}s launch_age=${age}s"
rm -f "$IDLE_FILE"
