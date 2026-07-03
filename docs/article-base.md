# Base Para Serie De Articulos: Kubernetes Hibrido Con Workers EC2 Bajo Demanda

> Actualizado 2026-07-03. La base original (2026-06-25) cubria solo la fase 1 (workers
> t4g.micro). Desde entonces la POC ha validado la fase GPU (g6/L4) y la demo final
> (ceremonia multimodelo hibrida). El material da para una **serie de 3 piezas**; este
> documento es la base comun y el indice de la serie.

## Tesis

Un cluster Kubernetes personal o de laboratorio no tiene por que elegir entre todo local o todo cloud. En esta POC el control-plane queda en una workstation local con GPUs y se anaden workers baratos en AWS EC2 solo cuando hace falta capacidad externa.

La idea central es separar:

- Plano de control: estable, local, bajo control del operador.
- Capacidad elastica: nodos EC2 que se arrancan, se unen al cluster y se paran bajo demanda.
- Red de union: WireGuard, simple y barata.
- Bootstrap de datos: S3 con clase Glacier y descarga desde la propia EC2 usando IAM minimo.

**La tesis quedo demostrada de punta a punta el 2026-07-03**: un panel multimodelo donde
4 LLMs locales (4x RTX 3090) deliberan y un quinto modelo (phi4-mini en una NVIDIA L4 de
una g6.xlarge) aporta la perspectiva cloud a traves del tunel WireGuard, todo orquestado
por un motor de ceremonias y un gateway OpenAI-compatible que incluye/excluye el nodo AWS
por health-check segun este arrancado o parado.

## Hitos Validados

- **Fase 1 (2026-06-25):** 2 workers EC2 (entonces t4g.micro) unidos por WireGuard,
  Calico sano, servicio HTTP en workers AWS via MetalLB, gateway de demanda POC,
  bootstrap desde S3 con IAM minimo.
- **Fase 1.5 (2026-06-26):** wake on-demand rootless e2e, node-names estables
  (`aws-worker-N`), join orquestado en OpenTofu (apply deja nodos Ready sin pasos
  manuales), reachability pod EC2 -> MetalLB, DNS privado Route53.
- **Fase 2 GPU (2026-06-28 -> 2026-07-02):** primer worker GPU arm64 (g5g/T4G) validado
  con GPU Operator... y descartado: torch cu130 dropeo sm_75 y vLLM actual no puede servir
  en T4G. Migracion a **x86 g6.xlarge (NVIDIA L4)** con imagen oficial vLLM. Incidente
  real del GPU Operator con runtimes mixtos (ver parte 2). Nodos GPU homogeneos en
  cri-o 1.35.2. Observabilidad de bootstrap por S3 (diagnostico con la instancia parada).
- **Fase 3 (2026-07-02 -> 2026-07-03):** llm-gateway label-driven + choreographer
  (motor de ceremonias) instalados en el cluster; ceremonia `multimodel_panel` con 4 LLMs
  locales y **`multimodel_panel_hybrid` con el 5o modelo en AWS** corridas e2e
  (actas en `choreographer/runs/`).

## Arquitectura (estado actual)

```text
Workstation local
wrx80-node1 (Arch, cri-o 1.35.2)
192.168.1.56 / 10.90.0.1/24 WireGuard
Kubernetes control-plane
GPU Operator / 4x RTX 3090 (4 vLLM: qwen3-coder, devstral, gemma4, ernie45)
choreographer + llm-gateway + MetalLB / ingress local
        |
        | WireGuard sobre Internet (endpoint PC->EC2 via wg-sync)
        |
AWS eu-south-2, VPC 10.80.0.0/16, subnet publica 10.80.1.0/24
aws-worker-1/2      t3.micro    10.90.0.11/.12  (containerd)
aws-gpu-worker-1    g6.xlarge   10.90.0.21      (cri-o, NVIDIA L4, vllm-phi4)
S3: bootstrap + modelos (.tar GLACIER_IR) + logs de bootstrap
```

## La Serie

### Parte 1 — Cluster hibrido: control-plane local, workers EC2 por WireGuard

La base original de este documento. Narrativa:

1. Problema: workstation con GPUs y cluster local; capacidad cloud temporal sin coste fijo.
2. Hipotesis: control-plane local + workers EC2 con cloud-init + kubeadm join sobre WireGuard; coste base ~solo EBS.
3. Implementacion: OpenTofu (VPC, SG, IAM, S3, EC2), bootstrap autonomo, join orquestado en el apply.
4. Problemas reales: Calico fijado a interfaz local, DNS `k8s.local` desde AWS, UFW vs tunel, retorno por 10.90.0.1, nodos stale al reemplazar EC2 (resuelto con node-names estables).
5. Resultado: nodos Ready, pods en AWS detras de MetalLB local, gateway de demanda.

### Parte 2 — GPU en el nodo elastico: lo que nadie te cuenta

El material mas fuerte de la serie (war stories con causa raiz verificada por journal):

1. **T4G no sirve para vLLM actual**: torch cu130 recorta a sm_80+; recompilar vLLM no salva (el limite es el wheel de torch). En eu-south-2 no hay GPU arm64 que no sea T4G -> migracion a x86 g6.xlarge (L4, sm_89) con imagen oficial multi-arch. Leccion: la compatibilidad la fija la cadena driver/CUDA/torch/imagen, no la GPU sola.
2. **GPU Operator + runtimes mixtos = NO**: el toolkit tiene UN modo cluster-wide; al unirse un worker containerd, el pod saliente del nodo cri-o revirtio la config y dejo los vLLM locales sin inyeccion GPU (latente hasta el siguiente reboot). Fix: nodos GPU homogeneos (cri-o en ambos) + handler nvidia host-managed + runtimeClassName explicito.
3. **Contenedores huerfanos al cambiar default_runtime**: el estado de crun es por-runtime-root; un typha arrancado con el handler viejo no es visible para el nuevo -> proceso vivo reteniendo el puerto -> 503 restarts. Leccion operativa: tras tocar runtime, reciclar pods hostNetwork y vigilar "Killing container ... failed".
4. **cri-o en AL2023**: pkgs.k8s.io no publica RPMs >1.32; bundle estatico oficial + iptables-nft + kernel6.12-devel.
5. **Observabilidad barata**: el bootstrap shippea su log a S3 cada 15s -> diagnostico sin SSM/SSH incluso con la instancia parada. Watchdog con auto-stop para no dejar una GPU cara en CrashLoop.

### Parte 3 — El payoff: panel multimodelo hibrido local+cloud

1. **llm-gateway** (reverse proxy OpenAI-compatible, ~stdlib Python): descubre los vLLM por label k8s `underpass.ai/llm-role`, agrega `/v1/models`, enruta por nombre exacto o alias `role:<rol>` con round-robin y health-check. El nodo AWS entra y sale del pool solo, segun este arrancado.
2. **Choreographer** (motor de ceremonias FSM): steps con specialty/rol, councils que deliberan, guards, actas y diagrama mermaid de la corrida.
3. **La demo**: `multimodel_panel_hybrid` — gemma abre, qwen3-coder+devstral debaten en council, **phi4 responde desde la L4 en AWS por el tunel**, ernie sintetiza. Evidencia de routing en logs (choreographer -> gateway -> vLLM en EC2). Flujo operativo completo: start g6 (reintentos por capacity) -> wg-sync -> phi4 Ready solo -> ceremonia -> stop (compute a 0).
4. Angulo extra si interesa: higiene de release del repo publico (chart OCI stale con el mismo numero de version, imagenes sin publicar desde jun).

## Decisiones Tecnicas (transversales)

### WireGuard En Vez De VPN Gateway

WireGuard evita coste fijo de AWS VPN Gateway y encaja con una POC. En este diseno, los workers EC2 inician el tunel hacia un endpoint local estable (`local_wireguard_endpoint`). El proceso de demanda solo arranca EC2 y espera a que Kubernetes vuelva a ver nodos/endpoints.

La condicion critica es que ese endpoint estable sea alcanzable por UDP desde AWS y termine realmente en la workstation o en un relay que llegue a ella. En la POC se separa el nombre de web del nombre de transporte: `aws-demand.underpassai.com` es HTTP/TLS interno por MetalLB; `aws-vpc-wg.underpassai.com` es solo WireGuard para unir la VPC con el cluster local. Un nombre DNS correcto no basta si resuelve a una web o a otro borde que no reenvia `UDP/51820`.

La IP publica de cada EC2 cambia en cada stop/start: el lado PC se resincroniza con `scripts/wg-sync-ec2-endpoints.sh` (sin el, el nodo queda NotReady porque kubelet no llega al apiserver).

### Ingress Interno Con MetalLB

El endpoint HTTP visible para la prueba no publica una carga nueva en AWS. `aws-demand.underpassai.com` resuelve a una IP RFC1918 de la LAN (`192.168.1.241`), anunciada por MetalLB para `ingress-nginx`. El certificado de laboratorio lo emite un issuer propio del namespace de pruebas.

### Public IPv4 Dinamica En Vez De Elastic IP

Evita coste idle de Elastic IP. El endpoint estable que importa para el arranque desde frio es el endpoint WireGuard local, no la IP publica dinamica de cada worker.

### IAM: Minimo Como Objetivo, Con Drift Consciente

El diseno original dejaba solo `s3:GetObject` / `s3:RestoreObject` / `s3:ListBucket`
acotados al objeto de bootstrap. El estado real de la fase 2 anade (documentado como
deuda en el repo):

- `AmazonSSMManagedInstanceCore` (re-attacheada por CLI para ops de diagnostico).
- Escritura S3 acotada a `logs/*` para el shipper de logs de bootstrap.
- Lectura de `models/*` (los .tar de pesos de modelos en GLACIER_IR).

Punto honesto para el articulo: el "IAM minimo" evoluciona con las necesidades operativas;
lo importante es que cada permiso extra este acotado por prefijo y anotado como deuda si
no esta codificado en TF.

### Del t4g.micro Al Pool Actual

`t4g.micro` (arm64) fue el minimo practico de la fase 1 (512 MiB del nano no bastan para
containerd+kubelet+Calico). Tras la migracion GPU a x86, el pool de workers baratos corre
`t3.micro` (misma talla, x86). La leccion arm64: sirve para workers genericos, pero la
unica GPU arm64 disponible (T4G) quedo fuera del soporte de vLLM/torch actual.

### `GLACIER_IR` Para La POC

Permite decir "clase Glacier" sin bloquear el primer arranque durante horas (acceso
inmediato). Se usa tanto para el ZIP de bootstrap como para los pesos de modelos
(un .tar por modelo, preservando symlinks de la cache HF). Para `GLACIER` o
`DEEP_ARCHIVE`, el bootstrap ya contempla `restore-object`.

## Comandos Clave (estado actual)

Levantar el lado AWS (la g6 tiene capacity escasa en eu-south-2a: reintentar):

```bash
aws ec2 start-instances --instance-ids <g6> <t3-1> <t3-2>
scripts/wg-sync-ec2-endpoints.sh          # IP publica nueva en cada start
kubectl get nodes
kubectl -n underpass-labs get pods -l app.kubernetes.io/name=vllm-phi4-aws
```

Logs de bootstrap de cualquier nodo, sin SSM/SSH (funciona con la instancia parada):

```bash
aws s3 cp s3://aws-side-poc-bootstrap-<id>/logs/<hostname>-bootstrap.log -
```

Backends del gateway (el nodo AWS entra/sale solo por health-check):

```bash
curl -s http://llm-gateway.underpass-labs:8000/backends | jq
```

Correr una ceremonia (port-forward gRPC + grpcurl; ojo al `-i` de podman para stdin):

```bash
kubectl -n underpass-labs port-forward svc/choreographer 50055:50055 &
jq -Rs '{ceremonyId:"run-1", definitionYaml:., leaseOwnerId:"operator", leaseTtlMs:120000}' \
  choreographer/ceremonies/multimodel-panel-hybrid.yaml \
| podman run -i --rm --network=host -v <checkout>/crates/choreo-proto/proto:/protos:ro \
    docker.io/fullstorydev/grpcurl -plaintext -import-path /protos \
    -proto underpass/choreo/v1/choreo.proto -d @ \
    localhost:50055 underpass.choreo.v1.ChoreographerService/RunCeremony
```

Parar todo (compute a 0; queda solo EBS):

```bash
aws ec2 stop-instances --instance-ids <g6> <t3-1> <t3-2>
```

## Evidencia De Los Hitos

Nodos (fase actual):

```text
wrx80-node1        Ready  control-plane  192.168.1.56   cri-o 1.35.2
aws-worker-1       Ready  <none>         10.90.0.11     containerd
aws-worker-2       Ready  <none>         10.90.0.12     containerd
aws-gpu-worker-1   Ready  <none>         10.90.0.21     cri-o 1.35.2, nvidia.com/gpu: 1
```

Ceremonia hibrida (2026-07-03, acta en `choreographer/runs/multimodel-panel-hybrid-1.md`):

```text
ceremony: multimodel-panel-hybrid-1   finalState: CLOSED
open_panel        COMPLETED  gemma-4-26b        (local, RTX 3090)
technical_debate  COMPLETED  qwen3-coder + devstral (council local)
aws_perspective   COMPLETED  phi4-mini-aws      (AWS g6/L4 via WireGuard)
synthesis         COMPLETED  ernie-4.5-21b-a3b  (local)
```

Evidencia del salto a AWS: el pod vllm-phi4-aws registra los POST del llm-gateway,
que a su vez recibe los del choreographer (cadena verificada en logs, no inferida).

## Ideas De Titulos

Parte 1:

- Kubernetes hibrido casero: control-plane local y workers EC2 bajo demanda
- Uniendo una workstation GPU a AWS con WireGuard y kubeadm

Parte 2:

- La GPU cloud que no podia servir: torch, sm_75 y por que recompilar no salva
- GPU Operator con dos runtimes: anatomia de un drift que tardo 4 dias en explotar

Parte 3:

- Un panel de 5 LLMs: cuatro en mi escritorio, uno en AWS
- De workstation a cluster elastico: inferencia multimodelo local+cloud por WireGuard

## Pendientes

- Correr `article-decision-traces-hybrid.yaml` (ceremonia editorial; genera material/trazas para la propia serie).
- Merge `feat/aws-gpu-x86-l4` -> `main`.
- Scale-down automatico cuando no haya carga (el gateway de demanda ya hace wake; falta sleep).
- Metricas de coste por minuto de inferencia.
- Codificar en TF el drift IAM (SSM + inline s3-node-logs) o retirarlo.
