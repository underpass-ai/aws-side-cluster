# Join orquestado en Terraform

Antes el join era manual: `kubeadm token create` a mano + pegar en
`terraform.tfvars` (caduca a 24h), y un `wg-sync` manual tras `apply`. Ahora
**`tofu apply` deja los nodos Ready por sí solo** — ambos pools:
`aws-worker-N` (genérico, t3.micro/containerd) y `aws-gpu-worker-N` (GPU,
g6.xlarge/cri-o). Definido en `terraform/join.tf`.

## Piezas

- **Token bootstrap dinámico**: provider `kubernetes` (usa `~/.kube/config`,
  `var.kubeconfig_path`) + `random_string` (id `[a-z0-9]{6}`, secret
  `[a-z0-9]{16}`) → `kubernetes_secret` tipo `bootstrap.kubernetes.io/token` en
  `kube-system`. El `random_string` es estable en el state (no rota en cada
  apply). Sin `expiration` → no caduca (rotar si se endurece).
- **Comando de join**: `local.effective_join_command`. Usa
  `var.kubeadm_join_command` si se define (override manual); si está vacío, el
  generado por TF: `kubeadm join <endpoint> --token <id>.<secret>
  --discovery-token-ca-cert-hash sha256:<hash>`. Se pasa al cloud-init.
- **Hash del CA** (`var.discovery_ca_cert_hash`, en tfvars): estable por
  cluster, no secreto. Recalcular con:
  ```bash
  kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256
  ```
- **Nombre de nodo estable**: cloud-init añade `--node-name=aws-worker-${index}`
  al `kubeadm join`. El node object se reusa entre reemplazos → **sin nodos
  stale ni conflicto de IP en Calico** (la WG IP `10.90.0.1X` es estable por
  índice). Antes el nombre salía de la IP privada del EC2 (cambiaba al
  reemplazar → se acumulaban nodos stale; ver `docs/calico-recovery.md`).
- **wg-sync + espera** (`null_resource.wg_sync` → `scripts/wg-sync-and-wait.sh`):
  tras crear/cambiar instancias, fija los endpoints PC→EC2 (`sudo wg`, NOPASSWD)
  en bucle y espera Ready. El script es **pool-agnóstico**: cuenta las EC2
  arrancadas de ambos pools y espera nodos `aws-worker-*` Y `aws-gpu-worker-*`
  (`WAIT_SECONDS` default 1200 — el bootstrap GPU incluye driver DKMS + reboot).
  Tolerante si el pool está parado (sale en éxito).
- **`ignore_changes = [associate_public_ip_address]`**: la subnet ya hace
  `map_public_ip_on_launch=true`; el atributo a nivel de instancia se lee como
  `false` en el state → sin esto, cada plan querría reemplazar las instancias.

## Uso

```bash
tofu -chdir=terraform init    # primera vez: descarga el provider kubernetes
tofu -chdir=terraform apply   # token + EC2 + sync wg + espera Ready
```

Reemplazo (cambió user_data, secretos WireGuard, AllowedIPs):

```bash
tofu -chdir=terraform apply \
  -replace='aws_instance.worker[0]' -replace='aws_instance.worker[1]'
# pool GPU:
tofu -chdir=terraform apply -replace='aws_instance.gpu_worker[0]'
```

Validado: el apply crea el `Secret`, arranca los EC2, sincroniza WireGuard, y
espera Ready antes de `Apply complete!`. Cero pasos manuales.

## Pool GPU (`aws_instance.gpu_worker`)

Mismo mecanismo de join con particularidades propias (todas en el cloud-init
del pool GPU): `gpu_instance_count` lo crea/destruye; node-name
`aws-gpu-worker-N`, WG `.2N`, label `underpass.ai/node-pool=aws-gpu`; bootstrap
con bundle estático cri-o 1.35.2 + `iptables-nft` + driver NVIDIA
(`kernel6.12-devel`, DKMS, reboot) + join con `--cri-socket`; descarga los
`.tar` de modelos de S3 a `/opt/llm-models`; y shippea su log de bootstrap a
`s3://aws-side-poc-bootstrap-*/logs/<hostname>-bootstrap.log` cada 15s
(diagnóstico sin SSM/SSH, incluso con la instancia parada). Tras recrear desde
cero, si el stack del GPU Operator no converge: borrar los pods
`nvidia-operator-validator`/`device-plugin`/`gfd`/`nfd-worker` del nodo (los
regenera el DaemonSet).

## Nota operativa importante

Un `apply` que cambia `user_data` con instancias **running** las **rearranca**
(el provider AWS las para → modifica el atributo → arranca). Hacer `apply` con
el pool parado, o contar con el restart. El ciclo start/stop **bajo demanda** lo
gestiona el demand-gateway / `scripts/ec2-pool.sh`, **fuera de Terraform** (TF
solo crea/destruye instancias).

## Prerrequisitos

- `~/.kube/config` con acceso admin (provider kubernetes crea el Secret).
- `sudoers.d/aws-side-wg` instalado (NOPASSWD `wg`) — el wg-sync hace `sudo wg set`.
- WireGuard local arriba: `sudo systemctl enable --now wg-quick@aws-workers`.
- `var.discovery_ca_cert_hash` en tfvars (el del cluster actual).
