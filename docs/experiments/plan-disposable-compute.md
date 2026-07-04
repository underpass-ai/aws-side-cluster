# Plan de ejecución — Disposable Compute, Persistent Evidence

Estado: aprobado 2026-07-04. Diseño en `disposable-compute-persistent-evidence.md`
(§27 decisiones, §28 hallazgo de los output contracts).

## Fase 0 — Infra prerequisito (este repo)

- **0.1 Reaper GPU de 5 min** (el título del artículo): daemon/timer en el PC
  que consulta Prometheus (`vllm:num_requests_running` de los backends de la
  L4 == 0 sostenido 300s, y sin pods no-Ready recientes) → `stop-instances` de
  la g6 + log del evento con timestamp (evidencia para la métrica
  `idle_shutdown_seconds`). Validar e2e: ceremonia → idle → auto-stop.
  Nota: separado del demand-gateway (señal = métricas, no HTTP).
- **0.2 Persistencia del decision artifact**: convención
  `s3://aws-side-poc-bootstrap-*/decisions/<decision_id>.json` (incluye
  trace_id, profile, claims, verdict del contract, worker_lifecycle). Escrito
  por el runner del experimento tras cada RunCeremony.
- **0.3 Reviewer en la L4** (load-bearing): decidir modelo (phi4-mini ya
  desplegado vs qwen3-coder-AWQ dedicado sin time-slicing) y fijarlo en
  values. El primary corre local.

## Fase 1 — Mejoras Choreographer (upstream, PRs)

- **1.1 Output contract en el step YAML** (`config.output_contract`: schema
  JSON inline o `contract_id` registrado) → `TaskConstraints.with_output_contract`.
  El rechazo ya existe (`NoValidProposal`); verificar que puede mapearse a un
  resultado de step que el FSM traduzca a `request_more_evidence`.
- **1.2 Validator de grounding**: `evidence_refs` de cada claim deben existir
  en el evidence pack del context; claim sin soporte → proposal inválida.
  (Nuevo `ValidatorPort` impl; el pipeline de validators ya corre por proposal.)
- **1.3 PR pequeña**: warning cuando `rounds > 0` y `num_agents < 2` (no-op
  silencioso, sufrido en csi-typha-appeal).
- **1.4 Atribución modelo↔llamada**: (a) nuestro llm-gateway loguea el modelo
  resuelto por request (nuestro repo, trivial); (b) span attribute con el
  modelo en el agente vllm del motor (PR).
- Backlog (no bloquea): agent kind `tool` (evidence collector nativo),
  council heterogéneo pinneado por agente, RPC reset del registry, release
  hygiene (chart OCI + imagen actualizados).

## Fase 2 — decision-trace-tui (Rust)

- `tools/decision-trace-tui/` (ratatui + reqwest): input `trace_id` →
  Tempo API (waterfall de spans), Loki API (logs filtrados por trace_id /
  ceremony_id), decision JSON (S3/fichero). Vistas: timeline de la decisión,
  claims con sus evidence_refs y veredicto, metadata del worker (nacimiento y
  muerte de la g6 en la misma pantalla que la decisión que ayudó a producir).
  Objetivo: la captura estrella + artefacto ejecutable por lectores.

## Fase 3 — Perfiles y ceremonias

- Evidence pack generator determinista (script: contexto del repo, trazas
  previas, snapshot de métricas → JSON al `context` del RunCeremony).
- 3 ceremonias YAML (lint con parser antes de correr):
  - **A** `single_model_freeform`: primary solo, sin contract.
  - **B** `single_model_evidence_gate`: primary + output contract + grounding.
  - **C** `evidence_bound_review`: primary local + skeptic en la L4 + contract.
- Las 5 tareas del §11 (decisiones técnicas reales del propio Choreographer).

## Fase 4 — Runs y medición

- 5 tareas × 3 perfiles (+ repeticiones del perfil C si hay presupuesto).
- Métricas infra: cold start (start→Ready→primer span, timestamps reales),
  GPU minutes (Prometheus/dcgm + uptime EC2), `trace_persisted_after_shutdown`.
- Métricas decisión: las del §12 + **evidence bytes vs GPU minutes** (§27.3).
- Cada run: decision JSON a S3 + trace_id anotado + g6 apagada por el reaper
  (no a mano — el apagado automático ES parte del experimento).

## Fase 5 — Artículo

- Reconstrucción en frío con el TUI (captura estrella) + waterfall Tempo +
  logs por trace_id + tabla real de los 3 perfiles.
- Dos hooks redactados y contrastados (§27.2). Inglés primero.

## Orden de ataque

0.1 (reaper) y 1.1 (contract YAML) en paralelo → 1.2 (grounding) → 3
(ceremonias A/B) → 2 (TUI, puede solapar con 3) → 0.3+C → 4 (runs) → 5.
