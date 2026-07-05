# AWS side cluster POC

POC para extender un cluster Kubernetes local con workers en AWS EC2. El control-plane queda en la workstation local (con 4 GPUs sirviendo LLMs) y los nodos EC2 se conectan por WireGuard. Tres fases validadas end-to-end: red y lifecycle de workers (fase 1), worker GPU con vLLM en la nube (fase 2), y ceremonias multimodelo hibridas local+AWS con observabilidad completa (fase 3).

## Articulo principal

Canonical write-up:
[I let my GPU workers shut themselves down after five minutes. Their decisions still had to be auditable.](https://underpassai.com/articles/disposable-compute-persistent-evidence/)

Este repo contiene la parte reproducible del experimento: Terraform, charts de
Helm, scripts operativos, dashboard de Grafana, runner A/B/C, artefactos de
decision y la TUI usada para reconstruir una decision despues de apagar el
worker GPU.

## Estado Validado

Hitos: 2026-06-25 fase 1 (red/workers/gateway) · 2026-06-26 wake rootless, join en Terraform, reachability MetalLB, DNS privado (`scripts/cluster-test.sh`) · 2026-06-28 4 vLLM en las GPUs locales · 2026-07-02 worker GPU x86/L4 validado (el T4G/arm64 resulto inviable: torch cu130 requiere sm_80+) · 2026-07-03 ceremonias multimodelo hibridas + time-slicing (2 modelos en la L4) + observabilidad (Prometheus/Tempo/Loki) + auto-stop por idle verificado.

- Control-plane local: `wrx80-node1`, `192.168.1.56`, cri-o, 4x RTX 3090 (4 vLLM: qwen3-coder, devstral, gemma4, ernie45-thinking).
- Workers AWS genericos: `aws-worker-1` (WG `10.90.0.11`) y `aws-worker-2` (WG `10.90.0.12`), `t3.micro`, containerd. Nombre de nodo estable; el ID de instancia cambia en cada replace.
- Worker GPU AWS: `aws-gpu-worker-1` (WG `10.90.0.21`), `g6.xlarge` (NVIDIA L4 24GB), cri-o 1.35.2, 2 vLLM via time-slicing (phi4-mini + smollm3).
- WireGuard local: `aws-workers`, local `10.90.0.1`. Tras cada stop/start de EC2: `scripts/wg-sync-ec2-endpoints.sh` (la IP publica cambia).
- VPC: `vpc-0ece93c68a3d23f84`, CIDR `10.80.0.0/16`; subnet publica `subnet-06e142a3f3d96f502` (`10.80.1.0/24`); SG `sg-095550d47f14a04f2`.
- S3: `aws-side-poc-bootstrap-5d7cbe73` — ZIP de bootstrap, pesos de modelos (`models/*.tar`, GLACIER_IR) y logs de bootstrap de cada nodo (`logs/<hostname>-bootstrap.log`, diagnostico sin SSM/SSH).
- IAM del rol EC2: `aws-side-poc-bootstrap-s3` (bootstrap + models) mas drift consciente documentado: `AmazonSSMManagedInstanceCore` (ops, attacheada por CLI) e inline `s3-node-logs` (shipper de logs). Ver "IAM" en `docs/article-base.md`.
- Servicio de prueba AWS: `underpass-labs/aws-echo`, MetalLB `192.168.1.242`.
- Gateway de demanda POC: `underpass-labs/aws-demand-gateway`, MetalLB `192.168.1.243`. Auto-stop por idle (300s) verificado — SOLO cubre los t3.micro; el nodo GPU se arranca/para a mano.
- LLM serving: `llm-gateway` (proxy OpenAI-compatible label-driven) + choreographer (ceremonias multimodelo; actas reales en `choreographer/runs/`).

## Arquitectura

```text
             LAN local
    +----------------------------------+
    | wrx80-node1 (cri-o)              |
    | Kubernetes control-plane         |
    | API 192.168.1.56:6443            |
    | WG  10.90.0.1                    |
    | 4x RTX 3090 -> 4 vLLM            |
    | choreographer + llm-gateway      |
    | MetalLB / ingress local          |
    | Prometheus + Tempo + Loki        |
    +---------------+------------------+
                    |
                    | WireGuard sobre Internet (estrella)
                    |
        +-----------+------------------------------+
        | AWS VPC 10.80.0.0/16, eu-south-2         |
        | subnet publica 10.80.1.0/24              |
        |                                          |
        | aws-worker-1     t3.micro    10.90.0.11  |
        | aws-worker-2     t3.micro    10.90.0.12  |
        | aws-gpu-worker-1 g6.xlarge   10.90.0.21  |
        |   NVIDIA L4 24GB (time-sliced x2)        |
        |   vllm-phi4-aws + vllm-smollm3-aws       |
        +------------------------------------------+
```

El plano de control no se mueve a AWS. AWS aporta capacidad elastica: workers genericos `t3.micro` (originalmente `t4g.micro` arm64; homogeneizados a x86 con la migracion GPU) y un worker GPU `g6.xlarge` que entra y sale del pool de modelos automaticamente (health-check del llm-gateway) al arrancarlo/pararlo.

## Componentes

- `terraform/`: VPC minima, EC2, IAM, S3 y cloud-init.
- `terraform/bootstrap_s3.tf`: bucket privado, payload aleatorio y ZIP.
- `terraform/cloud-init/bootstrap.sh.tftpl`: bootstrap EC2, WireGuard, S3, containerd, kubeadm/kubelet.
- `charts/underpass-labs/`: despliegue Kubernetes gestionado por Helm.
- `charts/underpass-labs/values.yaml`: servicios, rutas por nodo, IPs MetalLB e `idleSeconds`.
- `scripts/ec2-pool.sh`: `status`, `start`, `stop`, `scale` por tags.
- `scripts/demand-gateway.py`: primer gateway HTTP de wake/proxy para scale-on-demand.
- `scripts/generate-worker-secrets.sh`: claves WireGuard y tfvars secretos.
- `scripts/wg-sync-ec2-endpoints.sh`: fija el endpoint WireGuard PC->EC2 (IP publica dinamica). Lo invoca Terraform en cada apply y el gateway en cada wake.
- `scripts/wg-sync-and-wait.sh`: sincroniza y espera a que los nodos lleguen a Ready (usado por `null_resource.wg_sync`).
- `scripts/setup-pc-network.sh` + `systemd/aws-side-pc-net.service`: reglas forward/NAT del PC (WireGuard <-> LAN/MetalLB + hairpin worker<->worker), persistentes en boot.
- `scripts/create-kubeadm-join-command.sh`: helper opcional de token (el flujo normal lo genera Terraform).
- `scripts/cluster-test.sh`: smoke test integral (cold-start + cadena completa).
- `terraform/join.tf`: token bootstrap + join + wg-sync orquestados. Ver `docs/terraform-join.md`.
- `terraform/dns.tf`: zona Route53 privada para el endpoint WireGuard EC2->PC.
- `charts/local-llm/`: N modelos vLLM OpenAI-compatible, 1 GPU (o slot time-sliced) por modelo, labels `underpass.ai/llm-role`, ServiceMonitor Prometheus. `values.yaml` = 4 grandes locales; `values-aws-gpu.yaml` = 2 pequenos en la L4 (release separado `aws-gpu-llm`).
- `charts/llm-gateway/`: reverse proxy OpenAI-compatible que descubre los vLLM por label y enruta por nombre exacto o alias `role:<rol>` (round-robin + health-check). Los nodos parados salen solos del pool.
- `choreographer/`: values de despliegue del motor de ceremonias publico, ceremonias (`ceremonies/`) y actas de corridas reales (`runs/`). Ver `choreographer/README.md`.
- `scripts/install-local-llm.sh`: instalador de los releases de modelos (`big`/`small`/`all`/`uninstall`).

Documentacion:

- `docs/network-topology.md`: topologia de red completa (estrella, AllowedIPs, NAT, DNS).
- `docs/network-planes.md`: separacion del plano web y el plano de transporte WireGuard.
- `docs/terraform-join.md`: join orquestado en Terraform (ambos pools).
- `docs/calico-recovery.md`: rollback/preflight de Calico + modos de fallo de typha.
- `docs/demand-gateway.md`: uso y limitaciones del gateway de demanda.
- `docs/per-node-demand-test.md`: prueba de routing por tag/nodo.
- `docs/link-debug-logs.md`: forense historico del debug del enlace WG (resuelto).
- `docs/article-base.md`: base de la serie de articulos (3 piezas, con los hitos fechados).

## Decisiones De Diseno

- Red barata: WireGuard, sin VPN Gateway ni VPC peering.
- Sin SSH por defecto: `allowed_ssh_cidrs = []`.
- IAM minimo como objetivo, con drift consciente: la base es lectura/restore del bootstrap y `models/*`; se sumaron SSM (ops) y escritura `logs/*` (shipper), acotados y documentados como deuda.
- Public IPv4 dinamica: no usamos Elastic IP para evitar coste idle. A cambio, `wg-sync-ec2-endpoints.sh` obligatorio tras cada stop/start.
- `t4g.micro` fue el minimo practico arm64 de fase 1; el pool actual es `t3.micro` x86 (homogeneizado al migrar la GPU: la unica GPU arm64 en la region, T4G/sm_75, es inviable con torch cu130).
- GPU cloud `g6.xlarge` (L4) con imagen oficial vLLM multi-arch, cri-o homogeneo con el nodo local (el GPU Operator solo soporta UN modo de toolkit cluster-wide; runtimes mixtos causaron el incidente typha).
- Bootstrap idempotente: el ZIP S3 se descarga una sola vez y deja marker en el home del usuario.

## Prerrequisitos Locales

- OpenTofu o Terraform instalado. En este repo se esta usando OpenTofu.
- AWS CLI configurado con region `eu-south-2`.
- `kubectl` con acceso admin al cluster local.
- WireGuard instalado en la maquina local.
- Calico ya ajustado a `NodeInternalIP`.

Comprobacion rapida:

```bash
tofu -chdir=terraform version
aws sts get-caller-identity
kubectl get nodes -o wide
```

## Preparar Calico

Calico debe detectar la IP publicada por Kubernetes, no una interfaz local fija como `enp211s0`.

```bash
scripts/calico-status.sh
scripts/calico-backup.sh
scripts/calico-use-nodeinternalip.sh
```

Rollback:

```bash
scripts/calico-rollback-enp211s0.sh
```

Detalle en `docs/calico-recovery.md`.

## Preparar WireGuard

Generar claves:

```bash
scripts/generate-worker-secrets.sh 2 1   # 2 workers genericos + 1 GPU (peer .21)
```

Esto crea:

- `terraform/wireguard.auto.tfvars`
- `.secrets/aws-workers.conf`

Instalar la config local:

```bash
sudo install -d -m 700 /etc/wireguard
sudo install -m 600 .secrets/aws-workers.conf /etc/wireguard/aws-workers.conf
sudo systemctl enable --now wg-quick@aws-workers
```

La interfaz local debe escuchar en UDP/51820 para que las EC2 puedan iniciar el tunel:

```ini
Address = 10.90.0.1/24
ListenPort = 51820
```

Los workers deben poder devolver trafico a:

- `10.90.0.1/32`: IP WireGuard local usada por el control-plane para hablar con kubelet.
- `192.168.1.56/32`: API server por IP LAN.
- `10.96.0.0/12`: Service CIDR.
- `10.244.0.0/16`: Pod CIDR Calico.

En `terraform.tfvars`:

```hcl
local_cluster_allowed_cidrs = [
  "10.90.0.1/32",
  "192.168.1.56/32",
  "10.96.0.0/12",
  "10.244.0.0/16"
]
```

Si UFW esta activo en el control-plane, abrir solo lo necesario desde el tunel:

```bash
sudo ufw allow in on aws-workers proto tcp from 10.90.0.0/24 to 192.168.1.56 port 6443 comment 'aws-side-cluster kubeadm join'
sudo ufw allow in on aws-workers proto tcp from 10.90.0.0/24 to 192.168.1.56 port 5473 comment 'aws-side-cluster calico typha'
```

## Preparar Variables

```bash
cp examples/terraform.tfvars.example terraform/terraform.tfvars
```

Crear un join command apuntando a la IP real del API server:

```bash
KUBEADM_JOIN_ENDPOINT=192.168.1.56:6443 scripts/create-kubeadm-join-command.sh
```

Pegar el resultado en `terraform/terraform.tfvars` como `kubeadm_join_command`. No lo publiques; contiene token temporal.

Nota: el cluster anuncia `k8s.local` internamente en `kubeadm-config`. El cloud-init anade `192.168.1.56 k8s.local` a `/etc/hosts` de cada EC2 para que `kubeadm join` pueda completar el preflight.

## Crear Infraestructura

Inicializar y aplicar con OpenTofu:

```bash
tofu -chdir=terraform init
tofu -chdir=terraform apply
```

Terraform/OpenTofu crea:

- VPC publica minima.
- Subnet publica.
- Internet Gateway y ruta por defecto.
- Security group con salida abierta, WireGuard UDP 51820 y SSH solo si se configura.
- IAM role/profile con permisos S3 minimos.
- S3 privado con ZIP random en `bootstrap/random-payload.zip`.
- Dos EC2 `t3.micro` con Amazon Linux 2023 (pool generico) y, con `gpu_instance_count=1`, una `g6.xlarge` (pool GPU: driver NVIDIA, cri-o, descarga de modelos de S3).

## Operacion Del Pool

Estado:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh status
```

Parar workers:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh scale 0
```

Arrancar 2 workers:

```bash
AWS_REGION=eu-south-2 scripts/ec2-pool.sh scale 2
kubectl get nodes -o wide
```

En este modo, las EC2 inician WireGuard hacia `local_wireguard_endpoint`; el activador local solo arranca instancias y observa Kubernetes.

## Reemplazo De Workers

Si cambia `user_data`, secretos WireGuard o el join command, fuerza reemplazo:

```bash
tofu -chdir=terraform apply \
  -replace='aws_instance.worker[0]' \
  -replace='aws_instance.worker[1]'
```

Tras reemplazar:

```bash
kubectl get nodes -o wide
```

Si quedan nodos antiguos `NotReady` con las mismas IPs WireGuard, borrarlos del API:

```bash
kubectl delete node <old-node-name>
```

Esto evita conflictos de IP en Calico.

## Validacion

Cluster:

```bash
kubectl get nodes -o wide
kubectl -n calico-system get pods -o wide
```

Smoke test en workers AWS:

```bash
kubectl run aws-worker-smoke \
  --image=registry.k8s.io/pause:3.10 \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"underpass.ai/node-pool":"aws-poc"}}}'

kubectl wait --for=condition=Ready pod/aws-worker-smoke --timeout=120s
kubectl get pod aws-worker-smoke -o wide
kubectl delete pod aws-worker-smoke
```

Resultado esperado:

- Todos los nodos arrancados `Ready` (4 con todo encendido: wrx80-node1, aws-worker-1/2, aws-gpu-worker-1).
- `calico-node` `1/1` en cada nodo Ready.
- El smoke pod corre en un nodo `aws-worker-N` (node-names estables desde 2026-06-26).

## Servicio De Prueba

El chart `charts/underpass-labs` despliega los servicios HTTP de prueba en el namespace `underpass-labs`.

Caracteristicas:

- `Deployment/aws-echo` con 2 replicas.
- `nodeSelector underpass.ai/node-pool=aws-poc`, para forzar scheduling en EC2.
- `Service/aws-echo` tipo `LoadBalancer`.
- IP MetalLB fija: `192.168.1.242`.
- `Deployment/aws-echo-worker-1` y `Deployment/aws-echo-worker-2`, uno por nodo.
- `Service/aws-echo-worker-1` en `192.168.1.244`.
- `Service/aws-echo-worker-2` en `192.168.1.245`.
- Imagen: `registry.k8s.io/e2e-test-images/agnhost:2.53`.

Aplicar o actualizar:

```bash
helm upgrade --install underpass-labs charts/underpass-labs \
  -n underpass-labs \
  --take-ownership \
  --wait \
  --timeout 2m

kubectl -n underpass-labs rollout status deployment/aws-echo
kubectl -n underpass-labs rollout status deployment/aws-echo-worker-1
kubectl -n underpass-labs rollout status deployment/aws-echo-worker-2
kubectl -n underpass-labs get pods,svc -o wide
```

Probar desde la LAN local:

```bash
curl http://192.168.1.242/hostname
```

Resultado validado: el endpoint responde con el nombre de un pod `aws-echo` ejecutandose en uno de los workers AWS.

## Gateway De Demanda POC

La primera pieza de scale-on-demand es un proceso local en el control-plane. Recibe HTTP, comprueba si hay workers AWS y endpoints listos, y si falta capacidad ejecuta:

1. `scripts/ec2-pool.sh scale 2`
2. polling de nodes/endpoints hasta que el servicio real este listo
3. proxy hacia `aws-echo`

En esta POC el gateway no es aun un operador Kubernetes. Es una pieza explicita y facil de observar para validar el flujo antes de convertirlo en controller/systemd/operator. El activador se limita a AWS CLI y Kubernetes; WireGuard lo inicia la EC2 al arrancar.

La parte Kubernetes del gateway se gestiona por Helm:

```bash
helm upgrade --install underpass-labs charts/underpass-labs -n underpass-labs --take-ownership
```

Ejecutar gateway local:

```bash
AWS_REGION=eu-south-2 scripts/demand-gateway.py \
  --profiles-configmap underpass-labs/aws-demand-gateway-profiles
```

Probar estado y proxy:

```bash
curl http://192.168.1.243/status
curl http://192.168.1.243/hostname
```

Validado: `192.168.1.243/hostname` proxya correctamente al servicio `aws-echo` en `192.168.1.242` y devuelve el nombre de un pod ejecutandose en los workers AWS.

### Routing Por Nodo

La prueba por nodo usa una identidad comun entre AWS y Kubernetes:

- `worker-1`: ruta `/worker-1`, tag AWS `aws-side:index=1`, label Kubernetes `underpass.ai/worker-index=1`, servicio `192.168.1.244`.
- `worker-2`: ruta `/worker-2`, tag AWS `aws-side:index=2`, label Kubernetes `underpass.ai/worker-index=2`, servicio `192.168.1.245`.
- Cada perfil tiene `idleSeconds: 300` en `charts/underpass-labs/values.yaml`; pasado ese tiempo desde la ultima invocacion, el gateway para solo la EC2 asociada al perfil.

Actualizar configuracion:

```bash
helm upgrade underpass-labs charts/underpass-labs -n underpass-labs --take-ownership
```

Probar via gateway:

```bash
curl http://192.168.1.243/worker-1/hostname
curl http://192.168.1.243/worker-2/hostname
```

Probar via ingress interno:

```bash
curl -k https://aws-demand.underpassai.com/worker-1/status
curl -k https://aws-demand.underpassai.com/worker-1/hostname
```

`aws-demand.underpassai.com` resuelve a `192.168.1.241`, el LoadBalancer local de `ingress-nginx` anunciado por MetalLB. El certificado de esta POC se emite con un issuer propio en `underpass-labs`; mTLS queda preparado en Helm y desactivado por defecto para no bloquear la prueba simple.

Validado: cada ruta responde desde el pod fijado al worker correspondiente. La prueba de autolevantado desde frio se ejecuta con `scripts/ec2-pool.sh stop-tag aws-side:index <n>` y despues invocando `/worker-<n>/wake` o `/worker-<n>/hostname`.

Para arranque desde frio completo, configurar en Terraform:

```hcl
local_wireguard_endpoint = "aws-vpc-wg.underpassai.com:51820"
```

Ese nombre es solo para red WireGuard/VPC. No debe apuntar a la web publica salvo que esa maquina reenvie `UDP/51820` hacia la workstation o actue como relay WireGuard.

Las EC2 existentes no reejecutan `user_data` al cambiar ese valor. Si el endpoint se anade despues de crear workers, hay que reemplazarlos para validar arranque frio real.

## Operacion Del Worker GPU

El nodo GPU no esta gestionado por el demand-gateway (sin auto-stop por idle): se arranca y para a mano. La capacity de g6 en eu-south-2a es escasa — reintentar el start cada ~90s.

```bash
# levantar
aws ec2 start-instances --instance-ids <g6>          # reintentar si falla por capacity
scripts/wg-sync-ec2-endpoints.sh                      # IP publica nueva en cada start
kubectl -n underpass-labs get pods -l app.kubernetes.io/part-of=local-llm -w
# los 2 vLLM de la L4 (phi4, smollm3) llegan a 1/1 solos; el llm-gateway los re-incluye por health-check

# parar (compute a 0; queda el EBS de 100GB)
aws ec2 stop-instances --instance-ids <g6>
```

La L4 (24GB) sirve 2 modelos via time-slicing del GPU Operator: perfil `l4-slice-2` en el ConfigMap `time-slicing-config` (ns `nvidia`) + label `nvidia.com/device-plugin.config=l4-slice-2` en el nodo. Ojo: con time-slicing activo GFD renombra el producto a `NVIDIA-L4-SHARED` (el nodeSelector del chart ya lo refleja). Logs de bootstrap de cualquier nodo, sin SSM/SSH y con la instancia parada:

```bash
aws s3 cp s3://aws-side-poc-bootstrap-5d7cbe73/logs/<hostname>-bootstrap.log -
```

## Observabilidad

Cableada al stack existente del cluster (ns `monitoring`):

- **Prometheus**: ServiceMonitor `vllm-local-llm` (chart `local-llm`, activado solo en el release local — cubre los 6 vLLM del ns) → series `vllm:*` (KV cache, tokens/s, TTFT).
- **Tempo**: el choreographer exporta trazas OTLP (`CHOREO_OTLP_ENDPOINT` en `choreographer/values.underpass-labs-public.yaml`) — cada ceremonia es una traza distribuida (`rpc.run_ceremony` → `deliberate`, con span events de cada critica/revision).
- **Loki**: promtail en los 4 nodos; la linea temporal de una ceremonia y el conteo de intervenciones son queries LogQL (`proposal drafted`, `peer critique and revision`).

Runbooks upstream (PRs #115-117 de `underpass-ai/underpass-choreographer`): NOTES del chart que avisa si falta el OTLP, runbook de observabilidad y runbook de autoria de ceremonias.

## S3 Y Glacier

La instancia usa AWS CLI dentro de EC2 con Instance Profile. En el primer arranque descarga el ZIP al home de `ec2-user`.

Por defecto se usa `GLACIER_IR`: clase Glacier con acceso inmediato, adecuada para POC rapida.

Si se usa `GLACIER` o `DEEP_ARCHIVE`, el bootstrap ejecuta:

1. `aws s3api restore-object`
2. polling con `head-object`
3. `aws s3 cp` cuando el objeto esta disponible

Tiers:

- `Expedited`: minutos, mas caro y sujeto a capacidad.
- `Standard`: horas.
- `Bulk`: mas barato y mas lento.

## Coste Aproximado

Con todo parado, el coste base es EBS:

- 2 x 8 GB gp3 (t3.micro) ~= 1.41 USD/mes
- 1 x 100 GB gp3 (g6, driver + imagen vLLM + modelos) ~= 8 USD/mes — domina el coste base

Encendidas, pagan EC2 + IPv4 publica dinamica por horas (g6.xlarge ~0.50 USD/h on-demand). La IPv4 se libera al parar. Los pesos de modelos viven en S3 GLACIER_IR (`models/*.tar`) para poder recrear la g6 desde cero sin re-descargar de HF.

## Problemas Resueltos

- Calico fijo a `enp211s0`: se cambio a `kubernetes=NodeInternalIP`.
- `k8s.local` no resolvia en EC2: cloud-init escribe `/etc/hosts`.
- UFW bloqueaba `6443`: se abrio solo desde `aws-workers` y `10.90.0.0/24`.
- Calico Typha bloqueado por UFW: se abrio `5473` solo desde `aws-workers` y `10.90.0.0/24`.
- API server no podia hablar con kubelet por origen `10.90.0.1`: se anadio `10.90.0.1/32` a `AllowedIPs`.
- Reemplazos sucesivos dejaron nodos antiguos `NotReady`: se limpiaron con `kubectl delete node`. Resuelto de raiz con `--node-name=aws-worker-N` estable (cloud-init).
- Gateway rootless (systemd `--user`) no podia hacer `sudo wg set`: `sudoers.d/aws-side-wg` (NOPASSWD `wg`) + `DEMAND_GATEWAY_SYNC_COMMAND` en el unit.
- `demand-gateway.py` reventaba con EndpointSlice `endpoints=null` (workers parados): endurecido con `or []`.
- EC2 no veian las IPs MetalLB: `192.168.1.240/28` en AllowedIPs + forward/MASQUERADE en el PC (`setup-pc-network.sh`).
- Sin trafico worker<->worker (malla en estrella): `10.90.0.0/24` en AllowedIPs + hairpin forward en el PC.
- Token kubeadm manual y caducaba a 24h: ahora lo genera Terraform (provider `kubernetes`). Ver `docs/terraform-join.md`.
- Endpoint `aws-vpc-wg` creado por error en la zona publica (casi rompe la web): movido a zona Route53 PRIVADA (`terraform/dns.tf`).
- (fase 2) vLLM en T4G/arm64 inviable: torch cu130 recorta a sm_80+ y recompilar vLLM no salva (el limite es el wheel de torch) → migracion a x86 g6/L4 con imagen oficial.
- (fase 2) GPU Operator con runtimes mixtos revirtio la config cri-o local (drift latente que exploto en el siguiente reboot) → cri-o homogeneo en ambos nodos GPU + handler nvidia host-managed + `runtimeClassName` explicito.
- (fase 2) Cambiar `default_runtime` de cri-o con contenedores vivos dejo un typha huerfano reteniendo el puerto 5473 (estado de crun por-runtime-root) → tras tocar runtime, reciclar pods hostNetwork. Ver `docs/calico-recovery.md`.
- (fase 3) 2 modelos en una L4 de 24GB: time-slicing del device plugin + reparto asimetrico de VRAM (0.50/0.40, 8k contexto, enforce-eager) — 0.45/0.45 con 16k no cabe.

## Estado Y Siguiente Iteracion

Las 3 fases estan validadas: red y lifecycle (1), GPU cloud con vLLM (2), ceremonias multimodelo hibridas con observabilidad (3). Actas reales en `choreographer/runs/`; la base editorial de la serie en `docs/article-base.md`.

Candidatos para la siguiente iteracion:

- Reaper GPU: auto-stop de la g6 basado en metricas vLLM de Prometheus (`vllm:num_requests_running == 0` sostenido), analogo al idle de los t3 pero midiendo uso real de inferencia.
- Correr la ceremonia editorial `choreographer/ceremonies/article-decision-traces-hybrid.yaml` (lista, sin estrenar).
- Codificar en Terraform el drift IAM (SSM + `s3-node-logs`) o retirarlo.
- TLS/mTLS en el ingress de demanda; rotacion del token bootstrap TF.
- Redactar las piezas de la serie (ver `docs/article-base.md`).
