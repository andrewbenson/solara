export const KEEP_AWAKE_DETAIL = "keepAwake:";
export const SLEEP_AFTER_CHOICES = [15, 30, 60, 120, 240];

export type KeepAwakeCover = { kind: "none" } | { kind: "exact"; site: string } | { kind: "parent"; site: string };

export function normalizeSite(input: string): string | null {
  let text = input.normalize("NFC").trim().toLowerCase();
  const scheme = text.indexOf("://");
  if (scheme >= 0) text = text.slice(scheme + 3);
  if (text.startsWith("[*.]")) text = text.slice(4);
  if (text.startsWith("*.")) text = text.slice(2);
  const end = text.search(/[/?#]/);
  if (end >= 0) text = text.slice(0, end);
  const at = text.lastIndexOf("@");
  if (at >= 0) text = text.slice(at + 1);
  if (text.startsWith("[")) {
    const close = text.indexOf("]");
    if (close < 0) return null;
    text = text.slice(0, close + 1);
    return text.length > 2 && /^[0-9a-f:.]+$/.test(text.slice(1, -1)) ? text : null;
  }
  if ((text.match(/:/g) ?? []).length > 1) return /^[0-9a-f:.]+$/.test(text) ? `[${text}]` : null;
  const colon = text.lastIndexOf(":");
  if (colon >= 0) text = text.slice(0, colon);
  text = text.replace(/^\.+/, "").replace(/\.+$/, "");
  return text && /^[\p{L}\p{M}\p{N}._-]+$/u.test(text) ? text : null;
}

export function keepAwakeCover(sites: readonly string[], host: string): KeepAwakeCover {
  const h = normalizeSite(host);
  if (!h) return { kind: "none" };
  if (sites.includes(h)) return { kind: "exact", site: h };
  const parent = sites.filter((site) => h.endsWith(`.${site}`)).sort((a, b) => b.length - a.length)[0];
  return parent ? { kind: "parent", site: parent } : { kind: "none" };
}

export function siteHost(url: string | undefined): string {
  if (!url) return "";
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

export function sleepAfterMinutes(value: number | undefined): number {
  return value !== undefined && SLEEP_AFTER_CHOICES.includes(value) ? value : 30;
}
