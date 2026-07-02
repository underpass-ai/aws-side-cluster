# Handoff — aws-side-cluster

---

## ⚡ Sesión 2026-07-02 (noche) — motor de ceremonias + llm-gateway + incidente typha (LEER PRIMERO)

### Hecho y verificado
- **Choreographer PÚBLICO instalado via Helm** (release `choreographer` en `underpass-labs`, rev 5): chart del **checkout** de `github.com/underpass-ai/underpass-choreographer` (el chart OCI 0.1.0 publicado está **stale**, sin `providerEnv`), imagen pinneada `@sha256:18abb055…` (tag `metrics-e7a89f4`, jun-11 — única publicada con `RunCeremony`; `main` es de mayo). `agent_kinds=noop,vllm`. Overlay: `choreographer/values.underpass-labs-public.yaml`.
- **llm-gateway** (`charts/llm-gateway`, NUESTRO, no del producto): reverse proxy OpenAI-compatible que **descubre los vLLM por label** `underpass.ai/llm-role` (API k8s, RBAC ro), agrega `/v1/models`, enruta por `model` exacto o **alias `role:<rol>`** (round-robin + health-check). Stdlib Python en ConfigMap sobre `python:3.12-slim`. Endpoints: `http://llm-gateway:8000`, debug en `/backends`.
- **Ceremonias corridas e2e**: `hello_panel` (noop smoke) y **`multimodel_panel` con 4 LLMs reales** (gemma abre, qwen+devstral deliberan en council, ernie sintetiza), todo por el gateway con `role:<specialty>` — actas en `choreographer/runs/`.
- **Claves de ceremonias** (parser real): `agent_kind: vllm` + `provider.model/max_tokens/timeout_secs` van **en el config del step**; handler = specialty. GOTCHA: los agentes de ceremonia persisten por id en el registry — si cambias `agent_kind`, **reinicia el pod** del choreographer (in-memory) o reutiliza los viejos. GOTCHA2: `podman run` necesita **`-i`** para `grpcurl -d @` por stdin (sin él: "invalid ceremony yaml" con payload vacío).
- **Ceremonia HÍBRIDA lista sin correr**: `choreographer/ceremonies/multimodel-panel-hybrid.yaml` (step `aws_perspective` pide `phi4-mini-aws` por nombre via gateway).

### ⚠️ INCIDENTE typha — CAUSA EXACTA (journal, evidencia completa)
Cronología (CEST): **18:38** boot de wrx80 → crio (PID 1232) arranca typha, contenedor `f8b6aed0`, **proceso host 4830** (hostNetwork, puerto 5473). **~20:26** el toolkit del GPU Operator (ya en modo crio tras el flip) reescribe la config y **reinicia crio** (kubelet: `crio.sock: no such file`). El crio nuevo pierde la gestión del contenedor: cada kill delega en `/usr/bin/nvidia-container-runtime --root /run/crun kill f8b6aed0` → **"container does not exist"** (el contenedor fue creado por el runtime/estado ANTERIOR al cambio de `default_runtime`) → **el proceso 4830 nunca muere y retiene :5473** → cada typha nuevo falla `bind: address already in use` → **503 restarts**. El mismo mecanismo explica el nats de la mañana (puerto 8222 retenido en su netns).
**Lección**: cambiar el runtime por defecto de cri-o (drop-in + restarts del toolkit) con contenedores vivos deja contenedores huérfanos de gestión. Tras tocar runtime: `systemctl restart crio` + **reciclar los pods hostNetwork** (typha) y vigilar "Killing container … failed".

### 🔧 PRIMER PASO MAÑANA (1 comando con sudo)
El proceso fantasma sigue vivo reteniendo 5473 en wrx80 (kubelet no puede matarlo; el pod viejo está `Terminating` eterno):
```bash
sudo kill -9 4830   # (verificar antes: ps -fp 4830 → debe ser /usr/bin/calico-typha de las 18:38)
kubectl -n calico-system delete pod calico-typha-86f6f4c685-7lnlv --force --grace-period=0
# el ReplicaSet recrea typha en wrx80 y ya podrá bindear 5473
```
(Esta noche el typha "ready" estaba en el g6; al parar el g6 no queda typha ready — los 4 modelos locales siguen sirviendo igual, felix aguanta con último estado. No es urgente hasta querer tocar red/pods.)

### Pendiente mañana
1. `sudo kill` del fantasma (arriba) → typha sano en wrx80.
2. Arrancar g6 (`aws ec2 start-instances --instance-ids i-084f4b98659f48a19` + reintentos capacity) → `scripts/wg-sync-ec2-endpoints.sh` → si el stack nvidia no converge: borrar pods `nvidia-operator-validator`/`device-plugin`/`gfd`/`nfd-worker` del nodo (los regenera el DS; hoy hizo falta) → phi4 `1/1` → **el gateway lo re-incluye solo** (verificar en `/backends`).
3. **Correr `multimodel-panel-hybrid.yaml`** (payload: `jq -Rs '{definitionYaml: .}' … | grpcurl -d @` con podman `-i`; port-forward 50055) → acta a `choreographer/runs/` → STOP EC2.
4. Ideas artículo: higiene de release del repo público (imágenes desde mayo sin publicar, chart OCI stale, tag `metrics-*` sin label revision).

---

**Contexto temporal:** escrito **2026-07-02** al cierre de sesión. Todo lo marcado ✅ está **verificado con evidencia** (inferencia real, no supuesto). Rama: `feat/aws-gpu-x86-l4` (commits `e677f87`, `085d048` + este handoff). Sin mergear a `main`.

---

## TL;DR

- ✅ **Los 4 modelos locales** (4× RTX 3090, ns `underpass-labs`) **recuperados y sirviendo** tras el drift (causa raíz encontrada: el GPU Operator revirtió la config cri-o local al flip-flopear de runtime; ver §Causa raíz).
- ✅ **GPU worker AWS migrado a x86 `g6.xlarge` (NVIDIA L4)** con la **imagen oficial** `vllm/vllm-openai` — el T4G/arm64 era inviable (torch cu130 dropeó sm_75). **Phi-4-mini validado sirviendo chat en la L4**.
- ✅ **Los 2 nodos GPU homogéneos en cri-o 1.35.2** (local + AWS): el toolkit del GPU Operator quedó en modo `crio`, **sano 2/2** (el local llevaba 32 crashes desde el 28-jun). Decisión clave para el artículo.
- ✅ **Observabilidad de nodos**: cada bootstrap shippea su log a `s3://aws-side-poc-bootstrap-5d7cbe73/logs/<hostname>-bootstrap.log` cada 15s → diagnóstico sin SSM/SSH.
- ✅ **EC2 todas `stopped`** (compute 0). El EBS de la g6 (100GB) persiste (~$8/mes).

## Estado actual (verificado 2026-07-02 ~20:45 CEST)

**Cluster:**
| Nodo | Estado | Runtime | GPU |
|---|---|---|---|
| `wrx80-node1` (local) | Ready | **cri-o 1.35.2** | 4× RTX 3090, allocatable 4 |
| `aws-gpu-worker-1` (g6, **stopped**) | NotReady al parar | **cri-o 1.35.2** | 1× L4 (validada) |
| `aws-worker-1/2` (t3.micro, **stopped**) | NotReady al parar | containerd | — |

**Workloads (`underpass-labs`):** los 4 vLLM locales `1/1 Running` (qwen3-coder/devstral/ernie45/gemma4, helm release `local-llm` rev 8); `vllm-phi4-aws` queda Pending al estar la g6 parada (normal); choreographer + nats + otel-collector Running.

**EC2 (`eu-south-2`, cuenta 203918869295):** `i-084f4b98659f48a19` (g6.xlarge), `i-07a0f19bcff1afd47`, `i-01f3d1f11d2023991` (t3.micro) — **stopped**.

## Causa raíz del drift local (la historia completa, para el artículo)

1. **28-jun**: al unirse el worker AWS (containerd), el **GPU Operator flipó su toolkit a modo containerd** (el DS solo soporta UN modo cluster-wide). El pod toolkit saliente del nodo cri-o **revirtió su config al terminar**: borró el handler `nvidia` de `/etc/crio/crio.conf.d/99-nvidia.conf`.
2. Los modelos siguieron vivos (GPU ya inyectada en contenedores corriendo) → nadie lo notó.
3. **02-jul**: reboot del nodo local → toda creación nueva de pod GPU salía **sin inyección** (`nvidia-smi: command not found`, `cuda_available False`) → `Failed to infer device type` → CrashLoop de los 4.
4. Fix: (a) handler `nvidia` restaurado en cri-o con el runtime del **host** (pacman `nvidia-container-toolkit`, driver 595 alineado) vía `/etc/crio/crio.conf.d/99-zz-nvidia-runtime.conf` (host-managed, sobrevive al operator); (b) `runtimeClassName: nvidia` **explícito** en los values del chart (ya no se depende del `default_runtime`); (c) **cri-o en el nodo GPU AWS** → operator homogéneo, sin más flip-flops.

## Migración GPU AWS: T4G→L4 (por qué)

- vLLM actual (imagen oficial, torch **2.11+cu130**) requiere **sm_80+** (verificado en pod: `torch.cuda.get_arch_list() = [sm_80..sm_120]`). El T4G es sm_75 (Turing) → `cudaErrorNoKernelImageForDevice` **aunque** recompiles vLLM para 7.5 (se hizo: el bundle está en `s3://…/models/images/vllm-openai-v0.23.0-sm75.tar.zst`, inútil por el torch).
- En eu-south-2 **no hay GPU arm64 que no sea T4G** → x86 `g6.xlarge` (L4, sm_89) + imagen oficial multi-arch, sin builds custom.
- CUDA 13 en general: mínimo Turing 7.5; torch cu130 recorta más (8.0).

## Cómo levantar el lado AWS

```bash
# 1) arrancar (g6 = capacity ESCASA en eu-south-2a: reintentar cada ~90s, puede tardar >10 min)
aws ec2 start-instances --instance-ids i-084f4b98659f48a19 i-07a0f19bcff1afd47 i-01f3d1f11d2023991
# 2) la IP pública CAMBIA en cada stop/start -> resync WG (si no: nodo NotReady, kubelet no llega al apiserver)
scripts/wg-sync-ec2-endpoints.sh
# 3) esperar Ready + gpu allocatable; vllm-phi4-aws se recupera solo
kubectl get nodes; kubectl -n underpass-labs get pods -l app.kubernetes.io/name=vllm-phi4-aws
# logs de bootstrap de cualquier nodo, sin SSM:
aws s3 cp s3://aws-side-poc-bootstrap-5d7cbe73/logs/<hostname>-bootstrap.log -
```

**Recrear la g6 desde cero** (`tofu apply -replace='aws_instance.gpu_worker[0]'`): el bootstrap ya hace todo (cri-o bundle 1.35.2 + iptables-nft + driver `kernel6.12-devel` + join con `--cri-socket` + shipper de logs). Tras el join, si el toolkit no flipa solo: `kubectl -n nvidia rollout restart deploy/gpu-operator`.

## Deuda / drift conocido (menor)

- **Nodo local, host-managed** (fuera de git): `/etc/crio/crio.conf.d/99-zz-nvidia-runtime.conf`. Intencional (belt-and-braces frente al operator).
- **IAM por CLI** (no en TF): policy `AmazonSSMManagedInstanceCore` attacheada al rol `aws-side-poc-worker` (útil para ops; codificar en TF o quitar) y una inline `s3-node-logs` redundante (el próximo `tofu apply` mete `ShipNodeLogs` en la policy TF; borrar la inline: `aws iam delete-role-policy --role-name aws-side-poc-worker --policy-name s3-node-logs`).
- El próximo `tofu apply` actualizará `user_data` de las instancias (in-place, están stopped) — sin efecto hasta recreación (cloud-init no re-corre).
- Borrable de S3: `models/images/vllm-openai-v0.23.0-sm75.tar.zst` (8.7GB GLACIER_IR, obsoleto).

## Pendiente (siguiente sesión)

1. **Ceremonia híbrida con agente AWS** — el objetivo original ya desbloqueado: `choreographer/ceremonies/article-decision-traces-hybrid.yaml` (sin trackear; lint OK, nunca corrida). Los 4 locales + `phi4-mini-aws` (step `aws_perspective`) están operativos. Correr con `RunCeremony` gRPC :50055 (ver `choreographer/README.md`).
2. **Merge** `feat/aws-gpu-x86-l4` → `main`.
3. Commitear el collector OTEL en `../underpass-orchestrator` (chart upstream, sigue sin commitear en ESE repo).
4. Council heterogéneo (`RegisterAgent`+`CreateCouncil`, recipe en README) — sin probar.

## Aprendizajes clave (también en memoria del proyecto)

- **GPU Operator + runtimes mixtos = NO**: un solo modo de toolkit cluster-wide; al cambiar, el pod saliente revierte la config del runtime anterior. Homogeneizar los nodos GPU.
- **pkgs.k8s.io no publica RPMs de cri-o > v1.32** (403). Usar el **bundle estático oficial** (`storage.googleapis.com/cri-o/artifacts/cri-o.<arch>.v<ver>.tar.gz`); limpia sus conflists CNI (Calico manda) y exige `iptables-nft` en AL2023 minimal.
- **torch cu130 dropeó sm_75**; los rebuilds de vLLM no lo salvan (el límite es el wheel de torch).
- **AL2023 kernel streams**: 6.12 usa `kernel6.12-devel`, no `kernel-devel`.
- **Stop/start EC2 = IP pública nueva** → siempre `wg-sync-ec2-endpoints.sh`.
- **Vigilar instancias caras**: watchdog con auto-stop a pocos NRestarts (evitó otra tanda de g6 en bucle); los logs shippeados a S3 hacen el diagnóstico posible con la instancia parada.
- **Método**: verificar con evidencia antes de afirmar causa (dos "causas obvias" de hoy —CDI borrado por reboot, repo cri-o v1.35— resultaron falsas o distintas al comprobarlas).
