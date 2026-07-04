#!/usr/bin/env python3
"""Runner del experimento "Disposable Compute, Persistent Evidence".

Para (task, profile) genera la ceremonia YAML, la corre via RunCeremony
(grpcurl containerizado), parsea el output final, calcula las metricas de
decision y persiste el decision artifact JSON (local + S3).

  ./run.py --task 1 --profile B            # genera + corre + artifact
  ./run.py --task 1 --profile C --dry-run  # solo genera el YAML

Perfiles (gobernanza, no modelos):
  A single_model_freeform      sin evidencia, sin contract
  B single_model_evidence_gate evidencia + output contract + grounding
  C evidence_bound_review      B + skeptical reviewer en el worker G6 (L4)
"""
import argparse
import os
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
PROTO_DIR = pathlib.Path.home() / "ai/developents/underpass-orchestrator/crates/choreo-proto/proto"
S3_BUCKET = "aws-side-poc-bootstrap-5d7cbe73"
PRIMARY_MODEL = os.environ.get("PRIMARY_MODEL", "qwen3-coder-30b")  # local, 3090
REVIEWER_MODEL = "phi4-mini-aws"            # L4 del worker efimero (load-bearing)
GRPC = "localhost:50055"

OUTPUT_SPEC = (
    "CRITICAL OUTPUT FORMAT: your ENTIRE response must be raw JSON — the first character "
    "of your response must be { and the last must be }. NEVER wrap it in ``` fences. Shape: "
    '{"claims": [{"text": "...", "evidence_refs": ["ev-..."]}], '
    '"decision": "accept|reject|request_changes|request_more_evidence", '
    '"risks": ["..."], "assumptions": ["..."]}'
)
OUTPUT_SPEC_FREEFORM = (
    "CRITICAL OUTPUT FORMAT: your ENTIRE response must be raw JSON — the first character "
    "of your response must be { and the last must be }. NEVER wrap it in ``` fences. Shape: "
    '{"claims": [{"text": "..."}], '
    '"decision": "accept|reject|request_changes|request_more_evidence", '
    '"risks": ["..."], "assumptions": ["..."]}'
)


def evidence_block(task):
    lines = ["EVIDENCE PACK (the ONLY citable evidence; cite by id in evidence_refs):"]
    for ev in task["evidence"]:
        lines.append(f"- [{ev['id']}] {ev['text']}")
    return "\n".join(lines)


def contract_yaml(indent):
    pad = " " * indent
    return "\n".join(
        [
            f"{pad}output_contract:",
            f"{pad}  contract_id: evidence-bound-decision",
            f"{pad}  format: json_object",
            f"{pad}  required_fields: [claims, decision]",
            f"{pad}  allowed_values:",
            f"{pad}    decision: [accept, reject, request_changes, request_more_evidence]",
            f"{pad}  evidence:",
            f"{pad}    claims_field: claims",
            f"{pad}    refs_field: evidence_refs",
            f"{pad}    allowed_refs_from_context: evidence_pack",
        ]
    )


def step(step_id, state, handler, model, prompt, contract, tokens=1536, timeout=300, see_prior=False):
    lines = [
        f"  - id: {step_id}",
        f"    state: {state}",
        f"    handler: {handler}",
        "    config:",
        "      agent_kind: vllm",
        f'      provider.model: "{model}"',
        f"      provider.max_tokens: {tokens}",
        f"      provider.timeout_secs: {timeout}",
        f"      see_prior: {'true' if see_prior else 'false'}",
        "      num_agents: 1",
    ]
    if contract:
        lines.append(contract_yaml(6))
    escaped = prompt.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    lines.append(f'      prompt: "{escaped}"')
    return "\n".join(lines)


def linear_fsm(name, description, steps):
    """FSM lineal: un estado por step + CLOSED. steps = [(id, handler, role)]."""
    states, transitions, guards, bodies = [], [], [], []
    role_actions = {}  # rol -> acciones (un mismo rol puede llevar varios steps)
    for i, (sid, _, role, body) in enumerate(steps):
        st = sid.upper()
        states.append(f"  - id: {st}" + ("\n    initial: true" if i == 0 else ""))
        nxt = steps[i + 1][0].upper() if i + 1 < len(steps) else "CLOSED"
        transitions.append(
            f"  - from: {st}\n    to: {nxt}\n    trigger: {sid}_done\n    guards:\n      - g_{sid}"
        )
        guards.append(
            f"  g_{sid}:\n    type: automated\n    check: \"step_status:{sid}:COMPLETED\""
        )
        role_actions.setdefault(role, []).extend([sid, f"{sid}_done"])
        bodies.append(body)
    roles = [
        f"  - id: {role}\n    allowed_actions:\n" + "\n".join(f"      - {a}" for a in acts)
        for role, acts in role_actions.items()
    ]
    return f"""version: "1.0"
name: "{name}"
description: "{description}"
inputs:
  optional:
    - evidence_pack
outputs:
  decision:
    type: object
states:
{chr(10).join(states)}
  - id: CLOSED
    terminal: true
transitions:
{chr(10).join(transitions)}
steps:
{chr(10).join(bodies)}
guards:
{chr(10).join(guards)}
roles:
{chr(10).join(roles)}
timeouts:
  step_default: 600
retry_policies:
  default:
    max_attempts: 2
    backoff_seconds: 2
"""


def build_ceremony(task, profile):
    q = task["question"]
    ev = evidence_block(task)
    if profile == "A":
        prompt = (
            f"You are the primary engineer reviewing a technical decision for the "
            f"Underpass Choreographer platform. QUESTION: {q} Give your decision with "
            f"supporting claims, risks and assumptions. {OUTPUT_SPEC_FREEFORM}"
        )
        steps = [("propose", "primary_a", "PRIMARY_ENGINEER",
                  step("propose", "PROPOSE", "primary_a", PRIMARY_MODEL, prompt, contract=False))]
        return linear_fsm("single_model_freeform", "Profile A: one model, no evidence gate", steps)
    if profile == "B":
        prompt = (
            f"You are the primary engineer reviewing a technical decision for the "
            f"Underpass Choreographer platform. QUESTION: {q}\n{ev}\nEvery claim MUST cite "
            f"at least one evidence id from the pack in its evidence_refs; claims you cannot "
            f"support, leave out. {OUTPUT_SPEC}"
        )
        steps = [("propose", "primary_b", "PRIMARY_ENGINEER",
                  step("propose", "PROPOSE", "primary_b", PRIMARY_MODEL, prompt, contract=True))]
        return linear_fsm("single_model_evidence_gate", "Profile B: evidence pack + deterministic contract gate", steps)
    if profile == "C":
        p1 = (
            f"You are the primary engineer reviewing a technical decision for the "
            f"Underpass Choreographer platform. QUESTION: {q}\n{ev}\nEvery claim MUST cite "
            f"at least one evidence id from the pack in its evidence_refs. {OUTPUT_SPEC}"
        )
        p2 = (
            f"You are the skeptical reviewer, running on the ephemeral AWS GPU worker. "
            f"The primary engineer's proposal is in the prior discussion. Do NOT synthesize "
            f"an answer. For each claim: state OBJECTION (with which evidence id contradicts "
            f"or is missing) or ACCEPT. Flag any claim whose evidence_refs do not support its "
            f"text. End with: BLOCKING or NON-BLOCKING overall. Plain text, terse."
        )
        p3 = (
            f"You are the primary engineer. Revise your proposal incorporating the reviewer's "
            f"objections from the prior discussion (drop or fix unsupported claims; do not "
            f"argue). QUESTION: {q}\n{ev}\n{OUTPUT_SPEC}"
        )
        steps = [
            ("propose", "primary_c", "PRIMARY_ENGINEER",
             step("propose", "PROPOSE", "primary_c", PRIMARY_MODEL, p1, contract=True)),
            ("review", "skeptic_c", "SKEPTICAL_REVIEWER",
             step("review", "REVIEW", "skeptic_c", REVIEWER_MODEL, p2, contract=False,
                  tokens=1024, see_prior=True)),
            ("finalize", "primary_c_final", "PRIMARY_ENGINEER",
             step("finalize", "FINALIZE", "primary_c_final", PRIMARY_MODEL, p3, contract=True,
                  see_prior=True)),
        ]
        return linear_fsm("evidence_bound_review", "Profile C: primary + skeptic on ephemeral worker + contract gate", steps)
    raise SystemExit(f"perfil desconocido: {profile}")


def parse_final(output):
    """El output del step final: JSON de la decision (tolera texto alrededor)."""
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        start, end = output.find("{"), output.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(output[start : end + 1])
            except json.JSONDecodeError:
                return None
    return None


def decision_metrics(final, allowed_refs):
    claims = final.get("claims", []) if final else []
    with_ev = without_ev = escaped = 0
    for c in claims:
        refs = c.get("evidence_refs", []) if isinstance(c, dict) else []
        valid = [r for r in refs if r in allowed_refs]
        if valid:
            with_ev += 1
        else:
            without_ev += 1
            escaped += 1  # llego a la decision final sin soporte
    return {
        "final_claims_total": len(claims),
        "claims_with_evidence": with_ev,
        "claims_without_evidence": without_ev,
        "unsupported_claim_escape_count": escaped,
    }


def gpu_worker_lifecycle():
    try:
        out = subprocess.run(
            ["aws", "ec2", "describe-instances", "--filters",
             "Name=tag:underpass.ai/node-pool,Values=aws-gpu",
             "--query", "Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]",
             "--output", "json"],
            capture_output=True, text=True, timeout=30, check=True)
        rows = json.loads(out.stdout)
        if rows:
            iid, state, launch = rows[0]
            return {"provider": "aws", "instance_family": "g6.xlarge", "instance_id": iid,
                    "ephemeral": True, "state_at_run": state, "launched_at": launch,
                    "idle_shutdown_triggered": False}
    except Exception:
        pass
    return None


def run(task_n, profile, execute=True, repetition=1):
    task = json.loads((HERE / "tasks" / f"task-{task_n}.json").read_text())
    ceremony = build_ceremony(task, profile)
    # sufijo horario: el registry del engine es in-memory y un intento fallido
    # deja su ceremony_instance registrada (AlreadyExists al reutilizar id)
    run_id = f"exp-{task['id']}-{profile.lower()}-r{repetition}-{time.strftime('%H%M%S')}"
    out_dir = HERE / "runs" / run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "ceremony.yaml").write_text(ceremony)
    print(f"[{run_id}] ceremonia generada -> {out_dir/'ceremony.yaml'}")
    if not execute:
        return None

    allowed = [ev["id"] for ev in task["evidence"]]
    payload = {
        "ceremonyId": run_id,
        "definitionYaml": ceremony,
        "context": {"evidence_pack": allowed} if profile in ("B", "C") else {},
        "leaseOwnerId": "experiment-runner",
        "leaseTtlMs": 180000,
    }
    (out_dir / "payload.json").write_text(json.dumps(payload))

    t0 = time.time()
    cmd = ["podman", "run", "-i", "--rm", "--network=host",
           "-v", f"{PROTO_DIR}:/protos:ro", "docker.io/fullstorydev/grpcurl",
           "-plaintext", "-max-time", "1800", "-import-path", "/protos",
           "-proto", "underpass/choreo/v1/choreo.proto", "-d", "@", GRPC,
           "underpass.choreo.v1.ChoreographerService/RunCeremony"]
    proc = subprocess.run(cmd, input=(out_dir / "payload.json").read_text(),
                          capture_output=True, text=True, timeout=1900)
    elapsed = time.time() - t0
    (out_dir / "response.json").write_text(proc.stdout)
    if proc.returncode != 0:
        (out_dir / "grpc-error.log").write_text(proc.stderr)
        print(f"[{run_id}] RunCeremony FALLO (rc={proc.returncode}); ver grpc-error.log", file=sys.stderr)

    resp = None
    try:
        resp = json.loads(proc.stdout)
    except json.JSONDecodeError:
        pass
    final_state = resp.get("finalState") if resp else None
    step_list = resp.get("steps", []) if resp else []
    final_out = step_list[-1]["output"] if step_list else ""
    final = parse_final(final_out)
    metrics = decision_metrics(final, set(allowed))

    # trace_id: la traza rpc.run_ceremony cuyo INICIO cae mas cerca de t0
    # (runs consecutivas comparten ventana; el "mas reciente" atribuye mal).
    # El ingest de Tempo tarda unos segundos: reintentar antes de rendirse.
    trace_id = ""
    try:
        tempo = subprocess.run(
            ["kubectl", "-n", "monitoring", "get", "svc", "tempo",
             "-o", "jsonpath={.spec.clusterIP}"],
            capture_output=True, text=True, timeout=15).stdout.strip()
        for attempt in range(6):
            q = (f"http://{tempo}:3200/api/search?start={int(t0)-2}&end={int(time.time())+2}&limit=20")
            found = json.loads(urllib.request.urlopen(q, timeout=15).read())
            best = None
            for tr in found.get("traces", []):
                if tr.get("rootTraceName") != "rpc.run_ceremony":
                    continue
                st = int(tr.get("startTimeUnixNano", "0")) / 1e9
                if st < t0 - 2:
                    continue
                d = abs(st - t0)
                if best is None or d < best[0]:
                    best = (d, tr["traceID"])
            if best:
                trace_id = best[1]
                break
            time.sleep(5)
    except Exception as exc:
        print(f"[{run_id}] AVISO: sin trace_id ({exc})", file=sys.stderr)

    artifact = {
        "decision_id": run_id,
        "trace_id": trace_id,
        "ceremony_id": run_id,
        "profile": {"A": "single_model_freeform", "B": "single_model_evidence_gate",
                     "C": "evidence_bound_review"}[profile],
        "task": task["id"],
        "question": task["question"],
        "status": (final or {}).get("decision", "unparseable" if final_state == "CLOSED" else f"ceremony_{final_state or 'FAILED'}"),
        "final_state": final_state,
        "meeting_execution_seconds": round(elapsed, 1),
        "rejected_claims": 0,
        "worker_lifecycle": gpu_worker_lifecycle(),
        "observability": {"otel_trace_exported": bool(trace_id),
                           "logs_exported": True, "metrics_exported": True},
        **metrics,
    }
    (out_dir / "decision.json").write_text(json.dumps(artifact, indent=2))
    subprocess.run(["aws", "s3", "cp", str(out_dir / "decision.json"),
                    f"s3://{S3_BUCKET}/decisions/{run_id}.json"], capture_output=True)
    print(f"[{run_id}] finalState={final_state} status={artifact['status']} "
          f"claims={metrics['final_claims_total']} escaped={metrics['unsupported_claim_escape_count']} "
          f"trace={trace_id} ({elapsed:.0f}s)")
    return artifact


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", type=int, required=True)
    ap.add_argument("--profile", choices=["A", "B", "C"], required=True)
    ap.add_argument("--rep", type=int, default=1)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    run(a.task, a.profile, execute=not a.dry_run, repetition=a.rep)
