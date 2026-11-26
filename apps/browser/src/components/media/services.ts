import { startCast } from "./cast";
import { startTabShareCleanup } from "./ShareBar";
import { cancelDisplayMediaOnNavigation } from "./SharePicker";

let started = false;

export function startMedia() {
  if (started) return;
  started = true;
  cancelDisplayMediaOnNavigation();
  startTabShareCleanup();
  startCast();
}
