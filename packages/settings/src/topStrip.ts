import { requireOptionalNativeModule } from "expo-modules-core";

type TopStripModule = {
  incoming(windowId: string, x: number | null, y: number | null): Promise<string>;
  endIncoming(windowId: string): Promise<void>;
  peekShow(windowId: string): Promise<void>;
  peekHide(windowId: string): Promise<void>;
  peekState(windowId: string): Promise<string>;
  pinPeek(windowId: string, value: number): Promise<void>;
  tracePeek(windowId: string): Promise<void>;
  peekTrace(windowId: string): Promise<number[][]>;
};

const native = requireOptionalNativeModule<TopStripModule>("SolaraTopStrip");

export async function topStripIncoming(windowId: string, point: [number, number] | null): Promise<string | null | undefined> {
  if (!native?.incoming) return undefined;
  const found = JSON.parse(await native.incoming(windowId, point?.[0] ?? null, point?.[1] ?? null)) as { beforeId: string | null } | null;
  return found ? found.beforeId : undefined;
}

export function endTopStripIncoming(windowId: string) {
  return native?.endIncoming?.(windowId) ?? Promise.resolve();
}

export type TopStripPeekState = { live: boolean; slide: number; watching: boolean; panel: number[] | null; downloads: number[] | null; pageWidth: number };

export function topStripPeek(windowId: string) {
  return {
    show: () => native?.peekShow?.(windowId) ?? Promise.resolve(),
    hide: () => native?.peekHide?.(windowId) ?? Promise.resolve(),
    pin: (value: number) => native?.pinPeek?.(windowId, value) ?? Promise.resolve(),
    trace: () => native?.tracePeek?.(windowId) ?? Promise.resolve(),
    samples: () => native?.peekTrace?.(windowId) ?? Promise.resolve([]),
    state: async (): Promise<TopStripPeekState | null> => (native?.peekState ? (JSON.parse(await native.peekState(windowId)) as TopStripPeekState | null) : null),
  };
}
