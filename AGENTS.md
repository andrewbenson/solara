# AGENTS.md

Solara is a macOS browser by Andrew Benson: Arc's sidebar and Dia's polish on Chrome's own framework, built from
source (Chromium 156 with Helium's patches and ours), with no account, no AI features and no telemetry. This repo is
`andrewbenson/solara`; NOTICE credits the code it began from.

`CLAUDE.md` is a symlink to this file: edit this one. It holds the rules every session needs and points to the docs
that hold the detail. The architecture, the isolated build and test tooling, and how to drive a running instance are
in [docs/agent-brief.md](docs/agent-brief.md): read it before your first change.

## Where things are

| Path | Holds |
| --- | --- |
| `apps/browser` | The app: Expo SDK 54 + react-native-macos 0.81, zustand store (`src/store`), UI (`src/components`), Xcode project (`macos/`) |
| `packages/solaracore` | SolaraCore, the engine as the app sees it: Chrome's framework linked in, its Expo modules and JS API |
| `packages/shell` | Menus, shortcuts, windows, native views |
| `packages/core` | Omnibox parsing and suggestions, pure TypeScript with tests |
| `packages/{import,sync,shaders}` | Importing from other browsers, iCloud sync, Metal views |
| `engine/` | Our Chromium patch series (`engine/patches`), our Chrome-side code (`engine/chromium`, the `ac_*` C calls) and SolaraCore's window and tab layer (`engine/solaracore`) |
| `apps/cli` | The `solara` command-line tool (Python), shipped in each release |
| `scripts/` | `release.sh`, the DMG layout, and `scripts/agent/*`, the tools for parallel agents (each takes `--help`) |
| `.claude/skills/release` | The release skill and its smoke, update and publish scripts |

## Commands

| Task | Command |
| --- | --- |
| Install | `scripts/agent/locked pod -- pnpm install --frozen-lockfile` |
| Pods | `scripts/agent/locked pod -- pnpm pods` |
| Metro | already running on :8081 for every instance; never start a second one |
| Build the app | `scripts/agent/build-app --as <you>` (in the background; `--config Release`, `--force`) |
| Launch it hidden | `scripts/agent/ac launch <app> --data <scratch>/data`; `ac eval`, `ac page`, `ac quit` take that data dir |
| Typecheck / unit tests | `pnpm typecheck` / `pnpm test` (one package: `pnpm -C apps/browser test`) |
| End-to-end checks | one script per area, listed in [docs/testing.md](docs/testing.md) |
| Engine build | `scripts/agent/engine-build --as <you>` (incremental, under the chromium lock) |
| Engine patch series | `python3 engine/patches/series.py check` |

## Hard rules

- **The Chromium build cache is sacred.** Never touch `~/chromium-build/chromium_git/chromium/src/out`, and never run
  `gclient sync` or `gn clean`: a full rebuild costs about 5 hours. Engine builds are incremental only, holding the
  chromium lock ([docs/engine-build.md](docs/engine-build.md)). When freeing disk space, stay out of
  `~/chromium-build`.
- **Safe Storage stays as it is.** `chromium-safe-storage-name.patch` and `chromium-safe-storage-no-silent-reset.patch`
  decide which keychain item holds the key to every saved password and cookie, and that it is never silently
  replaced. Keep both unchanged through every re-sync and version bump, and don't change when the key may be created
  (`ac_safe_storage.mm`) without the owner ([docs/engine-build.md](docs/engine-build.md) › The patch series).
- **Never launch or touch other browsers' installed apps or the owner's own Solara install** (`/Applications/Solara.app`),
  or the preview builds in `apps/browser/build-vista`.
- **Never steal focus.** Launch builds only hidden: `scripts/agent/ac launch`, or
  `open -g -n --env SOLARA_BACKGROUND=1 --env SOLARA_DATA_DIR=<scratch> --env SOLARA_REMOTE_DEBUGGING_PORT=<port> <app>`.
  Never plain `open`, never `activate`. Test data lives in a scratch dir, never in `~/Documents`. Never give an
  extension shortcut Global scope in a test instance.
- **No comments in code.** None in source, scripts or config (`//`, `/* */`, `#`, `<!-- -->`, doc comments). Name
  things so the code says what it does and put the why in the commit message. Only what a tool reads stays:
  shebangs, license headers, compiler, linter and type directives, and the header a script prints as its `--help`.
- **One checkout, shared.** No git worktrees. Never `git checkout`, `git restore`, `git stash`, `git reset --hard` or
  `git clean` here: they wipe other agents' uncommitted work (`scripts/agent/guard-git` blocks them). Undo your own
  hunks by editing.
- **Commit straight to `main`, only your own hunks.** Stage explicit paths or `git add -p`, commit with
  `git commit --only -- <paths>` (the index is shared), and check `git diff --cached` first. Never
  `git apply --unidiff-zero`. No `Co-Authored-By` lines.
- **Dia is a read-only reference.** Screenshots and its app bundle are fine; never click or type in it, and never read
  its user data or any browser's real profile. Build fixtures instead.
- **No AI features.** The owner's decision. Dia's AI rows in `docs/dia-feature-parity.md` stay ⏸.
- **Never wait open-ended.** Every wait has a deadline under 10 minutes and fails fast when what it waits on dies:
  `scripts/agent/await --pid <pid> -- <test>`. Run builds with `run_in_background`. Wrap screen captures in
  `timeout 20` (they hang while the screen is locked).
- **`.claude/settings.local.json` is never committed.**

## How work gets done

- **Move fast.** No phases, no questions about details you can decide; ask only when the answer changes what you
  build. Run independent work in parallel (agents, builds, instances, tool calls); only timing measurements run one
  at a time, interleaved with their control.
- **Orchestrate.** The main session plans, hands implementation to subagents, and verifies what they return. Each agent
  gets its own files, its own build dir (`--as <name>`) and its own `SOLARA_DATA_DIR`. The main session checks on any
  agent it hasn't heard from in about 30 minutes; a stuck agent means a root cause to fix (a lock, a wait, a hang).
  New feedback goes to the agent that owns the area (SendMessage).
- **Second opinion.** Risky logic (races, lifetimes, security, migrations, sync) gets an independent model review
  before and after the change. Reproduce each finding before fixing it.
- **Verify in proportion.** Typecheck, build, and exercise the change in a hidden instance. A JS-only change needs no
  app build (Metro reloads it; relaunch before judging). Run the checks for what you changed once before and once
  after, then the nearby ones; the full suite is for engine, native lifetime, focus, quit and security changes. When
  the screen is locked, use the in-process snapshots ([docs/agent-brief.md](docs/agent-brief.md)) and list what still
  needs a visual check.
- **Errors get fixed without asking.** When `crash.log` shows up in the repo root or a crash report appears, check its
  binary UUID against the current build, find the cause and fix it; delete `crash.log` once handled.
- **Clean up.** Quit your instances (`ac quit`, never `pkill`), stop what you started, never kill what you didn't.
- **Reports** are short and plain: what shipped, what's left, what needs the owner.

## Building features

- **New UI is native.** Build every new surface, control and behaviour in Swift (SolaraKit, packages/shell,
  SolaraCore), never in React Native: React Native is on its way out (docs/roadmap.md, 0.4.0 to 1.0.0). A change to
  an existing React Native surface is fine when it's small; when it's large, port the surface first.
- **Sources of truth.** [docs/dia-feature-parity.md](docs/dia-feature-parity.md) is the checklist: update its row
  when you ship. [docs/dia-spec.md](docs/dia-spec.md) has Dia's measured values. [docs/roadmap.md](docs/roadmap.md)
  says what ships in which version: update an item's status when it lands.
- **Match Dia with numbers**, against a capture with the same crop and state. When the owner asks for Arc's layout,
  keep Dia's styling unless told otherwise.
- **Parity means UX too:** what each click does, what it remembers, animation timing in frames, what keeps running.
  Dismissing something never pauses playback or drags you to another tab; going back to the source ends a temporary
  view; nothing reopens right after you close it.
- **Owner recordings:** copy them out of their temp folder at once (glob the name: it has a narrow no-break space),
  extract 30 fps frames with ffmpeg and measure from the pixels. A size in a recording may be a saved preference.

## Shipping

- Releases use the `release` skill ([.claude/skills/release/SKILL.md](.claude/skills/release/SKILL.md)); the machinery
  is in [docs/releasing.md](docs/releasing.md). Two channels in one app: **nightly** (a GitHub prerelease, focused
  checks only) and **stable** (smoke, update test, perf ratchet and perf gate against the previous stable).
- Solara releases from this Mac to `andrewbenson/solara`'s GitHub releases; Sparkle reads the appcast there. It has no
  site, no Homebrew tap and no telemetry. The owner has authorized releases to go all the way through.
- No announcement or tweet drafts. Any other public action (posting anywhere, a PR or issue in another project)
  needs the owner's OK.

## Read when

| Before you | Read |
| --- | --- |
| change anything, the first time | [docs/agent-brief.md](docs/agent-brief.md) |
| touch app state | [docs/store-api.md](docs/store-api.md) |
| change or build the engine | [docs/engine-build.md](docs/engine-build.md), [docs/solaracore-parity.md](docs/solaracore-parity.md) |
| claim a change works | [docs/testing.md](docs/testing.md) |
| touch timing-sensitive code or a release's perf | [docs/perf/README.md](docs/perf/README.md) |
| touch sync or import | [docs/sync.md](docs/sync.md), [packages/import/README.md](packages/import/README.md) |
| work on the omnibox | [docs/omnibox-ux.md](docs/omnibox-ux.md) |
| touch the CLI | [docs/cli.md](docs/cli.md) |
| write release notes | [docs/release-notes/README.md](docs/release-notes/README.md) |
| change a dependency patch | [docs/agent-brief.md](docs/agent-brief.md) › Stack (`patches/`) |
