# Disposable GPUs, Persistent Evidence

**Propuesta de experimento y artículo para Underpass Choreographer**  
**Estado:** draft editorial + diseño experimental  
**Objetivo:** convertir el cluster híbrido efímero + Underpass Choreographer + observabilidad en un artículo coherente, técnico y con gancho.

---

## 1. Tesis central

El artículo no debería ir de “he montado un cluster híbrido”. Eso es interesante, pero no suficiente.

La tesis fuerte es:

> **The GPU worker can disappear. The decision trace cannot.**

Versión española:

> **El worker GPU puede desaparecer. La traza de decisión no.**

La idea larga:

> No estoy construyendo un sistema multiagente para que varios modelos opinen. Estoy construyendo una infraestructura donde una decisión de agentes pueda ejecutarse en cómputo efímero, quedar observada con OpenTelemetry, persistirse en métricas y logs, y ser reconstruible después de que los workers hayan desaparecido.

---

## 2. Qué hacer con el experimento anterior

El experimento anterior de varios modelos pequeños casi debería descartarse como núcleo del artículo.

No conviene centrar el post en:

- seis modelos pequeños;
- reunión tipo council abierta;
- votación o consenso;
- juez LLM como autoridad final;
- benchmark artesanal de “qué reunión responde mejor”;
- comparativa de modelos sin dataset amplio;
- afirmaciones fuertes sobre reducción de alucinaciones sin un método claro de medición.

Sí conviene conservarlo como detonante narrativo:

> My first version used several small heterogeneous models. It produced output, but the trace showed a more important problem: I was optimizing the number of voices instead of the quality of evidence.

Versión española:

> Mi primera versión usaba varios modelos pequeños y heterogéneos. Producía salida, pero la traza enseñó un problema más importante: estaba optimizando el número de voces en vez de la calidad de la evidencia.

---

## 3. Artículo recomendado

### Título principal recomendado

```text
I Let My AI GPU Workers Shut Down After 5 Minutes. Their Decisions Still Had to Be Auditable.
```

### Alternativas

```text
Disposable GPUs, Persistent Evidence: Building an Auditable AI Agent Cluster
```

```text
A Hybrid GPU Cluster for AI Agents That Can Explain Itself After It Shuts Down
```

```text
Stop Counting Agents. Start Auditing Decisions.
```

```text
The Cloud Worker Disappeared. The Decision Trace Did Not.
```

### Recomendación editorial

Publicar primero en inglés si el objetivo es maximizar lecturas en DEV.to y LinkedIn técnico internacional.

Después se puede hacer una versión española más reflexiva, enfocada en arquitectura y gobernanza de agentes.

---

## 4. Pregunta experimental

La pregunta correcta no es:

```text
¿Cuántos modelos necesito para que la reunión alucine menos?
```

La pregunta correcta es:

```text
Can an ephemeral hybrid GPU cluster execute an AI-agent decision workflow and preserve enough telemetry, logs, metrics and evidence to reconstruct the decision after the cloud workers have shut down?
```

Versión española:

```text
¿Puede un cluster híbrido efímero ejecutar una decisión de agentes y conservar suficiente telemetría, logs, métricas y evidencia para reconstruir la decisión después de que los workers cloud se hayan apagado?
```

---

## 5. Nombre del experimento

```text
Experiment: Disposable Compute, Persistent Evidence
```

Subtítulo:

```text
Running auditable AI-agent decisions on a hybrid GPU cluster with ephemeral cloud workers.
```

---

## 6. Arquitectura narrativa del experimento

```text
┌─────────────────────────────────────────────────────────┐
│                 Local Control Plane                      │
│                4×RTX 3090 workstation                    │
│                                                         │
│  - Underpass Choreographer                               │
│  - policy engine                                         │
│  - model gateway                                         │
│  - OpenTelemetry collector/exporter                      │
│  - time-series pipeline                                  │
│  - Loki/Roki logs                                        │
│  - persistent evidence store                             │
└───────────────────────┬─────────────────────────────────┘
                        │
                        │ wakes / schedules / observes
                        v
┌─────────────────────────────────────────────────────────┐
│                 AWS G6 Ephemeral Workers                 │
│                                                         │
│  - join hybrid cluster                                   │
│  - run bounded model/review jobs                         │
│  - export traces/logs/metrics                            │
│  - become idle                                           │
│  - stop after 5 minutes                                  │
└───────────────────────┬─────────────────────────────────┘
                        │
                        │ telemetry survives worker shutdown
                        v
┌─────────────────────────────────────────────────────────┐
│                 Persistent Evidence Layer                │
│                                                         │
│  - traces                                                │
│  - time series                                           │
│  - logs                                                  │
│  - decision JSON                                         │
│  - evidence refs                                         │
│  - model invocation metadata                             │
└─────────────────────────────────────────────────────────┘
```

Nota editorial: si el componente se llama exactamente **Roki**, mantenerlo. Si es **Loki**, corregirlo para evitar confusión técnica.

---

## 7. Principio arquitectónico

```text
Compute is disposable.
Evidence is persistent.
```

Versión española:

```text
El cómputo es desechable.
La evidencia es persistente.
```

Este principio debe aparecer varias veces en el artículo.

---

## 8. Perfil de reunión recomendado

No llamarlo “multi-agent council”. Usar un nombre más serio:

```text
Evidence-Bound Change Review
```

### YAML conceptual

```yaml
meeting_profile:
  name: evidence_bound_change_review
  purpose: "Review a bounded technical change using evidence, not consensus"
  majority_vote: false
  consensus_required: false
  require_evidence_refs: true
  allow_unsupported_final_claims: false
  max_rounds: 2

roles:
  evidence_collector:
    type: deterministic_tools
    responsibilities:
      - collect_repository_context
      - collect_previous_traces
      - collect_logs
      - collect_metrics
      - build_evidence_pack

  primary_engineer:
    type: llm
    responsibilities:
      - propose_architecture_decision
      - reference_evidence
      - list_assumptions
      - list_risks

  skeptical_reviewer:
    type: llm
    responsibilities:
      - challenge_unsupported_claims
      - identify_missing_evidence
      - request_changes_when_needed

  deterministic_judge:
    type: policy_engine
    responsibilities:
      - reject_claims_without_evidence
      - validate_schema
      - validate_required_fields
      - validate_trace_completeness
      - produce_final_decision
```

Frase clave:

```text
The judge is not another model. The judge is policy.
```

Versión española:

```text
El juez no es otro modelo. El juez es política.
```

---

## 9. Modelos recomendados

No centrar el artículo en benchmarks de modelos. Los modelos son parte del experimento, no el tema principal.

### Configuración recomendada para el artículo

```yaml
models:
  primary_engineer:
    model: Ornith-1.0-35B
    role: proposal_generation
    target: local_4x3090
    notes:
      - modelo principal para propuesta técnica
      - usar con temperatura baja o moderada
      - salida estructurada con claims, risks y evidence_refs

  skeptical_reviewer:
    model: Qwen3-Coder-30B-A3B-Instruct
    role: claim_challenge
    target: aws_g6_or_local_quantized
    notes:
      - revisor escéptico
      - no sintetiza respuesta final
      - solo objeta, pide evidencia o acepta parcialmente

  deterministic_judge:
    model: none
    role: final_decision_gate
    target: underpass_policy_engine
    notes:
      - no es LLM
      - valida esquema, evidencias, métricas y trazabilidad
      - puede rechazar la decisión o pedir más evidencia
```

### Qué dejar fuera del artículo principal

- Ornith 397B: mencionarlo solo como posible teacher/reviewer futuro.
- DSpark: no meterlo; distrae del mensaje.
- ASUS GB10: mencionarlo al final como siguiente fase/appliance portátil, no como protagonista.

---

## 10. Perfiles a comparar

La comparación debe ser de **gobernanza**, no de número de modelos.

### Profile A — Single model freeform

```yaml
profile_a:
  name: single_model_freeform
  models:
    - primary_engineer
  evidence_required: false
  deterministic_judge: false
  expected_value:
    - baseline simple
    - rápido
    - riesgo de claims sin evidencia
```

### Profile B — Single model with evidence gate

```yaml
profile_b:
  name: single_model_evidence_gate
  models:
    - primary_engineer
  evidence_required: true
  deterministic_judge: true
  expected_value:
    - mide el efecto de exigir evidencia
    - reduce claims finales no soportados
    - puede terminar en request_more_evidence
```

### Profile C — Strong model + skeptic + evidence gate

```yaml
profile_c:
  name: evidence_bound_review
  models:
    - primary_engineer
    - skeptical_reviewer
  evidence_required: true
  deterministic_judge: true
  expected_value:
    - añade revisión crítica
    - detecta missing evidence
    - fuerza decisiones más auditables
```

Mensaje esperado:

```text
Adding more agents was not the interesting part. Adding evidence constraints was.
```

Versión española:

```text
Añadir más agentes no era lo interesante. Añadir restricciones de evidencia sí.
```

---

## 11. Tareas del experimento

No usar tareas inventadas demasiado artificiales. Usar decisiones técnicas pequeñas, reales y relacionadas con Underpass Choreographer.

### Task 1

```text
Review whether Choreographer should reject final claims without evidence_refs.
```

### Task 2

```text
Review whether the final judge should be deterministic policy or LLM-as-judge.
```

### Task 3

```text
Review whether AWS G6 workers should be allowed to execute stateful model jobs.
```

### Task 4

```text
Review whether model responses should be persisted raw, summarized, or both.
```

### Task 5

```text
Review whether reviewer objections should block final acceptance or only lower confidence.
```

### Número de ejecuciones recomendado

```yaml
runs:
  tasks: 5
  repetitions_per_task: 3
  total_executions: 15
```

Esto es suficiente para un artículo técnico honesto sin venderlo como benchmark científico exhaustivo.

---

## 12. Métricas a capturar

### Infraestructura

```yaml
infrastructure_metrics:
  worker_cold_start_seconds:
    description: "Time from activation request to worker ready"

  worker_join_seconds:
    description: "Time from boot to cluster registration"

  first_trace_span_seconds:
    description: "Time until the first OTEL span appears"

  meeting_execution_seconds:
    description: "Total time from ceremony start to final decision"

  idle_shutdown_seconds:
    description: "Time from last activity to worker shutdown"

  cloud_gpu_minutes:
    description: "GPU minutes consumed by ephemeral workers"

  local_gpu_minutes:
    description: "GPU minutes consumed by local node"

  trace_persisted_after_shutdown:
    description: "Whether the full decision trace is readable after the worker stops"
```

### Decisión

```yaml
decision_metrics:
  final_claims_total:
    description: "Total claims in the final decision"

  claims_with_evidence:
    description: "Claims that reference concrete evidence"

  claims_without_evidence:
    description: "Claims without evidence references"

  rejected_claims:
    description: "Claims rejected by policy or reviewer"

  unsupported_claim_escape_count:
    description: "Unsupported claims that reached the final decision"

  tool_calls_total:
    description: "Number of tool calls executed"

  tool_call_failures:
    description: "Failed tool calls"

  reviewer_objections_total:
    description: "Total objections raised by the skeptical reviewer"

  reviewer_objections_accepted:
    description: "Reviewer objections accepted by the policy judge"

  final_decision:
    allowed_values:
      - accept
      - reject
      - request_changes
      - request_more_evidence
```

### Métrica estrella

```text
unsupported_claim_escape_count
```

Explicación:

```text
No mide si el modelo “suena bien”. Mide cuántas afirmaciones sin evidencia consiguieron llegar a la decisión final.
```

---

## 13. Criterios de éxito

```yaml
success_criteria:
  - "Every meeting produces a trace_id"
  - "Every final decision is reconstructable after the AWS worker shuts down"
  - "Every final claim has at least one evidence_ref"
  - "unsupported_claim_escape_count == 0"
  - "If evidence is insufficient, the final decision must be request_more_evidence"
  - "Worker shutdown does not delete decision evidence"
  - "The article includes at least one real trace screenshot"
  - "The article includes one metrics table from real runs"
```

Criterio central:

```text
I should be able to reconstruct the decision using only telemetry, logs, metrics and the persisted decision artifact after the cloud worker has stopped.
```

---

## 14. Tabla de resultados a publicar

No inventar datos. Ejecutar el experimento y rellenar.

```markdown
| Profile | Models | Evidence required | Deterministic judge | Unsupported claims escaped | Rejected claims | Trace survived shutdown | Cloud GPU minutes | Final decision quality |
|---------|--------|-------------------|---------------------|----------------------------|-----------------|-------------------------|-------------------|------------------------|
| A       | 1      | No                | No                  | TBD                        | TBD             | TBD                     | TBD               | TBD                    |
| B       | 1      | Yes               | Yes                 | TBD                        | TBD             | TBD                     | TBD               | TBD                    |
| C       | 2      | Yes               | Yes                 | TBD                        | TBD             | TBD                     | TBD               | TBD                    |
```

---

## 15. Artefacto de decisión esperado

Ejemplo de salida persistida. Usar datos reales en el artículo.

```json
{
  "decision_id": "dec_2026_07_04_001",
  "trace_id": "7e5c4e8f6a3f9c01",
  "profile": "evidence_bound_review",
  "status": "request_changes",
  "final_claims_total": 12,
  "claims_with_evidence": 12,
  "claims_without_evidence": 0,
  "rejected_claims": 4,
  "unsupported_claim_escape_count": 0,
  "worker_lifecycle": {
    "provider": "aws",
    "instance_family": "g6",
    "ephemeral": true,
    "idle_shutdown_triggered": true
  },
  "observability": {
    "otel_trace_exported": true,
    "metrics_exported": true,
    "logs_exported": true,
    "decision_reconstructable_after_shutdown": true
  }
}
```

---

## 16. Capturas imprescindibles

El artículo debe enseñar evidencia real, no solo diagramas.

### Captura 1 — Cluster wake-up

Panel donde se vea:

- AWS G6 worker starting;
- worker registered;
- first job assigned;
- first OTEL span emitted.

### Captura 2 — Trace waterfall

Una traza de Choreographer con spans:

```text
ceremony.started
evidence_pack.created
primary_model.invoked
proposal.generated
reviewer.invoked
review.completed
policy_gate.evaluated
decision.persisted
worker.idle
worker.stopped
```

### Captura 3 — Loki/Roki logs

Logs filtrados por `trace_id` mostrando:

- claim extracted;
- evidence_ref attached;
- unsupported claim rejected;
- final decision emitted.

### Captura 4 — Decision JSON

Mostrar el artefacto de decisión final.

### Captura 5 — Metrics table

Tabla o panel con:

- cold start;
- cloud GPU minutes;
- claims with evidence;
- rejected claims;
- unsupported claim escape count.

---

## 17. Estructura final del artículo

### 1. Hook

```text
I built a hybrid GPU cluster for AI agents.
The cloud workers shut down after 5 minutes of inactivity.
That created a new rule: compute can disappear, evidence cannot.
```

### 2. The wrong first question

Explicar brevemente que la primera intuición fue ajustar la reunión con varios modelos.

```text
More models, more opinions, more diversity.
But the problem was not the number of voices.
The problem was whether final claims were supported by evidence.
```

### 3. The architecture

Describir:

- nodo local 4×3090 como control plane estable;
- AWS G6 como workers efímeros;
- Underpass Choreographer como coordinador de decisiones;
- OpenTelemetry, series temporales y Loki/Roki como sustrato de evidencia.

### 4. The experiment

Describir el experimento:

- ejecutar una revisión técnica evidence-bound;
- dejar participar a workers efímeros;
- persistir trazas, métricas, logs y artefacto de decisión;
- apagar workers tras inactividad;
- reconstruir decisión después.

### 5. The meeting profile

Explicar:

- evidence collector;
- primary model;
- skeptical reviewer;
- deterministic judge;
- no majority vote;
- no unsupported final claims.

### 6. What I measured

Incluir métricas:

- cold start;
- time to first span;
- model latency;
- claims with evidence;
- rejected claims;
- unsupported claims escaped;
- GPU minutes;
- trace survival after shutdown.

### 7. Results

Incluir:

- tabla real;
- capturas reales;
- trace_id real;
- decision JSON real;
- limitaciones honestas.

### 8. What changed in my thinking

Mensaje:

```text
Fewer agents.
Stronger contracts.
Evidence before synthesis.
Policy before consensus.
Observability as decision infrastructure.
```

### 9. What comes next

Mencionar sin expandir demasiado:

- ASUS GB10 como nodo portátil/appliance;
- Ornith 35B como operador local;
- modelos más grandes como teacher/reviewer puntual;
- DSpark/speculative decoding como optimización futura, no core del artículo.

---

## 18. Primeros párrafos sugeridos

```markdown
# I Let My AI GPU Workers Shut Down After 5 Minutes. Their Decisions Still Had to Be Auditable.

I built a hybrid GPU cluster for agentic workloads.

The stable part runs locally on a 4×RTX 3090 node. The disposable part runs on AWS G6 workers that can start quickly, join the cluster, execute bounded jobs, and stop after five minutes of inactivity.

That sounds like a cost optimization story.

It is not.

The interesting question was not whether I could make cloud GPUs cheaper. The interesting question was whether an AI-agent decision could remain auditable after the worker that helped produce it had disappeared.

In other words:

The compute was disposable.
The evidence was not.
```

---

## 19. Frases fuertes para repartir por el artículo

```text
The problem was not that agents hallucinate. The problem was letting unsupported claims become decisions.
```

```text
Consensus is not evidence. A majority vote between models is still just a vote.
```

```text
The judge is not another model. The judge is policy.
```

```text
The cloud worker is allowed to disappear. The decision trace is not.
```

```text
Observability is not only for uptime. In agent systems, observability is part of governance.
```

```text
I stopped optimizing the number of agents and started measuring the quality of evidence.
```

```text
A trace is not just a debugging artifact. In an agent system, it can become part of the decision record.
```

---

## 20. Qué no meter en el artículo principal

Evitar:

- benchmarks genéricos de modelos;
- explicación larga de Ornith 397B;
- DSpark;
- ASUS GB10 como pieza central;
- detalles excesivos de Kubernetes;
- coste exacto por instancia como argumento principal;
- seis modelos pequeños como experimento principal;
- “mi sistema reduce alucinaciones” sin explicar cómo se mide;
- comparativas grandilocuentes sin dataset.

---

## 21. Qué sí meter

Incluir:

- arquitectura híbrida;
- apagado por inactividad;
- Underpass Choreographer;
- OpenTelemetry;
- time series;
- Loki/Roki;
- trace_id por decisión;
- evidence_refs;
- rejected_claims;
- unsupported_claim_escape_count;
- screenshot real de Grafana/Tempo;
- screenshot real de logs por trace_id;
- decision artifact JSON;
- tabla con tres perfiles comparados.

---

## 22. Mini-serie recomendada

### Artículo 1

```text
I Let My AI GPU Workers Shut Down After 5 Minutes. Their Decisions Still Had to Be Auditable.
```

Tema:

```text
hybrid cluster + ephemeral compute + persistent evidence + Choreographer + OTel
```

Este es el artículo con más potencial de visitas.

### Artículo 2

```text
Stop Counting Agents. Start Auditing Claims.
```

Tema:

```text
meeting profiles, evidence gates, primary model + skeptical reviewer, claims_without_evidence
```

---

## 23. Checklist antes de publicar

```markdown
- [ ] Confirmar naming exacto: Loki o Roki.
- [ ] Ejecutar 15 runs: 5 tareas × 3 repeticiones.
- [ ] Guardar trace_id de cada run.
- [ ] Exportar una captura limpia de trace waterfall.
- [ ] Exportar una captura limpia de métricas.
- [ ] Exportar logs filtrados por trace_id.
- [ ] Generar tabla real de resultados.
- [ ] Sustituir todos los TBD por datos reales.
- [ ] Evitar claims no medidos.
- [ ] Incluir limitaciones explícitas.
- [ ] Publicar en inglés primero si el objetivo son visitas.
- [ ] Reutilizar la versión española para LinkedIn o segundo post.
```

---

## 24. Limitaciones que conviene reconocer

```text
This is not a scientific benchmark of LLM reasoning.
It is an operational architecture experiment.
```

```text
The goal is not to prove that one model is better than another.
The goal is to prove that agent decisions can be executed on disposable compute while preserving an auditable decision record.
```

Versión española:

```text
Esto no es un benchmark científico de razonamiento de LLMs.
Es un experimento de arquitectura operativa.
```

```text
El objetivo no es demostrar que un modelo sea mejor que otro.
El objetivo es demostrar que las decisiones de agentes pueden ejecutarse en cómputo desechable conservando un registro auditable.
```

---

## 25. Decisión final

La recomendación cerrada es:

```text
Descartar el experimento anterior como benchmark.
Conservarlo solo como motivación narrativa.

Hacer un experimento nuevo:
Disposable Compute, Persistent Evidence.

Demostrar:
Un worker AWS G6 puede arrancar, participar en una decisión de agentes,
emitir OpenTelemetry/logs/métricas, apagarse por inactividad,
y aun así dejar una decisión reconstruible y auditable.

Usar:
- Ornith 35B como primary;
- Qwen3-Coder-30B-A3B como skeptical reviewer;
- Underpass policy engine como deterministic judge;
- OTel + time series + Loki/Roki como evidencia persistente.

Medir:
- cold start;
- GPU minutes;
- time to first span;
- claims_with_evidence;
- rejected_claims;
- unsupported_claim_escape_count;
- trace_persisted_after_shutdown.

Título recomendado:
I Let My AI GPU Workers Shut Down After 5 Minutes. Their Decisions Still Had to Be Auditable.
```

---

## 26. Resumen en una frase

```text
This article should not sell a multi-agent system. It should show an auditable decision system running on disposable GPU compute.
```

Versión española:

```text
Este artículo no debe vender un sistema multiagente. Debe mostrar un sistema de decisiones auditables ejecutándose sobre cómputo GPU desechable.
```
