import asyncio
import contextlib
import copy
import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import time
import unicodedata
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from urllib.parse import parse_qs, urlsplit

from solara_cli import cli, endpoint, runner


ROWS = [
    {"targetId": "small", "title": "Small", "url": "https://small.test/path", "profile": "Personal", "discarded": False, "bytes": 125000000},
    {"targetId": "sleep", "title": "Sleeping", "url": "https://sleep.test/", "profile": "Personal", "discarded": True, "bytes": None},
    {"targetId": "large", "title": "Large", "url": "https://large.test/path", "profile": "Work", "discarded": False, "bytes": 1500000000},
    {"targetId": "unknown", "title": "Unknown", "url": "https://unknown.test/", "profile": "Work", "discarded": False, "bytes": None},
    {"targetId": "zero", "title": "Zero", "url": "https://zero.test/", "profile": "Work", "discarded": False, "bytes": 0},
]
TOKEN = "solara-tabs-test-token"


class Tabs(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="solara-tabs-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.rows = copy.deepcopy(ROWS)
        self.requests = []
        self.status = 200
        self.raw = None
        self.redirect = None
        self.pause = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                owner.requests.append((self.path, dict(self.headers)))
                if owner.pause:
                    time.sleep(owner.pause)
                parts = urlsplit(self.path)
                if parts.path != "/solara/tabs" or parse_qs(parts.query) != {"token": [TOKEN]}:
                    self.send_response(403)
                    self.end_headers()
                    return
                self.send_response(owner.status)
                if owner.redirect:
                    self.send_header("Location", owner.redirect)
                payload = owner.raw if owner.raw is not None else json.dumps(owner.rows).encode()
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.port = self.server.server_address[1]
        control = self.root / "Chromium" / endpoint.CONTROL_FILE
        control.parent.mkdir()
        control.write_text(json.dumps({"port": self.port, "browser": "/devtools/browser/test", "token": TOKEN, "pid": os.getpid(), "generation": 1}))
        control.chmod(0o600)
        self.control = control
        self.environ = mock.patch.dict(os.environ, {"SOLARA_DATA_DIR": str(self.root), "SOLARA_CDP_URL": ""})
        self.environ.start()
        self.addCleanup(self.environ.stop)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def run_cli(self, *args, width=100):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch("shutil.get_terminal_size", return_value=os.terminal_size((width, 24))):
            try:
                code = cli.main(["tabs", *args])
            except SystemExit as error:
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def test_table_sorts_bytes_and_keeps_sleeping_unknown_and_zero_distinct(self):
        code, out, err = self.run_cli()
        self.assertEqual((code, err), (0, ""))
        lines = out.splitlines()
        self.assertIn("Memory", lines[0])
        self.assertIn("Title", lines[0])
        self.assertIn("URL", lines[0])
        self.assertIn("Profile", lines[0])
        self.assertLess(out.index("Large"), out.index("Small"))
        self.assertLess(out.index("Small"), out.index("Zero"))
        self.assertLess(out.index("Zero"), out.index("Sleeping"))
        for title, memory in (("Large", "1.5 GB"), ("Small", "125.0 MB"), ("Zero", "0.0 MB"), ("Sleeping", "—"), ("Unknown", "?")):
            self.assertIn(memory, next(line for line in lines if title in line))
        self.assertIn("1.6 GB", lines[-1])
        self.assertIn("5 tabs", lines[-1])
        self.assertIn("1 asleep", lines[-1])
        self.assertIn("1 unknown", lines[-1])
        self.assertIn("Known total", lines[-1])
        self.assertEqual(self.rows, ROWS)

    def test_json_keeps_endpoint_order_and_exact_byte_values(self):
        code, out, err = self.run_cli("--json")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), ROWS)
        self.assertEqual(len(self.requests), 1)
        self.assertNotIn("Origin", self.requests[0][1])

    def test_integral_float_bytes_preserve_native_json_values(self):
        self.rows[0]["bytes"] = 125000000.0
        code, out, err = self.run_cli("--json")
        self.assertEqual((code, err), (0, ""))
        self.assertIs(type(json.loads(out)[0]["bytes"]), float)
        self.assertEqual(json.loads(out), self.rows)
        code, out, err = self.run_cli()
        self.assertEqual((code, err), (0, ""))
        self.assertIn("125.0 MB", out)

    def test_rendering_failure_exits_one_without_traceback(self):
        self.rows[0]["bytes"] = 10 ** 400
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (1, ""))
        self.assertTrue(err)
        self.assertNotIn("Traceback", err)

    def test_widths_use_host_first_urls_and_safe_single_line_cells(self):
        self.rows = [{"targetId": "wide", "title": "資料" * 40 + "\n\x1b[31m", "url": "https://host.example/" + "long-path/" * 30, "profile": "仕事" * 20, "discarded": False, "bytes": 12000000}]
        for width in (40, 60, 80, 120):
            with self.subTest(width=width):
                code, out, err = self.run_cli(width=width)
                self.assertEqual((code, err), (0, ""))
                self.assertNotIn("\x1b", out)
                self.assertNotIn("https://", out)
                self.assertIn("host.example", out)
                for line in out.splitlines():
                    cells = sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in line)
                    self.assertLessEqual(cells, width, line)

    def test_full_keeps_whole_urls_even_when_they_exceed_terminal_width(self):
        url = "https://host.example/" + "long/" * 50 + "?query=whole#fragment"
        self.rows[0]["url"] = url
        code, out, err = self.run_cli("--full", width=40)
        self.assertEqual((code, err), (0, ""))
        self.assertIn(url, out)

    def test_empty_snapshot_has_zero_footer(self):
        self.rows = []
        code, out, err = self.run_cli()
        self.assertEqual((code, err), (0, ""))
        self.assertIn("0.0 MB", out)
        self.assertIn("0 tabs", out)
        self.assertIn("0 asleep", out)

    def test_explicit_devtools_routes_are_refused_before_any_request(self):
        for args in (("--port", str(self.port)), ("--ws", f"ws://127.0.0.1:{self.port}/devtools/browser/test")):
            with self.subTest(args=args):
                code, out, err = self.run_cli(*args)
                self.assertEqual((code, out), (2, ""))
                self.assertIn("SolaraControl.json", err)
                self.assertIn(args[0], err)
        with mock.patch.dict(os.environ, {"SOLARA_CDP_URL": f"ws://127.0.0.1:{self.port}/devtools/browser/test"}):
            code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertIn("SOLARA_CDP_URL", err)
        self.assertEqual(self.requests, [])

    def test_unsafe_or_missing_control_file_is_refused_without_request(self):
        self.control.chmod(0o644)
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertIn("0600", err)
        self.control.unlink()
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertIn("isn't running", err)
        self.assertEqual(self.requests, [])

    def test_http_failures_and_malformed_snapshots_are_exit_two_without_tokens(self):
        cases = [(503, None), (200, b"not json"), (200, b'{"tabs": []}'), (200, json.dumps([{**ROWS[0], "bytes": -1}]).encode()), (200, json.dumps([{**ROWS[0], "bytes": True}]).encode()), (200, json.dumps([{**ROWS[0], "bytes": float("inf")}]).encode()), (200, json.dumps([{**ROWS[0], "bytes": 1.5}]).encode())]
        for status, raw in cases:
            with self.subTest(status=status, raw=raw):
                self.status, self.raw = status, raw
                code, out, err = self.run_cli("--json")
                self.assertEqual((code, out), (2, ""))
                self.assertTrue(err)
                self.assertNotIn(TOKEN, err)
                self.assertNotIn("Traceback", err)

    def test_proxy_environment_does_not_receive_control_requests(self):
        with mock.patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "no_proxy": "", "NO_PROXY": ""}):
            code, out, err = self.run_cli("--json")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), ROWS)
        self.assertEqual(len(self.requests), 1)

    def test_oversized_snapshot_is_rejected_without_output(self):
        from solara_cli import tab_memory

        with mock.patch.object(tab_memory, "MAX_RESPONSE_BYTES", 64):
            code, out, err = self.run_cli("--json")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("too large", err)

    def test_redirect_never_forwards_token(self):
        self.status = 302
        self.redirect = f"http://127.0.0.1:{self.port}/stolen?token={TOKEN}"
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertNotIn(TOKEN, err)
        self.assertEqual(len(self.requests), 1)

    def test_helper_reads_same_snapshot_and_rejects_explicit_endpoint(self):
        from solara_cli import tab_memory

        actual = asyncio.run(tab_memory.read(endpoint.resolve()))
        self.assertEqual(actual, ROWS)
        with self.assertRaises(endpoint.EndpointError) as caught:
            asyncio.run(tab_memory.read(endpoint.Endpoint("ws://127.0.0.1:1/devtools/browser/test", "--ws", True)))
        self.assertIn("SolaraControl.json", str(caught.exception))
        self.assertEqual(len(self.requests), 1)

    @unittest.skipUnless(importlib.util.find_spec("pydoll"), "exec namespace needs pydoll")
    def test_exec_namespace_exposes_tab_memory(self):
        namespace = runner.build_namespace(SimpleNamespace(endpoint=endpoint.resolve(), browser=None), "<test>", self.root)
        self.assertEqual(asyncio.run(namespace["tab_memory"]()), ROWS)

    def test_async_deadline_returns_when_http_server_stalls(self):
        from solara_cli import tab_memory

        self.pause = 1
        start = time.monotonic()
        with mock.patch.object(tab_memory, "REQUEST_TIMEOUT", 0.05), self.assertRaises(endpoint.EndpointError):
            asyncio.run(tab_memory.read(endpoint.resolve()))
        self.assertLess(time.monotonic() - start, 0.8)


if __name__ == "__main__":
    unittest.main()
