import json
import os
import platform
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

from solara_cli import identity

URL_LIMIT = 7500
TEMPLATE = "bug.yml"
REPO_PART = re.compile(r"^[A-Za-z0-9._-]{1,100}$")


def valid_repo(repo: str) -> bool:
    parts = repo.split("/")
    return len(parts) == 2 and all(REPO_PART.match(part) and part not in (".", "..") for part in parts)


def version_field(version: str, build: str) -> str:
    build = build.strip()
    return version if not build or build == version else f"{version} ({build})"


def macos_version(raw: str | None = None) -> str:
    raw = platform.mac_ver()[0] if raw is None else raw
    if not raw:
        return ""
    parts = (raw.split(".") + ["0", "0"])[:3]
    return ".".join(parts)


def mac_model() -> str:
    try:
        return subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], capture_output=True, text=True, timeout=5, check=False).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def issue_url(repo: str, version: str, macos: str, mac: str, limit: int = URL_LIMIT) -> str | None:
    if not valid_repo(repo):
        return None
    fields = [("template", TEMPLATE), ("version", version), ("macos", macos), ("mac", mac)]
    url = f"https://github.com/{repo}/issues/new?" + "&".join(f"{key}={quote(value, safe='')}" for key, value in fields if value)
    return url if len(url) <= limit else None


def spotlight_apps() -> list[Path]:
    try:
        query = f"kMDItemCFBundleIdentifier == '{identity.BUNDLE_ID}'"
        out = subprocess.run(["/usr/bin/mdfind", query], capture_output=True, text=True, timeout=5, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [Path(line) for line in out.splitlines() if line.endswith(".app")]


def read_info(app: Path) -> dict | None:
    try:
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    return info if isinstance(info, dict) and info.get("CFBundleIdentifier") == identity.BUNDLE_ID else None


def version_key(info: dict) -> tuple:
    def numbers(text):
        return tuple(int(part) if part.isdigit() else 0 for part in re.split(r"[.\-]", str(text)))
    return (numbers(info.get("CFBundleVersion", "")), numbers(info.get("CFBundleShortVersionString", "")))


def installed_info(preferred: Path | None = None, found: list[Path] | None = None) -> dict | None:
    preferred = Path("/Applications") / f"{identity.PRODUCT}.app" if preferred is None else preferred
    info = read_info(preferred)
    if info is not None:
        return info
    infos = [info for info in map(read_info, spotlight_apps() if found is None else found) if info is not None]
    return max(infos, key=version_key) if infos else None


def report_url(info: dict | None) -> str | None:
    info = info or {}
    version = version_field(str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", "")))
    return issue_url(identity.RELEASE_REPO, version, macos_version(), mac_model())


def add_parser(commands) -> None:
    bug = commands.add_parser(
        "bug",
        help=f"open a new {identity.PRODUCT} bug report on GitHub, filled in",
        description=f"Open a new GitHub issue for {identity.PRODUCT} with its version, macOS and Mac model filled in, and print its link. Nothing is sent until you submit the form.",
    )
    bug.add_argument("--no-open", action="store_true", help="only print the link")
    bug.add_argument("--json", action="store_true", help="print the link as JSON")


def run(args) -> int:
    info = installed_info()
    url = report_url(info)
    if url is None:
        sys.stderr.write(f"{identity.COMMAND} bug: this build has no release repository to report to\n")
        return 1
    print(json.dumps({"url": url}) if args.json else url)
    if args.no_open or os.environ.get("SSH_CONNECTION"):
        return 0
    command = ["/usr/bin/open", "-b", identity.BUNDLE_ID, url] if info is not None else ["/usr/bin/open", url]
    try:
        opened = subprocess.run(command, capture_output=True, timeout=15, check=False).returncode == 0
    except (OSError, subprocess.SubprocessError):
        opened = False
    if not opened:
        sys.stderr.write(f"{identity.COMMAND} bug: couldn't open the link; copy it from above\n")
    return 0
