import asyncio
import json
import math
import os
import shutil
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from urllib.parse import urlsplit, urlunsplit

from solara_cli import browsing, identity, redact
from solara_cli.endpoint import EndpointError, NOT_REACHABLE, resolve

REQUEST_TIMEOUT = 10
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
TOKEN_ONLY = "tab memory needs SolaraControl.json; --port, --ws and $SOLARA_CDP_URL are not supported"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _request, _file, _code, _message, _headers, _url):
        return None


def resolve_endpoint(args):
    if args.port is not None or args.ws is not None or os.environ.get("SOLARA_CDP_URL"):
        raise EndpointError(TOKEN_ONLY)
    return resolve(data_dir=args.data_dir)


async def read(endpoint):
    if endpoint.explicit or not endpoint.active:
        raise EndpointError(TOKEN_ONLY)
    try:
        return await browsing.run_bounded(fetch, endpoint, budget=REQUEST_TIMEOUT)
    except browsing.OutOfTime:
        raise EndpointError(f"tab memory timed out after {REQUEST_TIMEOUT:g}s") from None


def fetch(endpoint, deadline):
    parts = urlsplit(endpoint.active)
    url = urlunsplit((parts.scheme, parts.netloc, "/solara/tabs", parts.query, ""))
    direct = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with direct.open(url, timeout=max(0.001, deadline - time.monotonic())) as response:
            raw = bytearray()
            while True:
                if time.monotonic() >= deadline:
                    raise EndpointError("tab memory timed out")
                chunk = response.read1(min(64 * 1024, MAX_RESPONSE_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise EndpointError("tab memory response is too large")
        rows = json.loads(raw)
    except EndpointError:
        raise
    except urllib.error.HTTPError as error:
        error.close()
        raise EndpointError(f"{NOT_REACHABLE} (tab memory is unavailable)") from None
    except Exception:
        raise EndpointError(f"{NOT_REACHABLE} (tab memory is unavailable)") from None
    if not isinstance(rows, list) or any(not valid_row(row) for row in rows):
        raise EndpointError("tab memory returned an invalid snapshot")
    return rows


def valid_row(row):
    if not isinstance(row, dict):
        return False
    if any(not isinstance(row.get(key), str) for key in ("targetId", "title", "url", "profile")):
        return False
    if not isinstance(row.get("discarded"), bool) or "bytes" not in row:
        return False
    size = row["bytes"]
    return size is None or (type(size) is int and size >= 0) or (type(size) is float and math.isfinite(size) and size >= 0 and size.is_integer())


def memory(size):
    return f"{size / 1_000_000_000:.1f} GB" if size >= 1_000_000_000 else f"{size / 1_000_000:.1f} MB"


def clean(value):
    return " ".join("".join(" " if unicodedata.category(char).startswith("C") else char for char in value).split())


def cell_width(value):
    return sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in value)


def shorten(value, width):
    if cell_width(value) <= width:
        return value
    if width <= 0:
        return ""
    result = ""
    used = 0
    for char in value:
        size = cell_width(char)
        if used + size > width - 1:
            break
        result += char
        used += size
    return result + "…"


def host_first(url):
    for prefix in ("https://", "http://"):
        if url.startswith(prefix):
            return url[len(prefix):]
    return url


def table(rows, full=False):
    width = max(1, shutil.get_terminal_size((100, 24)).columns)
    ordered = sorted(rows, key=lambda row: row["bytes"] if row["bytes"] is not None else -1, reverse=True)
    values = [("Memory", "Title", "URL", "Profile")]
    values.extend(
        (
            "—" if row["discarded"] else "?" if row["bytes"] is None else memory(row["bytes"]),
            clean(row["title"]),
            clean(row["url"]) if full else clean(host_first(row["url"])),
            clean(row["profile"]),
        )
        for row in ordered
    )
    memory_width = max(cell_width(row[0]) for row in values)
    profile_width = min(max(cell_width(row[3]) for row in values), max(4, width // 6))
    available = max(2, width - memory_width - profile_width - 6)
    title_width = max(1, available * 2 // 5)
    url_width = max(1, available - title_width)
    if full:
        url_width = max(cell_width(row[2]) for row in values)
    widths = (memory_width, title_width, url_width, profile_width)
    lines = []
    for row in values:
        cells = [shorten(value, size) for value, size in zip(row, widths)]
        line = "  ".join(value + " " * (size - cell_width(value)) for value, size in zip(cells, widths)).rstrip()
        lines.append(line if full else shorten(line, width))
    total = sum(row["bytes"] or 0 for row in rows)
    asleep = sum(row["discarded"] for row in rows)
    unknown = sum(row["bytes"] is None and not row["discarded"] for row in rows)
    label = "Known total" if unknown else "Total"
    footer = f"{label} {memory(total)} · {len(rows)} tabs · {asleep} asleep"
    if unknown:
        footer += f" · {unknown} unknown"
    if full or cell_width(footer) <= width:
        lines.extend(("", footer))
    else:
        lines.append("")
        for part in footer.split(" · "):
            lines.append(shorten(part, width))
    return "\n".join(lines)


def run(args):
    out = sys.stdout = redact.RedactingStream(sys.stdout)
    err = sys.stderr = redact.RedactingStream(sys.stderr)
    redact.install_log_redaction()
    try:
        try:
            endpoint = resolve_endpoint(args)
            rows = asyncio.run(read(endpoint))
        except EndpointError as error:
            sys.stderr.write(f"{identity.COMMAND}: {error}\n")
            return 2
        except KeyboardInterrupt:
            sys.stderr.write(f"{identity.COMMAND} tabs: interrupted\n")
            return 130
        try:
            text = json.dumps(rows, ensure_ascii=False, indent=2) if args.json else table(rows, args.full)
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
        except (TypeError, ValueError, OverflowError, OSError) as error:
            sys.stderr.write(f"{identity.COMMAND} tabs: can't print the result ({error})\n")
            return 1
        return 0
    finally:
        out.drain()
        err.drain()
