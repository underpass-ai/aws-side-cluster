# Handoff — aws-side-cluster

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
