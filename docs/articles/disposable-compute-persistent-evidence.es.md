# Dejé que mis workers GPU se apagaran a los 5 minutos. Sus decisiones tenían que seguir siendo auditables.

> **BORRADOR v1 (castellano)** — 2026-07-04. Regla: nada inventado. Todo lo
> marcado `[TBD]` se rellena con datos de las runs del experimento (fase 4).
> Todo lo demás es real y tiene evidencia (trace_id, logs o commits).
> Traducción al inglés cuando el texto esté cerrado.

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
ceremonias), tres perfiles, `[TBD]` ejecuciones.

**La métrica estrella: `unsupported_claim_escape_count`** — cuántas
afirmaciones sin evidencia consiguieron llegar a la decisión final. No mide si
el modelo "suena bien". Mide si el sistema deja pasar mentiras.

## 6. Qué medí

*[TBD — tabla real tras las runs. Columnas ya fijadas:]*

| Perfil | Claims totales | Con evidencia | Escaped | Rechazadas | Traza sobrevive al shutdown | GPU-minutos cloud | Decisión final |
|---|---|---|---|---|---|---|---|
| A | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| B | TBD | TBD | TBD | TBD | TBD | TBD | TBD |
| C | TBD | TBD | TBD | TBD | TBD | TBD | TBD |

Más las de infraestructura: cold start del worker `[TBD]`s, tiempo hasta el
primer span `[TBD]`s, apagado por inactividad a los `[TBD]`s del último
request (el reaper registra cada muerte con timestamp).

Y una que me gusta especialmente: **bytes de evidencia persistida por
GPU-minuto consumido** `[TBD]`. El cómputo que produjo la decisión costó
`[TBD]`; conservar su registro completo cuesta `[TBD]`. La evidencia es
órdenes de magnitud más barata que el cómputo que la genera. Guardarla toda no
tiene excusa.

## 7. La reconstrucción (el momento que buscaba)

Escribí una herramienta de terminal en Rust — `decision-trace-tui` — cuyo
punto de entrada no es el cluster: es el **artefacto de decisión**, un JSON
persistido con el `trace_id`, el perfil, las claims y el ciclo de vida del
worker. Desde ahí reconstruye todo: el waterfall de spans desde Tempo, la
timeline de la deliberación desde Loki, y — el detalle que me importa —
consulta si el worker que ejecutó aquello **sigue existiendo**.

La primera reconstrucción real (mi ceremonia de apelación, un día después,
con la instancia g6 ya parada):

```text
== decision dec_2026_07_03_appeal ==
status: request_changes · trace: a5ed9c25… (204.4s, 8 spans)
worker: g6.xlarge i-084f… idle_shutdown=… alive_now=Some(false)
-- spans --
rpc.run_ceremony (204423.0ms)
  prepare_ceremony_participants (0.2ms)
  run_ceremony (204422.4ms)
    deliberate (137723.6ms)   ← el council de 3 rondas
    …
-- eventos (78) --
17:15:30 proposal drafted author=agent-appeal_engineers-0
17:15:40 peer critique and revision reviewer=engineers-0 round=1
…
```

El worker no existe. La decisión, entera — quién propuso qué, quién criticó a
quién y en qué ronda, qué validó cada validator — sí.

*[CAPTURA 2 aquí: el TUI completo con el footer "el worker GPU ya NO existe".
TBD: captura de una run del experimento, no de la apelación.]*

Una traza no es solo un artefacto de debugging. En un sistema de agentes,
puede ser parte del expediente de la decisión.

## 8. Resultados

*[TBD — sección completa tras las runs. Esqueleto:]*

- Tabla real de los tres perfiles (§6).
- `[TBD]` ejemplo real de claim rechazada por el juez-política, con el texto
  del veredicto del validator.
- `[TBD]` el decision artifact JSON completo de una run C.
- Limitaciones honestas: esto no es un benchmark científico de razonamiento;
  es un experimento de arquitectura operativa. n=`[TBD]` ejecuciones sobre 5
  tareas; los resultados hablan de este sistema, no de los LLMs en general.

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

- **Evidencia real ya disponible**: trace `a5ed9c258aa7bd21366f663241b2e7c9`
  (apelación, 204s), ceremonias en `choreographer/runs/*.md`, reaper
  `events.log`, PRs upstream #115 (banner NOTES), #116 (runbook
  observabilidad), #117 (runbook autoría), #118 (output contract en YAML),
  #119 (grounding validator: refs dinamicas del context via allowed_refs_from_context, fail-loud si el pack falta).
- **Decisión pendiente**: hook A vs B (probar con 2-3 lectores).
- **Capturas pendientes**: las 5 del §16 del diseño, todas de runs reales.
- **Título inglés**: "I Let My AI GPU Workers Shut Down After 5 Minutes.
  Their Decisions Still Had to Be Auditable."
- Frases §19 del diseño ya integradas; revisar que ninguna quede huérfana.
