# Omnibox Swift actions implementation plan

Goal: Return, opening destinations, clipboard, dismissal and opening Command Bar actions work with JavaScript omnibox action handlers disabled.

Base: main HEAD `3c9a2f529af4cad2abba5df4e9df88efd7a49cfc`.

Architecture: `HeroBarModel` already parses and selects native `SolaraOmnibox` suggestions. A shared `OmniboxActionController` decorates model events, checks native workspace ownership on each action and dispatches typed SolaraStore commands. Settings hosts own AppKit menus, clipboard, file selection, extension operations and focus. JS callbacks remain the ownership-off fallback.

## Action ownership map

| Action / surface | Current JavaScript decision | Swift owner |
| --- | --- | --- |
| Return on URL, search, history/bookmark suggestion | `nativeBar.tsx` onOpen → `NativeOmniboxBar.go` / NewTab hero go → `open.ts:openFromBar` | `HeroBarModel.choose/go`, `OmniboxActionController`, Session `omniboxOpen` → navigate |
| Command/Option Return, Shift Return, Option Shift Return | `open.ts:Disposition/openFromBar`; modifier interpretation already in HeroBarModel | Native disposition includes backgroundTab; Session delegates newTab/createWindow |
| Command Shift Return verbatim search, Control Return www completion | Native model emits open to JS | Existing native model semantics with native open owner |
| Switch-to-tab / modified switch | `nativeBar.tsx:onSwitch`, `open.ts:switchFromBar`, `lib/actions.switchToTab` | Session `omniboxSwitch`, host native window focus |
| Sidebar address bar, toolbar/panel address bar | `NativeOmniboxBar.go`, JS cancellation props | Shared decorated NativeOmniboxView model events, closePanel and native focus |
| New Tab hero field | NewTab component `useNativeBar` go | Shared decorated NativeNewTabView events, current placeholder navigate |
| New Tab Command Bar into/group/list target | `newTabBar.ts:openFromNewTabBar` | Session reads native panel.newTab target, delegates navigate/newTabInGroup/newTab |
| Escape, blur/outside dismissal | `NativeOmniboxBar` onDone/onCancel → closePanel | Model retains scope/completion order, controller closes panel and releases native focus |
| Paste, paste-and-go/search, Copy URL | `nativeBar.tsx:contextMenu`, `paste.ts` classifier/URL menu | Native model clipboard choices, AppKit menu owner, native URL control menu |
| Command Bar actions that open tabs/windows/pages/splits | `runBar.ts:runBarAction` → `commands.ts` / organize actions | Native action dispatcher reuses store actions and installed native menu command handlers |
| Add-chip tabs/files, extensions | `nativeBar.tsx:openChip`, `runBarExtension` | Native host menus / file panel / extension owner |

Parsing and ranking already run as Swift `SolaraOmnibox` (the port of packages/core), including resolveInput, search URLs, bangs and paste classification. No JavaScript parser round trip is needed for actions. packages/core remains the reference parity corpus.

## Implementation and checks

- [x] Store actions and Swift cases for current/foreground/background/window, private profiles, cross-window switch and new-tab targets.
- [x] Shared native action controller and model clipboard/modifier tests; ownership-off fallback and stale action tests.
- [x] Host integration for all native fields, AppKit context/chip menus and opening commands; use existing native menu dispatch when installed.
- [x] JS ownership fallback guards and disabling/counter probe; a hidden-instance VM driver covering each action with JS handlers disabled.
- [x] Source review for Swift 6 isolation, allowed local checks, final independent review, fix.patch and result.md.

## Coordination

Read the completed cmds42 and ntph42 job reports and patches without editing their clones. Preserve their canonical store newTab/createWindow/placeholder behavior; keep this patch limited to action routing and call those actions. Commands job owns keyboard/menu command registration; omnibox invokes installed native handlers and never adds competing registrations. New Tab job owns creation/settlement; omnibox only passes targets and navigates. No build, installation, Swift execution, driver execution, app launch, commit or push on the owner's Mac. VM-only commands go in result.md.

Implementation and independent source reviews are complete. VM compilation, Swift/host tests, driver execution and visual checks are pending; exact commands are in result.md. Added app-URL routing and Developer Mode submission during the action audit. Extension options/popups/side panels now have native opening owners; five side-panel host regressions cover native events and lifetime/profile replacement.
