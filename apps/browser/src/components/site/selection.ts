import { replacePageField } from "@solara/settings";

type ReplaceResult = { field: boolean; count: number };

export async function replaceInField(tabId: string, query: string, replacement: string, all: boolean): Promise<ReplaceResult> {
  return replacePageField(tabId, query, replacement, all);
}

if (__DEV__) (globalThis as { acSelection?: unknown }).acSelection = { replaceInField };
