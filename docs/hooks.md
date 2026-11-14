# Hooks

Hooks are rules in `~/.config/solara/hooks.json` that act before or after things happen in Solara: block pages or
rewrite where they go before they load, send links from an app to a profile, save downloads in a folder, deny camera
or microphone to some sites, and play a sound, show a notification or run a program when a page loads, a download
finishes or a link from another app opens.

Solara reads the file at launch and again every time you save it. At launch, pages wait for the rules (at most 3 s)
before they load; if the rules aren't in by then the pages load unchecked, and Settings says how many did. Links
from other apps wait for the rules the same way, also at most 3 s, then open unchecked. A download that starts in
those seconds stays in the default folder. With no file, nothing is checked and nothing costs
anything. Settings › Advanced › Hooks lists every rule, says what it does and shows any error in the file.

## The file

```json
{
  "hooks": [
    { "name": "no-tiktok", "match": { "hosts": ["*.tiktok.com"] }, "block": true },
    { "name": "no-tracking", "match": { "hosts": ["*.example.com"] }, "stripParams": ["utm_*", "fbclid"] },
    { "name": "always-https", "match": { "hosts": ["plain.example"] }, "https": true },
    { "name": "old-reddit", "match": { "hosts": ["www.reddit.com"] }, "rewrite": "https://old.reddit.com{path}{query}{fragment}" },
    { "name": "slack-to-work", "match": { "apps": ["com.tinyspeck.slackmacgap"] }, "openIn": { "profile": "Work" } },
    { "name": "invoices", "match": { "urls": ["https://billing.example.com/*"] }, "fileInto": "~/Downloads/Invoices" },
    { "name": "no-camera", "match": { "hosts": ["*.example.com"] }, "deny": ["camera", "microphone"] },
    { "name": "chime", "on": ["download.finished"], "sound": "Glass" }
  ]
}
```

`"version": 1` may sit beside `"hooks"`. Every hook has a unique `name`, an optional `match` and exactly one action.
Any other key, a wrong type or a second action makes the whole file invalid: Solara keeps using the last rules that
loaded, and Settings shows the error with the hook it's in. Hooks are tried in file order; the first one that applies
decides.

The file and its folder must belong to you and not be writable by other users (as ssh asks of `~/.ssh`): otherwise
Solara ignores the file, turns every hook off and says so in Settings (`chmod go-w` fixes it). A symbolic link is
fine; the file it points to is checked.

### Match

All keys are optional. A URL matches when any of `urls`, `hosts` or `regex` matches it; `apps` and `profiles` then
narrow that down.

| Key | Matches |
|---|---|
| `urls` | URL patterns, `scheme://host/path`, read part by part as in Chrome extension match patterns: the scheme is `http`, `https` or `*`; the host is `example.com`, `*.example.com` (it and every subdomain) or `*`, with an optional `:port`; `*` in the path matches any run of characters, and the path pattern covers the path and query. `https://*.billing.com/*` never matches `https://evil.net/x.billing.com/` |
| `hosts` | `"example.com"` exactly, or `"*.example.com"` for it and every subdomain. Hosts with accents go in punycode (`xn--bcher-kva.de`) |
| `regex` | one regular expression that must match the whole URL (as if it began with `^` and ended with `$`), at most 1,024 characters, in the syntax both RE2 and macOS accept: no lookahead or lookbehind, backreferences, nested quantifiers like `(a+)+`, possessive or atomic groups or inline flags. Its groups are `{1}`…`{9}` in a rewrite when `regex` is the hook's only URL condition. A URL longer than 64 KB isn't checked: a page loading it is blocked whenever a page hook has a `regex`, a camera or microphone request is denied, and no other hook applies |
| `apps` | the code-signing identifier of the app a link came from (`com.apple.mail`, `com.tinyspeck.slackmacgap`), read from the sender's audit token, together with the team that signed it. An identifier starting `com.apple.` counts only when Apple itself signed the app. For any other app, the sender must be signed by the same team as the copies of that app in `/Applications` or `/System/Applications` (copies elsewhere, such as `~/Downloads` or a disk image, don't count, and copies there that disagree on their signer count as none: then only a `team` pin lets the app's links match); that team is remembered in Solara's data folder the first time a hook needs it and shown in Settings with a Forget button (forget it after an app changes its signer). A link signed by another team never matches and Settings names the app. `"team": "BQR82RBBHL"` next to `apps` pins the team for that hook alone instead (`codesign -dv` shows it as TeamIdentifier). Unsigned and ad hoc signed apps never count. Such a hook only matches links from other apps; a link whose sender macOS doesn't name (Handoff, a link that started Solara from a script) never matches. Only `block`, `openIn` and `run`, `notify` and `sound` on `link.opened` take it |
| `profiles` | profile names as in Settings › Profiles. A hook with `profiles` never applies in a private window |

URLs are compared the way Chrome reads them: a user name or password before the host is ignored (so
`https://a@www.tiktok.com/` is `www.tiktok.com`), one trailing dot on the host is dropped, and hosts are in lower
case and punycode. Only http and https URLs match.

### Actions

| Action | When | Approval | Notes |
|---|---|---|---|
| `"block": true` | a page or a frame in it is about to load: a link, a redirect, a typed address, a bookmark, a link from another app, back and forward | no | Chrome shows its "blocked" page (in the frame, for a frame); a link from another app is dropped. Every redirect along the way is checked, and `blob:` and `filesystem:` pages count as the site that made them. A page loading in the background for a quicker click (prerender) is cancelled. When the rules change, pages kept for back and forward and prerendered pages are dropped so a newly blocked one can't come back from there. Not covered: a page's own fetches and images, and speculation-rules prefetches (they may still send the request; the page itself is blocked when you open it). Private windows are untouched by every hook |
| `"stripParams": ["utm_*", "fbclid"]` | a page is about to load | no | Removes those query parameters (a trailing `*` matches a prefix) and keeps the rest in order |
| `"https": true` | same | no | Loads an `http://` page over `https://` (an explicit `:80` is dropped) |
| `"rewrite": "<template>"` | same | yes | See below |
| `"openIn": {"profile": "Work"}` | a link arrives from another app | no | Opens it in that profile's window |
| `"fileInto": "~/Downloads/Invoices"` | a download starts | outside `~/Downloads` | Chrome saves the file straight into that folder (made if missing), with its own unique names, quarantine and checks. A download you're asked about (Save As, a type that always asks), a private window's download and an extension's are left alone |
| `"deny": ["camera", "microphone"]` | a site asks for the camera or microphone | no | A request that includes a listed kind is denied without a prompt and nothing is remembered. The hook matches the site asking and the page it's on. A site you already allowed in Site Settings doesn't ask, so remove that first. Screen sharing (`getDisplayMedia`) isn't covered |
| `"sound": "Glass"` with `"on"` | `download.finished`, `page.loaded`, `link.opened` | no | Plays a system sound |
| `"notify": true` with `"on"` | same | no | Shows a notification: the file name, the page's title and host, or the link's host |
| `"run": ["/path/to/program", "arg"]` with `"on"` | same | yes | See below. `timeout` in seconds, 1 to 600, default 30 |

`block`, `stripParams`, `https` and `rewrite` act on the page itself, in Solara's engine. `stripParams`, `https` and
`rewrite` change only a page's own load, and only when it's a plain load: never a form being sent, a reload, back or
forward, or a redirect along the way (a redirect can still be blocked). If the new address asks Chrome to load it again with
more client hints or an origin trial (`Critical-CH`, `Critical-Origin-Trial`), Chrome would go back to the address from
before the rewrite: that load is blocked instead, so a rewrite to such a site fails the first time you open it and
works from then on. The page loads the new address as an
internal redirect, so it keeps who started it (the page, its frame, whether you clicked) and the referrer rules: a
rewrite never turns a page's click into something that looks typed.

`fileInto` matches the download's final address after redirects. When a page starts the download, that page (or the
tab it's in) must be on the same site as the final address, so another site can't push a file into your folder
through a matched site.

### Rewrite templates

`{url} {scheme} {host} {port} {path} {query} {fragment} {origin}` (`{port}` is `:8080` or empty, `{query}` starts
with `?`, `{fragment}` with `#`) and `{1}`…`{9}` for regex groups.

- The host is either written out (`https://old.reddit.com…`) or the page's own: the template starts with `{origin}`,
  `{scheme}://{host}`, `{scheme}://{host}{port}`, `https://{host}` or `http://{host}`, followed by `/`, `?`, `#`,
  `{path}`, `{query}` or `{fragment}`. A placeholder can't be part of the host, so `{origin}.evil.net`,
  `{origin}:8443` and `https://{1}.mirror.net/` are refused.
- `{path}`, `{query}` and `{fragment}` go in as they are. Every other placeholder after the host (`{url}`, `{host}`,
  `{1}`…) is percent-encoded, so a page can't add `/ ? # @ :` through it.
- The result is read as a URL and checked before it's used: http or https, no user name, at most 8 KB, the host and
  port the template names (or the page's own), and never `https` turned into `http`. Anything else and the hook
  doesn't apply.

Every `rewrite` needs approval, even one that stays on the page's site: a site's own pages can still forward a link
elsewhere or act on your account.

## Approval

`run` hooks, `rewrite` hooks and `fileInto` folders outside `~/Downloads` do nothing until you approve them in
Settings › Advanced › Hooks. Approve… opens a sheet with exactly what will be allowed, with nothing hidden: the
hook's text, the program and every argument in a fixed-width font, invisible and direction-changing characters
shown as `\u{…}`, and each file it runs with its SHA-256. It warns when the program is a shell, an interpreter or
a program that runs its arguments (`sh`, `bash`, `zsh`, `osascript`, `python`, `perl`, `ruby`, `node`, `env`, `open`,
`nohup`, `xargs`, `find`, `ssh`, `sudo`…, judged by the name of the file a link points to as well), when an interpreter's
arguments use `SOLARA_` values (which web pages choose) and when the program sits in a folder you can write to. If
the hook or one of its files changes while the sheet is open, the sheet closes and nothing is approved. When a hook
you approved before was edited, the sheet shows line by line what changed.

What an approval covers:

- the hook's exact text: any change to it (program, arguments, folder, match, name) turns it off until you approve
  it again. Moving hooks around in the file doesn't;
- for `run`: the SHA-256, device, inode, size and modification time of the program and of every argument that is an
  existing file (a script it runs; an argument that isn't a full path is looked up in your home folder, where the
  program runs), checked before every run. A changed file turns the hook off ("changed since it was approved"). The
  program that starts is the file that was checked: if it was replaced in between, the run is skipped. Only the
  files listed in the sheet are checked: whatever else the command reads can change without asking you. A program
  or script that other users can change (group or world writable, or in such a folder) can't be approved, and a
  hook whose interpreter is given a folder (`python3 ~/project`) stays off, with the reason in Settings: name the
  file it should run;
- for `fileInto` outside Downloads: the folder's real path and its device and inode. A folder replaced or swapped
  for a link isn't used. A folder inside Downloads needs no approval, but each one of its parts must be a real
  folder when a download starts: a symbolic link anywhere along the way sends the download to the default folder.

Approvals are kept in Solara's own data folder, not next to hooks.json, and don't sync. Only a click in Settings
approves a hook: nothing in hooks.json, a page, an extension or the `solara` command can.

## Programs

- Solara runs the program directly with the arguments in the list, never through a shell (use
  `["/bin/sh", "-c", "…"]` if you want one, and approve it knowingly). The program must be a full path (`/…` or
  `~/…`; `~` is your home folder from the system's user record); PATH isn't searched.
- What the page or download says is never put into the arguments. The program gets it in its environment and on
  standard input:
  - `SOLARA_HOOK` (the hook's name), `SOLARA_EVENT`, `SOLARA_URL`, `SOLARA_PROFILE`, `SOLARA_TITLE` (`page.loaded`),
    `SOLARA_FILE` (always a full path) and `SOLARA_MIME` (`download.finished`), `SOLARA_APP` (`link.opened`), each at
    most 4 KB with control characters and direction-changing characters removed;
  - the same as one JSON object on standard input.
  These values come from web pages: quote them in a shell (`"$SOLARA_URL"`), never `sh -c "… $SOLARA_TITLE …"` or
  `open "$SOLARA_FILE"` on a file a page named. For a sound or a notification use `sound` and `notify` instead.
- The environment is otherwise only `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `USER`, `LOGNAME`, `TMPDIR` and
  `LANG`. Nothing of Solara's own environment, open files, exception ports or DevTools port reaches it, its signals
  start at their defaults, and macOS doesn't count it as Solara for camera, microphone or folder permissions: it
  asks for its own. On a macOS that can't start it that way, it doesn't run at all.
- It runs in your home folder, in its own process group. When the program ends, anything it left running in its
  group is stopped too, but a daemon that leaves the group (`setsid`, `daemon`, a double fork into its own session)
  keeps running: Solara doesn't track it. After its timeout the group gets SIGTERM, then SIGKILL 2 s later. Its output (the first
  64 KB of each run) goes to `hooks.log` in Solara's data folder; clearing history in Solara empties `hooks.log`.
- At most 2 runs of a hook at once and 8 overall. Each hook has its own queue of 16 waiting `page.loaded` or
  `link.opened` runs and 30 of them a minute, and 256 waiting `download.finished` runs; past that the oldest waiting
  run of that kind is skipped. Settings shows how many runs a hook skipped.
- No event fires for private windows, and no hook sees internal pages. Nothing from a private window reaches
  `hooks.log` or Settings.

## Examples

Open YouTube links from Messages in a profile, strip tracking parameters from news links, and log every finished
PDF:

```json
{
  "hooks": [
    { "name": "messages-youtube", "match": { "apps": ["com.apple.MobileSMS"], "hosts": ["*.youtube.com", "youtu.be"] }, "openIn": { "profile": "Personal" } },
    { "name": "clean-news", "match": { "hosts": ["news.example"] }, "stripParams": ["utm_*", "ref"] },
    { "name": "pdf-log", "on": "download.finished", "match": { "urls": ["*://*/*.pdf"] }, "run": ["/bin/sh", "-c", "printf '%s\\n' \"$SOLARA_FILE\" >> ~/pdfs.txt"] }
  ]
}
```

## For testing

`SOLARA_CONFIG_DIR` points Solara at another folder instead of `~/.config/solara`. The end-to-end check is
`apps/browser/scripts/hooks-test.mjs` (docs/testing.md); page and download rules need an engine with
`ac_hooks_configure_v1`, and Settings says when the engine in use doesn't have it.
