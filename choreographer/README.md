# Choreographer en el POC (`underpass-labs`)

Integra el **Choreographer** (orquestador multi-agente, repo `underpass-orchestrator`) en el namespace
del POC `underpass-labs`, usando como agentes los **4 vLLM locales** del chart `charts/local-llm`.

El Choreographer NO es un router que construyamos aquí: es el plano de coordinación que corre
**councils** (propose → critique → revise → validate → score → winner) y **ceremonies** (FSM YAML).
Aquí solo (a) lo desplegamos en `underpass-labs` y (b) le damos una ceremonia que delibera sobre los
4 modelos del POC.

## Ceremonia: `ceremonies/article-decision-traces.yaml`

Planifica el artículo sobre las *decision traces* del Choreographer. Auto-referencial: la corrida
de la ceremonia ES una decision trace que puede ir dentro del propio artículo.

Flujo `FRAMING → DRAFTING → CRITIQUE → SYNTHESIS → SEALED`, un step por estado, cada uno con una
**specialty distinta → un modelo distinto** (auto-prepare crea un council por specialty):

| Step | Rol | specialty | Modelo (Service en `underpass-labs`) | Deliberación |
|---|---|---|---|---|
| `frame_scope` | FACILITATOR | `editorial_general` | gemma-4-26b (`vllm-gemma4`) | 1 agente |
| `draft_angles` | CONTRIBUTOR | `editorial_coding` | qwen3-coder-30b (`vllm-qwen3-coder`) | **2 agentes, 1 ronda** (la traza estrella) |
| `critique_gaps` | REVIEWER | `editorial_reasoning` | ernie-4.5-21b-a3b (`vllm-ernie45-thinking`) | 1 agente |
| `synthesize_outline` | EDITOR | `editorial_editor` | devstral-small-24b (`vllm-devstral`) | 1 agente |

> **Validada contra el parser real** (`CeremonyDefinitionYaml::parse_path`, el mismo que usa
> `RunCeremony`): pasa esquema serde + las 11 invariantes del `CeremonyDefinition`.
> Lint estructural reproducible en `scripts/` del scratchpad o re-corre el parser con un test
> en `crates/choreo-adapters/tests/` que llame `parse_path("…/article-decision-traces.yaml")`.

> Prompts en inglés (convención de las ceremonias del repo). Si el artículo va en español, cámbialos.

## Prerrequisitos

1. Los 4 vLLM del POC corriendo en `underpass-labs` (chart `local-llm`, release `local-llm`):
   `vllm-gemma4`, `vllm-qwen3-coder`, `vllm-ernie45-thinking`, `vllm-devstral` (todos `:8000`).
2. Choreographer desplegado en `underpass-labs` con `values.underpass-labs.yaml` (este dir).
   La imagen debe llevar la feature **`agent-vllm`** y el provider base `CHOREO_VLLM_*` (ya en el values).

## Correr la ceremonia

`RunCeremony` (gRPC) con `definition_yaml` = el fichero, y `context` con los `inputs`:

```bash
# port-forward al gRPC del choreographer (ajusta puerto/servicio segun el chart)
kubectl -n underpass-labs port-forward svc/choreographer 50051:50051 &

grpcurl -plaintext -d @ localhost:50051 underpass.choreo.v1.ChoreographyService/RunCeremony <<JSON
{
  "ceremony_id": "article-trace-1",
  "definition_yaml": $(yq -o=json -I=0 '.' ceremonies/article-decision-traces.yaml | jq -Rs .),
  "context": { "article_brief": "Artículo: cómo el Choreographer produce decision traces auditables (councils + judge + OTEL).", "audience_notes": "Ingenieros que evalúan orquestadores de agentes." },
  "lease_owner_id": "operator",
  "lease_ttl_ms": 120000
}
JSON
```

La respuesta trae `steps[]` (cada uno con `role_id`, `status`, `output` = winner_content = el acta del
step) y `mermaid_sequence`. Con `CHOREO_JUDGE_ENABLED=true` (en el values) el winner de cada step se
elige por **calidad intrínseca** (LLM-judge), no por tie-break arbitrario — que es justo el punto del
artículo. Con `otel` + endpoint OTLP, la corrida entera es una traza span-by-span.

## Variante: council heterogéneo (qwen3-coder + devstral en el MISMO step)

El auto-prepare hace councils **homogéneos** (todos los agentes de un step comparten `provider.model`).
Para que `draft_angles` delibere con qwen3-coder **y** devstral a la vez (disenso entre 2 modelos
distintos = mejor traza para el artículo), pre-registra los agentes ANTES de `RunCeremony` y deja el
step con `agent_kind: noop` (para que el throwaway no falle y prevalezca el council pre-registrado):

```text
RegisterAgent  specialty=editorial_coding  agent_id=agent-editorial_coding-0  kind=vllm
               attrs={ provider.endpoint=http://vllm-qwen3-coder:8000, provider.model=qwen3-coder-30b }
RegisterAgent  specialty=editorial_coding  agent_id=agent-editorial_coding-1  kind=vllm
               attrs={ provider.endpoint=http://vllm-devstral:8000,     provider.model=devstral-small-24b }
CreateCouncil  specialty=editorial_coding  num_agents=2
# luego RunCeremony con el step draft_angles usando agent_kind: noop, num_agents: 2, sin provider.*
```

(Verificar en un e2e real: el comportamiento "register duplicado AlreadyExists se traga y gana el
council pre-registrado" está inferido del código, no ejecutado.)

## Pendiente

- Labels por rol (`underpass.ai/llm-role: coding|reasoning|general`) en el chart `local-llm`
  (metadatos de selección; el choreographer enruta por specialty, no por label k8s).
- Script Python/FastAPI que orqueste el registro (variante heterogénea) + `RunCeremony`.
