import asyncio
import json
import os
import sys

from solara_cli import identity, redact, sidebar
from solara_cli.cdp import CdpError, ConnectionLost
from solara_cli.endpoint import EndpointError, NOT_REACHABLE, data_root, require_control
from solara_cli.inventory import complete, read_inventory, target_for_tab
from solara_cli.mcp_tools import Backend, BoundedCdp, TOOL_TIMEOUT, ToolError, web_url
from solara_cli.tab_memory import clean


def add_options(parser):
    sidebar.add_options(parser)
    parser.add_argument("--focus", "--activate", dest="focus", action="store_true", help="explicitly allow bringing Solara to the front")


def add_parser(commands):
    parser = commands.add_parser("open", help="open an HTTP(S) URL in a background tab")
    parser.set_defaults(tab_action="open")
    parser.add_argument("url", metavar="URL")
    parser.add_argument("--window", metavar="ID", help="requires an app change: select the destination window")
    parser.add_argument("--profile", metavar="NAME", help="requires an app change: select the destination profile")
    parser.add_argument("--background", action="store_true", help="open in the background (the default)")
    add_options(parser)


def add_tab_parsers(actions):
    descriptions = {
        "activate": "activate a tab; --focus explicitly permits bringing Solara forward",
        "close": "close a tab by its sidebar id",
        "reload": "reload a tab without changing focus",
        "duplicate": "duplicate a tab (requires an app change)",
        "mute": "mute a tab (requires an app change)",
        "sleep": "sleep a tab (requires an app change)",
        "close-duplicates": "close duplicate URLs within each window and profile",
        "sleep-idle": "sleep idle tabs (requires an app change)",
    }
    for action, help_text in descriptions.items():
        parser = actions.add_parser(action, help=help_text)
        parser.set_defaults(tab_action=action)
        if action not in ("close-duplicates", "sleep-idle"):
            parser.add_argument("id", metavar="ID")
        if action in ("close-duplicates", "sleep-idle"):
            parser.add_argument("--window", metavar="ID")
            parser.add_argument("--profile", metavar="NAME")
        if action == "sleep-idle":
            parser.add_argument("--minutes", type=float, default=30, metavar="N")
        if action == "mute":
            parser.add_argument("--unmute", action="store_true")
        if action == "reload":
            parser.add_argument("--bypass-cache", action="store_true")
        add_options(parser)


def unavailable(action, reason):
    raise ToolError(f"{action} requires an app change: {reason}; use the corresponding Solara tab control")


def result(action, args, **fields):
    return {"operation": f"tab.{action}" if action != "open" else "open", "dryRun": args.dry_run, **fields}


async def reload_tab(endpoint, row, bypass_cache):
    connection = BoundedCdp(endpoint.ws)
    try:
        await connection.open(10)
        attached = await connection.send("Target.attachToTarget", {"targetId": row["targetId"], "flatten": True}, timeout=10)
        session = attached.get("sessionId")
        if not isinstance(session, str) or not session:
            raise ToolError("Could not attach to tab")
        return await connection.send("Page.reload", {"ignoreCache": bypass_cache}, session=session, timeout=10)
    finally:
        await connection.close()


async def perform(args, backend):
    action = args.tab_action
    if args.port is not None or args.ws is not None or os.environ.get("SOLARA_CDP_URL"):
        raise EndpointError(sidebar.TOKEN_ONLY)
    endpoint = require_control(backend.root)
    if args.focus and getattr(args, "background", False):
        raise ToolError("--background and --focus cannot be combined")
    if action == "open":
        url = web_url(args.url)
        if args.window or args.profile:
            unavailable("scoped open", "the control API cannot atomically choose a window or profile")
        if args.dry_run:
            return result(action, args, url=url, background=not args.focus)
        value = await backend._command(endpoint, "Target.createTarget", {"url": url, "background": not args.focus})
        target_id = value.get("targetId")
        if not isinstance(target_id, str) or not target_id:
            raise ToolError("Tab creation returned no target ID; the outcome may be unknown")
        return result(action, args, id=None, targetId=target_id, url=url, background=not args.focus, idUnavailable="The app does not expose the sidebar ID for a created target; chaining this result to tab commands requires an app change")
    if action == "activate" and not args.focus:
        raise ToolError("tab activate requires --focus (or --activate): the control API may bring Solara to the front")
    if args.focus and action != "activate":
        raise ToolError("--focus is supported only for open and tab activate")
    if action in ("mute", "sleep", "sleep-idle"):
        unavailable(action, "the control API exposes no tab mute, discard or idle-activity operation")
    if action == "duplicate":
        unavailable(action, "the control API cannot duplicate tab state in its source window and profile")
    state = await read_inventory(backend.root, endpoint=endpoint)
    if action == "close-duplicates":
        return await close_duplicates(args, backend, endpoint, state)
    row = target_for_tab(state, args.id)
    if args.dry_run:
        return result(action, args, id=args.id, targetId=row["targetId"])
    if action == "reload":
        value = await reload_tab(endpoint, row, args.bypass_cache)
    else:
        method = {"activate": "Target.activateTarget", "close": "Target.closeTarget"}[action]
        value = await backend._command(endpoint, method, {"targetId": row["targetId"]})
        if action == "close" and value.get("success") is not True:
            raise ToolError("Solara did not confirm the tab was closed")
    return result(action, args, id=args.id, targetId=row["targetId"], result=value)


async def close_duplicates(args, backend, endpoint, state):
    complete(state)
    if args.profile:
        profiles = [row for row in state["profiles"] if row["id"] == args.profile or row.get("name") == args.profile]
        if len(profiles) != 1 or profiles[0].get("truncated"):
            raise ToolError("Profile is unavailable or ambiguous; use its exact sidebar ID")
        profile = profiles[0]["id"]
    else:
        profile = None
    if args.window and not any(row["id"] == args.window for row in state["windows"]):
        raise ToolError("Window is unavailable; use an exact sidebar window ID")
    groups = {}
    duplicates = []
    for row in state["tabs"]:
        if args.window and row.get("windowId") != args.window or profile and row.get("profileId") != profile:
            continue
        if row.get("truncated"):
            raise ToolError("Sidebar inventory is incomplete; closing duplicates requires complete URLs")
        try:
            url = web_url(row.get("url", ""))
        except ToolError:
            continue
        key = (row.get("windowId"), row.get("profileId"), url)
        if not key[0] or not key[1]:
            raise ToolError("Sidebar inventory is incomplete; closing duplicates requires window and profile IDs")
        groups.setdefault(key, []).append(row)
    for rows in groups.values():
        keeper = next((row for row in rows if row.get("pinned")), rows[0])
        for row in rows:
            if row is not keeper and not row.get("pinned"):
                duplicates.append(target_for_tab(state, row["id"]))
    if args.dry_run:
        return result("close-duplicates", args, ids=[row["id"] for row in duplicates])
    closed = []
    for row in duplicates:
        try:
            value = await backend._command(require_control(backend.root), "Target.closeTarget", {"targetId": row["targetId"]})
            if value.get("success") is not True:
                raise ToolError("Solara did not confirm closure")
        except (ToolError, CdpError, EndpointError, ConnectionLost) as error:
            raise ToolError(f"Closed {len(closed)} duplicate tabs before stopping ({clean(str(error))}); closure of the current tab may be unknown; no further tabs were attempted") from None
        closed.append(row["id"])
    return result("close-duplicates", args, ids=closed)


def run(args):
    out = sys.stdout = redact.RedactingStream(sys.stdout)
    err = sys.stderr = redact.RedactingStream(sys.stderr)
    redact.install_log_redaction()
    try:
        backend = Backend(data_root(args.data_dir), allow_actions=True)
        try:
            value = asyncio.run(asyncio.wait_for(perform(args, backend), TOOL_TIMEOUT))
        except EndpointError as error:
            sys.stderr.write(f"{identity.COMMAND}: {clean(str(error))}\n")
            return 2
        except (ConnectionLost, OSError):
            sys.stderr.write(f"{identity.COMMAND}: {NOT_REACHABLE}\n")
            return 2
        except (ToolError, CdpError) as error:
            sys.stderr.write(f"{identity.COMMAND}: {clean(str(error))}\n")
            return 1
        except asyncio.TimeoutError:
            sys.stderr.write(f"{identity.COMMAND}: action timed out; its outcome may be unknown\n")
            return 1
        except asyncio.CancelledError:
            sys.stderr.write(f"{identity.COMMAND}: terminated; the action outcome may be unknown\n")
            return 143
        except KeyboardInterrupt:
            sys.stderr.write(f"{identity.COMMAND}: interrupted\n")
            return 130
        if args.json:
            text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        else:
            prefix = "Dry run: " if value["dryRun"] else ""
            text = prefix + clean(json.dumps(value, ensure_ascii=False))
        sys.stdout.write(text + "\n")
        sys.stdout.flush()
        return 0
    finally:
        out.drain()
        err.drain()
