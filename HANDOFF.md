# Handoff — aws-side-cluster

**Contexto temporal:** trabajo hecho ~2026-06-28. Este handoff se escribe **2026-07-01** (han pasado ~3 días); el cluster ha hecho **drift** desde entonces (ver §Estado actual). Distingo **HECHO (verificado)** de *hipótesis a verificar*.

---

## Actualización 2026-07-01 (tarde) — GPU AWS migrado a x86/L4 · vLLM SIRVIENDO (resuelto)

El bloqueo del §AWS (servir vLLM en el T4G) queda **resuelto pivotando a x86**:

- **Causa raíz (verificada):** vLLM actual usa `torch 2.11+cu130`, cuyo wheel **arranca en sm_80** (`torch.cuda.get_arch_list() = sm_80,90,100,110,120`) — **dropeó Turing (sm_75)**. El T4G peta con `cudaErrorNoKernelImageForDevice` en la 1ª op de torch, aunque compiles los kernels de *vLLM* para 7.5 (ese build sm_75 se hizo y está en `s3://aws-side-poc-bootstrap-5d7cbe73/models/images/vllm-openai-v0.23.0-sm75.tar.zst`, pero es **inútil** por el torch dependency).
- **En eu-south-2 la única GPU arm64 es el T4G** (familia g5g). No hay Ampere+ en arm64.
- **Solución:** GPU worker migrado a **`g6.xlarge` (NVIDIA L4, sm_89, x86)** + **imagen oficial** `docker.io/vllm/vllm-openai` (ya trae sm_80+, sin build custom). **Phi-4-mini validado sirviendo** (chat real, vLLM 0.24.0).

**Cambios:**
- `terraform/terraform.tfvars` *(local/gitignored)*: `ami_architecture=x86_64`, `instance_type=t3.micro`, `gpu_instance_type=g6.xlarge`.
- `terraform/cloud-init/bootstrap.sh.tftpl`: driver NVIDIA **arch+stream-aware** — AL2023 x86 corre kernel 6.12 → paquete DKMS `kernel6.12-devel` (no `kernel-devel`); repo CUDA `x86_64` vs `sbsa` según `uname -m`.
- `charts/local-llm/values-aws-gpu.yaml`: imagen oficial + `nodeSelector NVIDIA-L4` + sin `--dtype half` (L4 tiene bf16).
- `charts/local-llm/templates/deployment.yaml`: `runtimeClassName: nvidia` (nodos containerd).

**Para levantarlo:** `tofu apply` (recrea g6 + 2× t3) → esperar nodo Ready + GPU allocatable → `helm upgrade aws-gpu-llm charts/local-llm -n underpass-labs -f charts/local-llm/values-aws-gpu.yaml`.

---

## TL;DR

- **4 modelos grandes locales** (4× RTX 3090, ns `underpass-labs`) desplegados y validados e2e el 28-jun (chat + tool-calling). Commit `da9a1b3`.
- **Choreographer** (proyecto Rust `../underpass-orchestrator`) desplegado en `underpass-labs` + **ceremonia editorial** corrida e2e con su **decision trace** capturada + **observabilidad OTEL in-namespace** (collector traído por el propio helm). Commits `42605e6`, `3d2bdc2`.
- **Worker GPU AWS (g5g/T4G)** validado a nivel infra (driver DKMS + join + GPU Operator). Commit `65d3d20`. Pero **servir vLLM en el T4G quedó bloqueado** (evidencia abajo).
- **EC2 todas paradas** (coste compute 0). El cluster local ha driftado: **GPUs marcadas `unhealthy`** por el device-plugin → los 4 modelos locales están crasheando **ahora** (drift de 3 días, no del código).

---

## Estado actual (verificado 2026-07-01)

**EC2 (`eu-south-2`):** todas **`stopped`** — 2× t4g.micro + 1× g5g.xlarge. Compute = 0. El g5g parado conserva su **EBS de 100GB (~$8/mes)**; destruir (`gpu_instance_count=0` + `tofu apply`) para coste 0.

**Cluster local (`wrx80-node1`):**
- Nodo `Ready`, sin DiskPressure/MemoryPressure, `/` 81% (176G libres). `nvidia.com/gpu allocatable: 4`, `nvidia-smi` lista las 4 GPUs (0 procesos).
- ⚠️ **Los 4 vLLM grandes están CrashLoop/UnexpectedAdmissionError.** Causa verificada: device-plugin rechaza la asignación → `Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu`, y vLLM cae con `Failed to infer device type`. → **GPUs marcadas unhealthy por el device-plugin tras ~3 días de uptime** (drift operativo, no regresión de código).
- `choreographer`, `choreographer-nats`, `choreographer-otel-collector`: **1/1 Running**.
- `aws-echo*` (demand-gateway del POC): Running (algún worker Pending por los EC2 parados; normal).
- Basura a limpiar: pods `vllm-*` duplicados (viejo UnexpectedAdmissionError + nuevo CrashLoop) y un pod `vllm-archcheck` Pending (debug, borrar).

**Recuperar las GPUs (a probar, NO hecho aún):**
1. `nvidia-smi` en el host + `dmesg | grep -i xid` para ver si hay Xid/fallo de driver.
2. Reiniciar el device-plugin: `kubectl -n nvidia rollout restart ds/nvidia-device-plugin-daemonset` (re-chequea salud de las GPUs).
3. Si persiste, reiniciar el driver/toolkit del GPU Operator o el nodo.
4. Limpiar pods muertos: `kubectl -n underpass-labs delete pod --field-selector status.phase=Failed` + borrar `vllm-archcheck`.
5. Cuando las GPUs estén healthy, los Deployments vLLM se recuperan solos (o `kubectl rollout restart`).

---

## Hecho esta sesión (commits en `main`)

| Commit | Qué |
|---|---|
| `da9a1b3` | **4 grandes** estables: qwen3-coder + devstral + gemma4 + **ernie45-thinking** (reemplazó a GLM-4.7-Flash, no viable por bug MLA+AWQ). Tuning KV + `--limit-mm` (visión Pixtral de devstral). |
| `2244638` | Labels `underpass.ai/llm-role` (coding/reasoning/general) por modelo. |
| `42605e6` | Ceremonia editorial `choreographer/ceremonies/article-decision-traces.yaml` **validada contra el parser real** (`CeremonyDefinitionYaml::parse_path`) + perfil `values.underpass-labs.yaml`. |
| `3d2bdc2` | Observabilidad OTEL in-ns (collector via helm → Tempo) + ceremonia corrida e2e → acta en `choreographer/runs/article-trace-1.md`. |
| `65d3d20` | Fix bootstrap TF: vars GPU en scope del script principal (estaban en el heredoc de kubeadm-join → `unbound`). Validó el g5g real. |

**Modelos (los 4, ns `underpass-labs`, 1 GPU c/u):**
- `qwen3-coder` = `QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ` (coding, parser qwen3_coder, maxModelLen 40960, gmu 0.95)
- `devstral` = `cyankiwi/Devstral-Small-2-24B-…-AWQ` (coding, parser mistral, `--limit-mm-per-prompt '{"image":0}'`)
- `ernie45-thinking` = `cyankiwi/ERNIE-4.5-21B-A3B-Thinking-AWQ-4bit` (reasoning, parsers ernie45, `--trust-remote-code` + `--tokenizer baidu/ERNIE-4.5-21B-A3B-Thinking`)
- `gemma4` = `cyankiwi/gemma-4-26B-A4B-it-AWQ` (general, sin parser)

**Ceremonia:** FSM `FRAMING→DRAFTING→CRITIQUE→SYNTHESIS→SEALED`, 4 steps con 4 specialties → 4 modelos (gemma facilita, qwen borra en council 2+1ronda, ernie critica, devstral edita). Correr con `RunCeremony` gRPC (puerto **50055**, servicio `underpass.choreo.v1.ChoreographerService`, ver `choreographer/README.md`).

---

## Sin commitear (revisar antes de commitear)

**En `aws-side-cluster`:**
- `M charts/local-llm/templates/deployment.yaml` — añade `runtimeClassName` (necesario en nodos containerd/g5g; ver §AWS).
- `?? charts/local-llm/values-aws-gpu.yaml` — sirve Phi-4-mini en el T4G (nodeSelector NVIDIA-T4G, `--dtype half`, runtimeClassName nvidia).
- `?? choreographer/ceremonies/article-decision-traces-hybrid.yaml` — variante con un step `aws_perspective` (Phi-4@T4G) para el AWS bursting. **Valida contra las 11 invariantes** (lint) pero NO corrida (bloqueada, ver §AWS).
- `terraform/terraform.tfvars`: `gpu_instance_count = 1`, `gpu_root_volume_size_gb = 100` (poner `gpu_instance_count = 0` para dejar limpio/coste 0).

**En `../underpass-orchestrator` (chart upstream, sin commitear en ESE repo):**
- `M charts/choreographer/values.yaml` + `?? templates/otel-collector.yaml` — el collector OTEL in-ns que añadí al chart (gated `otelCollector.enabled`). Requerido por el perfil `values.underpass-labs.yaml`. Commitear en ese repo cuando proceda.

---

## Pendiente

### 1. Agente AWS que participe (BLOQUEADO — decisión pendiente)
Objetivo: que el GPU de AWS sirva un modelo y participe en la ceremonia (`article-decision-traces-hybrid.yaml`).

Obstáculos resueltos por el camino: cuota → bug bootstrap → DiskPressure g5g (60→**100GB**) → **runtimeClassName nvidia** (containerd no inyecta GPU por defecto, sí el cri-o local).

**Bloqueo actual (con EVIDENCIA, sin coste):** la imagen `vllm/vllm-openai:v0.23.0` **arm64** trae `TORCH_CUDA_ARCH_LIST=8.0 8.7 8.9 9.0 10.0 11.0 12.0+PTX` (visto con `skopeo inspect --config`). El **T4G es sm_7.5 (Turing)**, que **no está** en esa lista (empieza en 8.0; `+PTX` solo en 12.0) → `cudaErrorNoKernelImageForDevice`. Es ESTE build arm64 el que recorta <8.0; vLLM el proyecto sí soporta Turing (el build x86 normalmente trae 7.5).

Opciones (a decidir con el user):
- **Ollama en el g5g** (arm64+CUDA, soporta Turing, OpenAI-compatible, GGUF propio) — reusa el g5g, pivota de vLLM solo en el agente AWS.
- **Instancia x86 (g4dn/T4)** — imagen vLLM x86 sí trae sm_75; pierde Graviton (más caro), cambia el cloud-init del driver al repo x86.
- **Build arm64+sm_75 propio** (`TORCH_CUDA_ARCH_LIST=7.5`) — más trabajo.
- (Verificar con `torch.cuda.get_arch_list()` en la imagen arm64 sobre el T4G si se quiere confirmar en hardware — requiere g5g encendido.)

### 2. Otros
- Commitear el collector OTEL en `underpass-orchestrator` (ver §Sin commitear).
- Labels `underpass.ai/llm-role` ya en el chart; el choreographer enruta por *specialty* (no por label k8s).
- Council heterogéneo (qwen+devstral en un mismo step) vía `RegisterAgent`+`CreateCouncil` — recipe en `choreographer/README.md`, sin probar.

---

## Aprendizajes clave (en memoria)
- **GLM-4.7-Flash AWQ**: MLA+AWQ peta en vLLM 0.23 (`_compute_prefill_context`, kv_b_proj sin `.weight`) → evitar MLA (deepseek/glm/kimi/minimax) con AWQ.
- **Ceremonias**: un solo handler real (todos deliberan; `handler:` = specialty por defecto); config `prompt/specialty/rounds/num_agents/provider.*`; auto-prepare crea 1 council por specialty (homogéneo). Esquema + 11 invariantes en la memoria del proyecto.
- **g5g/T4G**: EBS ≥100GB (driver DKMS + modelos S3 + imagen vLLM ~10GB); `runtimeClassName: nvidia`; la imagen vLLM se baja de Docker Hub (~10GB, lento) — el modelo de S3 in-region va rápido; hornear imagen en AMI/ECR para arranque mínimo.
- **Método**: contrastar con evidencia antes de afirmar una causa; no inferir. Vigilar coste EC2 (parar/destruir al pausar).
