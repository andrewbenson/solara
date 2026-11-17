import json
import os
import stat
import tempfile
from pathlib import Path

from solara_cli import identity

TARGETS = ("claude-code", "codex", "cursor")
MAX_CONFIG_BYTES = 4 * 1024 * 1024


def destination(target: str, project: bool) -> Path:
    base = Path.cwd() if project else Path.home()
    if target == "claude-code":
        return base / (".mcp.json" if project else ".claude.json")
    if target == "codex":
        return base / ".codex" / "config.toml"
    if target == "cursor":
        return base / ".cursor" / "mcp.json"
    raise ValueError("unknown MCP client target")


def checked_parent(path: Path, create=True) -> None:
    for parent in reversed(path.parent.parents):
        if parent.is_symlink():
            raise ValueError(f"{parent} is a symbolic link")
    if path.parent.is_symlink():
        raise ValueError(f"{path.parent} is a symbolic link")
    if create:
        path.parent.mkdir(parents=True, exist_ok=True)


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size


def read_config(path: Path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return "", None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise ValueError("configuration must be an owned regular file with one link")
        raw = os.read(fd, MAX_CONFIG_BYTES + 1)
        if len(raw) > MAX_CONFIG_BYTES:
            raise ValueError("configuration is too large")
        return raw.decode("utf-8"), fingerprint(info)
    finally:
        os.close(fd)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("configuration contains duplicate JSON keys")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"configuration contains non-JSON constant {value}")


def entry(target):
    value = {"command": identity.COMMAND, "args": ["mcp"]}
    if target != "codex":
        value = {"type": "stdio", **value}
    return value


def update_json(text, own):
    config = json.loads(text, object_pairs_hook=unique_keys, parse_constant=reject_constant) if text.strip() else {}
    if not isinstance(config, dict):
        raise ValueError("configuration must be a JSON object")
    servers = config.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        raise ValueError("mcpServers must be an object")
    if identity.COMMAND in servers:
        if servers[identity.COMMAND] != own:
            raise ValueError(f"{identity.COMMAND} exists and differs from this installer's read-only entry; edit or remove it first")
        return text
    servers[identity.COMMAND] = own
    return json.dumps(config, ensure_ascii=False, indent=2) + "\n"


def toml_entry():
    return f'[{"mcp_servers"}.{identity.COMMAND}]\ncommand = {json.dumps(identity.COMMAND)}\nargs = ["mcp"]\n'


def update_toml(text, own):
    try:
        import tomllib
    except ImportError:
        raise ValueError("Codex registration requires Python 3.11 or newer; the bundled CLI includes a supported Python") from None
    config = tomllib.loads(text)
    servers = config.get("mcp_servers", {})
    if not isinstance(servers, dict):
        raise ValueError("mcp_servers must be a table")
    if identity.COMMAND in servers:
        if servers[identity.COMMAND] != own:
            raise ValueError(f"{identity.COMMAND} exists and differs from this installer's read-only entry; edit or remove it first")
        return text
    updated = text + ("\n" if text.endswith("\n") else "\n\n" if text else "") + toml_entry()
    try:
        parsed = tomllib.loads(updated)
    except tomllib.TOMLDecodeError:
        raise ValueError("cannot append the MCP table to this TOML layout without changing unrelated configuration") from None
    if parsed.get("mcp_servers", {}).get(identity.COMMAND) != own:
        raise ValueError("cannot install the MCP table into this TOML layout")
    return updated


def backup_config(path, original):
    fd, name = tempfile.mkstemp(prefix=path.name + ".solara-mcp-backup-", dir=path.parent)
    backup = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(original.encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        backup.unlink(missing_ok=True)
        raise
    return backup


def write_config(path, text, previous, original):
    fd, name = tempfile.mkstemp(prefix=".solara-mcp-", dir=path.parent)
    staging = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            current = fingerprint(path.lstat())
        except FileNotFoundError:
            current = None
        if current != previous:
            raise ValueError("configuration changed during installation; retry")
        backup = backup_config(path, original) if previous is not None else None
        os.replace(staging, path)
        return backup
    finally:
        staging.unlink(missing_ok=True)


def install(target: str, project: bool, dry_run=False) -> int:
    try:
        path = destination(target, project)
        checked_parent(path, create=not dry_run)
        original, previous = read_config(path)
        own = entry(target)
        updated = update_toml(original, own) if target == "codex" else update_json(original, own)
        backup = None
        if not dry_run and (updated != original or previous is None):
            backup = write_config(path, updated, previous, original)
        print(f"{target}: {'Preview ' if dry_run else ''}{path}")
        if backup is not None:
            print(f"Backup: {backup}")
        print(toml_entry().rstrip() if target == "codex" else json.dumps({"mcpServers": {identity.COMMAND: own}}, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, UnicodeError) as error:
        print(f"{target}: error {error}")
        return 1
