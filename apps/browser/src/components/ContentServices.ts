import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";

export function useContentServices() {
  useEffect(startChromeTabs, []);
}
