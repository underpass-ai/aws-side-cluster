#!/usr/bin/env bash
# Reglas de red del PC (control-plane) para el cluster AWS-side:
#  - EC2(WireGuard) -> LAN/MetalLB (forward + MASQUERADE)
#  - hairpin worker<->worker (forward wg<->wg, malla en estrella via el PC)
# Idempotente. Pensado para boot via systemd (aws-side-pc-net.service) o a mano.
# Requiere root.
set -euo pipefail

WG_IF="${WG_IF:-aws-workers}"
WG_SUBNET="${WG_SUBNET:-10.90.0.0/24}"
LAN_IF="${LAN_IF:-enp211s0}"
METALLB_CIDR="${METALLB_CIDR:-192.168.1.240/28}"

if [[ $EUID -ne 0 ]]; then echo "necesita root" >&2; exit 1; fi

ins() {  # inserta en FORWARD (top) si no existe ya
  iptables -C FORWARD "$@" 2>/dev/null || iptables -I FORWARD 1 "$@"
}

sysctl -q -w net.ipv4.ip_forward=1

# EC2 -> MetalLB (LAN) y retorno establecido
ins -i "$WG_IF" -o "$LAN_IF" -s "$WG_SUBNET" -d "$METALLB_CIDR" -j ACCEPT
ins -i "$LAN_IF" -o "$WG_IF" -d "$WG_SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# worker <-> worker (hairpin via PC)
ins -i "$WG_IF" -o "$WG_IF" -s "$WG_SUBNET" -d "$WG_SUBNET" -j ACCEPT
# SNAT EC2 -> MetalLB para retorno simple
iptables -t nat -C POSTROUTING -s "$WG_SUBNET" -d "$METALLB_CIDR" -o "$LAN_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$WG_SUBNET" -d "$METALLB_CIDR" -o "$LAN_IF" -j MASQUERADE

echo "aws-side PC net OK (WG_IF=$WG_IF WG_SUBNET=$WG_SUBNET LAN_IF=$LAN_IF METALLB_CIDR=$METALLB_CIDR)"
