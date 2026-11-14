import asyncio
import contextlib
import io
import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
from types import SimpleNamespace

from solara_cli import cli, endpoint, guard


TOKEN = "sidebar-unit-test-token"


class Socket:
    def __init__(self, response=None, hang=False, disconnect=False):
        self.response = response
        self.hang = hang
        self.disconnect = disconnect
        self.messages = []
        self.queue = asyncio.Queue()
        self.closed = False

    def __aiter__(self):
        return self

    async def __anext__(self):
        value = await self.queue.get()
        if value is None:
            raise StopAsyncIteration
        return value

    async def send(self, raw):
        message = json.loads(raw)
        self.messages.append(message)
        if self.disconnect:
            await self.queue.put(None)
        elif not self.hang:
            response = self.response
            if response is None:
                response = {"operation": message["params"]["operation"], "dryRun": message["params"].get("dryRun", False), "changes": ["Move tab t1"]}
            await self.queue.put(json.dumps({"id": message["id"], **response} if "error" in response else {"id": message["id"], "result": response}))

    async def close(self):
        self.closed = True
        await self.queue.put(None)


class Sidebar(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="solara-sidebar-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.control = self.root / "Chromium" / endpoint.CONTROL_FILE
        self.control.parent.mkdir()
        self.control.write_text(json.dumps({"port": 8123, "browser": "/devtools/browser/sidebar", "token": TOKEN, "pid": os.getpid(), "generation": 1}))
        self.control.chmod(0o600)
        self.environ = mock.patch.dict(os.environ, {"SOLARA_DATA_DIR": str(self.root), "SOLARA_CDP_URL": ""})
        self.environ.start()
        self.addCleanup(self.environ.stop)
        self.socket = None
        self.connections = []

    def run_cli(self, *args, response=None, hang=False, disconnect=False):
        out, err = io.StringIO(), io.StringIO()

        async def connect(url, **kwargs):
            self.connections.append((url, kwargs))
            self.socket = Socket(response, hang, disconnect)
            return self.socket

        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(guard, "direct_connect", side_effect=connect):
            try:
                code = cli.main(list(args))
            except SystemExit as error:
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def test_commands_send_store_requests_with_exact_identifiers(self):
        cases = [
            (["group", "create", "Research", "--color", "blue", "--tabs", "t1", "t2"], {"operation": "group.create", "name": "Research", "color": "blue", "tabs": ["t1", "t2"]}),
            (["folder", "create", "Work", "--tabs", "t1", "t2"], {"operation": "folder.create", "name": "Work", "tabs": ["t1", "t2"]}),
            (["group", "create", "Empty", "--window", "w2"], {"operation": "group.create", "name": "Empty", "windowId": "w2"}),
            (["folder", "create", "Empty", "--window", "w2"], {"operation": "folder.create", "name": "Empty", "windowId": "w2"}),
            (["tab", "move", "t1", "--to-group", "g1"], {"operation": "tab.move", "id": "t1", "toGroup": "g1"}),
            (["tab", "move", "t1", "--to-folder", "f1"], {"operation": "tab.move", "id": "t1", "toFolder": "f1"}),
            (["tab", "move", "t1", "--to-window", "w2"], {"operation": "tab.move", "id": "t1", "toWindow": "w2"}),
            (["tab", "move", "t1", "--to-profile", "Work"], {"operation": "tab.move", "id": "t1", "toProfile": "Work"}),
            (["tab", "pin", "t1"], {"operation": "tab.pin", "id": "t1"}),
            (["tab", "unpin", "t1"], {"operation": "tab.unpin", "id": "t1"}),
            (["tab", "rename", "t1", "New title"], {"operation": "tab.rename", "id": "t1", "title": "New title"}),
            (["tab", "reorder", "t1", "--before", "t2"], {"operation": "tab.reorder", "id": "t1", "before": "t2"}),
            (["tab", "reorder", "t1", "--after", "t2"], {"operation": "tab.reorder", "id": "t1", "after": "t2"}),
            (["group", "rename", "g1", "New name"], {"operation": "group.rename", "id": "g1", "name": "New name"}),
            (["group", "delete", "g1"], {"operation": "group.delete", "id": "g1"}),
            (["folder", "rename", "f1", "New name"], {"operation": "folder.rename", "id": "f1", "name": "New name"}),
            (["folder", "delete", "f1"], {"operation": "folder.delete", "id": "f1"}),
        ]
        for args, request in cases:
            for dry_run in (False, True):
                with self.subTest(args=args, dry_run=dry_run):
                    code, out, err = self.run_cli(*args, *( ["--dry-run"] if dry_run else []), "--json")
                    self.assertEqual((code, err), (0, ""))
                    self.assertEqual(self.socket.messages, [{"id": 1, "method": "Solara.sidebar", "params": {**request, "dryRun": dry_run}}])
                    self.assertEqual(json.loads(out)["dryRun"], dry_run)
                    self.assertTrue(self.socket.closed)

    def test_mutually_exclusive_destinations_and_reorder_anchors_are_required(self):
        cases = [
            ("tab", "move", "t1"),
            ("tab", "move", "t1", "--to-group", "g", "--to-window", "w"),
            ("tab", "reorder", "t1"),
            ("tab", "reorder", "t1", "--before", "t2", "--after", "t3"),
            ("group",),
            ("folder",),
            ("tab",),
        ]
        for args in cases:
            with self.subTest(args=args):
                code, out, err = self.run_cli(*args)
                self.assertEqual(code, 2)
                self.assertIn("usage:", err)
        self.assertEqual(self.connections, [])

    def test_inventory_keeps_native_ids_and_json_shape(self):
        snapshot = {"operation": "sidebar.list", "profiles": [{"id": "default", "name": "Personal"}], "windows": [{"id": "w1", "profileId": "default"}], "tabs": [{"id": "t1", "windowId": "w1", "title": "Example"}], "groups": [{"id": "g1", "name": "Research"}], "folders": [{"id": "f1", "name": "Work"}]}
        code, out, err = self.run_cli("sidebar", "--json", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), snapshot)
        self.assertEqual(self.socket.messages[0]["params"], {"operation": "sidebar.list"})
        code, out, err = self.run_cli("sidebar", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        for value in ("t1", "g1", "f1", "w1", "Personal", "Example", "Research", "Work"):
            self.assertIn(value, out)

    def test_inventory_marks_capped_values_and_omitted_rows_in_text_and_json(self):
        snapshot = {
            "operation": "sidebar.list", "profiles": [], "windows": [], "groups": [], "folders": [],
            "tabs": [{"id": "t1", "title": "T" * 1024, "url": "data:," + "x" * 8186, "truncated": True}],
            "more": {"profiles": 2, "windows": 0, "tabs": 17, "groups": 3, "folders": 0},
        }
        code, out, err = self.run_cli("sidebar", "--json", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), snapshot)
        code, out, err = self.run_cli("sidebar", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("…", out)
        self.assertIn("(2 more profiles)", out)
        self.assertIn("(17 more tabs)", out)
        self.assertIn("(3 more groups)", out)
        self.assertNotIn("(0 more", out)

    def test_inventory_shows_omitted_memberships(self):
        snapshot = {
            "operation": "sidebar.list", "profiles": [], "tabs": [], "groups": [], "folders": [],
            "windows": [{"id": "w1", "tabIds": ["t1"], "more": {"tabIds": 999}, "truncated": True}],
        }
        code, out, err = self.run_cli("sidebar", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("(999 more tabIds)", out)

    def test_malformed_inventory_markers_are_endpoint_errors(self):
        snapshot = {"operation": "sidebar.list", "profiles": [], "windows": [], "tabs": [], "groups": [], "folders": []}
        cases = [
            {"more": []}, {"more": {"tabs": -1}}, {"more": {"tabs": "2"}}, {"more": {"tabs": True}},
            {"tabs": [{"id": "t1", "truncated": "yes"}]},
            {"tabs": [{"id": "t1", "more": 2}]},
            {"tabs": [{"id": "t1", "more": {"tabIds": -1}}]},
        ]
        for change in cases:
            with self.subTest(change=change):
                code, out, err = self.run_cli("sidebar", "--json", response={**snapshot, **change})
                self.assertEqual((code, out), (2, ""))
                self.assertIn("invalid", err)

    def test_inventory_json_formatting_stays_within_response_budget(self):
        snapshot = {
            "operation": "sidebar.list", "profiles": [], "tabs": [], "groups": [], "folders": [],
            "windows": [{"id": f"w{i}", "tabIds": ["t"] * 500} for i in range(100)],
            "more": {"profiles": 0, "windows": 0, "tabs": 0, "groups": 0, "folders": 0},
        }
        code, out, err = self.run_cli("sidebar", "--json", response=snapshot)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), snapshot)
        self.assertLessEqual(len(out.encode("utf-8")), 262144)

    def test_dry_run_output_explains_change_and_preserves_control_file(self):
        before = self.control.read_bytes()
        response = {"operation": "tab.rename", "dryRun": True, "changes": ["Rename tab t1 to New title"]}
        code, out, err = self.run_cli("tab", "rename", "t1", "New title", "--dry-run", response=response)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("Dry run", out)
        self.assertIn("Rename tab t1 to New title", out)
        self.assertEqual(self.control.read_bytes(), before)

    def test_text_output_cleans_terminal_controls_and_prints_created_id(self):
        response = {"operation": "group.create", "dryRun": False, "changes": ["Create group \x1b[31mResearch\nnext"], "id": "g1"}
        code, out, err = self.run_cli("group", "create", "Research", response=response)
        self.assertEqual((code, err), (0, ""))
        self.assertNotIn("\x1b", out)
        self.assertIn("g1", out)
        self.assertIn("Research next", out)

    def test_explicit_devtools_are_refused_without_connecting(self):
        for args in (("--port", "8123"), ("--ws", "ws://127.0.0.1:8123/devtools/browser/test")):
            with self.subTest(args=args):
                code, out, err = self.run_cli("tab", "pin", "t1", *args)
                self.assertEqual((code, out), (2, ""))
                self.assertIn("SolaraControl.json", err)
        with mock.patch.dict(os.environ, {"SOLARA_CDP_URL": "ws://127.0.0.1:8123/devtools/browser/test"}):
            code, out, err = self.run_cli("sidebar")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("SOLARA_CDP_URL", err)
        self.assertEqual(self.connections, [])

    def test_unsafe_control_file_and_connection_failures_are_exit_two(self):
        self.control.chmod(0o644)
        code, out, err = self.run_cli("tab", "pin", "t1")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("0600", err)
        self.assertEqual(self.connections, [])
        self.control.chmod(0o600)
        code, out, err = self.run_cli("tab", "pin", "t1", disconnect=True)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("isn't running", err)
        self.assertTrue(self.socket.closed)

    def test_app_refusals_are_errors_and_never_leak_token(self):
        for message in ("Private profiles are refused", "Unknown tab t1", "Unsupported profile move", "Failure " + TOKEN):
            with self.subTest(message=message):
                code, out, err = self.run_cli("tab", "pin", "t1", response={"error": {"code": -32000, "message": message}})
                self.assertEqual((code, out), (1, ""))
                self.assertIn("solara:", err)
                self.assertNotIn(TOKEN, err)
                self.assertNotIn("Traceback", err)
                self.assertTrue(self.socket.closed)

    def test_malformed_results_are_endpoint_errors(self):
        for response in ({}, {"dryRun": False, "changes": "wrong"}, {"operation": "tab.pin", "dryRun": False, "changes": [1]}, {"operation": "tab.pin", "dryRun": True, "changes": []}):
            with self.subTest(response=response):
                code, out, err = self.run_cli("tab", "pin", "t1", response=response)
                self.assertEqual((code, out), (2, ""))
                self.assertIn("invalid", err)
                self.assertTrue(self.socket.closed)

    def test_explicit_data_dir_selects_control_file(self):
        with mock.patch.dict(os.environ, {"SOLARA_DATA_DIR": str(self.root / "missing")}):
            code, out, err = self.run_cli("tab", "pin", "t1", "--data-dir", str(self.root))
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.connections[0][0], "ws://127.0.0.1:8123/devtools/browser/sidebar?token=" + TOKEN)

    def test_malformed_inventory_is_refused(self):
        response = {"operation": "sidebar.list", "profiles": [], "windows": [], "tabs": [{"id": 123}], "groups": [], "folders": []}
        code, out, err = self.run_cli("sidebar", "--json", response=response)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("invalid", err)

    def test_connection_failure_is_an_endpoint_error_without_traceback(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), mock.patch.object(guard, "direct_connect", side_effect=OSError("cannot connect " + TOKEN)):
            code = cli.main(["tab", "pin", "t1"])
        self.assertEqual((code, out.getvalue()), (2, ""))
        self.assertIn("isn't running", err.getvalue())
        self.assertNotIn(TOKEN, err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())

    def test_transport_bypasses_websocket_proxy_environment(self):
        from solara_cli import sidebar

        arguments = []

        async def connect(url, **kwargs):
            arguments.append(kwargs)
            self.socket = Socket()
            return self.socket

        with mock.patch.dict("sys.modules", {"websockets": SimpleNamespace(connect=connect)}), mock.patch.dict(os.environ, {"ws_proxy": "http://127.0.0.1:1", "http_proxy": "http://127.0.0.1:1"}):
            response = asyncio.run(sidebar.exchange(endpoint.resolve(), {"operation": "tab.pin", "id": "t1", "dryRun": False}))
        self.assertFalse(response["dryRun"])
        self.assertEqual(arguments[0]["proxy"], None)
        self.assertTrue(self.socket.closed)

    def test_deadline_stops_stalled_response_and_closes_connection(self):
        from solara_cli import sidebar

        start = time.monotonic()
        with mock.patch.object(sidebar, "REQUEST_TIMEOUT", 0.02):
            code, out, err = self.run_cli("tab", "pin", "t1", hang=True)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("timed out", err)
        self.assertLess(time.monotonic() - start, 0.8)
        self.assertTrue(self.socket.closed)


if __name__ == "__main__":
    unittest.main()
