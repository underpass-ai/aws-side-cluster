# Run: multimodel_panel — 2026-07-02

Primera ceremonia **multimodelo via llm-gateway** (reverse proxy label-driven):

- Cadena: RunCeremony → step config (`agent_kind: vllm`, `provider.model: role:<rol>`) →
  factory vLLM del choreographer → **llm-gateway** (descubre Services por `underpass.ai/llm-role`)
  → vLLM concreto. El placement de modelos en nodos GPU lo dirige k8s/GPU-operator.
- Roles→modelos de esta run: general→gemma-4-26b · coding→{qwen3-coder-30b, devstral-small-24b} (council de 2, round-robin) · reasoning→ernie-4.5-21b-a3b
- phi4-aws (nodo AWS parado) correctamente excluido por health-check del gateway.

## Backends del gateway en el momento de la run
```json
{
    "backends": [
        {
            "service": "vllm-devstral",
            "role": "coding",
            "endpoint": "http://vllm-devstral.underpass-labs.svc:8000",
            "models": [
                "devstral-small-24b"
            ],
            "healthy": true
        },
        {
            "service": "vllm-ernie45-thinking",
            "role": "reasoning",
            "endpoint": "http://vllm-ernie45-thinking.underpass-labs.svc:8000",
            "models": [
                "ernie-4.5-21b-a3b"
            ],
            "healthy": true
        },
        {
            "service": "vllm-gemma4",
            "role": "general",
            "endpoint": "http://vllm-gemma4.underpass-labs.svc:8000",
            "models": [
                "gemma-4-26b"
            ],
            "healthy": true
        },
        {
            "service": "vllm-phi4-aws",
            "role": "general",
            "endpoint": "http://vllm-phi4-aws.underpass-labs.svc:8000",
            "models": [],
            "healthy": false
        },
        {
            "service": "vllm-qwen3-coder",
            "role": "coding",
            "endpoint": "http://vllm-qwen3-coder.underpass-labs.svc:8000",
            "models": [
                "qwen3-coder-30b"
            ],
            "healthy": true
        }
    ],
    "roles": {
        "coding": [
            "devstral-small-24b",
            "qwen3-coder-30b"
        ],
        "reasoning": [
            "ernie-4.5-21b-a3b"
        ],
        "general": [
            "gemma-4-26b"
        ]
    }
}
```

## Resultado completo
```json
{
    "ceremonyId": "cdedc9ab-2da1-4037-a759-862a60ade23b",
    "definitionName": "multimodel_panel",
    "definitionVersion": "1.0",
    "finalState": "CLOSED",
    "completed": true,
    "steps": [
        {
            "stateId": "OPENING",
            "stepId": "open_panel",
            "roleId": "MODERATOR",
            "status": "COMPLETED",
            "attempt": 1,
            "output": "We will examine how the synergy of WireGuard-encrypted tunnels and Kubernetes orchestration transforms fragmented local silicon and AWS elasticity into a single, unified inference fabric. This discussion moves beyond simple cost-saving to address the architectural necessity of bursting LLM workloads across heterogeneous hardware boundaries without sacrificing data sovereignty."
        },
        {
            "stateId": "DEBATE",
            "stepId": "technical_debate",
            "roleId": "ENGINEER_PANEL",
            "status": "COMPLETED",
            "attempt": 1,
            "output": "{\n  \"Hardest Problem\": \"Cross-cluster model synchronization latency under variable network conditions (WireGuard overhead, AWS-to-local jitter, and Kubernetes networking APIs).\",\n  \"Mitigation\": \"Deploy optimized SSH-based proxy layer with HTTP/2 multiplexing at the edge, prioritizing local hardware resources. Validate performance improvements through end-to-end user journey testing with latency benchmarks at 99.99% percentile, ensuring measurable reduction in model sync delays from user perspective.\",\n  \"Testing\": \"Include automated end-to-end tests that simulate real-world network conditions and measure model synchronization time from user action to completion, with pass/fail criteria based on latency thresholds.\"\n}"
        },
        {
            "stateId": "SYNTHESIS",
            "stepId": "synthesis",
            "roleId": "RAPPORTEUR",
            "status": "COMPLETED",
            "attempt": 1,
            "output": "\nConclusion: The hybrid local + AWS GPU cluster architecture achieves low-latency model synchronization by optimizing network efficiency through HTTP/2 multiplexing and SSH proxy layering, validated by rigorous end-to-end performance testing under variable network conditions.  \nRecommended Next Step: Execute automated simulations of real-world network variability to baseline latency metrics and iterate on tunable parameters for optimal burstability and data sovereignty.\n"
        }
    ],
    "mermaidSequence": "sequenceDiagram\n  title multimodel_panel v1.0\n  participant R1 as ENGINEER_PANEL\n  participant R2 as MODERATOR\n  participant R3 as RAPPORTEUR\n  Note over R1,R3: State OPENING\n  R2->>R1: open_panel [general]\n  Note over R1,R3: panel_opened -> DEBATE (guards: opening_done)\n  Note over R1,R3: State DEBATE\n  R1->>R3: technical_debate [coding]\n  Note over R1,R3: debate_closed -> SYNTHESIS (guards: debate_done)\n  Note over R1,R3: State SYNTHESIS\n  R3->>R3: synthesis [reasoning]\n  Note over R1,R3: synthesis_delivered -> CLOSED (guards: synthesis_done)"
}
```
