import { useEffect } from "react";
import { startChromeTabs } from "../lib/chromeTabs";
import { startDeviceChoosers } from "./site/DeviceChooser";


export function useContentServices() {
  useEffect(startChromeTabs, []);
  useEffect(startDeviceChoosers, []);
}
