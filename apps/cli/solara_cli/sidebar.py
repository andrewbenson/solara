import asyncio
import json
import os
import sys

from solara_cli import identity, redact
from solara_cli.cdp import Cdp, CdpError, ConnectionLost
from solara_cli.endpoint import EndpointError, NOT_REACHABLE, resolve
from solara_cli.tab_memory import clean

REQUEST_TIMEOUT = 10
TOKEN_ONLY = "sidebar commands need SolaraControl.json; --port, --ws and $SOLARA_CDP_URL are not supported"
FIELDS = ("name", "color", "tabs", "windowId", "id", "title", "toGroup", "toFolder", "toWindow", "toProfile", "before", "after")


def add_options(parser, mutation=True):
    parser.add_argument("--data-dir", metavar="DIR", help=f"the {identity.PRODUCT} data dir (default: $SOLARA_DATA_DIR, else the installed app's)")
    parser.add_argument("--json", action="store_true", help="print the result as JSON")
    parser.add_argument("--port", type=int, metavar="N", help="unsupported: sidebar commands require SolaraControl.json")
    parser.add_argument("--ws", metavar="URL", help="unsupported: sidebar commands require SolaraControl.json")
    if mutation:
        parser.add_argument("--dry-run", action="store_true", help="validate and print the change without applying it")


def add_parser(commands):
    sidebar = commands.add_parser("sidebar", help="list sidebar tab, group, folder, window and profile ids")
    sidebar.set_defaults(sidebar_operation="sidebar.list")
    add_options(sidebar, mutation=False)
    for kind in ("group", "folder"):
        parser = commands.add_parser(kind, help=f"create, rename and delete sidebar {kind}s")
        actions = parser.add_subparsers(dest="sidebar_action", metavar="<command>", required=True)
        create = actions.add_parser("create", help=f"create a {kind} from tabs (default: the active tab)")
        create.add_argument("name", metavar="NAME")
        create.add_argument("--tabs", nargs="+", metavar="ID", help="sidebar tab ids (default: active tab)")
        create.add_argument("--window", dest="windowId", metavar="ID", help="window for the default active tab")
        if kind == "group":
            create.add_argument("--color", metavar="COLOR", help="group color: grey, blue, red, yellow, green, pink, purple, cyan, orange, none or neutral")
        rename = actions.add_parser("rename", help=f"rename a {kind}")
        rename.add_argument("id", metavar="ID")
        rename.add_argument("name", metavar="NAME")
        delete = actions.add_parser("delete", help=f"delete a {kind}")
        delete.add_argument("id", metavar="ID")
        for action, child in (("create", create), ("rename", rename), ("delete", delete)):
            child.set_defaults(sidebar_operation=f"{kind}.{action}")
            add_options(child)
    tab = commands.add_parser("tab", help="move, pin, unpin, rename and reorder sidebar tabs")
    actions = tab.add_subparsers(dest="sidebar_action", metavar="<command>", required=True)
    move = actions.add_parser("move", help="move a tab to a group, folder, window or profile")
    move.add_argument("id", metavar="ID")
    target = move.add_mutually_exclusive_group(required=True)
    for option, field in (("group", "toGroup"), ("folder", "toFolder"), ("window", "toWindow"), ("profile", "toProfile")):
        target.add_argument(f"--to-{option}", dest=field, metavar="NAME" if option == "profile" else "ID")
    rename = actions.add_parser("rename", help="set a tab's custom title")
    rename.add_argument("id", metavar="ID")
    rename.add_argument("title", metavar="TITLE")
    reorder = actions.add_parser("reorder", help="place a tab before or after another sidebar row")
    reorder.add_argument("id", metavar="ID")
    anchor = reorder.add_mutually_exclusive_group(required=True)
    anchor.add_argument("--before", metavar="ID")
    anchor.add_argument("--after", metavar="ID")
    children = [("move", move), ("rename", rename), ("reorder", reorder)]
    for action in ("pin", "unpin"):
        child = actions.add_parser(action, help=f"{action} a tab")
        child.add_argument("id", metavar="ID")
        children.append((action, child))
    for action, child in children:
        child.set_defaults(sidebar_operation=f"tab.{action}")
        add_options(child)


def request_for(args):
    request = {"operation": args.sidebar_operation}
    for field in FIELDS:
        value = getattr(args, field, None)
        if value is not None:
            request[field] = value
    if request["operation"] != "sidebar.list":
        request["dryRun"] = args.dry_run
    return request


def resolve_endpoint(args):
    if args.port is not None or args.ws is not None or os.environ.get("SOLARA_CDP_URL"):
        raise EndpointError(TOKEN_ONLY)
    return resolve(data_dir=args.data_dir)


def valid_more(value, keys):
    return isinstance(value, dict) and all(key in keys and type(count) is int and count >= 0 for key, count in value.items())


def validate_result(value, request):
    if not isinstance(value, dict) or value.get("operation") != request["operation"]:
        raise EndpointError("sidebar returned an invalid result")
    if request["operation"] == "sidebar.list":
        keys = ("profiles", "windows", "tabs", "groups", "folders")
        if not valid_more(value.get("more", {}), keys):
            raise EndpointError("sidebar returned an invalid inventory")
        for key in keys:
            rows = value.get(key)
            if not isinstance(rows, list) or any(
                not isinstance(row, dict) or not isinstance(row.get("id"), str)
                or ("truncated" in row and not isinstance(row["truncated"], bool))
                or not valid_more(row.get("more", {}), ("tabIds",))
                for row in rows
            ):
                raise EndpointError("sidebar returned an invalid inventory")
    elif not isinstance(value.get("dryRun"), bool) or value["dryRun"] != request["dryRun"] or not isinstance(value.get("changes"), list) or any(not isinstance(change, str) for change in value["changes"]) or ("id" in value and not isinstance(value["id"], str)):
        raise EndpointError("sidebar returned an invalid change")
    return value


async def exchange(endpoint, request):
    if endpoint.explicit:
        raise EndpointError(TOKEN_ONLY)
    connection = Cdp(endpoint.ws)

    async def perform():
        await connection.open(REQUEST_TIMEOUT)
        return await connection.send("Solara.sidebar", request, timeout=REQUEST_TIMEOUT + 1)

    try:
        value = await asyncio.wait_for(perform(), REQUEST_TIMEOUT)
    except asyncio.TimeoutError:
        raise EndpointError(f"sidebar timed out after {REQUEST_TIMEOUT:g}s; the outcome may be unknown") from None
    except ConnectionLost:
        raise EndpointError(NOT_REACHABLE) from None
    except CdpError:
        raise
    except Exception:
        raise EndpointError(NOT_REACHABLE) from None
    finally:
        await connection.close()
    return validate_result(value, request)


def format_text(value):
    if value["operation"] == "sidebar.list":
        lines = []
        for key in ("profiles", "windows", "tabs", "groups", "folders"):
            lines.append(key.capitalize())
            for row in value[key]:
                cells = [row["id"], row.get("name", row.get("title", ""))]
                for field in ("profileId", "windowId", "groupId", "folderId"):
                    if row.get(field):
                        cells.append(f"{field}={row[field]}")
                if row.get("url"):
                    cells.append(row["url"])
                if row.get("truncated"):
                    cells.append("…")
                for field, count in row.get("more", {}).items():
                    if count:
                        cells.append(f"({count} more {field})")
                lines.append("  ".join(clean(str(cell)) for cell in cells if cell))
            more = value.get("more", {}).get(key, 0)
            if more:
                lines.append(f"({more} more {key})")
            elif not value[key]:
                lines.append("(none)")
        return "\n".join(lines)
    lines = ["Dry run:"] if value["dryRun"] else []
    lines.extend(clean(change) for change in value["changes"])
    if "id" in value:
        lines.append(f"id {clean(value['id'])}")
    return "\n".join(lines)


def run(args):
    out = sys.stdout = redact.RedactingStream(sys.stdout)
    err = sys.stderr = redact.RedactingStream(sys.stderr)
    redact.install_log_redaction()
    try:
        try:
            endpoint = resolve_endpoint(args)
            value = asyncio.run(exchange(endpoint, request_for(args)))
        except EndpointError as error:
            sys.stderr.write(f"{identity.COMMAND}: {error}\n")
            return 2
        except CdpError as error:
            sys.stderr.write(f"{identity.COMMAND}: {clean(str(error))}\n")
            return 1
        except KeyboardInterrupt:
            sys.stderr.write(f"{identity.COMMAND} {args.command}: interrupted\n")
            return 130
        try:
            if args.json:
                text = json.dumps(value, ensure_ascii=False, separators=(",", ":")) if value["operation"] == "sidebar.list" else json.dumps(value, ensure_ascii=False, indent=2)
            else:
                text = format_text(value)
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except (TypeError, ValueError, OverflowError, OSError) as error:
            sys.stderr.write(f"{identity.COMMAND} {args.command}: can't print the result ({error})\n")
            return 1
        return 0
    finally:
        out.drain()
        err.drain()
