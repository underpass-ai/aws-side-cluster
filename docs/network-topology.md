# Topología de red — aws-side-cluster

Cómo se conectan el control-plane local y los workers EC2, y cómo se reproduce
todo. Complementa `docs/network-planes.md` (separación de nombres) y
`docs/terraform-join.md` (orquestación del join).

## Resumen

Control-plane Kubernetes local (`wrx80-node1`, `192.168.1.56`) + workers EC2
efímeros, unidos por **WireGuard en estrella**: el PC (control-plane) es el
**hub** y cada worker es un radio. **No hay túnel directo worker↔worker**; el
tráfico entre workers se enruta por el PC.

```text
            aws-worker-1 (10.90.0.11)
                   \
   LAN 192.168.1.0/24 \        WireGuard (estrella)
   wrx80-node1 ─────── PC hub (10.90.0.1) ─────── aws-worker-2 (10.90.0.12)
   MetalLB .240-.250         (UDP/51820)
```

## Direccionamiento

| Red | CIDR | Notas |
|---|---|---|
| WireGuard | `10.90.0.0/24` | PC `.1`, worker-N `.(10+N)` (w1 `.11`, w2 `.12`) |
| VPC AWS | `10.80.0.0/16` | subnet pública `10.80.1.0/24` |
| LAN local | `192.168.1.0/24` | nodo `.56`, MetalLB pool `192.168.1.240-250` |
| Pod CIDR (Calico) | `10.244.0.0/16` | vxlan |
| Service CIDR | `10.96.0.0/12` | |

## WireGuard: endpoints e iniciación (dos caminos)

1. **PC→EC2 (validado, principal).** La IP pública del EC2 es dinámica; el PC
   fija el endpoint del peer: `wg set aws-workers peer <pub> endpoint
   <ip-publica-ec2>:51820 persistent-keepalive 25`. Lo hace
   `scripts/wg-sync-ec2-endpoints.sh`, invocado por Terraform en cada apply
   (`null_resource.wg_sync`) y por el demand-gateway en cada wake
   (`DEMAND_GATEWAY_SYNC_COMMAND`). Funciona **detrás de NAT/CGNAT** porque el PC
   inicia saliente. Requiere `sudoers` NOPASSWD para `wg` (`/etc/sudoers.d/aws-side-wg`).
2. **EC2→PC (secundario).** El EC2 resuelve `aws-vpc-wg.underpassai.com` en una
   zona Route53 **privada** (VPC-scoped, `terraform/dns.tf`) → `203.0.113.10:51820`
   (borde de casa). Requiere que el router reenvíe **UDP/51820 → 192.168.1.56**.
   Si no llega, el camino 1 establece el túnel igual (WireGuard roaming). El
   nombre vive en zona privada para **no tocar la zona pública** de la web.

## AllowedIPs

Lado **EC2** (peer = PC), de `local_cluster_allowed_cidrs` (horneado en cloud-init):

| CIDR | para qué |
|---|---|
| `10.90.0.0/24` | PC + otros workers (hairpin worker↔worker vía PC) |
| `192.168.1.56/32` | API server / Calico typha |
| `10.96.0.0/12` | Service CIDR |
| `10.244.0.0/16` | Pod CIDR |
| `192.168.1.240/28` | VIPs MetalLB de la LAN |

Lado **PC** (peer = worker-N): solo `10.90.0.(10+N)/32` (la IP WG del worker).

## El PC como hub: forward + NAT

`scripts/setup-pc-network.sh` (idempotente), persistido por
`systemd/aws-side-pc-net.service` (oneshot en boot, `After` wg-quick y ufw):

- `net.ipv4.ip_forward=1`
- FORWARD EC2→MetalLB: `-i aws-workers -o enp211s0 -s 10.90.0.0/24 -d 192.168.1.240/28 -j ACCEPT` (+ retorno `RELATED,ESTABLISHED`)
- FORWARD hairpin worker↔worker: `-i aws-workers -o aws-workers -s 10.90.0.0/24 -d 10.90.0.0/24 -j ACCEPT`
- NAT: `POSTROUTING -s 10.90.0.0/24 -d 192.168.1.240/28 -o enp211s0 -j MASQUERADE`

Aviso: `ufw reload` flushea la cadena FORWARD; re-ejecutar el service
(`sudo systemctl restart aws-side-pc-net`) tras un `ufw reload` manual.

## Flujos validados

- **EC2 pod → VIP MetalLB local** (p.ej. `.241` ingress): Calico `natOutgoing`
  hace SNAT del pod a la IP del nodo (`10.90.0.1X`) → wg → PC → kube-proxy DNAT
  al pod backend (local) → respuesta. Las VIPs van por kube-proxy; las reglas
  forward/NAT del PC cubren hosts LAN **reales** (no-VIP) del `/28`.
- **worker-1 ↔ worker-2 (pod↔pod / VIP con backend remoto)**: Calico vxlan
  encapsula a la IP del nodo remoto (`10.90.0.12`) → wg → PC (FORWARD hairpin) →
  worker-2. Sin `10.90.0.0/24` en AllowedIPs + el hairpin del PC, esto no
  funcionaba (malla en estrella).
- **gateway (PC) → VIP per-worker** (`.244`/`.245`): kube-proxy → pod fijado al
  worker por Calico. Es el camino del demand-gateway.

## Reproducibilidad (de qué se encarga cada cosa)

| Pieza | Dónde |
|---|---|
| VPC/SG/EC2/IAM/S3, wg del EC2, AllowedIPs, join, node-name, labels | `terraform/` (cloud-init) |
| Token bootstrap + wg-sync + espera Ready | `terraform/join.tf` (ver `docs/terraform-join.md`) |
| Zona Route53 privada del endpoint | `terraform/dns.tf` |
| wg del PC (claves, peers) | `scripts/generate-worker-secrets.sh` → `/etc/wireguard/aws-workers.conf` |
| forward/NAT del PC (persistente) | `scripts/setup-pc-network.sh` + `systemd/aws-side-pc-net.service` |
| sudoers NOPASSWD `wg` | `sudoers.d/aws-side-wg` → `/etc/sudoers.d/aws-side-wg` |
