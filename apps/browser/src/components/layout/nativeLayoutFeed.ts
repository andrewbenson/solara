import { publishSettingsTopic, windowNativeLayoutGeneration } from "@solara/settings";
import { useEffect, useRef, useState } from "react";

export class NativeLayoutFeed<T extends object> {
  private entries = new Map<string, { owner: object; generation: number; value?: T }>();

  private publish: (windows: Record<string, T & { generation: number }>) => void;

  constructor(publish: (windows: Record<string, T & { generation: number }>) => void) {
    this.publish = publish;
  }

  begin(windowId: string, owner: object, generation: number) {
    if (generation <= 0 || generation < (this.entries.get(windowId)?.generation ?? 0)) return;
    this.entries.set(windowId, { owner, generation });
  }

  update(windowId: string, owner: object, value: T) {
    const entry = this.entries.get(windowId);
    if (!entry || entry.owner !== owner) return;
    entry.value = value;
    this.flush();
  }

  end(windowId: string, owner: object) {
    if (this.entries.get(windowId)?.owner !== owner) return;
    this.entries.delete(windowId);
    this.flush();
  }

  private flush() {
    this.publish(Object.fromEntries([...this.entries].flatMap(([id, entry]) => entry.value ? [[id, { ...entry.value, generation: entry.generation }]] : [])));
  }
}

export function nativeLayoutFeed<T extends object>(topic: string) {
  return new NativeLayoutFeed<T>((windows) => publishSettingsTopic(topic, { windows }));
}

export function useNativeLayoutFeed<T extends object>(feed: NativeLayoutFeed<T>, windowId: string, value: T, key = windowId) {
  const owner = useRef({}).current;
  const [generation] = useState(() => windowNativeLayoutGeneration(windowId));
  useEffect(() => {
    feed.begin(key, owner, generation);
    return () => feed.end(key, owner);
  }, [feed, key, owner, generation]);
  useEffect(() => feed.update(key, owner, value), [feed, key, owner, value]);
}

export type NativePanePresentation<T> = { windowId: string; tabId: string; presentation: T | null };

export function nativePaneWindows<T>(entries: Record<string, NativePanePresentation<T> & { generation: number }>, previous: Record<string, { generation: number; presentations: Record<string, T> }> = {}) {
  const windows: Record<string, { generation: number; presentations: Record<string, T> }> = Object.fromEntries(
    Object.entries(previous).map(([id, entry]) => [id, { generation: entry.generation, presentations: {} }]),
  );
  for (const entry of Object.values(entries)) {
    let window = windows[entry.windowId];
    if (!window || window.generation < entry.generation) windows[entry.windowId] = window = { generation: entry.generation, presentations: {} };
    if (window.generation !== entry.generation || !entry.presentation) continue;
    window.presentations[entry.tabId] = entry.presentation;
  }
  return windows;
}
