import { PSL_SITE_RULES } from "./publicSuffixRules.ts";
import { PSL_TLDS } from "./tlds.ts";

export type PinnedLinkTarget = "peek" | "tab" | "littleSolara";
export type PinnedLinkInput = {
  sourceUrl: string;
  targetUrl: string;
  pinned: boolean;
  topApp: boolean;
  isMainFrame: boolean;
  userGesture: boolean;
  navigationType: "link" | "form" | "redirect" | "script" | "other";
  method: string;
  download: boolean;
  hasOpener: boolean;
  disposition: "current" | "newTab" | "newWindow" | "popup";
  modified: boolean;
  target?: PinnedLinkTarget;
};

let siteRules: { exact: Set<string>; wildcard: Set<string>; exception: Set<string> } | undefined;

function httpUrl(raw: string): URL | null {
  if (!/^https?:\/\//i.test(raw) || /[\u0000-\u0020\u007f]/.test(raw) || /%(?![0-9a-f]{2})/i.test(raw)) return null;
  try {
    const url = new URL(raw);
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname && !url.username && !url.password ? url : null;
  } catch {
    return null;
  }
}

function rulesForSites() {
  if (siteRules) return siteRules;
  const exact = new Set(PSL_TLDS.split(/\s+/).map((rule) => new URL(`https://${rule}`).hostname));
  const wildcard = new Set<string>();
  const exception = new Set<string>();
  for (const rule of PSL_SITE_RULES.trim().split(/\s+/)) {
    const destination = rule.startsWith("!") ? exception : rule.startsWith("*.") ? wildcard : exact;
    const host = new URL(`https://${rule.replace(/^!|^\*\./, "")}`).hostname;
    destination.add(host);
  }
  siteRules = { exact, wildcard, exception };
  return siteRules;
}

export function registrableDomain(raw: string): string | null {
  const url = httpUrl(raw);
  if (!url) return null;
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host.includes(".")) return rulesForSites().exact.has(host) ? null : host;
  if (host.startsWith("[") || /^(\d{1,3}\.){3}\d{1,3}$/.test(host) || host.endsWith(".localhost")) return host;
  const labels = host.split(".");
  if (labels.some((label) => !label)) return null;
  const rules = rulesForSites();
  let suffixLength = 1;
  for (let i = 0; i < labels.length; i++) {
    const suffix = labels.slice(i).join(".");
    if (rules.exception.has(suffix)) return labels.slice(-(labels.length - i)).join(".");
    if (rules.exact.has(suffix)) suffixLength = Math.max(suffixLength, labels.length - i);
    if (i > 0 && rules.wildcard.has(suffix)) suffixLength = Math.max(suffixLength, labels.length - i + 1);
  }
  return labels.length > suffixLength ? labels.slice(-suffixLength - 1).join(".") : null;
}

function redirectParameter(url: URL): string[] | null {
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  const path = url.pathname;
  if ((host === "google.com" || host === "www.google.com") && path === "/url") return ["q", "url"];
  if (host === "slack-redir.net" && path === "/link") return ["url"];
  if (host.endsWith(".safelinks.protection.outlook.com") && path === "/") return ["url"];
  if (["facebook.com", "www.facebook.com", "l.facebook.com", "lm.facebook.com", "m.facebook.com"].includes(host) && path === "/l.php") return ["u"];
  if ((host === "linkedin.com" || host === "www.linkedin.com") && (path === "/redir/redirect" || path === "/safety/go")) return ["url"];
  return null;
}

export function unwrapLinkRedirects(raw: string): string | null {
  let current = raw;
  const seen = new Set<string>();
  for (let depth = 0; depth < 8; depth++) {
    const url = httpUrl(current);
    if (!url || seen.has(url.href)) return null;
    seen.add(url.href);
    const parameters = redirectParameter(url);
    if (!parameters) return current;
    const targets = parameters.flatMap((parameter) => url.searchParams.getAll(parameter)).filter(Boolean);
    if (targets.length !== 1 || !httpUrl(targets[0]!)) return null;
    current = targets[0]!;
  }
  return null;
}

export function resolvePinnedLink(input: PinnedLinkInput): { target: PinnedLinkTarget; url: string } | null {
  if ((!input.pinned && !input.topApp) || !input.isMainFrame || !input.userGesture || input.navigationType !== "link" ||
      input.method.toUpperCase() !== "GET" || input.download || input.modified || input.disposition === "popup") return null;
  const destination = unwrapLinkRedirects(input.targetUrl) ?? (httpUrl(input.targetUrl) ? input.targetUrl : null);
  const sourceSite = registrableDomain(input.sourceUrl);
  const targetSite = destination ? registrableDomain(destination) : null;
  if (!destination || !sourceSite || !targetSite || sourceSite === targetSite) return null;
  return { target: input.target === "tab" || input.target === "littleSolara" ? input.target : "peek", url: input.targetUrl };
}
