export type BackFacts = {
  newTabShown: boolean;
  canGoBack: boolean;
  engineBack: boolean;
  backToNewTab: boolean;
  historyKnown: boolean;
  opener: string | undefined;
};

export type BackAction = "none" | "page" | "opener";

export function backAction(f: BackFacts): BackAction {
  if (f.newTabShown) return "none";
  if (f.canGoBack || f.engineBack || f.backToNewTab) return "page";
  return f.opener && f.historyKnown ? "opener" : "none";
}

export function reportsKnownHistory(url: string, isLoading: boolean): boolean {
  return !isLoading && !!url && url !== "about:blank";
}

export const knownHistoryFor = (opener: string | undefined) => (page: { historyKnown: boolean }): boolean => !!opener && page.historyKnown;
