# Pooled pages: the JS contract

With `pagesPooledIn(windowId)` true, `TabViewPool` owns every page view in the window and RN mounts none
(architecture.md › Page views: static ownership). Everything the app did through a mounted `EngineWebView` still has
to happen. This is who does each part. Native side: port-omnibox. JS side: port-shell.

## Gate

One check, `pagesPooledIn(windowId)` in `apps/browser/src/lib/pagesPool.ts`: the shell, pane roots,
`SOLARA_NATIVE_PAGES_POOL=1` and `SolaraTabPool.available()`. ContentCard, Peek and the JS pool session read it, so a
build where the pool can't serve pages keeps RN's. `windowPagesPoolActive()` is the switch alone: native split chrome
keys off it, and it stays on when `SOLARA_TAB_POOL=0` turns the pool off.

## Page events

The pool is each page view's delegate. Its `onPageEvent` feed carries the tab, registration and session,
the event name, and the payload. Renderer events reserve their identity and settle native facts before delivery.
The payload keeps the native view's field names and engine URLs. The JavaScript UI handlers use
`unwrapPageEvent` to decode the payload, including its URLs, and recheck identity when held delivery resumes.

`onPageCreated` describes the engine and the navigation sequence known to have executed, or `-1` when no
sequence has been confirmed. A new registration starts a new session. A retained producer may send another
creation event when it reestablishes Store facts. `onPageGone` retires the UI projection for its exact identity.

## The handle

The ~40 callers of `webviews.get(tabId)` keep working: JS registers a pooled `WebViewHandle` in `webviews` on
`onPageCreated` and deletes it on `onPageGone`.

- `SolaraTabPool.pageCall(tabId, method, args, registrationGeneration)` is the one native entry: `method` is the view manager's AsyncFunction
  name (`goBack`, `loadUrl`, `find`, `focus`, …) and `args` its arguments, as the RN view's native handle passes them
  (engine URLs, `loadUrl(url, userInitiated)`). It resolves to what that AsyncFunction resolves to. Both kinds of page
  run one Swift dispatcher.
- `@solara/solaracore` builds both handles from one typed function over that native handle (`pooledWebViewHandle`), so
  URL conversion, `evaluate`'s JSON and fallbacks match, and TypeScript checks every method and argument.
- A call for a tab the pool has no view for rejects with code `ERR_NO_PAGE`; the handle returns the same fallback the
  RN handle returns for a missing view.
- `nativeTag()` is null for a pooled page. Its one caller, the focus-move claim in `focusHandoff.ts`, claims a pooled
  page by tab id instead (`SolaraTabPool.claimFocusPage(generation, tabId)`), which resolves the tab's pooled view and
  hands it to the shell's focus-move claim.
- WebKit tabs get a `WebKitTab` view through the same adapter, with the same events and handle.
- `pageCall(tabId, "focus", [])` makes the page view first responder in its window. Peek's open, Open as Tab and Split use it.

## What a mounted EngineWebView did besides events

| Logic | Owner when pooled |
|---|---|
| Navigation | Swift follows the committed Store request by exact identity. The inline host begins after renderer start. The pool follows during reconciliation. Both use verified constructor and transfer execution state. |
| Engine, readiness and browser ID | Swift settles engine and ready facts. The shared UI handler keeps the browser-ID projection and profile-use bookkeeping. |
| Retirement | Swift retires the session and registration. The JS pool projection drops its matching handle and progress. |
| Initial page: `url`, `adoptId`, `profile`, `engine`, `transferKey` | pool, from the store (`TabViewWanted`) |
| `visible`, `warm`, `neighbour` | pool, from where it places the view |
| `temporary` / `temporarySource` (Peek's source) | pool, from `state.peeks` |
| `pageColor`, `contentsBackgroundColor`, `autoPictureInPicture`, `shownUrl` | JS computes them as today and pushes them: `SolaraTabPool.setPageProps(tabId, { … })`, only on change |
| Discard and resume | Swift settles discard facts. The shared UI handler clears presentation state. Resume follows the committed request. |
| `handOff` / `takeHandOff`, `adoptId` transfers, pin handoffs, peek to tab | not in pooled mode: the pool moves its own view between slots and windows. Crossing to Little Solara is the park path |
| New Tab prewarm (`usePrewarm`) | off in pooled windows |
| A tab's engine or engine profile changes (Open in, Move to Profile) | The pool retires the old page and creates a new registration in its slot. The old page loses authority as soon as its engine or profile changes. Keyboard focus follows the replacement when warranted. |
| A page's `onWindowClose(withWindow)`: `withWindow` is true when Chrome started the window's close (an extension's `chrome.windows.remove`) | shared handler: `closeTabs([tabId], { lastClosesWindow: true, windowClosedByChrome: withWindow })` |
| Split-pane activation | Swift handles `onPageFocus` and `onPagePress` for the current registration and checks the visible split and Peek state before selecting a pane. The inline guest's touch handler uses the same Store command. |

## Checks

`pool-e2e-test.mjs`, with the pool on: a handle call reaches the page (find, zoom, back, `evaluate`), one event of
each kind reaches the store (title and favicon, progress, a notification click focuses its tab), a click in the
unfocused split pane focuses it, a peek opens and promotes, a tab moved to another profile and back gets a new page
each time (cookies prove which profile loaded it), and an engine change makes a new page whose ready reaches the store,
never one revived from an armed WebKit transfer, and that keeps keyboard focus when the old page had it.
