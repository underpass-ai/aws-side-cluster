# Resultados — Disposable Compute, Persistent Evidence

Ejecutado 2026-07-04. Todo dato de esta tabla sale de artifacts reales en
`experiment/runs/` (+ copia en `s3://…/decisions/`), trazas en Tempo y logs en
Loki. Nada inventado.

## Tabla principal (5 tareas × 3 perfiles, 1 rep)

| Perfil | Modelos | Evidencia | Juez determinista | Claims | Con evidencia | **Escaped** | Trace sobrevive shutdown | Decisiones |
|---|---|---|---|---|---|---|---|---|
| A `single_model_freeform` | 1 (qwen3-coder local) | no | no | 14 | 0 | **14** | sí | 4 accept · 1 reject |
| B `single_model_evidence_gate` | 1 | sí | sí | 18 | 18 | **0** | sí | 4 accept · 1 reject |
| C `evidence_bound_review` | 2 (+phi4 en la L4) | sí | sí | 18 | 18 | **0** | sí | 3 accept · **2 reject** |

- **Criterio de éxito `unsupported_claim_escape_count == 0`: cumplido en B y C
  al 100%** (0/36 claims). En el baseline A escaparon TODAS (14/14).
- **El reviewer del worker efímero cambió decisiones**: task-1 con la misma
  evidencia fue `accept` en B y `reject` en C tras las objeciones del
  escéptico. El G6 no decora: decide.
- Trazas únicas por decisión (15 trace_ids), verificables en Tempo.

## Métricas de infraestructura (medidas, no estimadas)

| Métrica | Valor | Fuente |
|---|---|---|
| Cold start: petición → instancia running | 77s | c-batch-metrics.env (13:06:24→13:07:41) |
| Cold start: petición → reviewer sirviendo | **306s** | reviewer_ready 13:11:30 |
| Batch C: 5 decisiones (3 steps c/u) | 92s (13:11:51→13:13:23) | run logs |
| Última petición → apagado autónomo | ~590s (GRACE 600s post-launch domina) | reaper events.log |
| **Apagado por idle (autónomo)** | **13:23:11, idle_for=350s, launch_age=1003s** | `gpu-idle-reaper/events.log` |
| Vida total del worker | **15,5 GPU-min** (13:07:41→13:23:11) | EC2 + reaper |
| Evidencia persistida (5 decisiones C: artifacts+responses) | **~32 KB** (+ spans Tempo y logs Loki, orden KB) | du sobre runs/ |
| Reconstrucción post-mortem | **OK con worker `stopped`**: `alive_now=false`, 6 spans, 33 eventos, veredictos del gate íntegros | decision-trace-tui --no-tui |

La relación evidencia/cómputo: ~32 KB conservan el registro completo de
decisiones que costaron 15,5 GPU-minutos (~0,12 USD) producir. Guardarlo todo
no tiene excusa.

## La línea que resume el experimento (log real)

```
validator=claims-evidence-grounded passed=true
  verdict=all 2 claims grounded in the evidence pack (5 allowed refs)
…
worker: g6.xlarge i-084f4b98659f48a19 idle_shutdown=true alive_now=Some(false)
```

## Hallazgos operativos honestos (para la sección de limitaciones)

1. **Los modelos hablan markdown**: devstral fenceó el JSON siempre; qwen3 el
   60% de las veces, con prompts explícitos en contra. Propuestas bien
   fundadas morían por cosmética de transporte → PR #120 (los validators
   toleran fences puros). Sin esa tolerancia, el gate mide obediencia de
   formato, no calidad de evidencia.
2. El registry in-memory convierte los reintentos en `AlreadyExists`: ids de
   ceremonia únicos por invocación.
3. La atribución run↔traza necesita ventana temporal exacta (dos runs
   consecutivas se roban la traza con una búsqueda "la más reciente").
4. n=15 runs, 1 repetición: experimento de arquitectura operativa, no
   benchmark de razonamiento. El GRACE de 600s del reaper domina el tiempo
   hasta el apagado en sesiones cortas (ajustable; el contador de idle en sí
   fue 350s ≈ los 300s configurados + tick).
5. `rejected_claims` está en 0 en todos los perfiles: el gate actual mata
   PROPUESTAS enteras, no claims individuales; el conteo por-claim rechazada
   requiere el estado request_more_evidence (trabajo futuro anotado en #118).

## Inventario de PRs upstream nacidas del experimento

#115 (NOTES banner) · #116 (observability runbook) · #117 (ceremony authoring
runbook) · #118 (output contract en step YAML) · #119 (grounding validator)
· #120 (tolerancia a fences). Las 3 últimas SON el juez-política.
