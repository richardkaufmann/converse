import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).resolve().parents[1] / "scripts/jolly_bridge.py")
bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.token = self.root / "token"; self.token.write_text("synthetic-test-token")
        self.b = bridge.Bridge(self.root / "spool", self.token, "https://example.test")
        self.server = bridge.Server(("127.0.0.1", 0), bridge.handler(self.b, wait_seconds=.05))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = "http://127.0.0.1:" + str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.temp.cleanup()
    def call(self, path, body=None, auth=True):
        headers = {"Authorization": "Bearer synthetic-test-token"} if auth else {}
        data = None if body is None else json.dumps(body).encode()
        if data is not None: headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=3) as r: return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            with e: return e.code, json.load(e)
    def live(self):
        bridge.atomic(self.b.root / "directory.json", {"available": True, "updatedAt": time.time(), "agents": [{"id": "fixture", "name": "Stock"}]})
    def test_auth_and_retired_routes(self):
        self.assertEqual(self.call("/health", auth=False)[1]["backend"], "converse")
        self.assertEqual(self.call("/v1/agents", auth=False)[0], 401)
        self.assertEqual(self.call("/v1/jobs/prepare", {"world": "never-run"})[0], 410)
        self.assertNotIn("/v1/jobs/prepare", self.call("/openapi.json", auth=False)[1]["paths"])
        self.token.unlink()
        self.assertEqual(self.call("/identity")[0], 401)
    def test_request_idempotency_and_correlation(self):
        self.live()
        body = {"question": "Price?", "agent": "Stock", "request_id": "same"}
        status, result = self.call("/v1/ask", body)
        self.assertEqual(status, 202)
        key = result["requestId"]
        self.assertEqual(self.call("/v1/ask", body)[1]["requestId"], key)
        self.assertEqual(len(list((self.b.root / "requests").glob("*.json"))), 1)
        self.assertEqual(self.call("/v1/ask", {**body, "question": "Different"})[0], 409)
        bridge.atomic(self.b.root / "responses" / (key + ".json"), {"ok": True, "status": "completed", "answer": "fixture"})
        self.assertEqual(self.call("/v1/requests/" + key)[1]["answer"], "fixture")
        self.assertEqual(self.call("/v1/ask", body)[1]["answer"], "fixture")
    def test_app_unavailable_and_limits(self):
        self.assertEqual(self.call("/v1/ask", {"question": "Hi"})[0], 503)
        self.live()
        self.assertEqual(self.call("/v1/ask", {"question": "x"*4001})[0], 400)
        self.assertEqual(self.call("/v1/ask", {"question": ["bad"]})[0], 400)
        bridge.atomic(self.b.root / "directory.json", {"available": True, "updatedAt": time.time()-30})
        self.assertEqual(self.call("/v1/ask", {"question": "Hi"})[0], 503)
    def test_rate_bound_and_replay(self):
        self.live()
        body = {"question": "One", "request_id": "first"}
        self.assertEqual(self.b.admit(body)[0], 202)
        self.b.admissions = [time.monotonic()] * 30
        self.assertEqual(self.b.admit({"question": "New", "request_id": "new"})[0], 429)
        self.assertEqual(self.b.admit(body)[0], 202)
    def test_inbox_ack_and_traversal(self):
        key = "a"*64
        bridge.atomic(self.b.root / "outbox" / (key + ".json"), {"id": key, "text": "hi", "read": False})
        self.assertEqual(len(self.call("/v1/inbox")[1]["messages"]), 1)
        self.assertEqual(len(self.call("/v1/inbox")[1]["messages"]), 1)
        self.assertEqual(self.call("/v1/inbox/ack", {"ids": ["../../token"]})[0], 400)
        self.assertEqual(self.call("/v1/inbox/ack", {"ids": [key]})[0], 200)
        self.assertEqual(self.call("/v1/inbox")[1]["messages"], [])
        self.assertEqual(self.call("/v1/requests/../../token")[0], 400)
        self.assertEqual(self.call("/v1/images/../../token", auth=False)[0], 404)

if __name__ == "__main__": unittest.main()
