import builtins
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from solara_cli import cli, mcp_install


class McpInstallTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="solara-mcp-install-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = self.root / "home"
        self.project = self.root / "project"
        self.home.mkdir()
        self.project.mkdir()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(Path, "home", return_value=self.home).start()
        mock.patch.object(Path, "cwd", return_value=self.project).start()

    def install(self, target, project=False, dry_run=False):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = mcp_install.install(target, project, dry_run=dry_run)
        return status, out.getvalue()

    def test_default_and_project_destinations(self):
        cases = {
            "claude-code": (self.home / ".claude.json", self.project / ".mcp.json"),
            "cursor": (self.home / ".cursor/mcp.json", self.project / ".cursor/mcp.json"),
            "codex": (self.home / ".codex/config.toml", self.project / ".codex/config.toml"),
        }
        for target, paths in cases.items():
            for project, expected in zip((False, True), paths):
                self.assertEqual(mcp_install.destination(target, project), expected)

    def test_preview_does_not_create_directories_or_files(self):
        for target in mcp_install.TARGETS:
            status, out = self.install(target, dry_run=True)
            self.assertEqual(status, 0, out)
            self.assertIn("Preview", out)
            path = mcp_install.destination(target, False)
            self.assertFalse(path.exists())
            if target != "claude-code":
                self.assertFalse(path.parent.exists())

    def test_preview_preserves_existing_bytes_and_creates_no_backup(self):
        path = mcp_install.destination("claude-code", False)
        original = b'{"theme":"dark"}\r\n'
        path.write_bytes(original)
        status, out = self.install("claude-code", dry_run=True)
        self.assertEqual(status, 0, out)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(path.parent.glob(path.name + ".solara-mcp-backup-*")), [])

    def test_changed_existing_configuration_gets_a_private_exact_backup(self):
        for target in mcp_install.TARGETS:
            path = mcp_install.destination(target, False)
            path.parent.mkdir(exist_ok=True)
            original = b'model = "example"\r\n' if target == "codex" else b'{"theme":"dark"}\r\n'
            path.write_bytes(original)
            status, out = self.install(target)
            self.assertEqual(status, 0, out)
            backups = list(path.parent.glob(path.name + ".solara-mcp-backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
            self.assertIn(str(backups[0]), out)
            self.assertEqual(self.install(target)[0], 0)
            self.assertEqual(list(path.parent.glob(path.name + ".solara-mcp-backup-*")), backups)

    def test_json_install_preserves_other_servers_and_settings(self):
        for target in ("claude-code", "cursor"):
            path = mcp_install.destination(target, False)
            path.parent.mkdir(exist_ok=True)
            existing = {"theme": "dark", "mcpServers": {"other": {"command": "other", "args": ["serve"]}}}
            path.write_text(json.dumps(existing))
            status, out = self.install(target)
            self.assertEqual(status, 0, out)
            written = json.loads(path.read_text())
            self.assertEqual(written["theme"], "dark")
            self.assertEqual(written["mcpServers"]["other"], existing["mcpServers"]["other"])
            self.assertEqual(written["mcpServers"]["solara"], {"type": "stdio", "command": "solara", "args": ["mcp"]})
            self.assertIn(str(path), out)
            self.assertIn('"solara"', out)
            self.assertNotIn("--allow-actions", out)

    def test_missing_tomllib_only_refuses_codex_registration(self):
        original_import = builtins.__import__

        def import_without_tomllib(name, *args, **kwargs):
            if name == "tomllib":
                raise ImportError("not available")
            return original_import(name, *args, **kwargs)

        with mock.patch("builtins.__import__", side_effect=import_without_tomllib):
            status, out = self.install("codex")
            self.assertEqual(status, 1)
            self.assertIn("Python 3.11", out)
            self.assertFalse(mcp_install.destination("codex", False).exists())
            self.assertEqual(self.install("cursor")[0], 0)

    def test_codex_appends_without_rewriting_existing_bytes(self):
        path = mcp_install.destination("codex", False)
        path.parent.mkdir()
        original = 'model = "example"\n\n[mcp_servers.other]\ncommand = "other"\nargs = ["serve"]\n'
        path.write_text(original)
        status, out = self.install("codex")
        self.assertEqual(status, 0, out)
        self.assertTrue(path.read_text().startswith(original))
        parsed = tomllib.loads(path.read_text())
        self.assertEqual(parsed["model"], "example")
        self.assertEqual(parsed["mcp_servers"]["solara"], {"command": "solara", "args": ["mcp"]})
        self.assertIn('[mcp_servers.solara]', out)

    def test_idempotence_does_not_rewrite(self):
        for target in mcp_install.TARGETS:
            self.assertEqual(self.install(target)[0], 0)
            path = mcp_install.destination(target, False)
            before = (path.read_bytes(), path.stat().st_mtime_ns)
            self.assertEqual(self.install(target)[0], 0)
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)

    def test_unrelated_solara_entry_is_refused_without_rewrite(self):
        for target in mcp_install.TARGETS:
            path = mcp_install.destination(target, False)
            path.parent.mkdir(exist_ok=True)
            text = '[mcp_servers.solara]\ncommand = "unrelated"\n' if target == "codex" else '{"mcpServers":{"solara":{"command":"unrelated"}}}'
            path.write_text(text)
            status, out = self.install(target)
            self.assertEqual(status, 1)
            self.assertIn("exists", out)
            self.assertEqual(path.read_text(), text)

    def test_customized_action_entry_is_not_silently_replaced(self):
        path = mcp_install.destination("cursor", False)
        path.parent.mkdir()
        text = json.dumps({"mcpServers": {"solara": {"type": "stdio", "command": "solara", "args": ["mcp", "--allow-actions"]}}})
        path.write_text(text)
        self.assertEqual(self.install("cursor")[0], 1)
        self.assertEqual(path.read_text(), text)

    def test_invalid_configuration_is_refused(self):
        for target in mcp_install.TARGETS:
            path = mcp_install.destination(target, False)
            path.parent.mkdir(exist_ok=True)
            for text in ("[broken", '"unexpected"', 'mcp_servers = 3' if target == "codex" else '{"mcpServers":3}'):
                path.write_text(text)
                self.assertEqual(self.install(target)[0], 1, text)
                self.assertEqual(path.read_text(), text)

    def test_duplicate_json_keys_are_refused(self):
        path = mcp_install.destination("claude-code", False)
        text = '{"mcpServers":{},"mcpServers":{"other":{"command":"other"}}}'
        path.write_text(text)
        self.assertEqual(self.install("claude-code")[0], 1)
        self.assertEqual(path.read_text(), text)

    def test_non_json_numbers_are_refused_without_rewrite(self):
        for target in ("claude-code", "cursor"):
            path = mcp_install.destination(target, False)
            path.parent.mkdir(exist_ok=True)
            for value in ("NaN", "Infinity", "-Infinity"):
                text = '{"mcpServers":{},"other":' + value + '}'
                path.write_text(text)
                self.assertEqual(self.install(target)[0], 1)
                self.assertEqual(path.read_text(), text)

    def test_symlink_file_and_parent_are_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        original = outside / "config"
        original.write_text("{}")
        path = mcp_install.destination("claude-code", False)
        path.symlink_to(original)
        self.assertEqual(self.install("claude-code")[0], 1)
        self.assertEqual(original.read_text(), "{}")
        (self.home / ".cursor").symlink_to(outside)
        self.assertEqual(self.install("cursor")[0], 1)
        self.assertFalse((outside / "mcp.json").exists())

    def test_hardlinked_file_is_refused(self):
        source = self.root / "source"
        source.write_text("{}")
        path = mcp_install.destination("claude-code", False)
        os.link(source, path)
        self.assertEqual(self.install("claude-code")[0], 1)
        self.assertEqual(source.read_text(), "{}")

    def test_new_file_is_private(self):
        self.assertEqual(self.install("claude-code")[0], 0)
        self.assertEqual(mcp_install.destination("claude-code", False).stat().st_mode & 0o777, 0o600)

    def test_codex_inline_table_is_refused_without_rewrite(self):
        path = mcp_install.destination("codex", False)
        path.parent.mkdir()
        original = 'mcp_servers = {other = {command = "other"}}\n'
        path.write_text(original)
        self.assertEqual(self.install("codex")[0], 1)
        self.assertEqual(path.read_text(), original)

    def test_project_install_leaves_user_config_alone(self):
        for target in mcp_install.TARGETS:
            self.assertEqual(self.install(target, True)[0], 0)
            self.assertTrue(mcp_install.destination(target, True).is_file())
            self.assertFalse(mcp_install.destination(target, False).exists())

    def test_server_and_install_parser(self):
        args = cli.build_parser().parse_args(["mcp", "--allow-actions", "--profiles", "Work,Personal", "--data-dir", "scratch"])
        self.assertTrue(args.allow_actions)
        self.assertEqual(args.profiles, "Work,Personal")
        self.assertEqual(args.data_dir, "scratch")
        args = cli.build_parser().parse_args(["mcp", "install", "--target", "codex", "--project"])
        self.assertEqual(args.mcp_command, "install")
        self.assertEqual(args.target, "codex")
        self.assertTrue(args.project)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            cli.build_parser().parse_args(["mcp", "install"])
        for option in ("--port", "--ws", "--allow-actions"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cli.build_parser().parse_args(["mcp", "install", "--target", "codex", option, "x"])

    def test_cli_routes_install_without_starting_server(self):
        with mock.patch.object(mcp_install, "install", return_value=0) as install:
            self.assertEqual(cli.main(["mcp", "install", "--target", "cursor", "--project"]), 0)
        install.assert_called_once_with("cursor", True, dry_run=False)


if __name__ == "__main__":
    unittest.main()
