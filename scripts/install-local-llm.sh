#!/usr/bin/env bash
# Instalador del chart local-llm en el namespace del POC (underpass-labs).
# Orquesta: secret HF (copiado de underpass-runtime si falta) + helm upgrade.
#
# Uso:
#   scripts/install-local-llm.sh small      # 2 pequeños (Phi-4-mini, SmolLM3) -> release llm-small
#   scripts/install-local-llm.sh big        # 4 grandes (Qwen/GLM/Devstral/Gemma) -> release local-llm
#   scripts/install-local-llm.sh all         # ambos (ojo: 6 modelos > 4 GPUs)
#   scripts/install-local-llm.sh uninstall   # quita ambos releases
set -euo pipefail
cd "$(dirname "$0")/.."
NS="${NS:-underpass-labs}"
CHART="charts/local-llm"
ACTION="${1:-small}"

ensure_hf_secret() {
  if kubectl -n "$NS" get secret huggingface-token >/dev/null 2>&1; then return; fi
  echo "[hf] copiando secret huggingface-token de underpass-runtime -> $NS"
  kubectl -n underpass-runtime get secret huggingface-token -o json \
    | python3 -c 'import sys,json;s=json.load(sys.stdin);m=s["metadata"];[m.pop(k,None) for k in ("namespace","uid","resourceVersion","creationTimestamp","ownerReferences","managedFields","generation","annotations")];s.pop("status",None);print(json.dumps(s))' \
    | kubectl -n "$NS" apply -f -
}

install_big() {
  ensure_hf_secret
  echo "[helm] local-llm (4 grandes) -> ns $NS"
  helm upgrade --install local-llm "$CHART" -n "$NS"
}

install_small() {
  ensure_hf_secret
  echo "[helm] llm-small (2 pequeños) -> ns $NS"
  helm upgrade --install llm-small "$CHART" -n "$NS" \
    -f "$CHART/values.yaml" -f "$CHART/values-small.yaml"
}

case "$ACTION" in
  big)   install_big ;;
  small) install_small ;;
  all)   install_big; install_small ;;
  uninstall)
    helm uninstall local-llm -n "$NS" 2>/dev/null || true
    helm uninstall llm-small -n "$NS" 2>/dev/null || true
    ;;
  *) echo "uso: $0 {small|big|all|uninstall}" >&2; exit 2 ;;
esac

echo
kubectl -n "$NS" get pods -l app.kubernetes.io/part-of=local-llm -o wide 2>/dev/null || true
