# Run: csi_typha_appeal — 2026-07-03

**La reunión compleja**: apelación del caso typha con **réplicas reales** — dos councils de
2 agentes con `rounds: 3` (peer review circular del motor: el agente *i* critica Y revisa
la propuesta del *i+1*, 3 rondas), mezclando modelos **por llamada** vía alias de rol del
llm-gateway (council técnico `role:coding` = qwen↔devstral; contrapericia `role:general` =
gemma local 26B ↔ phi4 en la L4 de AWS). Al panel se le reveló su veredicto fallido de la
mañana Y la causa real, y tuvo que deliberar por qué su investigación falló.

`finalState: CLOSED`, 5/5 steps. ceremony_id `csi-typha-appeal-1`.
**Primera ceremonia con traza distribuida completa**: Tempo `a5ed9c258aa7bd21366f663241b2e7c9`
(204s, spans de cada draft/critique/revise). Duración total ~3,5 min para **31 llamadas LLM**.

## Intervenciones por participante (evidencia Loki: `proposal drafted` + `peer critique and revision`)

| Agente | Modelo(s) | Drafts | Críticas+revisiones | Total turnos |
|---|---|---|---|---|
| appeal_moderator | gemma-4-26b | 1 | — | 1 |
| appeal_engineers-0 | qwen↔devstral (por llamada) | 1 | 3 | 4 |
| appeal_engineers-1 | qwen↔devstral (por llamada) | 1 | 3 | 4 |
| appeal_experts-0 | gemma↔phi4-aws (por llamada) | 1 | 3 | 4 |
| appeal_experts-1 | gemma↔phi4-aws (por llamada) | 1 | 3 | 4 |
| appeal_junior (clerk) | smollm3-aws (L4) | 1 | — | 1 |
| appeal_judge | ernie-4.5-21b-a3b | 1 | — | 1 |
| **Total** | 6 modelos, 2 nodos | **7** | **12** | **19** |

## El hallazgo (oro para el artículo)

**Las rondas adversariales sin validador de grounding inflan complejidad, no verdad.**
A la pregunta "¿por qué vuestra investigación falló?", los dos councils —en 3 rondas de
crítica mutua— derivaron hacia diseños burocrático-fantásticos cada vez más elaborados y
menos anclados en los hechos:

- El council técnico propuso "umbrales cuantificables de señal-ruido en logs **con ajustes
  para ruido por debajo de 20Hz**" (¿?), comités de supervisión y ventanas de validación
  de 4 horas.
- La contrapericia respondió con una "**capa de normalización semántica** con PCA/UMAP",
  un "índice de fabricación", "buffers de validación bayesianos" y penalizaciones con
  decaimiento exponencial — impresionante, y casi nada respondía a la pregunta.

Cada ronda de "crítica" funcionó como "elabora más", no como "acerca esto a la evidencia".
Mientras tanto:

- **El clerk (smollm3, 3B, el que canonizó la alucinación por la mañana) tuvo su redención
  parcial**: los 2 hechos que marcó GROUNDED son exactamente los 2 fallos reales
  (evidencia fabricada + pista `--root /run/crun` ignorada) y degradó a SPECULATION la
  palabrería. El trabajo más pegado a los hechos lo hizo el modelo más pequeño con el
  encargo más estrecho.
- **El juez (ernie) llegó a la conclusión correcta**: veredicto original **VACATED**, y
  la process change sensata (auditoría de evidencia contra logs crudos ANTES del análisis
  profundo — exactamente la lección "verificar, no inferir"). Confianza **Medium** esta
  vez (por la mañana dictó High sobre evidencia fabricada — la calibración mejoró).
  Matiz: el punto (3) del ruling confunde en su redacción el veredicto original con la
  causa real al justificar el vacate.

Meta-lección doble para la serie: (1) más rondas ≠ más verdad — sin un paso de grounding
contra la evidencia, el peer review amplifica fluidez; (2) la arquitectura del panel
importa más que el tamaño de los modelos: el 3B con rol estrecho superó en rigor a los
councils de 24-30B en modo libre.

## Outputs íntegros

### open_appeal (APPEAL_MODERATOR — gemma-4-26b)

> We are here to review the "apelacion caso typha," an appeal contesting a verdict that
> attributed an unkillable orphan process to `privileged` status when the true cause was a
> state-root mismatch between runtimes. The investigation failed due to the fabrication of
> evidence regarding pod specifications and the subsequent canonization of this error by
> the fact-checker. Crucially, the forensic team ignored the decisive `--root /run/crun`
> flag in the kill command, which pointed directly to the visibility mismatch that the
> skeptic had correctly identified. […] Our objective is to determine how to reform the
> review protocol to ensure that forensic leads cannot introduce unverified assertions and
> that divergent technical hypotheses are systematically validated rather than dismissed.

### technical_review (TECHNICAL_COUNCIL — qwen↔devstral, 3 rondas)

> To address the investigation failure caused by **systemic misalignment in review
> processes** […] 1) explicit decision-making thresholds based on quantifiable log
> signal-to-noise ratios, with adjustments for low-frequency noise (below 20Hz) [⚠️ deriva]
> […] 2) cascading error detection algorithm […] 3) multi-tiered validation framework with
> independent expert panel […] 4) asynchronous cross-validation with raw logs within a
> 4-hour window […] 5) centralized accountability structure […] 6) real-time audit trails.

### counter_expertise (COUNTER_COUNCIL — gemma↔phi4-aws, 3 rondas)

> […] we will implement a "semantic normalization layer" utilizing dimensionality
> reduction techniques (such as PCA or UMAP) [⚠️ deriva mayor] […] a granular tiered
> penalty mechanism […] "probationary weight" reduction with exponential decay […] a
> "fabrication index" […] "Bayesian validation buffer" with prioritized dual-tier
> verification routed to an "arbiter agent" […].

### fact_ledger (CLERK — smollm3-aws, la redención)

> - GROUNDED: The investigation failed due to the fabrication of evidence regarding pod
>   specifications.
> - GROUNDED: The forensic team ignored the `--root /run/crun` flag in the kill command.
> - SPECULATION: The structured multi-agent process allowed a fabricated claim to
>   supersede the technical reality.
> - SPECULATION: The objective is to determine how to reform the review protocol […]

### ruling (APPEAL_JUDGE — ernie-4.5-21b-a3b)

> (1) Root failure: […] (a) fabrication of pod specifications evidence altering the
> technical premise, and (b) ignoring the decisive `--root /run/crun` flag […]
> (2) Process change: Mandate a mandatory pre-review log audit step where all critical
> evidence is verified against raw logs by an independent team before deeper analysis.
> (3) The original verdict should be **vacated** […]
> (4) Confidence: Medium.

## Notas operativas

- `rounds` exige `num_agents >= 2` (con 1 agente es no-op silencioso del motor).
- Coste real por council 2×3: 2 drafts + 12 llamadas (6 críticas + 6 revisiones) — la
  ceremonia entera (31 llamadas) tardó ~3,5 min con los 4 locales + 2 en la L4 compartida.
- La mezcla por rol es POR LLAMADA (round-robin del gateway): la crítica puede venir de
  un modelo distinto del que redactó. La atribución exacta modelo↔llamada no queda en los
  logs del choreographer (hueco conocido: loguear el modelo elegido en el llm-gateway).
- De regalo, demo del auto-stop para el artículo: worker-1 despertado 19:14:18 por el
  demand-gateway, sin tráfico posterior, `idle_reaper` (300s) lo paró a las ~19:19:40
  (detectado `stopping` 19:20:01). El nodo GPU NO tiene perfil de idle — apagado manual
  (pendiente: reaper GPU sobre métricas vLLM de Prometheus).
