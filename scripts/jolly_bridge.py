#!/usr/bin/env python3
"""Converse's authenticated Jolly ingress. No model or fallback backend lives here.
The app owns agent selection/execution. This service only journals requests and
serves their correlated replies while preserving the existing phone connector URL.
"""
import argparse
import hashlib
import hmac
import json
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

MAX_BODY = 16384
LOCK = threading.RLock()

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name("." + uuid.uuid4().hex + ".tmp")
    try:
        temp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        temp.chmod(0o600)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)

def read(path, fallback=None):
    try:
        if path.stat().st_size > 2_000_000:
            return fallback
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback

class Bridge:
    def __init__(self, root, token_file, public_base):
        self.admissions = []
        self.root, self.token_file, self.public_base = Path(root), Path(token_file), public_base.rstrip("/")
        for name in ("requests", "responses", "images", "outbox"):
            (self.root / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    def authorized(self, header):
        try:
            token = self.token_file.read_text().strip()
        except OSError:
            return False
        return bool(token) and hmac.compare_digest(header.encode(), ("Bearer " + token).encode())
    def directory(self):
        doc = read(self.root / "directory.json", {})
        return doc if time.time() - doc.get("updatedAt", 0) < 20 else {"agents": [], "available": False}
    def admit(self, payload):
        question, context, agent = payload.get("question", ""), payload.get("context", ""), payload.get("agent", "")
        request_id = payload.get("request_id") or str(uuid.uuid4())
        if not all(isinstance(x, str) for x in (question, context, agent, request_id)) or not question.strip() or len(question) > 4000 or len(context) > 8000 or len(agent) > 200 or len(request_id) > 128:
            return 400, {"ok": False, "error": "Invalid question, context, agent, or request_id."}
        key = hashlib.sha256(request_id.encode()).hexdigest()
        body = {"id": key, "requestID": request_id, "question": question, "context": context, "agent": agent}
        with LOCK:
            path = self.root / "requests" / (key + ".json")
            prior = read(path)
            if prior:
                if any(prior.get(k) != body[k] for k in ("question", "context", "agent")):
                    return 409, {"ok": False, "error": "request_id already belongs to a different request."}
                return self.result(key)
            now = time.monotonic()
            self.admissions = [at for at in self.admissions if now - at < 3600]
            if len(self.admissions) >= 30:
                return 429, {"ok": False, "error": "Jolly hourly request limit reached."}
            if not self.directory().get("available", False):
                return 503, {"ok": False, "error": "Converse is unavailable. Open Converse on its home Mac. No other backend was contacted."}
            # Never evict idempotency records. A full journal fails visibly.
            if sum(1 for _ in (self.root / "requests").glob("*.json")) >= 10000:
                return 503, {"ok": False, "error": "Jolly request journal is full."}
            body["createdAt"] = time.time()
            atomic(path, body)
            self.admissions.append(now)
        return 202, {"ok": True, "status": "pending", "requestId": key}
    def result(self, key):
        if not re.fullmatch("[0-9a-f]{64}", key):
            return 400, {"ok": False, "error": "Invalid request ID."}
        result = read(self.root / "responses" / (key + ".json"))
        if result:
            result["requestId"] = key
            image = result.pop("imageID", None)
            if image and re.fullmatch("[0-9a-f]{64}", image):
                result["images"] = [{"title": "Agent scoreboard art", "url": self.public_base + "/v1/images/" + image}]
            return 200, result
        if not (self.root / "requests" / (key + ".json")).exists():
            return 404, {"ok": False, "error": "Unknown request."}
        return 202, {"ok": True, "status": "pending", "requestId": key}

def schema():
    security = [{"bearerAuth": []}]
    def get(summary):
        return {"get": {"summary": summary, "security": security, "responses": {"200": {"description": "JSON result"}}}}
    def post(summary, properties, required):
        body = {"type": "object", "required": required, "properties": properties}
        return {"post": {"summary": summary, "security": security,
            "requestBody": {"required": True, "content": {"application/json": {"schema": body}}},
            "responses": {"200": {"description": "Result"}, "202": {"description": "Pending: poll requestId"}, "503": {"description": "Converse unavailable"}}}}
    paths = {"/health": get("Bridge health"), "/identity": get("Converse routing identity"),
        "/v1/agents": get("Agents available to Jolly"),
        "/v1/inbox": get("Read pending messages without consuming them")}
    paths["/health"]["get"]["security"] = []
    paths["/v1/requests/{requestId}"] = get("Poll a previously submitted request")
    paths["/v1/requests/{requestId}"]["get"]["parameters"] = [{"name": "requestId", "in": "path", "required": True, "schema": {"type": "string"}}]
    paths["/v1/inbox/ack"] = post("Acknowledge received inbox message IDs",
        {"ids": {"type": "array", "items": {"type": "string"}, "maxItems": 100}}, ["ids"])
    paths["/v1/ask"] = post("Ask a Converse agent", {
        "question": {"type": "string", "maxLength": 4000}, "context": {"type": "string", "maxLength": 8000},
        "agent": {"type": "string", "maxLength": 200, "description": "Agent ID or exact name from /v1/agents"},
        "request_id": {"type": "string", "maxLength": 128, "description": "Stable unique ID for this request; reuse on retries"}}, ["question"])
    return {"openapi": "3.0.3", "info": {"title": "Ask Converse", "version": "3.0.0",
        "description": "Jolly addresses Converse agents. List agents, then ask with an agent ID or exact name. If ambiguous, ask Richard which agent; never guess or broadcast. Reuse request_id when retrying. A pending response has requestId: poll /v1/requests/{requestId}. Agent execution can take minutes. No fallback backend. Inbox is non-consuming; acknowledge received IDs explicitly."},
        "components": {"securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer"}}}, "paths": paths}

def handler(bridge, wait_seconds=20):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ConverseJolly/3"
        def log_message(self, *_):
            pass  # Never put prompts, headers or tokens in service logs.
        def send(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store"); self.end_headers()
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
        def auth(self):
            if bridge.authorized(self.headers.get("Authorization", "")): return True
            self.send(401, {"ok": False, "error": "Unauthorized."}); return False
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/health": return self.send(200, {"ok": True, "service": "converse-jolly", "backend": "converse", "appAvailable": bridge.directory().get("available", False)})
            if path == "/openapi.json": return self.send(200, schema())
            if path.startswith("/v1/images/"):
                key = path.removeprefix("/v1/images/")
                file = bridge.root / "images" / (key + ".png")
                if not re.fullmatch("[0-9a-f]{64}", key) or not file.is_file() or file.stat().st_size > 8_000_000:
                    return self.send(404, {"ok": False, "error": "Image unavailable."})
                data = file.read_bytes()
                self.send_response(200); self.send_header("Content-Type", "image/png"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
            if not self.auth(): return
            if path == "/identity": return self.send(200, {"ok": True, "backend": "converse", "available": bridge.directory().get("available", False)})
            if path == "/v1/agents": return self.send(200, {"ok": True, **bridge.directory()})
            if path.startswith("/v1/requests/"): return self.send(*bridge.result(path.removeprefix("/v1/requests/")))
            if path == "/v1/inbox":
                with LOCK:
                    messages = [read(p) for p in sorted((bridge.root / "outbox").glob("*.json"))]
                    messages = [m for m in messages if m and not m.get("read")][:100]
                return self.send(200, {"ok": True, "messages": messages, "consumed": False})
            return self.send(410, {"ok": False, "error": "This connector now routes only to Converse agents. Refresh its schema."})
        def do_POST(self):
            if not self.auth(): return
            try:
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 <= length <= MAX_BODY: raise ValueError()
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict): raise ValueError()
            except (ValueError, OSError):
                return self.send(400, {"ok": False, "error": "Invalid or oversized JSON."})
            path = urlsplit(self.path).path
            if path == "/v1/inbox/ack":
                ids = body.get("ids")
                if not isinstance(ids, list) or len(ids) > 100 or any(not isinstance(i, str) or not re.fullmatch("[0-9a-f-]{32,64}", i) for i in ids):
                    return self.send(400, {"ok": False, "error": "Invalid message IDs."})
                with LOCK:
                    for key in ids:
                        file = bridge.root / "outbox" / (key + ".json")
                        value = read(file)
                        if value: value["read"] = True; atomic(file, value)
                return self.send(200, {"ok": True})
            if path != "/v1/ask": return self.send(410, {"ok": False, "error": "Retired operation. Use Converse agents."})
            status, result = bridge.admit(body)
            if status == 202:
                deadline = time.monotonic() + wait_seconds
                while time.monotonic() < deadline:
                    time.sleep(.1)
                    status, result = bridge.result(result["requestId"])
                    if status != 202: break
            return self.send(status, result)
    return Handler

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args, **kwargs)
    def process_request(self, request, address):
        if not self.slots.acquire(False):
            request.close(); return
        request.settimeout(30)
        try: super().process_request(request, address)
        except Exception: self.slots.release(); raise
    def process_request_thread(self, request, address):
        try: super().process_request_thread(request, address)
        finally: self.slots.release()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--port", type=int, default=4691)
    parser.add_argument("--public-base", default="https://muse.kaoslabs.app")
    args = parser.parse_args()
    os.umask(0o077)
    bridge = Bridge(args.root, args.token_file, args.public_base)
    Server(("127.0.0.1", args.port), handler(bridge)).serve_forever()
