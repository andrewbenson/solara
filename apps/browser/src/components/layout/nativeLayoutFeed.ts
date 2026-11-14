import { publishSettingsTopic, windowNativeLayoutGeneration } from "@solara/settings";
import { useEffect, useRef, useState } from "react";

export class NativeLayoutFeed<T extends object> {
  private entries = new Map<string, { owner: object; generation: number; value?: T }>();

  private publish: (windows: Record<string, T & { generation: number }>) => void;

  constructor(publish: (windows: Record<string, T & { generation: number }>) => void) {
    this.publish = publish;
  }

  begin(windowId: string, owner: object, generation: number) {
    if (generation > 0) this.entries.set(windowId, { owner, generation });
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

export function useNativeLayoutFeed<T extends object>(feed: NativeLayoutFeed<T>, windowId: string, value: T) {
  const owner = useRef({}).current;
  const [generation] = useState(() => windowNativeLayoutGeneration(windowId));
  useEffect(() => {
    feed.begin(windowId, owner, generation);
    return () => feed.end(windowId, owner);
  }, [feed, windowId, owner, generation]);
  useEffect(() => feed.update(windowId, owner, value), [feed, windowId, owner, value]);
}
