import { HoverSlot } from "../components/HoverSlot";

const tracked = new WeakSet<object>();

export function markHoverProps<T extends { onMouseEnter: () => void; onMouseLeave: () => void }>(props: T): T {
  if (__DEV__) tracked.add(props.onMouseEnter);
  return props;
}

type Fiber = {
  type: unknown;
  child: Fiber | null;
  sibling: Fiber | null;
  return: Fiber | null;
  stateNode: unknown;
  memoizedProps: Record<string, unknown> | null;
};
type Host = { measureInWindow(cb: (x: number, y: number, w: number, h: number) => void): void };
type Frame = [number, number, number, number];
export type Shift = { scope: string; hovered: string; view: string; before: Frame; after: Frame };
type Change = { fiber: Fiber; before: Frame; after: Frame };

const nameOf = (f: Fiber): string => {
  const t = f.type as { displayName?: string; name?: string; render?: { name?: string }; type?: { name?: string } } | string | null;
  if (!t) return "";
  if (typeof t === "string") return t;
  return t.displayName || t.name || t.render?.name || t.type?.name || "";
};
const isHost = (f: Fiber) => typeof (f.stateNode as Host | null)?.measureInWindow === "function" && typeof f.type === "string";

function* fibers(root: Fiber, skip?: (f: Fiber) => boolean): Generator<Fiber> {
  const stack = [root];
  while (stack.length) {
    const f = stack.pop()!;
    yield f;
    if (skip?.(f)) continue;
    const kids: Fiber[] = [];
    for (let c = f.child; c; c = c.sibling) kids.push(c);
    for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]!);
  }
}

function roots(): Fiber[] {
  const hook = (globalThis as { __REACT_DEVTOOLS_GLOBAL_HOOK__?: { renderers: Map<number, unknown>; getFiberRoots(id: number): Set<{ current: Fiber }> } })
    .__REACT_DEVTOOLS_GLOBAL_HOOK__;
  if (!hook) throw new Error("no React DevTools hook (a Debug build has one)");
  return [...hook.renderers.keys()].flatMap((id) => [...hook.getFiberRoots(id)].map((r) => r.current));
}

function label(f: Fiber): string {
  const names: string[] = [];
  for (let x: Fiber | null = f; x && names.length < 4; x = x.return) {
    const n = nameOf(x);
    if (n && typeof x.type !== "string" && !n.startsWith("Animated") && n !== "View" && n !== "Pressable") names.push(n);
  }
  return `${names.reverse().join(" › ")} (${nameOf(f)})`;
}

function around(f: Fiber): Map<Host, Fiber> {
  let parent = f.return;
  while (parent && !isHost(parent)) parent = parent.return;
  const out = new Map<Host, Fiber>();
  if (!parent) return out;
  for (const x of fibers(parent, (x) => isHost(x) && x.return?.type === HoverSlot)) if (isHost(x)) out.set(x.stateNode as Host, x);
  return out;
}

const measure = (h: Host) =>
  new Promise<Frame | null>((resolve) => {
    const timer = setTimeout(() => resolve(null), 500);
    h.measureInWindow((x, y, w, hgt) => {
      clearTimeout(timer);
      resolve([x, y, w, hgt]);
    });
  });
const frames = (n: number) => new Promise<void>((resolve) => {
  const step = () => (n-- <= 0 ? resolve() : requestAnimationFrame(step));
  step();
});
const same = (a: number, b: number) => Math.abs(a - b) <= 0.01;
const moved = (a: Frame, b: Frame) => a.some((v, i) => !same(v, b[i]!));
const measureAll = (hosts: Host[]) => Promise.all(hosts.map(measure));
const anyMoved = (a: (Frame | null)[], b: (Frame | null)[]) => a.some((was, i) => !!was && !!b[i] && moved(was, b[i]!));

async function heldStill(hosts: Host[], maxFrames = 60): Promise<(Frame | null)[]> {
  let last = await measureAll(hosts);
  for (let waited = 0; waited < maxFrames; waited += 2) {
    await frames(2);
    const now = await measureAll(hosts);
    if (!anyMoved(last, now)) return now;
    last = now;
  }
  return last;
}

function ownerName(f: Fiber): string {
  for (let x = f.return; x; x = x.return) {
    const n = nameOf(x);
    if (n && typeof x.type !== "string" && !n.startsWith("Animated") && n !== "View") return n;
  }
  return "";
}
const isTitle = (f: Fiber) => typeof f.type === "string" && f.type.endsWith("SolaraFadeLabel");
const isHoverSlot = (f: Fiber) => ownerName(f) === "HoverSlot";
const trailingShrinks = ([x, y, w, h]: Frame, [x2, y2, w2, h2]: Frame) => same(x, x2) && same(y, y2) && same(h, h2) && w2 < w;
const leadingGrows = ([x, y, w, h]: Frame, [x2, y2, w2, h2]: Frame) => same(x + w, x2 + w2) && same(y, y2) && same(h, h2) && w2 > w;

function unintended(changes: Change[]): Change[] {
  const titles = changes.filter((c) => isTitle(c.fiber) && trailingShrinks(c.before, c.after));
  const slots = changes.filter((c) => isHoverSlot(c.fiber) && leadingGrows(c.before, c.after));
  const shrunk = titles.reduce((sum, c) => sum + c.before[2] - c.after[2], 0);
  const grown = slots.reduce((sum, c) => sum + c.after[2] - c.before[2], 0);
  const madeRoom = titles.length > 0 && Math.abs(shrunk - grown) <= 0.5;
  return changes.filter((c) => {
    if (madeRoom && (titles.includes(c) || slots.includes(c))) return false;
    return true;
  });
}

export async function check({ scopes, settleFrames = 3 }: { scopes?: string[]; settleFrames?: number } = {}): Promise<{ hovered: number; shifts: Shift[] }> {
  const targets: { scope: string; fiber: Fiber }[] = [];
  for (const root of roots()) {
    const scopeRoots = scopes ? [...fibers(root)].filter((f) => scopes.includes(nameOf(f))) : [root];
    for (const scope of scopeRoots) {
      for (const f of fibers(scope)) {
        const enter = f.memoizedProps?.onMouseEnter;
        if (isHost(f) && typeof enter === "function" && tracked.has(enter)) targets.push({ scope: nameOf(scope) || "root", fiber: f });
      }
    }
  }
  const shifts: Shift[] = [];
  for (const { scope, fiber } of targets) {
    const props = fiber.memoizedProps as { onMouseEnter?: () => void; onMouseLeave?: () => void } | null;
    if (!props?.onMouseEnter || !props.onMouseLeave) continue;
    const views = [...around(fiber)];
    const before = await heldStill(views.map(([h]) => h));
    props.onMouseEnter();
    await frames(settleFrames);
    const after = await measureAll(views.map(([h]) => h));
    const changes: Change[] = [];
    views.forEach(([, f], i) => {
      const was = before[i];
      const now = after[i];
      if (was && now && moved(was, now)) changes.push({ fiber: f, before: was, after: now });
    });
    for (const c of unintended(changes)) shifts.push({ scope, hovered: label(fiber), view: label(c.fiber), before: c.before, after: c.after });
    props.onMouseLeave();
    await frames(settleFrames);
  }
  return { hovered: targets.length, shifts };
}
