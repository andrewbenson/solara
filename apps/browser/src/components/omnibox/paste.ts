import { classifyPaste, searchUrl, type PasteAction } from "@solara/core";
import type { MenuItem } from "@solara/shell";
import { NativeModules } from "react-native";
import { useBrowser } from "../../store/browser";
import { defaultSearchEngine } from "../../store/settings";

const NativeClipboard = NativeModules.Clipboard as { getString(): Promise<string> } | undefined;

export const readClipboard = (): Promise<string> => NativeClipboard?.getString().catch(() => "") ?? Promise.resolve("");

export async function clipboardPasteAction(): Promise<PasteAction | null> {
  return classifyPaste(await readClipboard());
}

export function pasteMenuItem(action: PasteAction | null): MenuItem[] {
  if (!action) return [];
  return [{ id: "pasteAndGo", title: action.kind === "go" ? "Paste and Go" : "Paste and Search", symbol: action.kind === "go" ? "arrow.right.circle" : "magnifyingglass" }];
}

export function pasteTarget(action: PasteAction): string {
  return action.kind === "go" ? action.url : searchUrl(defaultSearchEngine(useBrowser.getState().settings), action.query);
}
