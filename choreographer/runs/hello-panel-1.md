# Run: hello_panel (smoke del motor público) — 2026-07-02

- Motor: chart del checkout underpass-choreographer@19f2447 (perfil embedded-nats + overlay underpass-labs)
- Imagen: ghcr.io/underpass-ai/underpass-choreographer@sha256:18abb055… (tag metrics-e7a89f4, build 2026-06-11)
- agent_kinds=noop,vllm · agentes: NoopAgent seed-panel-0 (config.seedSpecialties=panel)
- Invocación: RunCeremony gRPC :50055 (grpcurl containerizado, protos del checkout)

```json
{
    "ceremonyId": "f62ebcda-8d5b-49c8-b3a7-3f5b662c355b",
    "definitionName": "hello_panel",
    "definitionVersion": "1.0",
    "finalState": "CLOSED",
    "completed": true,
    "steps": [
        {
            "stateId": "PANEL_OPEN",
            "stepId": "opening_statement",
            "roleId": "MODERATOR",
            "status": "COMPLETED",
            "attempt": 1,
            "output": "noop-proposal[seed-panel-0] for task: You are acting as MODERATOR in the \"hello_panel\" ceremony (current stage: PANEL_OPEN).\n\nMission brief:\n- topic: hybrid local+AWS GPU clusters\n\nYour task now: Open the panel: state in one sentence why hybrid local+cloud GPU clusters matter."
        },
        {
            "stateId": "SUMMARY",
            "stepId": "closing_summary",
            "roleId": "RAPPORTEUR",
            "status": "COMPLETED",
            "attempt": 1,
            "output": "noop-proposal[seed-panel-0] for task: You are acting as RAPPORTEUR in the \"hello_panel\" ceremony (current stage: SUMMARY).\n\nMission brief:\n- topic: hybrid local+AWS GPU clusters\n\nThe meeting so far:\n- MODERATOR (opening_statement): noop-proposal[seed-panel-0] for task: You are acting as MODERATOR in the \"hello_panel\" ceremony (current stage: PANEL_OPEN).\n\nMission brief:\n- topic: hybrid local+AWS GPU clusters\n\nYour task now: Open the panel: state in one sentence why hybrid local+cloud GPU clusters matter.\n\nYour task now: Summarize the panel in one sentence, building on the opening statement."
        }
    ],
    "mermaidSequence": "sequenceDiagram\n  title hello_panel v1.0\n  participant R1 as MODERATOR\n  participant R2 as RAPPORTEUR\n  Note over R1,R2: State PANEL_OPEN\n  R1->>R2: opening_statement [panel]\n  Note over R1,R2: topic_discussed -> SUMMARY (guards: opening_completed)\n  Note over R1,R2: State SUMMARY\n  R2->>R2: closing_summary [panel]\n  Note over R1,R2: summary_delivered -> CLOSED (guards: summary_completed)"
}
```
