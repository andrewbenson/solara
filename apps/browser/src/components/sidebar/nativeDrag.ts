import { hapticTick, onAppEvent, setDragEscapeCapture } from "@solara/shell";
import { requireOptionalNativeModule } from "expo-modules-core";
import type { TabPlacement } from "../../store/organize";
import { addNativeSettingsHandlers } from "../settings/nativeSettings";
import "../layout/nativeTabDrag";
import { arrangeLive } from "./pinnedOrder";
import { closeFolderPanel } from "./tileFolderUi";

type Frame = { x: number; y: number; w: number; h: number };
type ProbeItem = Frame & {
  key: string;
  kind: string;
  section: string;
  tabIds: string[];
  parentGroup: string | null;
  groupId: string | null;
  folderId: string | null;
};
type Probe = {
  active: boolean;
  external: number;
  gapKey: string | null;
  pitch: number;
  marks: NativeMarks;
  items: ProbeItem[];
  regions: Record<string, Frame>;
  landed: { key: string; x: number; y: number } | null;
  viewport: Frame | null;
  scrollY: number;
};
type NativeMarks = {
  sources: string[];
  folderAway: boolean;
  folderTarget: string | null;
  pins: boolean;
  pinCount: number;
  dropInto: string | null;
};

type DragModule = {
  escape(): Promise<void>;
  external(windowId: string, phase: string, x: number, y: number, count: number): Promise<string | null>;
  startProbe(windowId: string): Promise<string>;
  probe(windowId: string): string;
  clearLanded(windowId: string): Promise<void>;
  scrollTo(windowId: string, y: number): Promise<void>;
};

const native = requireOptionalNativeModule<DragModule>("SolaraSidebarDrag");

addNativeSettingsHandlers({
  "sidebar.drag.live": (sequence: string[]) => arrangeLive(sequence),
  "sidebar.drag.escape": (on: boolean) => setDragEscapeCapture(on),
  "sidebar.drag.haptic": () => hapticTick(),
  "sidebar.drag.closePanel": () => closeFolderPanel(),
});

if (native) onAppEvent((e) => e.type === "dragEscape" && void native.escape());

export const nativeSidebarDrag = {
  external(windowId: string, phase: "enter" | "move" | "leave" | "drop", [x, y]: [number, number], count = 0): Promise<TabPlacement | null> {
    if (!native) return Promise.resolve(null);
    return native.external(windowId, phase, x, y, count).then((text) => (text ? (JSON.parse(text) as TabPlacement) : null));
  },
};

type ViewLike = {
  measureInWindow(cb: (x: number, y: number, w: number, h: number) => void): void;
};

export function installNativeDragProbe(windowId: string) {
  if (!__DEV__ || !native) return;
  void native.startProbe(windowId);
  const read = (): Probe | null => {
    let probe: Probe | null = null;
    try {
      probe = JSON.parse(native.probe(windowId)) as Probe | null;
    } catch {
      probe = null;
    }
    if (!probe) void native.startProbe(windowId);
    return probe;
  };
  const view = (pick: (p: Probe) => Frame | undefined): ViewLike => ({
    measureInWindow(cb) {
      void native.startProbe(windowId).then((text) => {
        const p = JSON.parse(text) as Probe | null;
        const f = p && pick(p);
        cb(f?.x ?? 0, f?.y ?? 0, f?.w ?? 0, f?.h ?? 0);
      });
    },
  });
  const probe = {
    get items() {
      const p = read();
      const out = new Map<string, unknown>();
      for (const i of p?.items ?? []) {
        out.set(i.key, {
          ...i,
          view: view((q) => q.items.find((x) => x.key === i.key)),
        });
      }
      return out;
    },
    get regions() {
      const p = read();
      const out = new Map<string, unknown>();
      for (const name of Object.keys(p?.regions ?? {}))
        out.set(
          name,
          view((q) => q.regions[name]),
        );
      return out;
    },
    get marks() {
      const p = read();
      return {
        getState: () => ({
          ...(p?.marks ?? {}),
          sources: new Set(p?.marks.sources ?? []),
        }),
      };
    },
    scroll: {
      scrollTo: ({ y }: { y: number }) => void native.scrollTo(windowId, y),
      measureInWindow: view((q) => q.viewport ?? undefined).measureInWindow,
    },
    get scrollY() {
      return read()?.scrollY ?? 0;
    },
    get active() {
      return !!read()?.active;
    },
    get external() {
      return read()?.external ?? 0;
    },
    get gapKey() {
      return read()?.gapKey ?? null;
    },
    get pitch() {
      return read()?.pitch ?? 0;
    },
    get landed() {
      return read()?.landed ?? null;
    },
    set landed(value: unknown) {
      if (value === null) void native.clearLanded(windowId);
    },
  };
  const dev = globalThis as { sidebarDrag?: unknown; sidebarDrags?: Record<string, unknown> };
  dev.sidebarDrag = probe;
  (dev.sidebarDrags ??= {})[windowId] = probe;
  return () => {
    if (dev.sidebarDrags?.[windowId] === probe) delete dev.sidebarDrags[windowId];
    if (dev.sidebarDrag === probe) dev.sidebarDrag = Object.values(dev.sidebarDrags ?? {}).at(-1);
  };
}
