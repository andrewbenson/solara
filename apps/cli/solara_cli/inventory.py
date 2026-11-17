import asyncio
import copy
import json
import math
import sys
import time

from solara_cli import browsing, identity, mcp_tools, redact, sidebar, tab_memory
from solara_cli.cdp import CdpError, ConnectionLost
from solara_cli.endpoint import EndpointError, data_root, require_control

MAPPING_UNAVAILABLE = "This operation requires an app change: the sidebar does not expose a verified engine target and sleep state for each canonical tab ID"


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0 or number > 365:
        import argparse
        raise argparse.ArgumentTypeError("must be greater than zero and at most 365")
    return number


def positive_limit(value):
    import argparse
    number = int(value)
    if not 1 <= number <= 500:
        raise argparse.ArgumentTypeError("must be between 1 and 500")
    return number


def add_tab_options(parser):
    parser.add_argument("--window", metavar="ID", help="limit to a canonical sidebar window ID")
    parser.add_argument("--profile", metavar="ID_OR_NAME", help="limit to one normal profile")
    parser.add_argument("--group", metavar="ID", help="limit to a canonical sidebar group ID")
    asleep = parser.add_mutually_exclusive_group()
    asleep.add_argument("--asleep", action="store_true", help="only sleeping tabs; requires an app-provided target mapping")
    asleep.add_argument("--awake", action="store_true", help="only awake tabs; requires an app-provided target mapping")


def add_parser(commands):
    for name in ("profiles", "windows"):
        parser = commands.add_parser(name, help=f"list normal sidebar {name} by canonical ID")
        sidebar.add_options(parser, mutation=False)
        parser.add_argument("--profile", metavar="ID_OR_NAME", help="limit to one normal profile")
    find = commands.add_parser("find", help="find literal text in tabs, pins and recent history")
    sidebar.add_options(find, mutation=False)
    find.add_argument("query", metavar="QUERY")
    find.add_argument("--profile", metavar="ID_OR_NAME")
    for source in ("tabs", "pins", "history"):
        find.add_argument(f"--{source}", action="store_true", help=f"search {source} (default: all sources)")
    find.add_argument("--days", type=positive_float, default=7, metavar="N")
    find.add_argument("--limit", type=positive_limit, default=200, metavar="N")
    history = commands.add_parser("history", help="list recent browsing history, newest first")
    sidebar.add_options(history, mutation=False)
    history.add_argument("query", nargs="?", default="", metavar="QUERY")
    history.add_argument("--profile", metavar="ID_OR_NAME")
    history.add_argument("--days", type=positive_float, default=1, metavar="N")
    history.add_argument("--limit", type=positive_limit, default=200, metavar="N")
    history.add_argument("--domains", action="store_true", help="combine pages by domain")


def complete(state):
    if state.get("truncated") or any(state.get("more", {}).values()) or any(row.get("truncated") or any(row.get("more", {}).values()) for section in mcp_tools.SECTIONS for row in state[section]):
        raise mcp_tools.ToolError("Sidebar inventory is incomplete; this operation requires a complete snapshot")


def resolve_profile(state, selector):
    rows = [row for row in state["profiles"] if mcp_tools.normal_profile(row)]
    found = [row for row in rows if row["id"] == selector]
    if not found:
        if state.get("more", {}).get("profiles") or state.get("truncated"):
            raise mcp_tools.ToolError("Profile inventory is incomplete; select an exact canonical profile ID")
        found = [row for row in rows if row.get("name") == selector and not row.get("truncated")]
    if len(found) > 1:
        raise mcp_tools.ToolError("Profile name is ambiguous; use a canonical profile ID")
    if not found:
        raise mcp_tools.ToolError(f"Unknown or unavailable profile: {selector}")
    return found[0]


async def read_inventory(root, endpoint=None, targets=True):
    endpoint = endpoint or require_control(root)
    backend = mcp_tools.Backend(root)
    raw = await backend._sidebar(endpoint)
    state = mcp_tools.filtered_sidebar(raw, mcp_tools.selected_profiles(raw, None))
    state = copy.deepcopy(state)
    if not targets:
        return state
    target_rows = await backend._target_rows(endpoint, raw)
    profiles = {row["id"]: row for row in state["profiles"]}
    target_counts = {}
    for row in target_rows:
        target_counts[row["targetId"]] = target_counts.get(row["targetId"], 0) + 1
    mappings = {}
    for row in state["tabs"]:
        target_id = row.pop("targetId", None)
        if not isinstance(target_id, str) or not target_id:
            continue
        profile = profiles.get(row.get("profileId"), {})
        matches = [target for target in target_rows if target["targetId"] == target_id and target.get("profile") == profile.get("name")]
        if len(matches) != 1 or target_counts.get(target_id) != 1 or profile.get("truncated"):
            continue
        mappings.setdefault(target_id, []).append((row, matches[0]))
    for target_id, entries in mappings.items():
        if len(entries) != 1:
            continue
        row, target = entries[0]
        row.update({key: target[key] for key in ("targetId", "bytes", "discarded", "profile")})
    return state


def target_for_tab(state, tab_id):
    complete(state)
    rows = [row for row in state["tabs"] if row["id"] == tab_id]
    if len(rows) != 1:
        raise mcp_tools.ToolError("Canonical tab ID is missing or ambiguous")
    if not isinstance(rows[0].get("targetId"), str):
        raise mcp_tools.ToolError(MAPPING_UNAVAILABLE)
    return rows[0]


def filter_tabs(state, args):
    rows = state["tabs"]
    selector = getattr(args, "profile", None)
    if selector is not None:
        profile_id = resolve_profile(state, selector)["id"]
        rows = [row for row in rows if row.get("profileId") == profile_id]
    window = getattr(args, "window", None)
    if window is not None:
        if not any(row["id"] == window for row in state["windows"]):
            raise mcp_tools.ToolError(f"Unknown or unavailable window: {window}")
        rows = [row for row in rows if row.get("windowId") == window]
    group = getattr(args, "group", None)
    if group is not None:
        groups = [row for row in state["groups"] if row["id"] == group and (window is None or row.get("windowId") == window)]
        if len(groups) != 1:
            raise mcp_tools.ToolError("Group is missing or ambiguous; specify --window with its canonical ID")
        rows = [row for row in rows if row.get("groupId") == group and row.get("windowId") == groups[0].get("windowId")]
    if getattr(args, "asleep", False) or getattr(args, "awake", False):
        complete(state)
        if any(type(row.get("discarded")) is not bool for row in rows):
            raise mcp_tools.ToolError(MAPPING_UNAVAILABLE)
        rows = [row for row in rows if row["discarded"] == args.asleep]
    return rows


async def read_history(root, profile=None, days=1, limit=200, domains=False):
    endpoint = require_control(root)
    state = await read_inventory(root, endpoint, targets=False)
    complete(state)
    if profile is not None:
        profile = resolve_profile(state, profile)["id"]
    rows = await browsing.run_bounded(mcp_tools.history_rows, root, state["profiles"], days=days, limit=limit, profile=profile, domains=domains)
    require_control(root)
    return rows


def matches(row, query):
    needle = query.casefold()
    return any(needle in str(row.get(key, "")).casefold() for key in ("title", "url", "domain", "top_title"))


def pin_rows(root, profiles, deadline=None):
    deadline = deadline or time.monotonic() + browsing.HISTORY_BUDGET
    session = browsing.read_session(root, deadline)
    source_profiles = session.get("profiles") or {}
    counts = {}
    for profile_id, source in source_profiles.items():
        if isinstance(source, dict):
            name = source.get("name") or profile_id
            counts[name] = counts.get(name, 0) + 1
    allowed = set()
    for row in profiles:
        source = source_profiles.get(row["id"])
        if not isinstance(source, dict):
            continue
        name = source.get("name") or row["id"]
        if counts.get(name) != 1:
            raise mcp_tools.ToolError("Pin profile name is ambiguous; an app change is required to scope pins by profile ID")
        if name != row.get("name"):
            raise mcp_tools.ToolError("Profile changed while reading pins; try again")
        allowed.add(name)
    return [row for row in browsing.pinned(root, deadline=deadline) if row.get("profile") in allowed]


async def search(root, args, state=None):
    state = state or await read_inventory(root, targets=False)
    complete(state)
    selected = resolve_profile(state, args.profile) if args.profile else None
    all_sources = not any((args.tabs, args.pins, args.history))
    result = []
    if all_sources or args.tabs:
        tabs = [row for row in state["tabs"] if selected is None or row.get("profileId") == selected["id"]]
        result.extend({**row, "source": "tab"} for row in tabs if matches(row, args.query))
    if all_sources or args.pins:
        profiles = [selected] if selected else state["profiles"]
        pins = await browsing.run_bounded(pin_rows, root, profiles)
        result.extend({**row, "source": "pin"} for row in pins if matches(row, args.query))
    if all_sources or args.history:
        rows = await read_history(root, profile=args.profile, days=args.days, limit=None)
        result.extend({**row, "source": "history"} for row in rows if matches(row, args.query))
    require_control(root)
    return result[:args.limit]


async def execute(args):
    endpoint = sidebar.resolve_endpoint(args)
    root = data_root(args.data_dir)
    if args.command == "history":
        rows = await read_history(root, profile=args.profile, days=args.days, limit=None if args.query else args.limit, domains=args.domains)
        return [row for row in rows if matches(row, args.query)][:args.limit]
    state = await read_inventory(root, endpoint, targets=args.command == "tabs" and (args.asleep or args.awake))
    if args.command == "find":
        return await search(root, args, state)
    if args.command == "tabs":
        complete(state)
        return filter_tabs(state, args)
    complete(state)
    rows = state[args.command]
    if args.profile:
        profile_id = resolve_profile(state, args.profile)["id"]
        rows = [row for row in rows if (row["id"] if args.command == "profiles" else row.get("profileId")) == profile_id]
    return rows


def format_text(rows):
    if not rows:
        return "(none)"
    lines = []
    for row in rows:
        cells = [row.get("source"), row.get("id"), row.get("name", row.get("title", row.get("domain", row.get("top_title"))))]
        cells.extend(f"{key}={row[key]}" for key in ("windowId", "profileId", "groupId", "folderId", "profile") if row.get(key))
        if row.get("url"):
            cells.append(row["url"])
        if row.get("last_visit"):
            cells.append(row["last_visit"])
        if "discarded" in row:
            cells.append("asleep" if row["discarded"] else "awake")
        if row.get("truncated"):
            cells.append("…")
        lines.append("  ".join(tab_memory.clean(str(cell)) for cell in cells if cell is not None and cell != ""))
    return "\n".join(lines)


def run(args):
    out = sys.stdout = redact.RedactingStream(sys.stdout)
    err = sys.stderr = redact.RedactingStream(sys.stderr)
    redact.install_log_redaction()
    try:
        try:
            rows = asyncio.run(execute(args))
            text = json.dumps(rows, ensure_ascii=False, indent=2) if args.json else format_text(rows)
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
            return 0
        except (EndpointError, ConnectionLost) as error:
            sys.stderr.write(f"{identity.COMMAND}: {tab_memory.clean(str(error))}\n")
            return 2
        except (mcp_tools.ToolError, browsing.BrowsingDataError, CdpError, TypeError, ValueError, OSError) as error:
            sys.stderr.write(f"{identity.COMMAND}: {tab_memory.clean(str(error))}\n")
            return 1
        except KeyboardInterrupt:
            sys.stderr.write(f"{identity.COMMAND} {args.command}: interrupted\n")
            return 130
    finally:
        out.drain()
        err.drain()
