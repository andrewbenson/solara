import argparse
import contextlib
import io
import unittest
from pathlib import Path
from unittest import mock

from solara_cli import inventory, mcp_tools


def state():
    return {
        "operation": "sidebar.list",
        "profiles": [{"id": "default", "name": "Personal"}, {"id": "work", "name": "Work"}, {"id": "incognito:x", "name": "Private"}],
        "windows": [{"id": "w1", "profileId": "default", "tabIds": ["a", "b"]}, {"id": "w2", "profileId": "work", "tabIds": ["c"]}],
        "tabs": [{"id": "a", "profileId": "default", "windowId": "w1", "groupId": "g", "title": "Example", "url": "https://example.test", "pinned": True}, {"id": "b", "profileId": "default", "windowId": "w1", "title": "Example", "url": "https://example.test"}, {"id": "c", "profileId": "work", "windowId": "w2", "title": "Work", "url": "https://work.test"}],
        "groups": [{"id": "g", "profileId": "default", "windowId": "w1", "tabIds": ["a"]}],
        "folders": [], "more": {},
    }


class InventoryTests(unittest.IsolatedAsyncioTestCase):
    async def test_read_preserves_canonical_ids_and_never_matches_urls(self):
        value = state()
        targets = [{"targetId": "page1", "profile": "Personal", "title": "Example", "url": "https://example.test", "discarded": False, "bytes": 123}]
        with mock.patch.object(mcp_tools.Backend, "_sidebar", new=mock.AsyncMock(return_value=value)), mock.patch.object(mcp_tools.Backend, "_target_rows", new=mock.AsyncMock(return_value=targets)):
            result = await inventory.read_inventory(Path("unused"), endpoint=object())
        self.assertEqual([row["id"] for row in result["tabs"]], ["a", "b", "c"])
        self.assertNotIn("targetId", result["tabs"][0])
        self.assertEqual([row["id"] for row in result["profiles"]], ["default", "work"])
        with self.assertRaisesRegex(mcp_tools.ToolError, "app change"):
            inventory.target_for_tab(result, "a")

    async def test_explicit_target_mapping_enriches_without_mutating_source(self):
        value = state()
        value["tabs"][0]["targetId"] = "page1"
        targets = [{"targetId": "page1", "profile": "Personal", "title": "Engine title", "url": "https://example.test", "discarded": True, "bytes": None}]
        with mock.patch.object(mcp_tools.Backend, "_sidebar", new=mock.AsyncMock(return_value=value)), mock.patch.object(mcp_tools.Backend, "_target_rows", new=mock.AsyncMock(return_value=targets)):
            result = await inventory.read_inventory(Path("unused"), endpoint=object())
        self.assertEqual(inventory.target_for_tab(result, "a")["targetId"], "page1")
        self.assertEqual(result["tabs"][0]["title"], "Example")
        self.assertTrue(result["tabs"][0]["discarded"])
        self.assertNotIn("discarded", value["tabs"][0])

    async def test_target_mapping_rejects_profile_mismatch(self):
        value = state()
        value["tabs"][0]["targetId"] = "page1"
        targets = [{"targetId": "page1", "profile": "Work", "title": "Example", "url": "https://example.test", "discarded": False, "bytes": 123}]
        with mock.patch.object(mcp_tools.Backend, "_sidebar", new=mock.AsyncMock(return_value=value)), mock.patch.object(mcp_tools.Backend, "_target_rows", new=mock.AsyncMock(return_value=targets)):
            result = await inventory.read_inventory(Path("unused"), endpoint=object())
        with self.assertRaisesRegex(mcp_tools.ToolError, "app change"):
            inventory.target_for_tab(result, "a")

    async def test_history_reuses_scoped_mcp_helper(self):
        rows = [{"title": "Example", "url": "https://example.test"}]
        with mock.patch.object(inventory, "require_control", return_value=object()), mock.patch.object(inventory, "read_inventory", new=mock.AsyncMock(return_value=state())), mock.patch.object(inventory.browsing, "run_bounded", new=mock.AsyncMock(return_value=rows)) as run:
            self.assertEqual(await inventory.read_history(Path("unused"), profile="work", days=2, limit=10), rows)
        self.assertIs(run.call_args.args[0], mcp_tools.history_rows)
        self.assertEqual(run.call_args.kwargs["profile"], "work")


    async def test_normal_tab_listing_does_not_read_memory_or_wake_tabs(self):
        args = argparse.Namespace(command="tabs", data_dir="unused", window=None, profile=None, group=None, asleep=False, awake=False)
        with mock.patch.object(inventory.sidebar, "resolve_endpoint", return_value=object()), mock.patch.object(inventory, "read_inventory", new=mock.AsyncMock(return_value=state())) as read:
            result = await inventory.execute(args)
        self.assertEqual([row["id"] for row in result], ["a", "b", "c"])
        self.assertFalse(read.call_args.kwargs["targets"])

    async def test_listing_rejects_incomplete_snapshot(self):
        value = state()
        value["more"] = {"tabs": 1}
        args = argparse.Namespace(command="profiles", data_dir="unused", profile=None)
        with mock.patch.object(inventory.sidebar, "resolve_endpoint", return_value=object()), mock.patch.object(inventory, "read_inventory", new=mock.AsyncMock(return_value=value)):
            with self.assertRaisesRegex(mcp_tools.ToolError, "incomplete"):
                await inventory.execute(args)

    async def test_find_single_source_does_not_read_other_sources(self):
        args = argparse.Namespace(query="EXAMPLE", profile="Personal", tabs=True, pins=False, history=False, days=7, limit=1)
        with mock.patch.object(inventory, "require_control", return_value=object()), mock.patch.object(inventory.browsing, "run_bounded", new=mock.AsyncMock()) as read, mock.patch.object(inventory, "read_history", new=mock.AsyncMock()) as history:
            rows = await inventory.search(Path("unused"), args, state())
        self.assertEqual([row["id"] for row in rows], ["a"])
        self.assertEqual(rows[0]["source"], "tab")
        read.assert_not_called()
        history.assert_not_called()

    async def test_find_default_sources_labels_and_profile_scope(self):
        args = argparse.Namespace(query="example", profile="work", tabs=False, pins=False, history=False, days=2, limit=10)
        pins = [{"title": "Example pin", "profile": "Work", "url": "https://example.test"}]
        history_rows = [{"title": "Example old", "profile": "Work", "url": "https://old.test"}]
        with mock.patch.object(inventory, "require_control", return_value=object()), mock.patch.object(inventory.browsing, "run_bounded", new=mock.AsyncMock(return_value=pins)) as read, mock.patch.object(inventory, "read_history", new=mock.AsyncMock(return_value=history_rows)) as history:
            rows = await inventory.search(Path("unused"), args, state())
        self.assertEqual([row["source"] for row in rows], ["pin", "history"])
        self.assertEqual(read.call_args.args[2], [{"id": "work", "name": "Work"}])
        self.assertEqual(history.call_args.kwargs["profile"], "work")
        self.assertIsNone(history.call_args.kwargs["limit"])

    async def test_history_query_finds_older_than_newest_500(self):
        args = argparse.Namespace(command="history", data_dir="unused", query="needle", profile=None, days=7, limit=1, domains=False)
        rows = [{"title": "Other"} for _ in range(500)] + [{"title": "Needle older match"}]

        async def history(root, **options):
            return rows[:options["limit"]]

        with mock.patch.object(inventory.sidebar, "resolve_endpoint", return_value=object()), mock.patch.object(inventory, "read_history", side_effect=history):
            self.assertEqual(await inventory.execute(args), [{"title": "Needle older match"}])

    async def test_history_query_filters_and_limits(self):
        args = argparse.Namespace(command="history", data_dir="unused", query="EXAMPLE", profile=None, days=2, limit=1, domains=False)
        rows = [{"title": "Other"}, {"title": "Example one"}, {"title": "Example two"}]
        with mock.patch.object(inventory.sidebar, "resolve_endpoint", return_value=object()), mock.patch.object(inventory, "read_history", new=mock.AsyncMock(return_value=rows)) as read:
            self.assertEqual(await inventory.execute(args), [{"title": "Example one"}])
        self.assertIsNone(read.call_args.kwargs["limit"])


class FilterTests(unittest.TestCase):
    def options(self, **kwargs):
        return argparse.Namespace(window=None, profile=None, group=None, asleep=False, awake=False, **kwargs)

    def test_filters_compose_and_profile_names_resolve_exactly(self):
        args = self.options()
        args.profile, args.window, args.group = "Personal", "w1", "g"
        self.assertEqual([row["id"] for row in inventory.filter_tabs(state(), args)], ["a"])

    def test_unknown_and_ambiguous_profiles_fail(self):
        value = state()
        value["profiles"].append({"id": "another", "name": "Personal"})
        with self.assertRaisesRegex(mcp_tools.ToolError, "ambiguous"):
            inventory.resolve_profile(value, "Personal")
        with self.assertRaisesRegex(mcp_tools.ToolError, "Unknown"):
            inventory.resolve_profile(value, "missing")

    def test_profile_name_requires_complete_profile_inventory(self):
        value = state()
        value["more"] = {"profiles": 1}
        with self.assertRaisesRegex(mcp_tools.ToolError, "incomplete"):
            inventory.resolve_profile(value, "Personal")
        self.assertEqual(inventory.resolve_profile(value, "default")["id"], "default")

    def test_sleep_filter_requires_known_sleep_state(self):
        args = self.options()
        args.asleep = True
        with self.assertRaisesRegex(mcp_tools.ToolError, "app change"):
            inventory.filter_tabs(state(), args)
        value = state()
        for row in value["tabs"]:
            row["discarded"] = row["id"] == "b"
        self.assertEqual([row["id"] for row in inventory.filter_tabs(value, args)], ["b"])

    def test_partial_inventory_cannot_resolve_action_target(self):
        value = state()
        value["more"] = {"tabs": 1}
        value["tabs"][0]["targetId"] = "page1"
        with self.assertRaisesRegex(mcp_tools.ToolError, "incomplete"):
            inventory.target_for_tab(value, "a")

    def test_parser_supports_composable_filters_and_sources(self):
        parser = argparse.ArgumentParser()
        commands = parser.add_subparsers(dest="command")
        inventory.add_parser(commands)
        tabs = commands.add_parser("tabs")
        inventory.add_tab_options(tabs)
        args = parser.parse_args(["tabs", "--profile", "work", "--window", "w2", "--awake"])
        self.assertTrue(args.awake)
        args = parser.parse_args(["find", "example", "--tabs", "--history", "--limit", "5"])
        self.assertTrue(args.tabs)
        self.assertEqual(args.limit, 5)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["tabs", "--awake", "--asleep"])

    def test_pins_refuse_ambiguous_profile_names(self):
        session = {"version": 2, "profiles": {"default": {"name": "Personal"}, "incognito:x": {"name": "Personal"}}}
        rows = [{"title": "Pin", "profile": "Personal", "url": "https://example.test"}]
        with mock.patch.object(inventory.browsing, "read_session", return_value=session), mock.patch.object(inventory.browsing, "pinned", return_value=rows):
            with self.assertRaisesRegex(mcp_tools.ToolError, "ambiguous"):
                inventory.pin_rows(Path("unused"), state()["profiles"][:1])

    def test_text_sanitizes_terminal_controls(self):
        text = inventory.format_text([{"id": "a", "title": "hello\x1b[2J\nworld", "url": "https://example.test"}])
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\n", text)

    def test_find_text_matching_is_case_insensitive_and_literal(self):
        self.assertTrue(inventory.matches({"title": "Example [one]", "url": "https://test"}, "[ONE]"))
        self.assertFalse(inventory.matches({"title": "Example", "url": "https://test"}, "^Ex"))


if __name__ == "__main__":
    unittest.main()
