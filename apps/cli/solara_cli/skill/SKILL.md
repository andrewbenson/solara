---
name: solara
description: Use when a task needs the user's running Solara browser and logins, page reading or interaction, screenshots, JavaScript, tab memory, sidebar tabs, groups or folders, userscripts, or reports from pinned and visited sites.
---

# Driving Solara

Use `solara exec` for web pages. Use `solara sidebar` to find native sidebar IDs, then `solara tab`,
`solara group` or `solara folder` to arrange them. Use `solara tabs` for tab memory. Sidebar IDs and DevTools
`targetId` values are different; never substitute one for the other.

## Sidebar

Start with a listing:

```sh
solara sidebar --json
```

It lists normal profiles, regular windows, tabs, groups and Top Apps folders, including sleeping tabs without
waking them. Private profiles and windows are omitted and refused as sources or destinations of edits.

Run every edit with `--dry-run` first, especially anything destructive. Inspect the proposed change, then repeat
without `--dry-run` to apply it. Dry-run validates without changing state or allocating IDs; it still needs Solara
running with control on. Use IDs from the listing in these examples:

| Edit | Preview |
| --- | --- |
| Create an unpinned group | `solara group create Research --color blue --tabs t_1 t_2 --dry-run` |
| Rename a group | `solara group rename g_1 Reading --dry-run` |
| Delete a group and close its tabs | `solara group delete g_1 --dry-run` |
| Create a Top Apps folder and pin its tabs | `solara folder create Tools --tabs t_3 t_4 --dry-run` |
| Rename a folder | `solara folder rename tf_1 "Daily tools" --dry-run` |
| Dissolve a folder, keeping its pinned tabs | `solara folder delete tf_1 --dry-run` |
| Move into a group | `solara tab move t_5 --to-group g_1 --dry-run` |
| Move into a folder | `solara tab move t_5 --to-folder tf_1 --dry-run` |
| Move to a window | `solara tab move t_5 --to-window w_2 --dry-run` |
| Move to a profile by its unique name | `solara tab move t_5 --to-profile Work --dry-run` |
| Pin a tab | `solara tab pin t_5 --dry-run` |
| Unpin a tab | `solara tab unpin t_5 --dry-run` |
| Set a custom title | `solara tab rename t_5 "Daily reading" --dry-run` |
| Reorder before a tab | `solara tab reorder t_5 --before t_6 --dry-run` |
| Reorder after a tab | `solara tab reorder t_5 --after t_6 --dry-run` |

Create requires tabs from one window and profile. Without `--tabs`, it uses the active tab of the focused regular
window, or the window selected with `--window w_1`; empty groups and folders are unsupported. Group colors:
`grey`, `blue`, `red`, `yellow`, `green`, `pink`, `purple`, `cyan`, `orange`, `none` (transparent), `neutral`.
An empty title (`solara tab rename t_5 "" --dry-run`) clears the custom title.

Reorder stays within one window, profile, pin section, group and folder. Split panes move together; split rows
cannot enter Top Apps folders. A profile move starts a fresh navigation using that profile's cookies and session;
it does not carry page state. Move to the destination window or profile before moving into its group or folder.

All edits accept `--json` and `--data-dir DIR`. JSON gives `operation`, `dryRun`, `changes`, and a new `id` after
creation. Sidebar commands require the token control path (`SolaraControl.json`), native workspace ownership,
control on and safe mode off. `--port`, `--ws` and `$SOLARA_CDP_URL` are refused. The data dir is `--data-dir`,
then `$SOLARA_DATA_DIR`, then the installed app's. After a timeout or disconnect, inspect `solara sidebar` before
repeating an edit: its outcome may be unknown.

Write limits apply to dry-run too: 65,536 bytes of serialized JSON params; 256 Unicode scalars for names,
titles and profile-name destinations; 1–256 ASCII letters, digits or `._:@-` for IDs; 500 explicit tab entries
before deduplication and 500 tabs after split-row expansion. Operation names are capped at 64 scalars, colors
at 32; only supported values are accepted. Invalid input is refused, never shortened. Folder names cannot start
or end with whitespace.

Listings cap names and titles at 1,024 Unicode scalars, URLs at 8,192, IDs at 256 and colors at 32. A capped row
has `truncated: true` in JSON and `…` in text; stored values stay intact. Each row returns at most 500 `tabIds`,
with omitted membership in its `more.tabIds`. The whole inventory has a 262,144-byte budget: top-level `more`
counts omitted profiles, windows, tabs, groups and folders. Text shows `(17 more tabs)` or `(42 more tabIds)`.
Referenced IDs can belong to omitted rows. There is no pagination flag; do not treat a partial listing as complete.

## Tab memory

```sh
solara tabs
solara tabs --full
solara tabs --json
solara exec --json 'await tab_memory()'
```

`solara tabs` lists actual Chromium tabs in normal profiles across windows, including sleeping tabs without waking
them. Restored sidebar tabs not yet instantiated in Chromium may be absent. Use `solara sidebar` for saved sidebar
IDs and titles, subject to its listing caps. The memory table sorts largest first, in decimal MB/GB. `—` means asleep; `?` means awake with no reading. The footer
sums available tab readings, not whole-browser memory; it says `Known total` when an awake reading is missing.
`--full` keeps whole URLs; the normal table shortens columns to terminal width. Private, guest and system profiles
are excluded.

`--json` and `await tab_memory()` return the original-order list with `targetId`, `title`, `url`, `profile`,
`discarded` and unrounded `bytes` (`null` when asleep or unavailable). `title` is Chromium's page title, not a custom
sidebar name; titles and URLs are unshortened. This is attributed private footprint, not JavaScript heap size or a renderer total repeated per tab. Measurements can change between
requests. Both use the token control path, accept `--data-dir DIR` on their command, and refuse `--port`, `--ws`
and `$SOLARA_CDP_URL`. An engine without the tab-memory endpoint reports an error.

## Page execution

`solara exec` runs Python against the Solara the user has open, with top-level `await`. The value of the last
expression is printed: strings as they are, anything else as its repr, or JSON with `--json`. Every run is a new
process, so carry state between runs in a URL or a file, not a variable.

```sh
solara exec 'await tab.title()'
solara exec --json '[await t.current_url() for t in tabs]'
solara exec -f script.py
```

In scope:

- `tab`: the web page the user is looking at when the run starts, even with Solara's window covered. When they're on
  New Tab or another Solara view, any use of `tab` raises `NoPageTab` (and `bool(tab)` is False): open a page with
  `new_tab` instead.
- `tabs`: every web page tab when the run starts, the user's own included, plus the ones `new_tab` opens.
- `new_tab(url, background=True)`: opens a tab in the sidebar, waits for the page to load and returns it.
  `background=False` switches the user to it.
- `js(expression, tab=None)`: evaluates JavaScript and returns its value. Pass `tab=t` for your own tab; without
  it, `js` uses the user's tab, else the last tab you opened, else raises `NoPageTab`.
- `browser` (pydoll `Chrome`), `By`, `Key`, `asyncio` and the rest of `pydoll`'s exports.

Exit status: 0 done, 1 your code raised or timed out (`--timeout`, default 300 s), 2 Solara can't be reached or
stopped the connection.
On exit 2, tell the user to open Solara and turn on Settings › "Let the solara command control Solara".

## Etiquette

This is the user's own browser, signed in to their accounts.

- Do your work in a tab you open with `new_tab`. Read the user's `tab`, but don't navigate it unless they ask.
- Close only the tabs you opened (`await t.close()`), and only when you're done with them.
- Delete the scratch scripts you wrote; keep the files the user asked for (screenshots, exports).
- Ask before anything with consequences: submitting forms, sending messages, posting, buying, deleting,
  changing settings or accepting dialogs.
- Don't read or export cookies, passwords or storage unless the user asks for exactly that.

## Recipes

Read the page the user is on (raises `NoPageTab` on New Tab):

```sh
solara exec 'await tab.current_url(), await tab.title()'
solara exec 'await js("document.body.innerText.slice(0, 5000)")'
```

Open a page and work there. Every run starts over, so find your tab again by URL:

```sh
solara exec 't = await new_tab("https://example.com"); await js("document.links[0].href", tab=t)'
solara exec 't = [t for t in tabs if "example.com" in await t.current_url()][0]; await t.page_source()'
```

Longer work goes in a file. Close your tab, then put the data on the last line so it's printed:

```python
t = await new_tab("https://news.ycombinator.com")
rows = await js("[...document.querySelectorAll('.titleline > a')].slice(0, 3).map(a => [a.innerText, a.href])", tab=t)
await t.take_screenshot("/tmp/hn.png")
await t.close()
rows
```

```sh
solara exec --json -f /tmp/hn.py && rm /tmp/hn.py
```

Find, click and type:

```python
t = await new_tab("https://example.com/search")
box = await t.query('input[name="q"]', timeout=10)
await box.type_text("solara browser\r")
await t.wait_for_url("**?q=*", timeout=15)
results = await t.query("h3", find_all=True)
[await r.text() for r in results[:5]]
```

`query` takes CSS or XPath; `find(tag_name=..., id=..., class_name=..., name=..., text=..., **attributes)` builds
the selector for you. Both wait up to `timeout` seconds for the element. When it isn't there they raise
`ElementNotFound` (with `timeout=0`, the default) or `WaitElementTimeout` (with a timeout), or return `None` with
`raise_exc=False`. For a click that loads a new page:

```python
async with t.expect_navigation():
    await (await t.find(tag_name="a", text="Next")).click()
```

Wait for things:

```python
await (await t.query("#results", timeout=10)).wait_until(is_visible=True, timeout=10)
await t.wait_for_script("document.readyState === 'complete'", timeout=10)
await t.wait_for_network_idle(timeout=15)
```

Screenshots and PDFs go to a file:

```sh
solara exec 'await tab.take_screenshot("/tmp/page.png"); "/tmp/page.png"'
solara exec 'await tab.take_screenshot("/tmp/full.png", beyond_viewport=True)'
solara exec 'el = await tab.query("main"); await el.take_screenshot("/tmp/main.png")'
solara exec 'await tab.print_to_pdf("/tmp/page.pdf")'
```

Run JavaScript: `js()` returns plain values (awaiting promises) and raises on a JavaScript error.

```sh
solara exec --json 'await js("[...document.links].slice(0, 20).map(a => ({text: a.innerText, href: a.href}))")'
```

The full pydoll 3.0 API is in `references/pydoll.md`.

## Userscripts

When the user wants a site to look or behave differently every time they visit it, write a userscript instead of
driving the page by hand. `solara scripts` takes TypeScript or JavaScript with a Violentmonkey `==UserScript==` header,
so existing `.user.js` files work too. `solara scripts --help` and each command's `--help` explain the details.

- Start from `solara scripts new`, or from a script the user already has.
- Read the real page before writing selectors, and keep the script small and robust to the site changing.
- Iterate with `solara scripts test` until it passes cleanly on the pages it targets. It runs in a tab of its own and
  reports what ran, what logged and what threw.
- Install only once the user is happy with it. `solara scripts list` and `uninstall` manage what's installed.

## Daily reports

Once you know Solara works, ask the user whether they'd like a daily report. If they say no, drop it. If they say
yes, ask what they care about most and when they want it, then set it up so it runs on its own each day (your
harness's scheduler if it has one, otherwise the system's). Save what you agreed on where the scheduled run can read
it.

Each report starts from what the user actually uses. `await pinned()` returns their pinned tabs and favorites, and
`await history()` returns what they visited recently. Visit the sites that matter in tabs of your own, using their
logins, and only read: never reply, mark as read, accept or send anything. By default the report covers what's
pending for them and what changed on things they finished or are waiting on since the last report. Shape it around
their priorities, keep it short, and deliver it the way they asked. Keep enough state between runs to tell new from
old.

## Gotchas

- Tab and element methods are coroutines: `await tab.title()`, `await tab.current_url()`, `await el.text()`.
  `el.get_attribute("href")` is a plain call and `el.tag_name` a plain property, both read when the element was found.
- `solara exec` refuses `browser.stop()` and `Browser.close`. It never quits Solara.
- It reaches web pages only (http, https, `about:blank`, `data:`, `blob:`), not `file://`, `chrome://`, extension
  pages or Solara's own views. Solara also refuses DevTools calls that read cookies, storage or saved data, change
  browser settings or permissions, intercept requests or touch local files; those fail with
  `solara: <Method> isn't allowed for the solara command`. Network events come without cookie and authorization headers.
- Background tabs are hidden, so pages there may throttle timers and animations. Screenshots still work.
- An `await` inside a generator expression makes it async, so `next(... await ...)` fails. Use a list comprehension.
- Type with `type_text` (real key events) when a page listens for keys; `insert_text` is faster for plain fields.
- To press Enter in a field, end the typed text with `"\r"`. `keyboard.press(Key.ENTER)` sends no character, so it
  doesn't submit forms; use it for key handlers only.
