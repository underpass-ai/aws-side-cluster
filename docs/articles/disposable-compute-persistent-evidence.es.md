# Dejé que mis workers GPU se apagaran a los 5 minutos. Sus decisiones tenían que seguir siendo auditables.

> **BORRADOR v2 (castellano)** — 2026-07-04. Regla cumplida: nada inventado.
> El experimento está EJECUTADO y todos los datos son reales (fuentes en
> `experiment/RESULTS.md`; cada cifra tiene artifact, trace_id o log).
> Pendiente: elegir hook A/B, capturas (comandos en el apéndice) y pasada
> editorial humana. Traducción al inglés cuando el texto esté cerrado.

---

## Hook — VERSIÓN A (la historia del fracaso) *[a contrastar con B]*

Mi fact-checker canonizó una mentira.

Había montado un panel de seis modelos de lenguaje para investigar un incidente
real de mi cluster: un proceso huérfano que retenía un puerto y que ni
Kubernetes ni el runtime podían matar. Le di al panel la evidencia cruda del
journal — sin la conclusión — y papeles: un forense, un escéptico, un perito,
un testigo junior cuyo único trabajo era separar hechos de conjeturas, y un
juez.

El forense (un modelo de 30B parámetros) afirmó que el pod tenía
`privileged: true` "según el spec". El expediente no decía eso en ninguna
parte. Se lo inventó.

El testigo junior — el modelo más pequeño del panel, 3B, cuya única función
era el fact-checking — lo escribió en su registro como **"Fact"**.

Y el juez dictó veredicto con confianza **"High"**, citando esa evidencia.

Cuando monté la apelación (dos councils, tres rondas de crítica adversarial
cruzada, la respuesta correcta revelada), fue peor: cada ronda de "critica la
propuesta de tu compañero" funcionó como "elabora más". Al final de la tercera
ronda, los councils proponían "capas de normalización semántica con PCA/UMAP"
y "umbrales para ruido por debajo de 20Hz". Nadie volvió a mirar la evidencia.

El problema no era cuántas voces tenía mi reunión de agentes. El problema era
que ninguna afirmación estaba obligada a apoyarse en evidencia — y todo el
aparato social del panel (crítica, revisión, fact-check, juez) amplificaba la
fluidez, no la verdad.

Así que cambié la pregunta.

## Hook — VERSIÓN B (arquitectural) *[a contrastar con A]*

Monté un cluster GPU híbrido para cargas agénticas.

La parte estable corre en local: una workstation con 4× RTX 3090. La parte
desechable corre en AWS: workers g6 con una NVIDIA L4 que arrancan rápido, se
unen al cluster por WireGuard, ejecutan trabajos acotados y se apagan solos a
los cinco minutos de inactividad.

Suena a una historia de optimización de costes.

No lo es.

La pregunta interesante no era si podía abaratar las GPUs en la nube. Era si
una decisión tomada por agentes de IA podía **seguir siendo auditable después
de que el worker que ayudó a producirla hubiera desaparecido**.

Dicho de otra forma:

El cómputo era desechable.
La evidencia no podía serlo.

---

## 1. La primera pregunta equivocada

*(Si gana el hook B, aquí va la historia CSI comprimida en tres párrafos; si
gana el A, esta sección se funde con el hook.)*

Mi primera versión usaba varios modelos pequeños y heterogéneos deliberando en
consejo. Producía salida — actas convincentes, veredictos con confianza alta.
Pero la traza enseñaba un problema más importante: estaba optimizando el
número de voces en vez de la calidad de la evidencia.

Los datos de esa etapa (reales, reproducibles en mi repo):

- Un panel de 6 modelos acertó la *clase* de causa raíz de un incidente real,
  pero fabricó por el camino la evidencia clave, y el mecanismo de
  fact-checking la consagró en vez de filtrarla.
- Tres rondas de peer review adversarial (12 críticas+revisiones, 31 llamadas
  LLM, trace `a5ed9c25…`) **aumentaron** la distancia entre las conclusiones
  y los hechos. El único participante que se mantuvo pegado a la evidencia fue
  el modelo más pequeño (3B) con el encargo más estrecho.
- El consenso no es evidencia. Una votación entre modelos sigue siendo solo
  una votación.

La conclusión operativa no fue "necesito mejores modelos". Fue:

**El problema no es que los agentes alucinen. El problema es dejar que las
afirmaciones sin soporte se conviertan en decisiones.**

## 2. La pregunta correcta

> ¿Puede un cluster híbrido efímero ejecutar una decisión de agentes y
> conservar suficiente telemetría, logs, métricas y evidencia para
> **reconstruir la decisión después de que los workers cloud se hayan
> apagado**?

Dos principios, repetidos a lo largo de todo el diseño:

**El cómputo es desechable. La evidencia es persistente.**

**El juez no es otro modelo. El juez es política.**

## 3. La arquitectura

```text
┌─────────────────────────────────────────────────┐
│         Control plane local (estable)           │
│         workstation 4× RTX 3090                 │
│  choreographer (motor de ceremonias, Rust)      │
│  llm-gateway (routing por labels k8s)           │
│  Prometheus · Tempo · Loki  ← capa de evidencia │
└────────────────────┬────────────────────────────┘
                     │ WireGuard (estrella)
                     ▼
┌─────────────────────────────────────────────────┐
│         Worker GPU efímero (AWS g6, L4)         │
│  arranca → join → sirve modelos → idle →        │
│  APAGADO AUTOMÁTICO a los 5 min sin peticiones  │
└────────────────────┬────────────────────────────┘
                     │ la telemetría sobrevive al worker
                     ▼
┌─────────────────────────────────────────────────┐
│         Capa de evidencia persistente           │
│  trazas (Tempo) · métricas (Prometheus)         │
│  logs (Loki) · decision artifact (JSON, S3)     │
└─────────────────────────────────────────────────┘
```

Detalles que importan (y que son el 80% del trabajo real):

- **El apagado no es un cron**: un reaper mide la señal real de uso
  (`vllm:num_requests_running` en Prometheus) porque el tráfico LLM in-cluster
  es invisible para un gateway HTTP. Cinco minutos a cero → stop. Cada apagado
  queda registrado con timestamps: el apagado es un dato del experimento, no
  una molestia.
- **La observabilidad no es opcional**: si el endpoint OTLP no está
  configurado, el chart del motor te lo grita en el install con un banner
  imposible de ignorar. (Ese banner es una PR nuestra al proyecto — nació de
  descubrir que llevábamos días corriendo deliberaciones sin exportar trazas.)
- **La IP pública del worker cambia en cada arranque**; el control-plane
  resincroniza el túnel. Los pesos de los modelos viven en S3 (clase Glacier
  con acceso inmediato) para que recrear el worker desde cero sea barato.

*[CAPTURA 1 aquí: panel de arranque — instancia starting → nodo Ready →
primer span OTEL. TBD tras las runs.]*

## 4. El perfil de reunión: Evidence-Bound Change Review

No es un "consejo multiagente". Es una revisión de cambios con evidencia
obligatoria:

- **evidence_collector** (determinista, no LLM): construye el evidence pack —
  contexto del repo, trazas previas, métricas. Los agentes solo pueden citar
  lo que está en el pack.
- **primary_engineer** (LLM, local): propone la decisión con claims, riesgos y
  `evidence_refs`.
- **skeptical_reviewer** (LLM, **en el worker efímero**): ataca las claims sin
  soporte. No sintetiza; solo objeta o acepta.
- **deterministic_judge** (motor de políticas, **no es un modelo**): valida
  esquema, campos obligatorios, que cada claim tenga `evidence_refs` que
  existan en el pack. Puede rechazar la decisión entera o pedir más evidencia.

Sin votación por mayoría. Sin consenso. Una claim sin evidencia no llega a la
decisión final: el contrato la mata antes.

Esto no es un diseño en papel: el motor (open source) ya tenía el aparato de
contratos de salida y el rechazo determinista (`NoValidProposal`); lo que
faltaba era poder declararlo en el YAML de la ceremonia y el validator de
grounding. Son las dos PRs que abrimos durante el experimento *(#118, #[TBD
grounding])* — el "juez-política" es cableado, no ciencia ficción.

## 5. Los tres perfiles comparados

La comparación es de **gobernanza**, no de modelos:

| Perfil | Modelos | Evidencia obligatoria | Juez determinista |
|---|---|---|---|
| A `single_model_freeform` | 1 | no | no |
| B `single_model_evidence_gate` | 1 | sí | sí |
| C `evidence_bound_review` | 2 (uno en el worker efímero) | sí | sí |

Cinco tareas de revisión reales (decisiones de diseño del propio motor de
ceremonias), tres perfiles, 15 ejecuciones.

**La métrica estrella: `unsupported_claim_escape_count`** — cuántas
afirmaciones sin evidencia consiguieron llegar a la decisión final. No mide si
el modelo "suena bien". Mide si el sistema deja pasar mentiras.

## 6. Qué medí

Los resultados reales (2026-07-04; cada fila sale de artifacts persistidos con
su trace_id):

| Perfil | Claims totales | Con evidencia | **Escaped** | Traza sobrevive al shutdown | Decisiones |
|---|---|---|---|---|---|
| A freeform | 14 | 0 | **14** | sí | 4 accept · 1 reject |
| B evidence gate | 18 | 18 | **0** | sí | 4 accept · 1 reject |
| C evidence-bound review | 18 | 18 | **0** | sí | 3 accept · **2 reject** |

El baseline hizo exactamente lo que se temía: **las 14 claims del perfil A
llegaron a la decisión sin una sola referencia a evidencia**. Con el contrato
activado, cero de treinta y seis. Y el dato que no esperaba: **con la misma
evidencia, la tarea 1 fue `accept` en B y `reject` en C** — las objeciones
del escéptico (que corría en el worker efímero) cambiaron el veredicto, no
solo lo decoraron.

Infraestructura, medida con timestamps:

- Cold start: petición de arranque → instancia running **77s** → reviewer
  sirviendo inferencia **306s**.
- Las 5 decisiones del perfil C (3 pasos cada una): **92 segundos** en total.
- **Apagado autónomo**: el reaper mató el worker a las 13:23:11 tras 350s de
  inactividad medida (la primera línea real de su `events.log`:
  `idle_shutdown instances=i-084f… idle_for=350s`).
- Vida total del worker: **15,5 GPU-minutos** (~0,12 USD).

Y la que más me gusta: **~32 KB de evidencia persistida** conservan el
registro completo de decisiones que costaron 15,5 GPU-minutos producir. La
evidencia es órdenes de magnitud más barata que el cómputo que la genera.
Guardarla toda no tiene excusa.

## 7. La reconstrucción (el momento que buscaba)

Escribí una herramienta de terminal en Rust — `decision-trace-tui` — cuyo
punto de entrada no es el cluster: es el **artefacto de decisión**, un JSON
persistido con el `trace_id`, el perfil, las claims y el ciclo de vida del
worker. Desde ahí reconstruye todo: el waterfall de spans desde Tempo, la
timeline de la deliberación desde Loki, y — el detalle que me importa —
consulta si el worker que ejecutó aquello **sigue existiendo**.

La reconstrucción de la tarea 1 del perfil C, con el worker YA MUERTO — y
muerto por decisión propia del sistema (el reaper, no yo):

```text
== decision exp-task-1-c-r1-131151 (evidence_bound_review) ==
status: reject · trace: 80157a56… (6.9s, 6 spans)
claims: 1 total, 1 con evidencia, 0 ESCAPED
worker: g6.xlarge i-084f… idle_shutdown=true alive_now=Some(false)
-- spans --
rpc.run_ceremony (6933.7ms)
  run_ceremony (6933.3ms)
    deliberate (1604.4ms)   ← primary propone (local)
    deliberate (3989.1ms)   ← el escéptico objeta (desde la L4)
    deliberate (1339.6ms)   ← revisión final contra el contrato
-- eventos (33) --
11:11:52 validator=claims-evidence-grounded passed=true
         verdict=all 2 claims grounded in the evidence pack (5 allowed refs)
11:11:56 proposal drafted author=agent-skeptic_c-0
…
```

El worker no existe. La decisión, entera — quién propuso qué, qué objetó el
escéptico, qué validó el juez-política claim a claim — sí.

*[CAPTURA 2 aquí: el TUI completo sobre esta decisión, footer verde "el
worker GPU ya NO existe". Comando listo en el apéndice.]*

Una traza no es solo un artefacto de debugging. En un sistema de agentes,
puede ser parte del expediente de la decisión.

## 8. Resultados

La tabla del §6 es el resultado principal: **0/36 claims sin evidencia
llegaron a una decisión final en los perfiles con contrato, contra 14/14 en
el baseline**. Tres piezas más completan el expediente:

**El escéptico bloqueando de verdad** (output real del reviewer en la L4,
tarea 1): el primary proponía aceptar; el reviewer respondió:

> OBJECTION to "ev-t1-csi-fabrication" — the term 'privileged:true in the pod
> spec' is mentioned without context; may require further clarification. […]
> **BLOCKING overall.** Non-blocking decisions are too risky with partial
> evidence; we seek definitive proof before making a non-rejection motion.

La decisión final fue `reject`. En el perfil B, sin reviewer, la misma
evidencia terminó en `accept`. El worker efímero no participó de adorno.

**El juez-política matando propuestas de verdad**: en las primeras runs, el
gate rechazó como `NoValidProposal` propuestas *bien fundadas* — porque los
modelos envolvían el JSON en fences markdown pese a prompts explícitos en
contra (devstral: siempre; qwen3: el 60% de las runs). Es la anécdota más
honesta del experimento: un policy gate estricto primero te enseña cuánto de
tu pipeline depende de cosmética de transporte. Lo resolvimos en el motor
(los validators toleran payloads *puramente* fenceados — PR #120), porque la
alternativa era que el gate midiera obediencia de formato en vez de calidad
de evidencia.

**El decision artifact real** (tarea 1, perfil C, tal como está en S3):

```json
{
  "decision_id": "exp-task-1-c-r1-131151",
  "trace_id": "80157a56cf6cc30994585d31b1cc1a6f",
  "profile": "evidence_bound_review",
  "status": "reject",
  "final_claims_total": 1,
  "claims_with_evidence": 1,
  "unsupported_claim_escape_count": 0,
  "worker_lifecycle": {
    "instance_family": "g6.xlarge",
    "ephemeral": true,
    "idle_shutdown_triggered": true,
    "stopped_at": "2026-07-04T13:23:11+02:00",
    "idle_shutdown_evidence": "gpu-idle-reaper events.log: idle_for=350s"
  },
  "observability": {
    "otel_trace_exported": true,
    "logs_exported": true,
    "metrics_exported": true
  }
}
```

**Limitaciones honestas**: esto no es un benchmark científico de
razonamiento; es un experimento de arquitectura operativa. n=15 ejecuciones
sobre 5 tareas y una repetición; los resultados hablan de este sistema, no de
los LLMs en general. `rejected_claims` va a cero en todos los perfiles porque
el gate actual rechaza propuestas enteras, no claims individuales (el estado
`request_more_evidence` como transición de primera clase es trabajo futuro
anotado en la PR #118). Y el "5 minutos" del titular es el contador de idle:
en sesiones cortas, el periodo de gracia post-arranque (10 min, para no matar
la carga de modelos) domina el tiempo total hasta el apagado.

## 9. Qué cambió en mi cabeza

Menos agentes.
Contratos más fuertes.
Evidencia antes que síntesis.
Política antes que consenso.
La observabilidad como infraestructura de la decisión, no como monitoring.

La frase que me llevo: dejé de optimizar el número de agentes y empecé a
medir la calidad de la evidencia.

## 10. Qué viene después

- Un policy gate que transicione la ceremonia a `request_more_evidence` como
  estado de primera clase (hoy el rechazo mata el step; la transición
  explícita está anotada como trabajo futuro en la PR).
- Modelos más grandes como reviewer puntual — me tienta Ornith-35B como
  primary local cuando esté maduro.
- Un nodo appliance portátil como tercer plano de cómputo.

---

## Apéndice para la redacción (no publicar)

- **TODOS los datos rellenados con las runs del 2026-07-04** (fuentes:
  `experiment/RESULTS.md`, artifacts en `experiment/runs/` + S3 `decisions/`,
  reaper `~/.local/state/gpu-idle-reaper/events.log`). Sin TBD de datos.
- **Decisión pendiente**: hook A vs B (probar con 2-3 lectores).
- **PRs upstream**: #115 banner NOTES · #116 runbook observabilidad · #117
  runbook autoría · #118 output contract YAML · #119 grounding validator ·
  #120 tolerancia a fences. Las 3 últimas SON el juez-política.
- **Capturas pendientes (comandos listos)**:
  1. TUI reconstrucción (LA captura):
     `TEMPO=$(kubectl -n monitoring get svc tempo -o jsonpath='{.spec.clusterIP}'); LOKI=$(kubectl -n monitoring get svc loki -o jsonpath='{.spec.clusterIP}'); ./tools/decision-trace-tui/target/debug/decision-trace-tui experiment/runs/exp-task-1-c-r1-131151/decision.json --tempo http://$TEMPO:3200 --loki http://$LOKI:3100`
  2. Waterfall en Grafana → Tempo, trace `80157a56cf6cc30994585d31b1cc1a6f`
     (o `4c4bd9f6…` task-2 C, más spans).
  3. Loki en Grafana: `{namespace="underpass-labs", pod=~"choreographer.*"} |= "exp-task-1-c-r1-131151"` — se ve el veredicto del gate por claim.
  4. Decision JSON: ya embebido en §8 (real).
  5. Métricas: panel Prometheus `vllm:num_requests_running` de 13:06–13:24
     (se ve la actividad del batch C y el silencio que mató al worker).
- **Título inglés**: "I Let My AI GPU Workers Shut Down After 5 Minutes.
  Their Decisions Still Had to Be Auditable."
- Frases §19 del diseño ya integradas; revisar que ninguna quede huérfana.
