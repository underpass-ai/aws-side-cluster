#!/usr/bin/env python3
import argparse
import http.server
import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def env_int(name, default):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return int(value)


def env_float(name, default):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return float(value)


class Config:
    listen_host = os.environ.get("DEMAND_GATEWAY_LISTEN_HOST", "0.0.0.0")
    listen_port = env_int("DEMAND_GATEWAY_LISTEN_PORT", 18080)
    aws_region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "eu-south-2"))
    profiles_file = os.environ.get("DEMAND_GATEWAY_PROFILES_FILE", "config/demand-gateway-profiles.json")
    profiles_configmap = os.environ.get("DEMAND_GATEWAY_PROFILES_CONFIGMAP", "")
    desired_workers = env_int("DEMAND_GATEWAY_DESIRED_WORKERS", 2)
    min_ready_nodes = env_int("DEMAND_GATEWAY_MIN_READY_NODES", 2)
    min_ready_endpoints = env_int("DEMAND_GATEWAY_MIN_READY_ENDPOINTS", 1)
    node_selector = os.environ.get("DEMAND_GATEWAY_NODE_SELECTOR", "underpass.ai/node-pool=aws-poc")
    target_namespace = os.environ.get("DEMAND_GATEWAY_TARGET_NAMESPACE", "underpass-labs")
    target_service = os.environ.get("DEMAND_GATEWAY_TARGET_SERVICE", "aws-echo")
    target_base_url = os.environ.get("DEMAND_GATEWAY_TARGET_BASE_URL", "http://192.168.1.242")
    warmup_timeout = env_float("DEMAND_GATEWAY_WARMUP_TIMEOUT_SECONDS", 600)
    poll_seconds = env_float("DEMAND_GATEWAY_POLL_SECONDS", 10)
    sync_seconds = env_float("DEMAND_GATEWAY_SYNC_SECONDS", 15)
    sync_command = os.environ.get("DEMAND_GATEWAY_SYNC_COMMAND", "")
    proxy_timeout = env_float("DEMAND_GATEWAY_PROXY_TIMEOUT_SECONDS", 60)
    idle_seconds = env_float("DEMAND_GATEWAY_IDLE_SECONDS", 0)


class Profile:
    def __init__(
        self,
        name,
        prefix,
        target_namespace,
        target_service,
        target_base_url,
        node_selector,
        desired_workers,
        min_ready_nodes,
        min_ready_endpoints,
        idle_seconds,
        aws_tag_key=None,
        aws_tag_value=None,
        strip_prefix=True,
    ):
        self.name = name
        self.prefix = prefix.rstrip("/") if prefix and prefix != "/" else prefix
        self.target_namespace = target_namespace
        self.target_service = target_service
        self.target_base_url = target_base_url
        self.node_selector = node_selector
        self.desired_workers = desired_workers
        self.min_ready_nodes = min_ready_nodes
        self.min_ready_endpoints = min_ready_endpoints
        self.idle_seconds = idle_seconds
        self.aws_tag_key = aws_tag_key
        self.aws_tag_value = aws_tag_value
        self.strip_prefix = strip_prefix

    @classmethod
    def default(cls):
        return cls(
            name="default",
            prefix=None,
            target_namespace=Config.target_namespace,
            target_service=Config.target_service,
            target_base_url=Config.target_base_url,
            node_selector=Config.node_selector,
            desired_workers=Config.desired_workers,
            min_ready_nodes=Config.min_ready_nodes,
            min_ready_endpoints=Config.min_ready_endpoints,
            idle_seconds=Config.idle_seconds,
        )

    @classmethod
    def from_dict(cls, item, defaults):
        return cls(
            name=item["name"],
            prefix=item["prefix"],
            target_namespace=item.get("target_namespace", defaults.target_namespace),
            target_service=item.get("target_service", defaults.target_service),
            target_base_url=item.get("target_base_url", defaults.target_base_url),
            node_selector=item.get("node_selector", defaults.node_selector),
            desired_workers=int(item.get("desired_workers", defaults.desired_workers)),
            min_ready_nodes=int(item.get("min_ready_nodes", defaults.min_ready_nodes)),
            min_ready_endpoints=int(item.get("min_ready_endpoints", defaults.min_ready_endpoints)),
            idle_seconds=float(item.get("idle_seconds", defaults.idle_seconds)),
            aws_tag_key=item.get("aws_tag_key"),
            aws_tag_value=str(item["aws_tag_value"]) if "aws_tag_value" in item else None,
            strip_prefix=bool(item.get("strip_prefix", True)),
        )

    def public(self):
        payload = {
            "name": self.name,
            "prefix": self.prefix,
            "desired_workers": self.desired_workers,
            "idle_seconds": self.idle_seconds,
            "min_ready_endpoints": self.min_ready_endpoints,
            "min_ready_nodes": self.min_ready_nodes,
            "node_selector": self.node_selector,
            "target": {
                "base_url": self.target_base_url,
                "namespace": self.target_namespace,
                "service": self.target_service,
            },
        }
        if self.aws_tag_key and self.aws_tag_value:
            payload["aws_tag"] = {
                "key": self.aws_tag_key,
                "value": self.aws_tag_value,
            }
        return payload


def load_profiles():
    default = Profile.default()
    if Config.profiles_configmap:
        if "/" in Config.profiles_configmap:
            namespace, name = Config.profiles_configmap.split("/", 1)
        else:
            namespace = Config.target_namespace
            name = Config.profiles_configmap
        data = kubectl_json(["-n", namespace, "get", "configmap", name])
        raw = json.loads(data.get("data", {}).get("profiles.json", "{}"))
    else:
        path = ROOT / Config.profiles_file
        if not path.exists():
            return [default]
        raw = json.loads(path.read_text(encoding="utf-8"))

    profiles = [default]
    for item in raw.get("profiles", raw.get("routes", [])):
        profiles.append(Profile.from_dict(item, default))

    routed = sorted(
        [profile for profile in profiles if profile.prefix],
        key=lambda profile: len(profile.prefix),
        reverse=True,
    )
    return routed + [default]


PROFILES = []
DEFAULT_PROFILE = None


class GatewayState:
    def __init__(self):
        self.lock = threading.Lock()
        self.profiles = {}

    def entry(self, profile_name):
        if profile_name not in self.profiles:
            self.profiles[profile_name] = {
                "last_request_at": None,
                "last_scale_up_at": None,
                "last_scale_down_at": None,
                "last_error": None,
                "warming": False,
            }
        return self.profiles[profile_name]

    def update(self, profile_name, **fields):
        with self.lock:
            self.entry(profile_name).update(fields)

    def snapshot(self, profile_name=None):
        with self.lock:
            if profile_name:
                return dict(self.entry(profile_name))
            return {
                "profiles": {
                    name: dict(state)
                    for name, state in sorted(self.profiles.items())
                }
            }


STATE = GatewayState()
WAKE_LOCK = threading.Lock()
STOP_EVENT = threading.Event()


def command_env():
    env = os.environ.copy()
    env["AWS_REGION"] = Config.aws_region
    env["AWS_DEFAULT_REGION"] = Config.aws_region
    return env


def run_command(args, timeout=120):
    completed = subprocess.run(
        args,
        cwd=ROOT,
        env=command_env(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{' '.join(args)} failed: {message}")
    return completed.stdout.strip()


def kubectl_json(args):
    output = run_command(["kubectl", *args, "-o", "json"], timeout=30)
    return json.loads(output)


def ready_condition(item):
    for condition in (item.get("status") or {}).get("conditions") or []:
        if condition.get("type") == "Ready":
            return condition.get("status") == "True"
    return False


def ready_aws_nodes(profile):
    data = kubectl_json(["get", "nodes", "-l", profile.node_selector])
    return [
        item["metadata"]["name"]
        for item in (data.get("items") or [])
        if ready_condition(item)
    ]


def ready_service_endpoints(profile):
    data = kubectl_json([
        "-n",
        profile.target_namespace,
        "get",
        "endpointslices",
        "-l",
        f"kubernetes.io/service-name={profile.target_service}",
    ])
    endpoints = []
    for item in (data.get("items") or []):
        for endpoint in (item.get("endpoints") or []):
            conditions = endpoint.get("conditions") or {}
            if conditions.get("ready", True) is False:
                continue
            endpoints.extend(endpoint.get("addresses") or [])
    return endpoints


def readiness_snapshot(profile):
    nodes = ready_aws_nodes(profile)
    endpoints = ready_service_endpoints(profile)
    return {
        "profile": profile.name,
        "ready_nodes": nodes,
        "ready_node_count": len(nodes),
        "ready_endpoints": endpoints,
        "ready_endpoint_count": len(endpoints),
        "target_ready": len(nodes) >= profile.min_ready_nodes and len(endpoints) >= profile.min_ready_endpoints,
    }


def scale_workers(count, profile):
    if profile.aws_tag_key and profile.aws_tag_value:
        args = ["scripts/ec2-pool.sh", "scale-tag", profile.aws_tag_key, profile.aws_tag_value, str(count)]
    else:
        args = ["scripts/ec2-pool.sh", "scale", str(count)]

    output = run_command(args, timeout=180)
    now = time.time()
    if count > 0:
        STATE.update(profile.name, last_scale_up_at=now)
    else:
        STATE.update(profile.name, last_scale_down_at=now)
    return output


def sync_wireguard():
    if Config.sync_command:
        return run_command(shlex.split(Config.sync_command), timeout=90)
    return "wireguard sync disabled"


def ensure_capacity(profile):
    snapshot = readiness_snapshot(profile)
    if snapshot["target_ready"]:
        return {"changed": False, "readiness": snapshot}

    with WAKE_LOCK:
        snapshot = readiness_snapshot(profile)
        if snapshot["target_ready"]:
            return {"changed": False, "readiness": snapshot}

        STATE.update(profile.name, warming=True, last_error=None)

        try:
            scale_output = scale_workers(profile.desired_workers, profile)
            deadline = time.time() + Config.warmup_timeout
            last_sync_at = 0.0
            last_snapshot = snapshot
            sync_error = None

            while time.time() < deadline:
                now = time.time()
                if now - last_sync_at >= Config.sync_seconds:
                    try:
                        sync_wireguard()
                        sync_error = None
                    except Exception as exc:
                        sync_error = str(exc)
                    last_sync_at = now

                last_snapshot = readiness_snapshot(profile)
                if last_snapshot["target_ready"]:
                    return {
                        "changed": True,
                        "scale_output": scale_output,
                        "wireguard_sync_error": sync_error,
                        "readiness": last_snapshot,
                    }
                time.sleep(Config.poll_seconds)

            raise TimeoutError(
                "timed out waiting for AWS workers/service readiness: "
                + json.dumps(last_snapshot, sort_keys=True)
            )
        except Exception as exc:
            STATE.update(profile.name, last_error=str(exc))
            raise
        finally:
            STATE.update(profile.name, warming=False)


def mark_request(profile):
    STATE.update(profile.name, last_request_at=time.time())


def json_response(handler, status, payload):
    body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if handler.command != "HEAD":
        try:
            handler.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def select_profile(path):
    for profile in PROFILES:
        if not profile.prefix:
            return profile, path
        if path == profile.prefix or path.startswith(profile.prefix + "/"):
            if not profile.strip_prefix:
                return profile, path
            upstream_path = path[len(profile.prefix):] or "/"
            if not upstream_path.startswith("/"):
                upstream_path = "/" + upstream_path
            return profile, upstream_path
    return DEFAULT_PROFILE, path


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class DemandGatewayHandler(http.server.BaseHTTPRequestHandler):
    server_version = "aws-demand-gateway/0.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def do_HEAD(self):
        self.route()

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_PUT(self):
        self.route()

    def do_PATCH(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/healthz":
            json_response(self, 200, {"ok": True})
            return
        if parsed.path == "/status":
            try:
                payload = {
                    "config": public_config(),
                    "state": STATE.snapshot(),
                    "readiness": [readiness_snapshot(profile) for profile in PROFILES],
                }
                json_response(self, 200, payload)
            except Exception as exc:
                json_response(self, 503, {"error": str(exc), "state": STATE.snapshot()})
            return
        if parsed.path == "/wake":
            self.handle_wake_only(DEFAULT_PROFILE)
            return

        profile, upstream_path = select_profile(parsed.path)
        if upstream_path == "/status":
            self.handle_profile_status(profile)
            return
        if upstream_path == "/wake":
            self.handle_wake_only(profile)
            return

        self.handle_proxy(profile, upstream_path)

    def handle_profile_status(self, profile):
        try:
            payload = {
                "config": profile.public(),
                "state": STATE.snapshot(profile.name),
                "readiness": readiness_snapshot(profile),
            }
            json_response(self, 200, payload)
        except Exception as exc:
            json_response(self, 503, {"error": str(exc), "state": STATE.snapshot(profile.name), "profile": profile.name})

    def handle_wake_only(self, profile):
        mark_request(profile)
        try:
            result = ensure_capacity(profile)
            json_response(self, 200, {"profile": profile.name, "ready": True, **result})
        except Exception as exc:
            json_response(self, 503, {"profile": profile.name, "ready": False, "error": str(exc), "state": STATE.snapshot(profile.name)})

    def handle_proxy(self, profile, upstream_path):
        mark_request(profile)
        try:
            ensure_capacity(profile)
            self.proxy_to_target(profile, upstream_path)
        except Exception as exc:
            json_response(self, 503, {"profile": profile.name, "error": str(exc), "state": STATE.snapshot(profile.name)})

    def request_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return None
        return self.rfile.read(length)

    def proxy_to_target(self, profile, upstream_path):
        parsed = urllib.parse.urlsplit(self.path)
        target_path = upstream_path
        if parsed.query:
            target_path = target_path + "?" + parsed.query
        target = profile.target_base_url.rstrip("/") + target_path
        body = None if self.command in {"GET", "HEAD"} else self.request_body()
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP_HEADERS:
                continue
            if key.lower() == "host":
                continue
            headers[key] = value

        request = urllib.request.Request(target, data=body, headers=headers, method=self.command)
        try:
            response = urllib.request.urlopen(request, timeout=Config.proxy_timeout)
        except urllib.error.HTTPError as exc:
            response = exc

        response_body = b"" if self.command == "HEAD" else response.read()
        self.send_response(response.status)
        for key, value in response.headers.items():
            if key.lower() in HOP_BY_HOP_HEADERS:
                continue
            if key.lower() == "content-length":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        if response_body:
            self.wfile.write(response_body)


def public_config():
    return {
        "aws_region": Config.aws_region,
        "desired_workers": Config.desired_workers,
        "idle_seconds": Config.idle_seconds,
        "listen": f"{Config.listen_host}:{Config.listen_port}",
        "min_ready_endpoints": Config.min_ready_endpoints,
        "min_ready_nodes": Config.min_ready_nodes,
        "node_selector": Config.node_selector,
        "profiles_configmap": Config.profiles_configmap,
        "profiles_file": Config.profiles_file,
        "profiles": [profile.public() for profile in PROFILES],
        "sync_command": Config.sync_command or "disabled",
        "target": {
            "base_url": Config.target_base_url,
            "namespace": Config.target_namespace,
            "service": Config.target_service,
        },
    }


def idle_reaper():
    while not STOP_EVENT.wait(30):
        now = time.time()
        for profile in PROFILES:
            if profile.idle_seconds <= 0:
                continue
            if not profile.aws_tag_key or not profile.aws_tag_value:
                continue
            snapshot = STATE.snapshot(profile.name)
            last_request_at = snapshot["last_request_at"]
            if snapshot["warming"] or last_request_at is None:
                continue
            if now - last_request_at < profile.idle_seconds:
                continue
            try:
                scale_workers(0, profile)
                STATE.update(profile.name, last_request_at=None, last_error=None)
            except Exception as exc:
                STATE.update(profile.name, last_error=str(exc))


def parse_args():
    parser = argparse.ArgumentParser(description="Wake/proxy gateway for AWS-backed Kubernetes workers.")
    parser.add_argument("--listen-host", default=Config.listen_host)
    parser.add_argument("--listen-port", type=int, default=Config.listen_port)
    parser.add_argument("--target-base-url", default=Config.target_base_url)
    parser.add_argument("--idle-seconds", type=float, default=Config.idle_seconds)
    parser.add_argument("--profiles-file", default=Config.profiles_file)
    parser.add_argument("--profiles-configmap", default=Config.profiles_configmap)
    return parser.parse_args()


def main():
    args = parse_args()
    Config.listen_host = args.listen_host
    Config.listen_port = args.listen_port
    Config.target_base_url = args.target_base_url
    Config.idle_seconds = args.idle_seconds
    Config.profiles_file = args.profiles_file
    Config.profiles_configmap = args.profiles_configmap

    global PROFILES, DEFAULT_PROFILE
    PROFILES = load_profiles()
    DEFAULT_PROFILE = next(profile for profile in PROFILES if profile.name == "default")
    for profile in PROFILES:
        STATE.snapshot(profile.name)

    threading.Thread(target=idle_reaper, daemon=True).start()

    server = http.server.ThreadingHTTPServer((Config.listen_host, Config.listen_port), DemandGatewayHandler)
    print(json.dumps({"event": "started", "config": public_config()}, sort_keys=True), flush=True)
    try:
        server.serve_forever()
    finally:
        STOP_EVENT.set()
        server.server_close()


if __name__ == "__main__":
    main()
