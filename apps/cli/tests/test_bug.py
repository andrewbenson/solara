import contextlib
import io
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from solara_cli import bug, cli, identity


def fields(url):
    return {key: values[0] for key, values in parse_qs(urlsplit(url).query, keep_blank_values=True).items()}


class BugReportLink(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="solara-bug-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)

    def fixture_app(self, bundle_id=identity.BUNDLE_ID, version="0.4.5", build="107"):
        app = self.root / f"{identity.PRODUCT}.app"
        (app / "Contents").mkdir(parents=True, exist_ok=True)
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version, "CFBundleVersion": build}, handle)
        return app

    def test_the_link_fills_the_forms_fields_from_the_installed_bundle(self):
        info = bug.installed_info([self.root / "missing.app"], [self.fixture_app()])
        with mock.patch.object(bug, "macos_version", return_value="26.6.2"), mock.patch.object(bug, "mac_model", return_value="MacBookPro18,4"):
            url = bug.report_url(info)
        self.assertTrue(url.startswith(f"https://github.com/{identity.RELEASE_REPO}/issues/new?template=bug.yml&"))
        self.assertEqual(fields(url), {"template": "bug.yml", "version": "0.4.5 (107)", "macos": "26.6.2", "mac": "MacBookPro18,4"})
        self.assertIn("version=0.4.5%20%28107%29", url)
        self.assertIn("mac=MacBookPro18%2C4", url)
        self.assertLessEqual(len(url), bug.URL_LIMIT)

    def test_another_apps_bundle_is_not_ours(self):
        self.assertIsNone(bug.installed_info([self.root / "missing.app"], [self.fixture_app(bundle_id="com.example.other")]))
        with mock.patch.object(bug, "macos_version", return_value="26.6.2"), mock.patch.object(bug, "mac_model", return_value="Mac15,3"):
            self.assertEqual(fields(bug.report_url(None)), {"template": "bug.yml", "macos": "26.6.2", "mac": "Mac15,3"})

    def test_values_are_percent_encoded_like_the_apps_builder(self):
        url = bug.issue_url("andrewbenson/solara", "1.0 & more=yes #1 ü/?", "26.6", "Mac")
        query = urlsplit(url).query
        for pair in query.split("&"):
            value = pair.split("=", 1)[1]
            self.assertRegex(value, r"^[A-Za-z0-9\-_.~%]*$")
        self.assertEqual(fields(url)["version"], "1.0 & more=yes #1 ü/?")

    def test_the_version_and_macos_match_the_apps_spelling(self):
        self.assertEqual(bug.version_field("0.4.5", ""), "0.4.5")
        self.assertEqual(bug.version_field("0.4.5", "0.4.5"), "0.4.5")
        self.assertEqual(bug.version_field("0.4.5", "107"), "0.4.5 (107)")
        self.assertEqual(bug.macos_version("27.2"), "27.2.0")
        self.assertEqual(bug.macos_version("26.6.2"), "26.6.2")
        self.assertEqual(bug.macos_version(""), "")

    def test_the_repo_must_be_an_owner_and_name_and_the_cap_holds(self):
        for repo in ("", "solara", "a/b/c", "../x", "a/..", "evil.com/x?y", "a b/c", "$(AC_RELEASE_REPO)"):
            self.assertIsNone(bug.issue_url(repo, "1", "2", "3"), repo)
        self.assertIsNone(bug.issue_url("a/b", "x" * 8000, "2", "3"))

    def fixture_at(self, folder, version, build):
        app = self.root / folder / f"{identity.PRODUCT}.app"
        (app / "Contents").mkdir(parents=True, exist_ok=True)
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identity.BUNDLE_ID, "CFBundleShortVersionString": version, "CFBundleVersion": build}, handle)
        return app

    def test_applications_wins_then_the_newest_copy(self):
        preferred = self.fixture_at("Applications", "0.4.4", "106")
        old = self.fixture_at("Downloads", "0.4.3", "105")
        new = self.fixture_at("Desktop", "0.4.10", "112")
        self.assertEqual(bug.installed_info([preferred, self.fixture_at("HomeApplications", "0.4.9", "111")], [new, old])["CFBundleVersion"], "106")
        self.assertEqual(bug.installed_info([self.root / "none.app", self.fixture_at("HomeApplications2", "0.4.2", "104")], [old, new])["CFBundleVersion"], "104")
        self.assertEqual(bug.installed_info([self.root / "none.app", self.root / "none2.app"], [old, new])["CFBundleVersion"], "112")
        self.assertIsNone(bug.installed_info([self.root / "none.app"], []))

    def run_command(self, argv, info, env=None):
        out = io.StringIO()
        with (
            mock.patch.object(bug, "installed_info", return_value=info),
            mock.patch.object(bug, "macos_version", return_value="26.6.2"),
            mock.patch.object(bug, "mac_model", return_value="Mac15,3"),
            mock.patch.dict("os.environ", env or {}, clear=False),
            mock.patch.object(bug.subprocess, "run") as run,
            contextlib.redirect_stdout(out),
        ):
            if env is None:
                bug.os.environ.pop("SSH_CONNECTION", None)
            run.return_value.returncode = 0
            code = cli.main(argv)
        return code, out.getvalue().strip(), run

    def test_it_opens_in_solara_when_installed_and_prints_the_link(self):
        code, printed, run = self.run_command(["bug"], {"CFBundleIdentifier": identity.BUNDLE_ID, "CFBundleShortVersionString": "0.4.5", "CFBundleVersion": "107"})
        self.assertEqual(code, 0)
        self.assertEqual(fields(printed)["version"], "0.4.5 (107)")
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", "-b", identity.BUNDLE_ID, printed])

    def test_without_solara_it_opens_the_default_browser(self):
        code, printed, run = self.run_command(["bug", "--json"], None)
        self.assertEqual(code, 0)
        url = __import__("json").loads(printed)["url"]
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", url])

    def test_over_ssh_or_with_no_open_it_only_prints(self):
        for argv, env in ((["bug", "--no-open"], None), (["bug"], {"SSH_CONNECTION": "1 2 3 4"})):
            code, printed, run = self.run_command(argv, None, env)
            self.assertEqual(code, 0)
            self.assertTrue(printed.startswith("https://github.com/"))
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
