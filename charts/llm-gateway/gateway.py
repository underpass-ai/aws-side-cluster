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

_SA = "/var/run/secrets/kubernetes.io/serviceaccount"


class Registry:
    """Tabla de rutas: modelo->backend y rol->[backends sanos]."""

    def __init__(self):
        self._lock = threading.Lock()
        self.by_model = {}   # model_id -> {"endpoint","role","service"}
        self.by_role = {}    # role -> [model_id, ...] (solo sanos)
        self.backends = []   # estado completo para /backends
        self._rr = {}        # role -> indice round-robin

    def update(self, backends):
        by_model, by_role = {}, {}
        for b in backends:
            for m in b["models"]:
                by_model[m] = {"endpoint": b["endpoint"], "role": b["role"],
                               "service": b["service"]}
                if b["healthy"]:
                    by_role.setdefault(b["role"], []).append(m)
        with self._lock:
            self.by_model, self.by_role, self.backends = by_model, by_role, backends

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

    def snapshot(self):
        with self._lock:
            return {"backends": self.backends,
                    "roles": {r: list(m) for r, m in self.by_role.items()}}


REGISTRY = Registry()


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


def discover_loop():
    sel = urllib.parse.quote(LABEL)
    while True:
        try:
            svcs = k8s_get(f"/api/v1/namespaces/{NAMESPACE}/services?labelSelector={sel}")
            backends = []
            for s in svcs.get("items", []):
                name = s["metadata"]["name"]
                role = s["metadata"]["labels"].get(LABEL, "unknown")
                port = s["spec"]["ports"][0]["port"]
                endpoint = f"http://{name}.{NAMESPACE}.svc:{port}"
                models, healthy = probe_models(endpoint)
                backends.append({"service": name, "role": role, "endpoint": endpoint,
                                 "models": models, "healthy": healthy})
            REGISTRY.update(backends)
        except Exception as e:
            print(f"[discover] error: {e}", flush=True)
        time.sleep(REFRESH_SECS)


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
        endpoint, real = REGISTRY.resolve(model)
        if not endpoint:
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
