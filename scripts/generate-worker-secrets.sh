#!/usr/bin/env bash
# Genera claves WireGuard de los workers (pool t4g y, opcional, pool GPU) y
# escribe terraform/wireguard.auto.tfvars + el config WireGuard local del PC.
#
# Uso: scripts/generate-worker-secrets.sh [t4g-count] [gpu-count]
#   t4g workers -> aws-side:index 1..N  -> WG 10.90.0.(10+i)  -> worker-0i.key
#   gpu workers -> aws-side:index 21..  -> WG 10.90.0.(20+i)  -> worker-2i.key
# (los indices GPU empiezan en 21 para no chocar con t4g; casan con cidrhost+21
#  en main.tf y con el filtro por aws-side:index de wg-sync-ec2-endpoints.sh)
set -euo pipefail

count="${1:-2}"
gpu_count="${2:-0}"
secrets_dir="${SECRETS_DIR:-.secrets}"
tfvars_path="${TFVARS_PATH:-terraform/wireguard.auto.tfvars}"

[[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 )) || { echo "Usage: $0 [t4g-count] [gpu-count]" >&2; exit 2; }
[[ "$gpu_count" =~ ^[0-9]+$ ]] || { echo "gpu-count must be an integer" >&2; exit 2; }
command -v wg >/dev/null 2>&1 || { echo "wg required (install wireguard-tools)" >&2; exit 1; }

mkdir -p "$secrets_dir"; chmod 0700 "$secrets_dir"

genkey() {  # genkey <name>   (idempotente: no regenera si ya existe)
  local n="$1"
  if [[ ! -f "$secrets_dir/$n.key" ]]; then
    umask 077
    wg genkey > "$secrets_dir/$n.key"
    wg pubkey < "$secrets_dir/$n.key" > "$secrets_dir/$n.pub"
  fi
}

t4g_names=(); for i in $(seq 1 "$count"); do t4g_names+=("worker-$(printf '%02d' "$i")"); done
gpu_names=(); for i in $(seq 1 "$gpu_count"); do gpu_names+=("worker-$(printf '%02d' $((20 + i)))"); done

genkey local
for n in "${t4g_names[@]}" ${gpu_names[@]+"${gpu_names[@]}"}; do genkey "$n"; done

emit_list() {  # emit_list <hcl-var> <key|pub> <name...>
  local var="$1" suf="$2"; shift 2
  printf '%s = [\n' "$var"
  local n; for n in "$@"; do printf '  "%s",\n' "$(cat "$secrets_dir/$n.$suf")"; done
  printf ']\n'
}

{
  printf 'local_wireguard_public_key = "%s"\n\n' "$(cat "$secrets_dir/local.pub")"
  emit_list worker_wireguard_private_keys key "${t4g_names[@]}"; printf '\n'
  emit_list worker_wireguard_public_keys  pub "${t4g_names[@]}"
  if (( gpu_count > 0 )); then
    printf '\n'
    emit_list gpu_worker_wireguard_private_keys key "${gpu_names[@]}"; printf '\n'
    emit_list gpu_worker_wireguard_public_keys  pub "${gpu_names[@]}"
  fi
} > "$tfvars_path"
chmod 0600 "$tfvars_path"

local_addr="${LOCAL_WG_ADDRESS:-10.90.0.1/24}"
local_port="${LOCAL_WG_PORT:-51820}"
local_conf="$secrets_dir/aws-workers.conf"
emit_peer() {  # emit_peer <name> <wg-last-octet> <comment>
  printf '[Peer]\n# %s (WireGuard roaming; el PC fija el endpoint via wg-sync)\nPublicKey = %s\nAllowedIPs = 10.90.0.%s/32\n\n' \
    "$3" "$(cat "$secrets_dir/$1.pub")" "$2"
}
{
  printf '[Interface]\nPrivateKey = %s\nAddress = %s\nListenPort = %s\n\n' \
    "$(cat "$secrets_dir/local.key")" "$local_addr" "$local_port"
  for i in $(seq 1 "$count");     do emit_peer "worker-$(printf '%02d' "$i")"          "$((10 + i))" "t4g worker $i"; done
  for i in $(seq 1 "$gpu_count"); do emit_peer "worker-$(printf '%02d' $((20 + i)))"   "$((20 + i))" "gpu worker $i"; done
} > "$local_conf"
chmod 0600 "$local_conf"

echo "Wrote $tfvars_path ($count t4g + $gpu_count gpu)"
echo "Wrote $local_conf"
echo "Aplicar el config del PC:"
echo "  sudo install -m 600 $local_conf /etc/wireguard/aws-workers.conf"
echo "  sudo systemctl reload wg-quick@aws-workers   # o restart si reload no recarga peers"
