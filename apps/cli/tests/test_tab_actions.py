import argparse
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from solara_cli import sidebar, tab_actions
from solara_cli.mcp_tools import Backend, ToolError


def arguments(*words):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command")
    sidebar.add_parser(commands)
    tab_actions.add_parser(commands)
    return parser.parse_args(words)


class Parsers(unittest.TestCase):
    def test_existing_sidebar_action(self):
        self.assertEqual(arguments("tab", "pin", "tab-1").sidebar_operation, "tab.pin")

    def test_open_background(self):
        args = arguments("open", "https://example.com", "--background")
        self.assertEqual(args.tab_action, "open")
        self.assertFalse(args.focus)

    def test_activation_opt_in(self):
        self.assertFalse(arguments("tab", "activate", "tab-1").focus)
        self.assertTrue(arguments("tab", "activate", "tab-1", "--focus").focus)


class Actions(unittest.IsolatedAsyncioTestCase):
    async def invoke(self, words, state=None):
        backend = Backend(Path("/unused"), allow_actions=True)
        backend._command = AsyncMock(return_value={"targetId": "new-target", "success": True})
        with patch.object(tab_actions, "require_control", return_value=object()), patch.object(tab_actions, "read_inventory", new=AsyncMock(return_value={**{key: [] for key in ("tabs", "profiles", "windows", "groups", "folders")}, **(state or {})})):
            result = await tab_actions.perform(arguments(*words), backend)
        return result, backend

    async def test_open_uses_existing_command_and_stays_background(self):
        value, backend = await self.invoke(["open", "https://example.com"])
        self.assertIsNone(value["id"])
        self.assertIn("app change", value["idUnavailable"])
        backend._command.assert_awaited_once()
        self.assertEqual(backend._command.await_args.args[1:], ("Target.createTarget", {"url": "https://example.com", "background": True}))

    async def test_open_rejects_url_before_command(self):
        with self.assertRaises(ToolError):
            await self.invoke(["open", "file:///private"])

    async def test_scoped_open_refuses(self):
        for flag in ("--window", "--profile"):
            with self.subTest(flag=flag), self.assertRaisesRegex(ToolError, "app change"):
                await self.invoke(["open", "https://example.com", flag, "w"])

    async def test_activation_requires_focus(self):
        with self.assertRaisesRegex(ToolError, "--focus"):
            await self.invoke(["tab", "activate", "tab-1"])

    async def test_unsupported_actions_refuse(self):
        for words in (["tab", "mute", "tab-1"], ["tab", "sleep", "tab-1"], ["tab", "sleep-idle"]):
            with self.subTest(words=words), self.assertRaisesRegex(ToolError, "app change"):
                await self.invoke(words)

    async def test_missing_mapping_never_guesses_from_duplicate_url(self):
        state = {"tabs": [{"id": "one", "url": "https://same/"}, {"id": "two", "url": "https://same/"}]}
        with self.assertRaisesRegex(ToolError, "app change"):
            await self.invoke(["tab", "close", "one"], state)

    async def test_close_sends_only_exact_target(self):
        with patch.object(tab_actions, "target_for_tab", return_value={"id": "one", "targetId": "exact"}):
            value, backend = await self.invoke(["tab", "close", "one"])
        self.assertEqual(value["id"], "one")
        self.assertEqual(backend._command.await_args.args[1:], ("Target.closeTarget", {"targetId": "exact"}))

    async def test_duplicate_refuses_until_it_can_preserve_scope(self):
        with self.assertRaisesRegex(ToolError, "app change"):
            await self.invoke(["tab", "duplicate", "one"])

    async def test_bulk_close_preflights_all_ids_before_closing(self):
        state = {"profiles": [], "groups": [], "folders": [], "windows": [{"id": "w"}], "tabs": [
            {"id": "a", "windowId": "w", "profileId": "p", "url": "https://same/"},
            {"id": "b", "windowId": "w", "profileId": "p", "url": "https://same/"},
            {"id": "c", "windowId": "w", "profileId": "p", "url": "https://same/"},
        ]}
        backend = Backend(Path("/unused"), allow_actions=True)
        backend._command = AsyncMock()
        with patch.object(tab_actions, "require_control", return_value=object()), patch.object(tab_actions, "read_inventory", new=AsyncMock(return_value=state)), patch.object(tab_actions, "target_for_tab", side_effect=[{**state["tabs"][1], "targetId": "b-target"}, ToolError("missing")]):
            with self.assertRaisesRegex(ToolError, "missing"):
                await tab_actions.perform(arguments("tab", "close-duplicates"), backend)
        backend._command.assert_not_awaited()

    async def test_bulk_close_keeps_pinned_duplicate(self):
        state = {"profiles": [], "groups": [], "folders": [], "windows": [{"id": "w"}], "tabs": [
            {"id": "a", "windowId": "w", "profileId": "p", "url": "https://same/"},
            {"id": "b", "windowId": "w", "profileId": "p", "url": "https://same/", "pinned": True},
        ]}
        with patch.object(tab_actions, "target_for_tab", side_effect=lambda state, tab_id: {"id": tab_id, "targetId": "target-" + tab_id}):
            value, backend = await self.invoke(["tab", "close-duplicates", "--dry-run"], state)
        self.assertEqual(value["ids"], ["a"])
        backend._command.assert_not_awaited()
