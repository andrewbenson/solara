import contextlib
import io
import unittest
from unittest.mock import patch

from solara_cli.cli import build_parser, main


class CommandParserTests(unittest.TestCase):
    def parse(self, *arguments):
        with contextlib.redirect_stderr(io.StringIO()):
            return build_parser().parse_args(arguments)

    def test_listing_parsers(self):
        for command in ("profiles", "windows", "history"):
            with self.subTest(command=command):
                args = self.parse(command, "--json", "--data-dir", "/fixture")
                self.assertEqual(args.command, command)
                self.assertTrue(args.json)
        args = self.parse("tabs", "--window", "w", "--profile", "Work", "--group", "g", "--asleep", "--json")
        self.assertEqual(args.window, "w")
        self.assertEqual(args.profile, "Work")
        self.assertEqual(args.group, "g")
        self.assertTrue(args.asleep)

    def test_sleep_filters_are_exclusive(self):
        with self.assertRaises(SystemExit):
            self.parse("tabs", "--awake", "--asleep")

    def test_find_parser(self):
        args = self.parse("find", "example", "--json")
        self.assertEqual(args.command, "find")

    def test_inventory_dispatch(self):
        with patch("solara_cli.inventory.run", return_value=0) as run:
            self.assertEqual(main(["profiles", "--json"]), 0)
            self.assertEqual(run.call_args.args[0].command, "profiles")

    def test_action_dispatch(self):
        with patch("solara_cli.tab_actions.run", return_value=0) as run:
            self.assertEqual(main(["open", "https://example.com", "--background"]), 0)
            self.assertEqual(run.call_args.args[0].command, "open")
            self.assertEqual(main(["tab", "reload", "tab-id"]), 0)
            self.assertEqual(run.call_args.args[0].id, "tab-id")

    def test_existing_sidebar_dispatch(self):
        with patch("solara_cli.sidebar.run", return_value=0) as run:
            self.assertEqual(main(["tab", "pin", "tab-id"]), 0)
            self.assertEqual(run.call_args.args[0].sidebar_operation, "tab.pin")
