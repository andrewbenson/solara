import { useState } from "react";
import { NativePage } from "@solara/settings";

export function NativeCard({ state, onEvent }: { state: string; onEvent: (e: { kind: string } & Record<string, unknown>) => void }) {
  const [height, setHeight] = useState(1);
  return (
    <NativePage
      kind={(JSON.parse(state) as { card: "calendarPreview" | "meetingAlert" }).card}
      state={state}
      style={{ height }}
      onPageEvent={(e) => {
        const ev = e.nativeEvent;
        if (ev.kind === "height") setHeight(Math.max(1, Math.ceil(Number(ev.height))));
        else onEvent(ev);
      }}
    />
  );
}

