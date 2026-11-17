# `solara mcp`

`solara mcp [--data-dir DIR] [--profiles A,B] [--allow-actions]` serves MCP over
newline-delimited UTF-8 JSON-RPC on stdin/stdout. It opens no listener. Diagnostics
go to stderr. Clients start it as a subprocess. It supports initialization, ping,
tools/list and tools/call, and no prompts, resources, sampling or arbitrary code.
It negotiates protocol versions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05.
Calls run sequentially; cancellation notifications do not interrupt an active call,
which remains bounded by its deadline. Oversized unterminated input ends the server.

## Policy and trust

The default tool set is read-only. Action tools are listed and callable only with
`--allow-actions`, including sidebar dry runs. That flag is a process startup
decision, never a tool argument. `exec` and arbitrary Python, JavaScript, CDP
methods, filesystem paths, shell commands and browser shutdown are absent.

Every operation requires the existing owned, mode-0600, live-pid
`Chromium/SolaraControl.json`. There is no --port/--ws or environment CDP fallback.
Connections use its token, bypass proxies, retain the engine token policy and
control pill, and stop working when Settings control is disabled. History uses
the existing `history()` reader after checking the live token endpoint.

Private, guest and system profiles never appear. Page operations require a fresh
target ID from `/solara/tabs`, which filters normal profiles; CDP target discovery
alone is insufficient. Sidebar inventory supplies separate sidebar IDs.
`--profiles` accepts exact profile display names or sidebar profile IDs and filters
all inventories, history and operation operands, including destination and anchor
IDs. IDs take precedence over names; ambiguous or unknown names reveal nothing.
Target access fails closed if profile inventory is incomplete or duplicate display
names prevent associating an engine target with one profile. History uses exact
storage folders and their filesystem identities, and refuses a shared history
store when any logical profile using it is outside the request. Changes in profile membership between
checks can cause a refusal; this CLI filter is not a defense against malicious
same-user software or simultaneous owner edits. Scoped open is refused because
the existing create-target endpoint cannot atomically select a profile.

All returned titles, URLs, history, sidebar names, accessibility text and images
are untrusted web content. Text results contain an explicit warning and a JSON
envelope with `untrusted: true`; screenshots include that warning beside an MCP
PNG image block. Instructions inside this content are data and must not authorize
tools. Labels reduce confusion; the client agent must still enforce its user's
intent and approval rules.

## Tools and schemas

All input schemas are objects, reject unknown properties and use the following
fields. IDs and URLs must be nonempty strings. No tool accepts executable code.

| Tool | Properties (required in bold) | Result / existing endpoint |
| --- | --- | --- |
| `list_tabs` | none | Tab memory rows, including sleeping tabs, from GET `/solara/tabs` |
| `list_sidebar` | none | Profiles, windows, tabs, groups and folders from `Solara.sidebar` / `sidebar.list` |
| `read_tab` | **`target_id`** | Title, URL and text from a tab's `Accessibility.getFullAXTree`, after normal-profile inventory validation |
| `screenshot_tab` | **`target_id`** | Viewport PNG from `Page.captureScreenshot`, after the same validation |
| `search_history` | `days` number greater than 0 through 365 (default 1), `limit` integer 1–500 (default 200), `profile` string, `domains` boolean (default false) | Existing `history()` rows or domain rollup, restricted to permitted profiles |
| `open_tab` | **`url`** | Background tab via `Target.createTarget`; unavailable with a profile restriction |
| `navigate_tab` | **`target_id`**, **`url`** | `Page.navigate` on a validated tab |
| `close_tab` | **`target_id`** | `Target.closeTarget` on a validated tab |
| `delete_group` | **`id`**, `windowId`, `dry_run` boolean (default true) | Delete a sidebar group and close its tabs through `Solara.sidebar` / `group.delete` |
| `sidebar_edit` | **`operation`**, `dry_run` boolean (default true), operation fields below | `Solara.sidebar` request, with `dry_run` mapped to `dryRun` |

Action tools are the final five rows. Open and navigate accept only http(s) URLs
without embedded credentials; no file, javascript, data, blob or internal URLs.
No action brings a window forward. Closing a pinned tab follows existing browser
semantics and may leave its pin behind. Repeating `close_tab` after the target is gone succeeds without changing another tab. Navigation/open returning means the
request was accepted, not that the document finished loading.

`sidebar_edit.operation` is one of `group.create`, `group.rename`,
`folder.create`, `folder.rename`, `folder.delete`, `tab.move`, `tab.pin`,
`tab.unpin`, `tab.rename`, `tab.reorder`. It accepts the existing operation fields:
`id`, `name`, `color`, `tabs` (array of sidebar tab IDs), `windowId`, `title`,
`toGroup`, `toFolder`, `toWindow`, `toProfile`, `before`, `after`. Create requires
an explicit nonempty `tabs` list; implicit active-tab selection is excluded.
Only fields appropriate to that operation are accepted. Every referenced object
and its affected members must be in scope, or the whole request is refused.
`delete_group` has its own destructive annotation; `sidebar_edit` cannot call `group.delete`. Deleting a folder only dissolves it and keeps its tabs. Both tools default to dry-run.
The native endpoint supplies semantic validation and dry-run change descriptions.
Edits are refused when inventory or membership is incomplete, or when a window
contains excluded tabs whose split-row effects cannot be ruled out.

Every tool has a title and explicit MCP annotations. These describe behavior;
the server enforces startup policy independently of client approval UI.

| Tool | readOnlyHint | destructiveHint | idempotentHint | openWorldHint |
| --- | --- | --- | --- | --- |
| `list_tabs` | true | false | true | false |
| `list_sidebar` | true | false | true | false |
| `search_history` | true | false | true | false |
| `read_tab` | true | false | true | true |
| `screenshot_tab` | true | false | true | true |
| `open_tab` | false | false | false | true |
| `navigate_tab` | false | true | false | true |
| `close_tab` | false | true | true | false |
| `sidebar_edit` | false | false | false | false |
| `delete_group` | false | true | false | false |

## Limits and failure behavior

Input messages cap at 64 KiB. Text results cap at 128 KiB of encoded JSON, strings
at 32,768 characters, metadata titles at 1,024, URLs at 8,192, and lists at 500
rows. Truncation is explicit and may omit trailing rows. Screenshots cap at 2 MiB
decoded PNG and use a bounded viewport. CDP messages cap at 8 MiB. Tool calls have
a 30-second deadline; underlying transport/history deadlines may be shorter.
Malformed input returns JSON-RPC errors; tool refusals/errors use `isError: true`.
EOF exits without closing Solara. No tool writes an image or page to a path.

## Threat model

A hostile page can put instructions in its title, URL, accessibility text,
history entry, or visible pixels. With read tools it can try to induce the agent
to read other permitted tabs/history and disclose their contents through another
tool or conversation. With actions enabled it can additionally try to induce
navigation/open to attacker URLs (including data encoded in query parameters),
close tabs, or rename, pin, regroup and move sidebar items. Dry-run permits review
but is not authorization. Profile limits reduce the available data and operands;
read-only mode prevents these browser writes, not disclosure through other agent
capabilities. Screenshots and reads can contain sensitive authenticated content.

Text comes from accessibility nodes, not page JavaScript evaluation, so page
getters cannot turn a text read into arbitrary page script execution. Engine
policy still blocks privileged targets and cross-world access. A compromised
local client can request every exposed tool; startup flags are the boundary, not
tool descriptions or model behavior. Same-user malware already able to read the
control token is outside this wrapper's boundary. Arbitrary `exec` would grant
filesystem, process and network powers far beyond those tools and defeat both
read-only and profile policy, which is why it is excluded.

## Client registration

`solara mcp install --target claude-code|codex|cursor [--project] [--dry-run]` registers a
read-only `solara` stdio entry. It prints the destination and entry and preserves
all unrelated entries. `--dry-run` previews the destination and registration without writing files or directories. Before replacing a changed existing file, install saves its original bytes in a private sibling `<filename>.solara-mcp-backup-<random>` file and prints its path. An unchanged entry needs no backup. It does not enable Settings control or start a browser.
An existing unrelated entry named `solara` is refused. Install never silently
enables actions; edit the registered arguments explicitly to add startup flags.

Claude Code uses `~/.claude.json` (`mcpServers`) or project `.mcp.json`; Cursor
uses `~/.cursor/mcp.json` or project `.cursor/mcp.json`; Codex uses
`~/.codex/config.toml` or project `.codex/config.toml` (`mcp_servers.solara`).
Clients retain their own workspace trust and MCP approval requirements. Codex registration from a source install
requires Python 3.11 or newer for TOML parsing; the bundled CLI includes Python 3.13.

Read-only MCP and keeping arbitrary `exec` out of MCP are Solara’s recommendations. Clients and users choose their own trust and approval policies. The standalone `solara exec` command remains available for explicitly authorized terminal automation.

The transport intentionally implements the small stdio/tools subset. The
official SDK additionally requires HTTP server/client, JWT/crypto, multipart,
SSE, ASGI server and OpenTelemetry packages. Those are unnecessary for a local
stdio-only CLI; the existing locked dependency graph stays unchanged.

Protocol and client references: [MCP stdio](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports),
[Claude Code](https://code.claude.com/docs/en/mcp),
[Codex](https://developers.openai.com/codex/mcp),
[Cursor](https://cursor.com/docs/mcp).
