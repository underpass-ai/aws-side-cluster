# Join orquestado en Terraform

Antes el join era manual: `kubeadm token create` a mano + pegar en
`terraform.tfvars` (caduca a 24h), y un `wg-sync` manual tras `apply`. Ahora
**`tofu apply` deja los nodos `aws-worker-N` Ready por sí solo**, sin pasos
manuales. Definido en `terraform/join.tf`.

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
  en bucle y espera a que `EXPECT_READY` (= `instance_count`) nodos del pool
  lleguen a Ready. Tolerante si el pool está parado (sale en éxito).
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
```

Validado: el apply crea el `Secret`, arranca los EC2, sincroniza WireGuard, y
espera `ready=2/2` antes de `Apply complete!`. Cero pasos manuales.

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
