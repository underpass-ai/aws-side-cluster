# Run: csi_typha — 2026-07-03

**El experimento curioso**: un post-mortem *whodunit*. Al panel de 6 modelos se le dio la
evidencia CRUDA del journal del incidente real del typha fantasma (2026-07-02, wrx80-node1)
**sin la conclusión**, y tuvo que deducir la causa raíz. La causa verificada existe
(HANDOFF/memoria), así que el veredicto se puede puntuar.

**Novedad de infraestructura**: 2 modelos en la MISMA L4 de 24GB (g6.xlarge) via
**time-slicing** del GPU Operator (`nvidia.com/gpu` replicas=2 solo en `aws-gpu-worker-1`,
perfil por label; las 4x3090 locales intactas). phi4 gmu 0.50 + smollm3 gmu 0.40,
contexto 8k, `--enforce-eager`. Ambos sirvieron la ceremonia desde la L4 compartida
(verificado en logs de ambos pods).

## Reparto (6 modelos, 6 papeles)

| Papel | Modelo | Dónde |
|---|---|---|
| MODERATOR (abre el caso) | gemma-4-26b | local, RTX 3090 |
| FORENSIC_LEAD (hipótesis) | qwen3-coder-30b | local, RTX 3090 |
| SKEPTIC (contrainterrogatorio) | devstral-small-24b | local, RTX 3090 |
| CLOUD_WITNESS (perito remoto) | phi4-mini-aws | **AWS L4 (time-sliced)** |
| JUNIOR_INVESTIGATOR (fact-check) | smollm3-aws | **AWS L4 (time-sliced)** |
| JUDGE (veredicto, thinking) | ernie-4.5-21b-a3b | local, RTX 3090 |

`finalState: CLOSED`, 6/6 steps `COMPLETED`. ceremony_id `csi-typha-1`.
Definición: `choreographer/ceremonies/csi-typha.yaml` (validada contra el parser real).

## ¿Acertó el panel? — Puntuación contra la causa verificada

**Causa real** (verificada por journal el 2026-07-02): el estado de crun/runc es
**por-runtime-root**; al cambiar `default_runtime` y reiniciar cri-o, el contenedor creado
con el handler anterior es **invisible para el runtime nuevo** (`--root /run/crun` mira en
un state root donde ese contenedor nunca se registró) → kill "container does not exist" →
el proceso sobrevive huérfano reteniendo su puerto.

| Aspecto | Panel | Real | Score |
|---|---|---|---|
| Clase del mecanismo (handover de runtime deja el contenedor fuera de gestión) | ✅ | ✅ | **acierto** |
| Mecanismo específico (state root por-runtime divergente) | ❌ culpó a `hostNetwork+privileged` | crun state root | **fallo** |
| Por qué falla el kill | "el runtime nuevo no trackea el proceso" (correcto en la forma, sin el porqué) | el state está en otro root | **medio** |
| Remediación (matar/reciclar antes-después de la transición) | ✅ pre-transition hook / reciclar | ✅ misma lección operativa | **acierto** |
| Prevención | "prohibir hostNetwork+privileged" (impracticable: typha/CNI lo necesitan) | homogeneizar runtime + reciclar hostNetwork tras tocar config | **fallo** |

**El detalle más revelador** (oro para el artículo): el forense (qwen) **se inventó
evidencia** — afirmó que el pod spec tenía `privileged:true` "como evidencia", cosa que el
case file nunca decía. El junior (smollm3, 3B), cuyo único trabajo era separar hechos de
afirmaciones, **canonizó la alucinación como "Fact"**. El escéptico (devstral) fue quien
más cerca estuvo del mecanismo real (mismatch de visibilidad de PIDs/estado entre runtimes)
y fue el único que pidió la evidencia discriminante correcta (inspeccionar el estado en el
momento del switch). El juez dictó "confidence: High" apoyándose en la evidencia
alucinada. La pista más gorda del case file — el `--root /run/crun` del comando de kill —
**nadie la explotó**.

Meta-lección: un panel de LLMs reproduce los modos de fallo de una revisión de incidentes
humana — la narrativa convincente le gana a la evidencia, el fact-checker valida lo que
dijo la autoridad, y el escéptico tenía razón pero nadie le hizo caso.

## Actas (outputs íntegros)

### open_case (MODERATOR — gemma-4-26b)

> Following the configuration rewrite by the NVIDIA GPU Operator on wrx80-node1, the
> `cri-o` runtime transitioned to the `nvidia-container-runtime`, effectively severing its
> ability to manage existing processes spawned under the previous runtime context. This
> state mismatch has left the `calico-typha` host-network process (PID 4830) orphaned and
> unkillable by the new runtime, resulting in a perpetual port 5473 bind conflict and
> escalating 503 errors. Notably, this pattern of "zombie" namespaces and unkillable PIDs
> was also observed earlier with the NATS container, suggesting a systemic failure in how
> runtime handovers interact with host-networked containers. What is the root-cause
> mechanism allowing this runtime mismatch to bypass standard container lifecycle
> management, and how do we prevent runtime reconfiguration from orphaning high-privilege
> host processes?

### forensic_analysis (FORENSIC_LEAD — qwen3-coder-30b)

> The root cause is that `calico-typha` operates with `hostNetwork:true` and
> `privileged:true` in its pod specification […] Evidence: the `calico-typha` process
> (PID 4830) is running with `hostNetwork=true` and `privileged=true` in the pod spec
> [⚠️ EVIDENCIA ALUCINADA: el case file no decía nada de privileged] […] The kill command
> reports "container does not exist" because the runtime's process tracking is broken for
> host-networked privileged containers […] Proposed remediation: Implement a
> pre-runtime-change hook that explicitly kills and cleans up host-networked privileged
> processes before runtime transitions. Prevention rule: Prohibit `hostNetwork:true` and
> `privileged:true` combinations in pods managed by runtime operators.

### cross_examination (SKEPTIC — devstral-small-24b)

> The weakest link in the forensic hypothesis is the assumption that the
> `nvidia-container-runtime` transition *always* breaks when privileged host-networked
> processes are involved […] An alternative: after the operator rewrite, `cri-o`
> incorrectly caches PIDs for host-networked processes as if they were managed, but when
> queried by the new runtime, the PIDs now fail to match the host's cgroups/scope […]
> Discriminating evidence: one snapshot of the *host PID namespace* against
> `/proc/4830/ns` at the time of the runtime switch, showing whether the PID namespace is
> actually orphaned, or instead shows the host PID in the new cgroup tree but not yet
> reaped by systemd.

### cloud_expert (CLOUD_WITNESS — phi4-mini-aws, L4 time-sliced)

> Managed Kubernetes environments […] might have automated policies to handle runtime
> transitions that could have prevented this issue; however, these systems may also
> obscure direct visibility into underlying issues […] Adopting the operational practice
> of "Immutable Infrastructure," where all components are treated as replaceable rather
> than updated in place, can protect a hybrid fleet from runtime-configuration drift by
> ensuring that any change introduces a new environment and necessitates a deliberate and
> controlled update process.

### junior_fact_check (JUNIOR_INVESTIGATOR — smollm3-aws, L4 time-sliced)

> - Fact: `calico-typha` process (PID 4830) was running with `hostNetwork:true` and
>   `privileged:true` in the pod spec. [⚠️ canoniza la alucinación del forense]
> - Fact: `nvidia-container-runtime` failed to manage `calico-typha` process due to
>   elevated privileges and host network access.
> - Claim (not evidenced): The transition *always* breaks with privileged host-networked
>   processes […]
> - Claim (not evidenced): `cri-o` incorrectly caches PIDs […]
> - Alternative angle: Investigate whether the GPU Operator's runtime transition scripts
>   lack explicit checks for host-networked privileged processes.

### verdict (JUDGE — ernie-4.5-21b-a3b)

> The root-cause mechanism is the `nvidia-container-runtime` transition from `cri-o`
> fails to track host-networked privileged containers (e.g., `calico-typha`) due to their
> exclusion from standard lifecycle hooks, leaving them in the host's PID namespace and
> unkillable by new runtime commands.
> Remediation: Pre-transition hook to explicitly kill such containers.
> Prevention rule: Prohibit `hostNetwork:true` and `privileged:true` in
> runtime-operator-managed pods.
> Confidence: High; root cause is confirmed by evidence of host-networked privileged
> containers bypassing new runtime tracking. [⚠️ "High" sobre evidencia alucinada]
> Assumption: The root cause is the runtime transition not accounting for host-networked
> privileged containers, as supported by all forensic, skeptic, and junior evidence.

## Notas operativas de la run

- Time-slicing: perfil `l4-slice-2` añadido al ConfigMap `time-slicing-config` existente
  (ns `nvidia`) + label `nvidia.com/device-plugin.config=l4-slice-2` en el nodo. GOTCHA:
  GFD renombra el producto a `NVIDIA-L4-SHARED` → hubo que actualizar el nodeSelector del
  chart (pods Pending con "didn't match node affinity/selector").
- VRAM: 0.45+0.45 con 16k de contexto NO cabe ("No available memory for cache blocks"):
  pesos + overhead de CUDA graphs se comen el presupuesto. Reparto final: phi4 0.50 +
  smollm3 0.40, `maxModelLen` 8192, `--enforce-eager`.
- smollm3 es *thinking* por defecto y `/no_think` solo aplica en system prompt (el
  provider manda user): se le dio max_tokens 1536. En esta run el think salió vacío.
- Coste: g6 arrancada ~1h15 en total (incluye 2 iteraciones de debug del reparto VRAM);
  parada tras la ceremonia.
