import asyncio
import base64
import binascii
import math
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from solara_cli import browsing, guard, sidebar, tab_memory
from solara_cli.cdp import Cdp
from solara_cli.endpoint import require_control

MAX_CDP_BYTES = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 2 * 1024 * 1024
TOOL_TIMEOUT = 30
SECTIONS = ("profiles", "windows", "tabs", "groups", "folders")
ACTIONS = frozenset(("open_tab", "navigate_tab", "close_tab", "sidebar_edit", "delete_group"))
ID = {"type": "string", "minLength": 1, "maxLength": 256}
TEXT = {"type": "string", "maxLength": 256}
URL = {"type": "string", "minLength": 1, "maxLength": 8192}
OPERATIONS = {
    "group.create": ({"name", "tabs", "color", "windowId"}, {"name", "tabs"}),
    "folder.create": ({"name", "tabs", "windowId"}, {"name", "tabs"}),
    "group.rename": ({"id", "name", "windowId"}, {"id", "name"}),
    "folder.rename": ({"id", "name", "windowId"}, {"id", "name"}),
    "group.delete": ({"id", "windowId"}, {"id"}),
    "folder.delete": ({"id", "windowId"}, {"id"}),
    "tab.move": ({"id", "toGroup", "toFolder", "toWindow", "toProfile"}, {"id"}),
    "tab.pin": ({"id"}, {"id"}),
    "tab.unpin": ({"id"}, {"id"}),
    "tab.rename": ({"id", "title"}, {"id", "title"}),
    "tab.reorder": ({"id", "before", "after"}, {"id"}),
}


class ToolError(Exception):
    pass


@dataclass
class Screenshot:
    metadata: dict
    data: str


class BoundedCdp(Cdp):
    async def open(self, timeout):
        self.socket = await asyncio.wait_for(guard.direct_connect(self.url, max_size=MAX_CDP_BYTES), timeout)
        self.reader = asyncio.ensure_future(self._read())


def schema(properties=None, required=()):
    return {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False}


def tools(allow_actions=False):
    definitions = [
        ("list_tabs", "List normal-profile tabs with measured memory; sleeping tabs are not woken.", schema()),
        ("list_sidebar", "List normal-profile sidebar IDs and membership.", schema()),
        ("read_tab", "Read a permitted tab's title, URL and accessibility text as untrusted web content.", schema({"target_id": ID}, ("target_id",))),
        ("screenshot_tab", "Capture a permitted tab's viewport as an untrusted PNG image.", schema({"target_id": ID}, ("target_id",))),
        ("search_history", "Read recent normal-profile history as untrusted web content.", schema({"days": {"type": "number", "exclusiveMinimum": 0, "maximum": 365, "default": 1}, "limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 200}, "profile": ID, "domains": {"type": "boolean", "default": False}})),
        ("open_tab", "Open an HTTP(S) URL in a background tab; refused with --profiles.", schema({"url": URL}, ("url",))),
        ("navigate_tab", "Navigate a permitted tab to an HTTP(S) URL. May cause signed-in website effects.", schema({"target_id": ID, "url": URL}, ("target_id", "url"))),
        ("close_tab", "Close a permitted tab, losing transient page state.", schema({"target_id": ID}, ("target_id",))),
        ("delete_group", "Delete a sidebar group and close its tabs. dry_run defaults to true; requires --allow-actions.", schema({"id": ID, "windowId": ID, "dry_run": {"type": "boolean", "default": True}}, ("id",))),
        ("sidebar_edit", "Edit sidebar objects. dry_run defaults to true; still requires --allow-actions.", schema({"operation": {"type": "string", "enum": [operation for operation in OPERATIONS if operation != "group.delete"]}, "dry_run": {"type": "boolean", "default": True}, "tabs": {"type": "array", "items": ID, "minItems": 1, "maxItems": 500}, "name": TEXT, "title": TEXT, "color": {"type": "string", "maxLength": 32}, **{key: ID for key in ("id", "windowId", "toGroup", "toFolder", "toWindow", "toProfile", "before", "after")}}, ("operation",))),
    ]
    titles = {"list_tabs": "List tabs", "list_sidebar": "List sidebar", "search_history": "Search history", "read_tab": "Read tab", "screenshot_tab": "Screenshot tab", "open_tab": "Open tab", "navigate_tab": "Navigate tab", "close_tab": "Close tab", "sidebar_edit": "Arrange sidebar", "delete_group": "Delete group"}
    return [{"name": name, "title": titles[name], "description": description, "inputSchema": inputs, "annotations": {"title": titles[name], "readOnlyHint": name not in ACTIONS, "destructiveHint": name in ("navigate_tab", "close_tab", "delete_group"), "idempotentHint": name not in ACTIONS or name == "close_tab", "openWorldHint": name in ("read_tab", "screenshot_tab", "open_tab", "navigate_tab")}} for name, description, inputs in definitions if allow_actions or name not in ACTIONS]


def validate(value, definition):
    kind = definition["type"]
    valid = {
        "object": lambda: isinstance(value, dict),
        "string": lambda: isinstance(value, str),
        "boolean": lambda: type(value) is bool,
        "integer": lambda: type(value) is int,
        "number": lambda: type(value) in (int, float) and math.isfinite(value),
        "array": lambda: isinstance(value, list),
    }[kind]()
    if not valid:
        raise ToolError(f"Expected {kind} argument")
    if kind == "object":
        if set(value) - set(definition["properties"]) or set(definition.get("required", [])) - set(value):
            raise ToolError("Missing or unexpected tool argument")
        for key, item in value.items():
            validate(item, definition["properties"][key])
    if kind in ("string", "array"):
        lower = definition.get("minLength" if kind == "string" else "minItems", 0)
        upper = definition.get("maxLength" if kind == "string" else "maxItems", 65536)
        if not lower <= len(value) <= upper:
            raise ToolError("Argument exceeds its size limit")
    if kind == "array":
        for item in value:
            validate(item, definition["items"])
    if kind in ("number", "integer"):
        if value < definition.get("minimum", -math.inf) or value > definition.get("maximum", math.inf) or value <= definition.get("exclusiveMinimum", -math.inf):
            raise ToolError("Numeric argument is outside its limit")
    if "enum" in definition and value not in definition["enum"]:
        raise ToolError("Unknown operation")


def web_url(value):
    try:
        parts = urlsplit(value)
        if parts.scheme not in ("http", "https") or not parts.hostname or parts.username is not None or parts.password is not None or any(ord(char) < 33 for char in value):
            raise ValueError()
        parts.port
    except ValueError:
        raise ToolError("URL must be HTTP(S), with a host and without credentials or whitespace") from None
    return value


def normal_profile(row):
    profile_id = row.get("id")
    return isinstance(profile_id, str) and not any(profile_id.casefold().startswith(prefix) for prefix in ("incognito:", "guest:", "private:", "system:", "guest profile", "system profile"))


def selected_profiles(state, requested):
    if requested is not None and state.get("more", {}).get("profiles", 0):
        return []
    rows = [row for row in state["profiles"] if normal_profile(row)]
    if requested is None:
        return rows
    selected = set()
    for selector in requested:
        matches = [row for row in rows if row["id"] == selector]
        if not matches:
            matches = [row for row in rows if row.get("name") == selector and not row.get("truncated")]
        if len(matches) == 1:
            selected.add(matches[0]["id"])
    return [row for row in rows if row["id"] in selected]


def filtered_sidebar(state, profiles, scoped=False):
    allowed = {row["id"] for row in profiles}
    normal_windows = {row["id"] for row in state["windows"]}
    tabs = [dict(row) for row in state["tabs"] if row.get("profileId") in allowed and row.get("windowId") in normal_windows]
    tab_ids = {row["id"] for row in tabs}
    related_windows = {row["windowId"] for row in tabs}
    value = {"operation": "sidebar.list", "profiles": [dict(row) for row in profiles], "tabs": tabs}
    for section in ("groups", "folders"):
        value[section] = [dict(row) for row in state[section] if row.get("profileId") in allowed and row.get("windowId") in normal_windows]
        related_windows.update(row["windowId"] for row in value[section])
    value["windows"] = [dict(row) for row in state["windows"] if row.get("profileId") in allowed or row["id"] in related_windows]
    group_ids = {row["id"] for row in value["groups"]}
    folder_ids = {row["id"] for row in value["folders"]}
    for section in ("windows", "groups", "folders"):
        for row in value[section]:
            if row.get("profileId") not in allowed:
                row.pop("profileId", None)
            row["tabIds"] = [item for item in row.get("tabIds", []) if item in tab_ids]
            row.pop("more", None)
    for row in tabs:
        if row.get("groupId") not in group_ids:
            row.pop("groupId", None)
        if row.get("folderId") not in folder_ids:
            row.pop("folderId", None)
    if not scoped and state.get("more"):
        value["more"] = dict(state["more"])
    if scoped and (any(state.get("more", {}).values()) or any(row.get("more") for section in SECTIONS for row in state[section])):
        value["truncated"] = True
    return value


def folder_identity(root, folder):
    try:
        info = (root / "Chromium" / folder).stat(follow_symlinks=False)
    except OSError:
        return (None, folder)
    if not stat.S_ISDIR(info.st_mode):
        raise ToolError("History profile directory is not a regular directory")
    return (info.st_dev, info.st_ino)


def history_rows(root, profiles, days=1, limit=200, profile=None, domains=False, deadline=None):
    deadline = deadline or time.monotonic() + browsing.HISTORY_BUDGET
    browsing.checked_root(root, "history")
    session = browsing.read_session(root, deadline)
    names = browsing.profile_names(session)
    choices = [row for row in profiles if not row.get("truncated")]
    if profile is not None:
        choices = selected_profiles({"profiles": choices}, [profile])
        if not choices:
            raise ToolError("Requested history profile is unavailable or outside permitted profiles")
    owners = {}
    for profile_id in names:
        data_id = (session.get("profiles", {}).get(profile_id) or {}).get("dataId") or profile_id
        folder = "Default" if data_id == browsing.DEFAULT_PROFILE_ID else f"Profile {data_id}"
        if "/" in folder or "\\" in folder or ":" in folder or "@" in folder:
            continue
        owners.setdefault(folder_identity(root, folder), set()).add(profile_id)
    allowed = {row["id"] for row in choices}
    chosen = []
    for row in choices:
        profile_id = row["id"]
        if profile_id not in names:
            continue
        data_id = (session.get("profiles", {}).get(profile_id) or {}).get("dataId") or profile_id
        folder = "Default" if data_id == browsing.DEFAULT_PROFILE_ID else f"Profile {data_id}"
        if "/" in folder or "\\" in folder or ":" in folder or "@" in folder:
            continue
        if not owners.get(folder_identity(root, folder), set()).issubset(allowed):
            raise ToolError("Requested history source is shared with profiles outside the request")
        chosen.append(folder)
    if not chosen:
        return []
    identities = {folder_identity(root, folder) for folder in chosen}
    for _, directory in browsing.profile_dirs(root, session):
        if folder_identity(root, directory.name) in identities:
            chosen.append(directory.name)
    return browsing.history(root, days=days, limit=limit, domains=domains, deadline=deadline, _profile_folders=frozenset(chosen))


class Backend:
    def __init__(self, root: Path, allow_actions=False, profiles=None):
        self.root = root
        self.allow_actions = allow_actions
        self.profiles = profiles

    async def call(self, name, arguments):
        definitions = {tool["name"]: tool["inputSchema"] for tool in tools(self.allow_actions)}
        if name not in definitions:
            raise ToolError("Unknown or disabled tool; actions require --allow-actions at server startup")
        validate(arguments, definitions[name])
        try:
            return await asyncio.wait_for(self._call(name, arguments), TOOL_TIMEOUT)
        except asyncio.TimeoutError:
            raise ToolError("Tool timed out; an action's outcome may be unknown") from None

    async def _sidebar(self, endpoint):
        connection = BoundedCdp(endpoint.ws)
        try:
            await connection.open(10)
            request = {"operation": "sidebar.list"}
            value = await connection.send("Solara.sidebar", request, timeout=10)
            return sidebar.validate_result(value, request)
        finally:
            await connection.close()

    async def _target_rows(self, endpoint, state=None):
        rows = await tab_memory.read(endpoint)
        if self.profiles is None:
            return rows
        state = state or await self._sidebar(endpoint)
        if state.get("more", {}).get("profiles", 0):
            return []
        profiles = selected_profiles(state, self.profiles)
        counts = {}
        for row in state["profiles"]:
            counts[row.get("name")] = counts.get(row.get("name"), 0) + 1
        allowed = {row.get("name") for row in profiles if counts.get(row.get("name")) == 1 and not row.get("truncated")}
        return [row for row in rows if row["profile"] in allowed]

    async def _target(self, endpoint, target_id):
        matches = [row for row in await self._target_rows(endpoint) if row["targetId"] == target_id]
        if len(matches) != 1:
            raise ToolError("Tab is unavailable or outside the permitted profiles")
        return matches[0]

    async def _call(self, name, args):
        endpoint = require_control(self.root)
        if name == "list_tabs":
            return await self._target_rows(endpoint)
        if name == "list_sidebar":
            state = await self._sidebar(endpoint)
            return filtered_sidebar(state, selected_profiles(state, self.profiles), self.profiles is not None)
        if name == "search_history":
            await tab_memory.read(endpoint)
            state = await self._sidebar(endpoint)
            profiles = selected_profiles(state, self.profiles)
            rows = await browsing.run_bounded(history_rows, self.root, profiles, days=args.get("days", 1), limit=args.get("limit", 200), profile=args.get("profile"), domains=args.get("domains", False))
            require_control(self.root)
            return rows
        if name in ("sidebar_edit", "delete_group"):
            if name == "delete_group":
                args = {**args, "operation": "group.delete"}
            state = await self._sidebar(endpoint)
            request = self._edit_request(state, args)
            connection = BoundedCdp(endpoint.ws)
            try:
                await connection.open(10)
                value = await connection.send("Solara.sidebar", request, timeout=10)
                return sidebar.validate_result(value, request)
            finally:
                await connection.close()
        if name == "open_tab":
            if self.profiles is not None:
                raise ToolError("open_tab is unavailable with --profiles because creation cannot select a profile atomically")
            return await self._command(endpoint, "Target.createTarget", {"url": web_url(args["url"]), "background": True})
        target_id = args["target_id"]
        if name == "close_tab":
            if not any(row["targetId"] == target_id for row in await self._target_rows(endpoint)):
                if self.profiles is not None and any(row["targetId"] == target_id for row in await tab_memory.read(endpoint)):
                    raise ToolError("Tab is unavailable or outside the permitted profiles")
                return {"success": True, "alreadyClosed": True}
            return await self._command(endpoint, "Target.closeTarget", {"targetId": target_id})
        row = await self._target(endpoint, target_id)
        connection = BoundedCdp(endpoint.ws)
        try:
            await connection.open(10)
            attached = await connection.send("Target.attachToTarget", {"targetId": target_id, "flatten": True}, timeout=10)
            session = attached.get("sessionId")
            if not isinstance(session, str):
                raise ToolError("Could not attach to tab")
            if name == "navigate_tab":
                return await connection.send("Page.navigate", {"url": web_url(args["url"])}, session=session, timeout=10)
            metadata = {"target_id": target_id, "title": row["title"], "url": row["url"]}
            if name == "read_tab":
                tree = await connection.send("Accessibility.getFullAXTree", {}, session=session, timeout=10)
                text = []
                length = 0
                for node in tree.get("nodes", []):
                    if not isinstance(node, dict) or node.get("ignored"):
                        continue
                    role = (node.get("role") or {}).get("value")
                    if role not in ("StaticText", "text", "InlineTextBox", "heading", "link", "button", "textbox", "image"):
                        continue
                    value = (node.get("name") or {}).get("value")
                    if isinstance(value, str) and value:
                        if text:
                            length += 1
                        text.append(value[:max(0, 32769 - length)])
                        length += len(text[-1])
                        if length >= 32769:
                            break
                result = {**metadata, "text": "\n".join(text)}
            else:
                image = await connection.send("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False, "fromSurface": True, "clip": {"x": 0, "y": 0, "width": 1280, "height": 800, "scale": 1}}, session=session, timeout=10)
                data = image.get("data")
                if not isinstance(data, str) or len(data) > ((MAX_IMAGE_BYTES + 2) // 3) * 4:
                    raise ToolError("Screenshot exceeds the 2 MiB limit")
                try:
                    raw = base64.b64decode(data, validate=True)
                except (ValueError, binascii.Error):
                    raise ToolError("Screenshot is not valid PNG data") from None
                if len(raw) > MAX_IMAGE_BYTES or not raw.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise ToolError("Screenshot exceeds its limit or is not PNG data")
                result = Screenshot(metadata, data)
            current = await self._target(require_control(self.root), target_id)
            if current["profile"] != row["profile"]:
                raise ToolError("Tab profile changed while reading")
            return result
        finally:
            await connection.close()

    async def _command(self, endpoint, method, params):
        connection = BoundedCdp(endpoint.ws)
        try:
            await connection.open(10)
            return await connection.send(method, params, timeout=10)
        finally:
            await connection.close()

    def _edit_request(self, state, args):
        if any(state.get("more", {}).values()):
            raise ToolError("Sidebar inventory is incomplete; edits require a complete snapshot")
        operation = args["operation"]
        fields, required = OPERATIONS[operation]
        values = set(args) - {"operation", "dry_run"}
        if values - fields or required - values:
            raise ToolError("Missing or unexpected sidebar operation argument")
        if operation == "tab.move" and len(values & {"toGroup", "toFolder", "toWindow", "toProfile"}) != 1:
            raise ToolError("Tab move needs exactly one destination")
        if operation == "tab.reorder" and len(values & {"before", "after"}) != 1:
            raise ToolError("Tab reorder needs exactly one anchor")
        profiles = selected_profiles(state, self.profiles)
        allowed = {row["id"] for row in profiles if not row.get("truncated")}
        tabs = {row["id"]: row for row in state["tabs"]}

        def tab_allowed(row):
            if row.get("profileId") not in allowed or row.get("truncated"):
                raise ToolError("Sidebar object is unavailable or outside permitted profiles")
            window = next((item for item in state["windows"] if item["id"] == row.get("windowId")), None)
            if window is None or window.get("more", {}).get("tabIds", 0):
                raise ToolError("Sidebar membership is incomplete")
            members = window.get("tabIds", [])
            if any(member not in tabs for member in members):
                raise ToolError("Sidebar membership is incomplete")
            if self.profiles is not None and any(tabs[member].get("profileId") not in allowed for member in members):
                raise ToolError("Window contains tabs outside permitted profiles")

        def referenced(section, value, window_id=None):
            context = window_id if window_id is not None else args.get("windowId")
            matches = [row for row in state[section] if row["id"] == value and (context is None or section not in ("groups", "folders") or row.get("windowId") == context)]
            if len(matches) != 1:
                raise ToolError("Sidebar object is missing or ambiguous")
            row = matches[0]
            if section == "profiles":
                if row["id"] not in allowed or row.get("truncated"):
                    raise ToolError("Profile is outside permitted profiles")
            elif section == "windows":
                if row.get("profileId") not in allowed or row.get("truncated") or row.get("more", {}).get("tabIds", 0):
                    raise ToolError("Window is outside permitted profiles or incomplete")
                for member in row.get("tabIds", []):
                    if member not in tabs:
                        raise ToolError("Sidebar membership is incomplete")
                    tab_allowed(tabs[member])
            else:
                tab_allowed(row)
                if section in ("groups", "folders"):
                    if row.get("more", {}).get("tabIds", 0):
                        raise ToolError("Sidebar membership is incomplete")
                    for member in row.get("tabIds", []):
                        if member not in tabs:
                            raise ToolError("Sidebar membership is incomplete")
                        tab_allowed(tabs[member])
            return row

        if "id" in args:
            source = referenced({"group": "groups", "folder": "folders", "tab": "tabs"}[operation.split(".")[0]], args["id"])
        for tab_id in args.get("tabs", []):
            referenced("tabs", tab_id)
        for field, section in (("windowId", "windows"), ("toWindow", "windows"), ("toGroup", "groups"), ("toFolder", "folders"), ("before", "tabs"), ("after", "tabs")):
            if field in args:
                referenced(section, args[field], source["windowId"] if field == "toFolder" else None)
        if "toProfile" in args:
            matches = [row for row in state["profiles"] if args["toProfile"] in (row["id"], row.get("name"))]
            if len(matches) != 1:
                raise ToolError("Destination profile is missing or ambiguous")
            referenced("profiles", matches[0]["id"])
            target_name = matches[0].get("name")
            if not isinstance(target_name, str) or len([row for row in state["profiles"] if row.get("name") == target_name]) != 1:
                raise ToolError("Destination profile name is ambiguous")
        request = {key: value for key, value in args.items() if key != "dry_run"}
        if operation in ("folder.rename", "folder.delete"):
            request["windowId"] = source["windowId"]
        if "toProfile" in args:
            request["toProfile"] = target_name
        request["dryRun"] = args.get("dry_run", True)
        return request
