import { escapeHtml as escapeHTML } from "../../../scripts/lib/fixture-html.mjs";

export const acceptancePage = (title, body, extra = "") =>
  `<!doctype html><html><head><title>${escapeHTML(title)}</title><link rel="icon" href="/icon.png">${extra}</head><body>${body}</body></html>`;

export const activationPage = (title, body, script = "") =>
  `<!doctype html><html><head><title>${escapeHTML(title)}</title><link rel="icon" href="data:,"></head><body style="font: 20px sans-serif">${body}<script>${script}</script></body></html>`;

export const acceptancePathPage = (pathname) => acceptancePage(pathname, escapeHTML(pathname));

export const activationPathPage = (url) => activationPage(url.searchParams.get("t") ?? url.pathname.slice(1), escapeHTML(url.pathname));

const FRAME_LISTENER = `<script>window.__frame = null; addEventListener("message", (e) => (window.__frame = e.data));</script>`;

export function frameHostResponse(url, origins) {
  const src = url.searchParams.get("src");
  try {
    const target = new URL(src);
    if (!["http:", "https:"].includes(target.protocol) || !origins.includes(target.origin) || target.username || target.password)
      return { status: 400, html: "Invalid fixture frame source" };
  } catch {
    return { status: 400, html: "Invalid fixture frame source" };
  }
  return {
    status: 200,
    html: acceptancePage("Frame host", `<iframe src="${escapeHTML(src)}"></iframe>`, FRAME_LISTENER),
  };
}

export function solidPage(url) {
  const color = url.searchParams.get("c") ?? "808080";
  const safeColor = color.length === 6 && /^[0-9a-fA-F]{6}$/.test(color) ? color : "808080";
  return acceptancePage(url.searchParams.get("t") ?? "Solid", "", `<style>html, body { margin: 0; height: 100%; background: #${safeColor} }</style>`);
}

export const capturerPage = (url) =>
  acceptancePage(url.searchParams.get("t") ?? "Capturer", "capturer", `<script>
      window.__cap = "idle";
      window.share = () => { window.__cap = "pending"; navigator.mediaDevices.getDisplayMedia({ video: true }).then((s) => { window.__stream = s; window.__cap = "live"; }, (e) => (window.__cap = e.name)); return true; };
      window.pixel = async () => {
        const bitmap = await new ImageCapture(window.__stream.getVideoTracks()[0]).grabFrame();
        const c = new OffscreenCanvas(bitmap.width, bitmap.height), g = c.getContext("2d");
        g.drawImage(bitmap, 0, 0);
        return Array.from(g.getImageData(bitmap.width >> 1, bitmap.height >> 1, 1, 1).data.slice(0, 3));
      };
    </script>`);

export function adFirstPage(url) {
  const tag = [...url.searchParams].map(([key, value]) => {
    const query = new URLSearchParams([[key, value]]).toString();
    return value ? query : query.slice(0, -1);
  }).join("&");
  return acceptancePage("Ad first", "ads", `<script src="http://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?${escapeHTML(tag)}"></script>
      <script src="http://securepubads.g.doubleclick.net/tag/js/gpt.js?${escapeHTML(tag)}"></script><img src="http://ib.adnxs.com/ut/v3?${escapeHTML(tag)}">`);
}
