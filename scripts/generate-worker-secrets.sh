#!/usr/bin/env bash
set -euo pipefail

count="${1:-2}"
wg_cidr="${WG_CIDR:-10.90.0.0/24}"
secrets_dir="${SECRETS_DIR:-.secrets}"
tfvars_path="${TFVARS_PATH:-terraform/wireguard.auto.tfvars}"

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
  echo "Usage: $0 [worker-count]" >&2
  exit 2
fi

if ! command -v wg >/dev/null 2>&1; then
  echo "wg is required. Install wireguard-tools first." >&2
  exit 1
fi

mkdir -p "$secrets_dir"
chmod 0700 "$secrets_dir"

if [[ ! -f "$secrets_dir/local.key" ]]; then
  umask 077
  wg genkey > "$secrets_dir/local.key"
  wg pubkey < "$secrets_dir/local.key" > "$secrets_dir/local.pub"
fi

for i in $(seq 1 "$count"); do
  idx="$(printf "%02d" "$i")"
  if [[ ! -f "$secrets_dir/worker-$idx.key" ]]; then
    umask 077
    wg genkey > "$secrets_dir/worker-$idx.key"
    wg pubkey < "$secrets_dir/worker-$idx.key" > "$secrets_dir/worker-$idx.pub"
  fi
done

{
  printf 'local_wireguard_public_key = "%s"\n' "$(cat "$secrets_dir/local.pub")"
  printf 'worker_wireguard_private_keys = [\n'
  for i in $(seq 1 "$count"); do
    idx="$(printf "%02d" "$i")"
    printf '  "%s",\n' "$(cat "$secrets_dir/worker-$idx.key")"
  done
  printf ']\n\n'
  printf 'worker_wireguard_public_keys = [\n'
  for i in $(seq 1 "$count"); do
    idx="$(printf "%02d" "$i")"
    printf '  "%s",\n' "$(cat "$secrets_dir/worker-$idx.pub")"
  done
  printf ']\n'
} > "$tfvars_path"
chmod 0600 "$tfvars_path"

local_addr="${LOCAL_WG_ADDRESS:-10.90.0.1/24}"
local_port="${LOCAL_WG_PORT:-51820}"
local_conf="$secrets_dir/aws-workers.conf"
{
  printf '[Interface]\n'
  printf 'PrivateKey = %s\n' "$(cat "$secrets_dir/local.key")"
  printf 'Address = %s\n' "$local_addr"
  printf 'ListenPort = %s\n\n' "$local_port"
  for i in $(seq 1 "$count"); do
    idx="$(printf "%02d" "$i")"
    peer_ip="10.90.0.$((10 + i))/32"
    printf '[Peer]\n'
    printf '# aws-side-poc-%s uses WireGuard roaming; workers can initiate when local_wireguard_endpoint is set\n' "$idx"
    printf 'PublicKey = %s\n' "$(cat "$secrets_dir/worker-$idx.pub")"
    printf 'AllowedIPs = %s\n\n' "$peer_ip"
  done
} > "$local_conf"
chmod 0600 "$local_conf"

echo "Wrote $tfvars_path"
echo "Wrote $local_conf"
echo "Install local WireGuard with: sudo install -m 600 $local_conf /etc/wireguard/aws-workers.conf"
echo "Then: sudo systemctl enable --now wg-quick@aws-workers"
