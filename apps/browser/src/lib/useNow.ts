import { useEffect, useState } from "react";
import { everySlowly } from "./slowTimers";

export function useNow(intervalMs = 15_000, enabled = true): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!enabled) return;
    setNow(Date.now());
    return everySlowly({ every: intervalMs, run: () => setNow(Date.now()) });
  }, [intervalMs, enabled]);
  return now;
}
