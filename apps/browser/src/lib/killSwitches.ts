import { killSwitchEnvironment, readDocument } from "@solara/shell";

type SwitchDef = {
  about: string;
  owner: string;
  removeBy: string;
  live: boolean;
};

export const MAX_SWITCHES = 8;

export const SWITCHES = {
  newTabPrewarm: {
    about: "A New Tab page's engine tab is made a moment after it opens, so Enter only navigates it (lib/preload.ts).",
    owner: "command bar",
    removeBy: "2026-12-15",
    live: true,
  },
  updatePrewarm: {
    about: "An update staged for install-on-quit is run once, hidden, so its first launch skips macOS's first-exec checks (Updater.swift).",
    owner: "updater",
    removeBy: "2026-12-15",
    live: true,
  },
  launchTab: {
    about: "The focused window's page starts loading as the app starts, before its window is up (store/launchTab.ts).",
    owner: "launch",
    removeBy: "2026-12-15",
    live: false,
  },
  focusedWindowFirst: {
    about: "A launch with several windows builds the focused one first and opens the others behind it after (lib/windowOpenOrder.ts).",
    owner: "launch",
    removeBy: "2026-12-15",
    live: false,
  },
  sidebarSlide: {
    about: "Hiding or showing the sidebar or the top tab strip (⌘S) slides it and the card's edge (Arc's motions and toolbar-less card with the address bar in the sidebar); off, they jump (layout/SidebarDock.tsx).",
    owner: "sidebar",
    removeBy: "2026-12-15",
    live: true,
  },
  sidebarSlideLean: {
    about: "The sidebar's slide draws the traffic lights' moves and lays them out once they stop (packages/shell ChromeWindows.swift).",
    owner: "sidebar",
    removeBy: "2026-12-15",
    live: false,
  },
  chromeBatterySaver: {
    about: "Battery Saver is Chrome's own (its battery saver mode: busy background tabs freeze, frame rate and timers are reduced); off, our sampler freezes busy background tabs over CDP (lib/tabLifecycle.ts).",
    owner: "tab lifecycle",
    removeBy: "2026-12-15",
    live: false,
  },
} as const satisfies Record<string, SwitchDef>;

type SwitchName = keyof typeof SWITCHES;

const CACHE_DOC = "switches-cache.json";
const SWITCHES_ENV = "SOLARA_SWITCHES";

type Values = Partial<Record<SwitchName, boolean>>;

const known = (name: string): name is SwitchName => Object.hasOwn(SWITCHES, name);

function parseSwitches(json: string | null | undefined): Values {
  const out: Values = {};
  try {
    const switches = (JSON.parse(json ?? "") as { switches?: Record<string, unknown> } | null)?.switches;
    if (switches && typeof switches === "object")
      for (const [name, value] of Object.entries(switches)) if (known(name) && typeof value === "boolean") out[name] = value;
  } catch {}
  return out;
}

export function parseOverride(text: string | null | undefined): Values {
  const out: Values = {};
  for (const part of (text ?? "").split(",")) {
    const [name, value] = part.split("=").map((s) => s.trim());
    if (!name || !known(name)) continue;
    if (value === "off" || value === "0" || value === "false") out[name] = false;
    else if (value === "on" || value === "1" || value === "true") out[name] = true;
  }
  return out;
}

let override: Values = {};
let cached: Values = {};
let loaded = false;

function load() {
  loaded = true;
  try {
    cached = parseSwitches(readDocument(CACHE_DOC));
    override = parseOverride(killSwitchEnvironment(SWITCHES_ENV));
  } catch {
    cached = {};
    override = {};
  }
}

export function switchOn(name: SwitchName): boolean {
  if (!loaded) load();
  return override[name] ?? cached[name] ?? true;
}

export function reloadSwitches() {
  loaded = false;
  cached = {};
  override = {};
}
