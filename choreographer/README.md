# Choreographer en el POC (`underpass-labs`)

Integra el **Choreographer** público ([github.com/underpass-ai/underpass-choreographer](https://github.com/underpass-ai/underpass-choreographer))
en el namespace del POC `underpass-labs`, usando como agentes los **6 vLLM** del POC:
4 locales (chart `charts/local-llm`, 4× RTX 3090) + 2 en la L4 del worker AWS
(release `aws-gpu-llm`, time-slicing).

El Choreographer NO es un router que construyamos aquí: es el plano de coordinación que corre
**councils** (propose → critique → revise → validate → score → winner) y **ceremonies** (FSM YAML).
Aquí (a) lo desplegamos, (b) lo conectamos al `llm-gateway`, y (c) le damos ceremonias.

## Cómo llegan los modelos: el llm-gateway (NO endpoints por step)

El provider base de los agentes `kind=vllm` es el **llm-gateway**
(`CHOREO_VLLM_ENDPOINT=http://llm-gateway:8000`, chart `charts/llm-gateway`),
que descubre los vLLM por la label `underpass.ai/llm-role` de sus Services. Los
steps eligen modelo con `provider.model`:

- **nombre exacto** (`"phi4-mini-aws"`, `"ernie-4.5-21b-a3b"`) → ese modelo, fijo;
- **alias `role:<rol>`** (`"role:coding"`) → round-robin entre los modelos del rol,
  **resuelto POR LLAMADA**: en un council multi-ronda, la crítica puede venir de un
  modelo distinto del que redactó (mezcla real de modelos — verificado en
  `csi-typha-appeal`). Roles actuales: `coding` (qwen3-coder, devstral),
  `general` (gemma4, phi4-aws), `reasoning` (ernie45), `junior` (smollm3-aws).

Los nodos parados salen solos del pool por health-check (`/backends` para debug).
La variante RegisterAgent+CreateCouncil (abajo) queda como camino alternativo NO verificado.

## Despliegue (verificado 2026-07-02/03)

- **Chart del checkout** del repo público (`~/ai/developents/underpass-choreographer/charts/choreographer`)
  — el chart OCI `0.1.0` publicado está **stale** (mismo número de versión, sin `providerEnv`).
- Imagen pinneada por digest: tag `metrics-e7a89f4` (`sha256:18abb055…`) — la única publicada
  con `RunCeremony`; GHCR privado → requiere el secret `ghcr-pull` en el ns.
- Values: `values.embedded-nats.yaml` (del checkout) + **`values.underpass-labs-public.yaml`**
  (este dir; providerEnv → gateway + **OTLP → Tempo**) + `--set config.seedSpecialties=panel`.
  (`values.underpass-labs.yaml` es el despliegue ANTIGUO pre-gateway; conservado como histórico.)

```bash
helm -n underpass-labs upgrade --install choreographer \
  <checkout>/charts/choreographer \
  -f <checkout>/charts/choreographer/values.embedded-nats.yaml \
  -f choreographer/values.underpass-labs-public.yaml \
  --set config.seedSpecialties=panel \
  --set image.digest=sha256:18abb0556a8818ab418c34b0461ba22b5e299aff1da0cc73338a82f7e92fe016 \
  --wait --timeout 5m
```

Al arrancar, el pod debe loguear `"otlp exporter wired"` — cada ceremonia queda como
traza distribuida en Tempo (`rpc.run_ceremony` → `deliberate`, con span events de cada
crítica/revisión). Si el banner del NOTES avisa de que falta el OTLP, revisa el overlay.

## Ceremonias y actas

| Ceremonia | Qué es | Estado |
|---|---|---|
| `hello-panel.yaml` | smoke noop | corrida (acta `runs/hello-panel-1.md`) |
| `multimodel-panel.yaml` | panel 4 modelos locales por roles | corrida (`runs/multimodel-panel-1.md`) |
| `multimodel-panel-hybrid.yaml` | + phi4 desde la L4 AWS (step `aws_perspective`) | corrida (`runs/multimodel-panel-hybrid-1.md`) |
| `csi-typha.yaml` | whodunit forense del incidente typha, 6 modelos | corrida (`runs/csi-typha-1.md`) |
| `csi-typha-appeal.yaml` | apelación: 2 councils × 3 rondas de peer review | corrida (`runs/csi-typha-appeal-1.md`) |
| `article-decision-traces.yaml` | ceremonia editorial del artículo (esquema pre-gateway) | corrida 2026-06-28 (`runs/article-trace-1.md`, esquema antiguo) |
| `article-decision-traces-hybrid.yaml` | editorial + step AWS | lint OK, **sin correr** |

Las actas en `runs/` incluyen los outputs íntegros, la evidencia de routing y (en las CSI)
la puntuación del panel contra la causa raíz verificada.

## Correr una ceremonia (receta verificada)

`grpcurl` no está instalado en el host: se usa **containerizado** con los protos del
checkout de `underpass-orchestrator`. GOTCHA: el `-i` de podman es obligatorio para
el payload por stdin (sin él: "invalid ceremony yaml" con payload vacío).

```bash
kubectl -n underpass-labs port-forward svc/choreographer 50055:50055 &

jq -Rs '{ceremonyId:"mi-run-1", definitionYaml:., context:{}, leaseOwnerId:"operator", leaseTtlMs:120000}' \
  ceremonies/<ceremonia>.yaml \
| podman run -i --rm --network=host \
    -v ~/ai/developents/underpass-orchestrator/crates/choreo-proto/proto:/protos:ro \
    docker.io/fullstorydev/grpcurl -plaintext -max-time 2400 \
    -import-path /protos -proto underpass/choreo/v1/choreo.proto -d @ \
    localhost:50055 underpass.choreo.v1.ChoreographerService/RunCeremony
```

La respuesta trae `steps[]` (`output` = winner del step) y `mermaidSequence`. `RunCeremony`
**bloquea** hasta el estado terminal: dimensiona el timeout del cliente al total de llamadas.

## Gotchas de autoría (verificados; detalle en el runbook upstream)

- **`rounds` exige `num_agents >= 2`** — con 1 agente es no-op SILENCIOSO. Con council,
  `rounds: N` corre peer review circular (el agente *i* critica Y revisa al *i+1*, N rondas).
- **Coste en llamadas por step**: `num_agents + rounds × num_agents × 2` (secuenciales).
  `provider.timeout_secs` acota cada llamada, no el step.
- **Los agentes/councils persisten por specialty** en memoria del pod: si cambias
  `agent_kind` de un handler ya usado, reinicia el pod o usa otro handler.
- **Modelos thinking** (smollm3, ernie): presupuesta `max_tokens` para el razonamiento
  + la respuesta; `/no_think` de SmolLM3 solo aplica en system prompt (el provider manda user).
- **Lint antes de correr**: test de 5 líneas con `CeremonyDefinitionYaml::parse_path` en
  `crates/choreo-adapters/tests/` del checkout de `underpass-orchestrator` (borrar tras usar).
- Prompts en inglés (convención del repo).

Runbooks upstream (nuestras PRs): `docs/operations/observability-runbook.md` (#116) y
`docs/operations/ceremony-authoring-runbook.md` (#117); NOTES del chart (#115).

## Variante alternativa: council heterogéneo por RegisterAgent (NO verificada)

Para mezclar modelos SIN gateway (endpoints directos), pre-registrar agentes antes de
`RunCeremony` y dejar el step con `agent_kind: noop`:

```text
RegisterAgent  specialty=editorial_coding  agent_id=agent-editorial_coding-0  kind=vllm
               attrs={ provider.endpoint=http://vllm-qwen3-coder:8000, provider.model=qwen3-coder-30b }
RegisterAgent  specialty=editorial_coding  agent_id=agent-editorial_coding-1  kind=vllm
               attrs={ provider.endpoint=http://vllm-devstral:8000,     provider.model=devstral-small-24b }
CreateCouncil  specialty=editorial_coding  num_agents=2
```

(Inferido del código, nunca ejecutado. Hoy la mezcla verificada es el alias `role:<rol>`.)

## Pendiente

- Correr `article-decision-traces-hybrid.yaml` (la editorial con step AWS).
- Loguear en el llm-gateway el modelo resuelto por request (atribución exacta
  modelo↔llamada en councils con alias de rol — hueco observable conocido).
