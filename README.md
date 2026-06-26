# AWS side cluster POC

POC para extender un cluster Kubernetes local con workers baratos en AWS EC2. El control-plane queda en la workstation local y los nodos EC2 se conectan por WireGuard. La primera fase ya valida que Kubernetes sigue funcionando con nodos externos y que se pueden arrancar/parar workers por tags.

## Estado Validado

Fecha de validacion: 2026-06-25 (fase 1). 2026-06-26: wake rootless, join orquestado en Terraform, reachability MetalLB, worker<->worker y DNS privado validados con `scripts/cluster-test.sh`.

- Control-plane local: `wrx80-node1`, `192.168.1.56`
- Workers AWS: `aws-worker-1` (WG `10.90.0.11`) y `aws-worker-2` (WG `10.90.0.12`). Nombre de nodo estable; el ID de instancia EC2 cambia en cada replace.
- WireGuard local: `aws-workers`, local `10.90.0.1`
- VPC: `vpc-0ece93c68a3d23f84`, CIDR `10.80.0.0/16`
- Public subnet: `subnet-06e142a3f3d96f502`, CIDR `10.80.1.0/24`
- Security group: `sg-095550d47f14a04f2`
- S3 bootstrap bucket: `aws-side-poc-bootstrap-5d7cbe73`
- S3 bootstrap object: `bootstrap/random-payload.zip`
- EC2 role policy final: solo `aws-side-poc-bootstrap-s3`
- Smoke test validado: pod `registry.k8s.io/pause:3.10` planificado en worker AWS y borrado.
- Servicio de prueba AWS: `underpass-labs/aws-echo`, MetalLB `192.168.1.242`.
- Gateway de demanda POC: `underpass-labs/aws-demand-gateway`, MetalLB `192.168.1.243`.

## Arquitectura

```text
             LAN local
    +-------------------------+
    | wrx80-node1             |
    | Kubernetes control-plane |
    | API 192.168.1.56:6443   |
    | WG  10.90.0.1           |
    | MetalLB / ingress local |
    +-----------+-------------+
                |
                | WireGuard sobre Internet
                |
        +-------+-------------------+
        | AWS VPC 10.80.0.0/16      |
        | subnet publica 10.80.1.0  |
        |                           |
        | EC2 worker 10.90.0.11     |
        | EC2 worker 10.90.0.12     |
        +---------------------------+
```

El plano de control no se mueve a AWS. AWS aporta capacidad elastica de workers. En esta POC son `t4g.micro`; en fase 2 la misma idea se reutilizara con nodos GPU para inferencia.

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
- `docs/network-topology.md`: topologia de red completa (estrella, AllowedIPs, NAT, DNS).
- `docs/terraform-join.md`: join orquestado en Terraform.
- `docs/calico-recovery.md`: rollback/preflight del cambio de Calico.
- `docs/demand-gateway.md`: uso y limitaciones del gateway de demanda.
- `docs/per-node-demand-test.md`: prueba de routing por tag/nodo.
- `docs/article-base.md`: notas base para el articulo.

## Decisiones De Diseno

- Red barata: WireGuard, sin VPN Gateway ni VPC peering.
- Sin SSH por defecto: `allowed_ssh_cidrs = []`.
- IAM minimo en EC2: solo lectura/restore del objeto ZIP de S3.
- Public IPv4 dinamica: no usamos Elastic IP para evitar coste idle.
- `t4g.micro`: minimo practico para kubeadm worker. `t4g.nano` es mas barata pero demasiado justa para kubelet/containerd.
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
scripts/generate-worker-secrets.sh 2
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
- Dos EC2 `t4g.micro` con Amazon Linux 2023.

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

- 3 nodos `Ready`.
- `calico-node` `1/1` en los 3 nodos.
- El smoke pod corre en un nodo `ip-10-80-1-*.eu-south-2.compute.internal`.

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

Con 2 workers parados casi todo el mes, el coste base es principalmente EBS:

- 2 x 8 GB gp3 ~= 1.41 USD/mes

Encendidos, pagan EC2 + IPv4 publica dinamica por horas. La IPv4 publica se libera al parar la instancia.

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

## Siguiente Fase

Fase 1 ya valida red, worker lifecycle, servicio en workers AWS y un primer gateway HTTP de demanda. Lo siguiente es configurar el endpoint WireGuard local, probar el ciclo completo con workers parados y anadir TLS/mTLS en ingress. En fase 2, el mismo patron se aplicara a nodos GPU para colas o servicios de inferencia especializados.
