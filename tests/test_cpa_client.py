from __future__ import annotations

import http.server
import json
import pathlib
import sys
import tempfile
import threading
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import cpa_client  # noqa: E402


class _Handler(http.server.BaseHTTPRequestHandler):
    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == "Bearer test-secret"

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/v1/models" or not self._authorized():
            self.send_error(401)
            return
        payload = {"object": "list", "data": [{"id": "test-model"}]}
        self._send(payload)

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/responses" or not self._authorized():
            self.send_error(401)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        if body.get("model") != "test-model":
            self.send_error(400)
            return
        self._send({"id": "resp_test", "object": "response", "output": []})

    def _send(self, payload: dict[str, object]) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args: object) -> None:
        return


class CpaClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}/v1"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.thread.join(timeout=2)
        cls.server.server_close()

    def test_models_and_responses(self) -> None:
        cpa_client.check_models(self.base_url, "test-secret", "test-model", False)
        cpa_client.check_responses(self.base_url, "test-secret", "test-model")

    def test_missing_model_fails(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not present"):
            cpa_client.check_models(self.base_url, "test-secret", "missing", False)

    def test_read_key_strips_newline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "key"
            path.write_text("test-secret\n", encoding="utf-8")
            self.assertEqual(cpa_client.read_key(str(path)), "test-secret")

    def test_read_key_rejects_internal_whitespace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "key"
            path.write_text("test secret\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "whitespace"):
                cpa_client.read_key(str(path))


if __name__ == "__main__":
    unittest.main()
