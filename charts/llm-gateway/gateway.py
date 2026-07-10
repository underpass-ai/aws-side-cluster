#!/usr/bin/env python3
"""llm-gateway: reverse proxy OpenAI-compatible para los vLLM del cluster.

- Descubre los Services por label (underpass.ai/llm-role) vía la API de k8s
  (ServiceAccount con list/get de services en el namespace, solo lectura).
- A cada backend le pregunta /v1/models para saber qué modelo sirve.
- Enruta POST /v1/chat/completions | /v1/completions por el campo "model":
    * nombre exacto (p.ej. "gemma-4-26b") -> su backend
    * alias "role:<rol>" (p.ej. "role:coding") -> backend sano de ese rol
      (round-robin), reescribiendo "model" al nombre real del backend.
- GET /v1/models agrega los modelos de todos los backends sanos.
- SSE/streaming: passthrough por chunks.
- Sin dependencias: stdlib only (corre en python:3.12-slim desde ConfigMap).

El placement de los modelos en nodos GPU lo dirige Kubernetes/GPU-operator;
este proxy solo traduce nombre/rol -> Service, agnóstico del nodo.
"""
import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAMESPACE = os.environ.get("GATEWAY_NAMESPACE") or open(
    "/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
LABEL = os.environ.get("GATEWAY_LABEL", "underpass.ai/llm-role")
PORT = int(os.environ.get("GATEWAY_PORT", "8000"))
REFRESH_SECS = int(os.environ.get("GATEWAY_REFRESH_SECS", "30"))
BACKEND_TIMEOUT = int(os.environ.get("GATEWAY_BACKEND_TIMEOUT_SECS", "300"))
PROBE_TIMEOUT = int(os.environ.get("GATEWAY_PROBE_TIMEOUT_SECS", "3"))
WAKE_ENABLED = os.environ.get("GATEWAY_WAKE_ENABLED", "true").lower() in ("1", "true", "yes", "on")
WAKE_TIMEOUT = int(os.environ.get("GATEWAY_WAKE_TIMEOUT_SECS", "900"))
WAKE_DISCOVERY_TIMEOUT = int(os.environ.get("GATEWAY_WAKE_DISCOVERY_TIMEOUT_SECS", "60"))
WAKE_POLL_SECS = int(os.environ.get("GATEWAY_WAKE_POLL_SECS", "5"))
MODEL_ANNOTATION = os.environ.get("GATEWAY_MODEL_ANNOTATION", "underpass.ai/served-model")
WAKE_URL_ANNOTATION = os.environ.get("GATEWAY_WAKE_URL_ANNOTATION", "underpass.ai/wake-url")

_SA = "/var/run/secrets/kubernetes.io/serviceaccount"


class Registry:
    """Tabla de rutas: modelo->backend y rol->[backends sanos]."""

    def __init__(self):
        self._lock = threading.Lock()
        self.by_model = {}   # model_id -> {"endpoint","role","service"}
        self.by_role = {}    # role -> [model_id, ...] (solo sanos)
        self.wake_by_model = {}  # model_id -> backend con wake_url
        self.wake_by_role = {}   # role -> [backend con wake_url, ...]
        self.backends = []   # estado completo para /backends
        self._rr = {}        # role -> indice round-robin

    def update(self, backends):
        by_model, by_role, wake_by_model, wake_by_role = {}, {}, {}, {}
        for b in backends:
            for m in b["models"]:
                by_model[m] = {"endpoint": b["endpoint"], "role": b["role"],
                               "service": b["service"]}
                if b["healthy"]:
                    by_role.setdefault(b["role"], []).append(m)
            if b.get("wake_url"):
                for m in b.get("expected_models") or b["models"]:
                    wake_by_model[m] = b
                wake_by_role.setdefault(b["role"], []).append(b)
        with self._lock:
            self.by_model = by_model
            self.by_role = by_role
            self.wake_by_model = wake_by_model
            self.wake_by_role = wake_by_role
            self.backends = backends

    def resolve(self, model):
        """-> (endpoint, model_real) o (None, None)."""
        with self._lock:
            if model.startswith("role:"):
                role = model.split(":", 1)[1]
                pool = self.by_role.get(role) or []
                if not pool:
                    return None, None
                i = self._rr.get(role, 0) % len(pool)
                self._rr[role] = i + 1
                real = pool[i]
                return self.by_model[real]["endpoint"], real
            hit = self.by_model.get(model)
            return (hit["endpoint"], model) if hit else (None, None)

    def wake_candidate(self, model):
        with self._lock:
            if model.startswith("role:"):
                role = model.split(":", 1)[1]
                candidates = self.wake_by_role.get(role) or []
                return candidates[0] if candidates else None
            return self.wake_by_model.get(model)

    def snapshot(self):
        with self._lock:
            return {"backends": self.backends,
                    "roles": {r: list(m) for r, m in self.by_role.items()}}


REGISTRY = Registry()
WAKE_LOCKS = {}
WAKE_LOCKS_GUARD = threading.Lock()


def k8s_get(path):
    token = open(f"{_SA}/token").read()
    ctx = ssl.create_default_context(cafile=f"{_SA}/ca.crt")
    req = urllib.request.Request(
        f"https://kubernetes.default.svc{path}",
        headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.load(r)


def probe_models(endpoint):
    try:
        with urllib.request.urlopen(f"{endpoint}/v1/models", timeout=PROBE_TIMEOUT) as r:
            data = json.load(r)
        return [m["id"] for m in data.get("data", [])], True
    except Exception:
        return [], False


def discover_once():
    sel = urllib.parse.quote(LABEL)
    svcs = k8s_get(f"/api/v1/namespaces/{NAMESPACE}/services?labelSelector={sel}")
    backends = []
    for s in svcs.get("items", []):
        metadata = s.get("metadata", {})
        annotations = metadata.get("annotations") or {}
        name = metadata["name"]
        role = metadata.get("labels", {}).get(LABEL, "unknown")
        port = s["spec"]["ports"][0]["port"]
        endpoint = f"http://{name}.{NAMESPACE}.svc:{port}"
        expected_models = [
            item.strip()
            for item in annotations.get(MODEL_ANNOTATION, "").split(",")
            if item.strip()
        ]
        wake_url = annotations.get(WAKE_URL_ANNOTATION)
        models, healthy = probe_models(endpoint)
        backends.append({
            "service": name,
            "role": role,
            "endpoint": endpoint,
            "models": models,
            "expected_models": expected_models,
            "healthy": healthy,
            "wake_url": wake_url,
        })
    REGISTRY.update(backends)
    return backends


def discover_loop():
    while True:
        try:
            discover_once()
        except Exception as e:
            print(f"[discover] error: {e}", flush=True)
        time.sleep(REFRESH_SECS)


def wake_lock_for(service):
    with WAKE_LOCKS_GUARD:
        if service not in WAKE_LOCKS:
            WAKE_LOCKS[service] = threading.Lock()
        return WAKE_LOCKS[service]


def call_wake(candidate, model):
    url = candidate.get("wake_url")
    if not url:
        raise RuntimeError("backend has no wake_url")
    print(f"[wake] model={model} service={candidate['service']} url={url}", flush=True)
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=WAKE_TIMEOUT) as r:
        detail = r.read(2000)
        print(f"[wake] service={candidate['service']} status={r.status} body={detail[:200]!r}", flush=True)


def resolve_or_wake(model):
    endpoint, real = REGISTRY.resolve(model)
    if endpoint:
        return endpoint, real, None
    if not WAKE_ENABLED:
        return None, None, None

    candidate = REGISTRY.wake_candidate(model)
    if not candidate:
        return None, None, None

    lock = wake_lock_for(candidate["service"])
    with lock:
        endpoint, real = REGISTRY.resolve(model)
        if endpoint:
            return endpoint, real, None
        try:
            call_wake(candidate, model)
            deadline = time.time() + WAKE_DISCOVERY_TIMEOUT
            while time.time() < deadline:
                discover_once()
                endpoint, real = REGISTRY.resolve(model)
                if endpoint:
                    return endpoint, real, None
                time.sleep(WAKE_POLL_SECS)
            return None, None, f"wake completed but model '{model}' did not become healthy"
        except Exception as e:
            return None, None, str(e)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}", flush=True)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"status": "ok"})
        if self.path == "/readyz":
            snap = REGISTRY.snapshot()
            healthy = [b for b in snap["backends"] if b["healthy"]]
            code = 200 if healthy else 503
            return self._json(code, {"status": "ready" if healthy else "no healthy backends",
                                     "healthy_backends": len(healthy)})
        if self.path == "/backends":
            return self._json(200, REGISTRY.snapshot())
        if self.path == "/v1/models":
            snap = REGISTRY.snapshot()
            data = []
            for b in snap["backends"]:
                if not b["healthy"]:
                    continue
                for m in b["models"]:
                    data.append({"id": m, "object": "model", "owned_by": b["service"],
                                 "metadata": {"role": b["role"]}})
            for role in snap["roles"]:
                data.append({"id": f"role:{role}", "object": "model",
                             "owned_by": "llm-gateway", "metadata": {"alias": True}})
            return self._json(200, {"object": "list", "data": data})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/v1/chat/completions", "/v1/completions", "/v1/embeddings"):
            return self._json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._json(400, {"error": "invalid json body"})
        model = body.get("model", "")
        endpoint, real, wake_error = resolve_or_wake(model)
        if not endpoint:
            if wake_error:
                return self._json(503, {"error": {
                    "message": f"model '{model}' wake failed: {wake_error}",
                    "type": "wake_failed"}})
            return self._json(404, {"error": {
                "message": f"model '{model}' not found (ni exacto ni alias role:)",
                "type": "model_not_found"}})
        body["model"] = real
        payload = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{endpoint}{self.path}", data=payload,
            headers={"Content-Type": "application/json"})
        try:
            upstream = urllib.request.urlopen(req, timeout=BACKEND_TIMEOUT)
        except urllib.error.HTTPError as e:
            detail = e.read()[:2000]
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(detail)))
            self.end_headers()
            self.wfile.write(detail)
            return
        except Exception as e:
            return self._json(502, {"error": {"message": f"backend error: {e}",
                                              "type": "bad_gateway"}})
        # passthrough (streaming SSE incluido): chunks tal cual llegan
        self.send_response(upstream.status)
        ctype = upstream.headers.get("Content-Type", "application/json")
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                chunk = upstream.read1(65536)
                if not chunk:
                    break
                self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        finally:
            upstream.close()


def main():
    threading.Thread(target=discover_loop, daemon=True).start()
    print(f"[gateway] ns={NAMESPACE} label={LABEL} port={PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
