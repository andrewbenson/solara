import assert from "node:assert/strict";
import { createServer } from "node:http";
import { connect } from "node:net";
import { test } from "node:test";
import { developerPage, fixturePage, historyPage, loadingPageHtml, modalPage, placementPage, poolPage, rekeyPage, searchPage, shortcutPage } from "./fixture-html.mjs";

const fixtures = [
  { alert: 109, render: (url) => fixturePage(url.slice(1)), url: "/a", html: "<!doctype html><title>A</title><link rel=\"icon\" href=\"data:,\"><body>a</body>" },
  { alert: 110, render: developerPage, url: "/some/path?x=1", html: "<!doctype html><title>dev</title><body style=\"margin:0;background:#3a6ea5;color:white\">/some/path?x=1</body>" },
  { alert: 111, render: (url) => loadingPageHtml(url.slice(1)), url: "/HiddenLoad", html: "<!doctype html><title>HiddenLoad</title><p>HiddenLoad-findme</p>" },
  { alert: 112, render: (url) => fixturePage(url.slice(1)), url: "/one", html: "<!doctype html><title>ONE</title><link rel=\"icon\" href=\"data:,\"><body>one</body>" },
  { alert: 113, render: (url) => fixturePage(url.slice(1) || "root"), url: "/a", html: "<!doctype html><title>A</title><link rel=\"icon\" href=\"data:,\"><body>a</body>" },
  { alert: 114, render: (url) => fixturePage(url.slice(1), { bodyStyle: "height:2000px" }), url: "/one", html: "<!doctype html><title>ONE</title><link rel=\"icon\" href=\"data:,\"><body style=\"height:2000px\">one</body>" },
  { alert: 115, render: (url) => fixturePage(url.slice(1) || "root"), url: "/b", html: "<!doctype html><title>B</title><link rel=\"icon\" href=\"data:,\"><body>b</body>" },
  { alert: 116, render: (url) => fixturePage(url.slice(1)), url: "/one", html: "<!doctype html><title>ONE</title><link rel=\"icon\" href=\"data:,\"><body>one</body>" },
  { alert: 117, render: (url) => fixturePage(url.slice(1)), url: "/one", html: "<!doctype html><title>ONE</title><link rel=\"icon\" href=\"data:,\"><body>one</body>" },
  { alert: 118, render: (url) => placementPage(url.slice(1)), url: "/pa", html: "<!doctype html><title>PA</title><link rel=\"icon\" href=\"data:,\"><body style=\"margin:0;height:4000px;font:16px sans-serif;caret-color:transparent;background:#fff\">\n<p style=\"position:absolute;left:300px;top:300px;margin:0\">some <span id=\"mid\">selectable</span> words</p></body>" },
  { alert: 120, render: (url) => poolPage(url.split("?")[0].slice(1), '<img src="/slow.png?123">'), url: "/slow", html: "<!doctype html><title>SLOW</title><link rel=\"icon\" href=\"/icon.png\"><body style=\"height:2000px;font:16px sans-serif\">\n<p>a needle and another needle</p><img src=\"/slow.png?123\"></body>" },
  { alert: 121, render: historyPage, url: "/history/a", html: "<!doctype html><title>/history/a</title><h1>/history/a</h1>" },
  { alert: 122, render: searchPage, url: "/search?q=selectable", html: "<!doctype html><title>RESULTS</title><link rel=\"icon\" href=\"data:,\"><body>/search?q=selectable</body>" },
  { alert: 123, render: modalPage, url: "/a", html: "<!doctype html><title>/a</title><link rel=\"icon\" href=\"data:,\"><body><button>Inside the page</button></body>" },
  { alert: 124, render: (url) => rekeyPage(url.split("?")[0].slice(1) || "index.html"), url: "/personal.html", html: "<!doctype html><title>Rekey personal.html</title><h1>personal.html</h1><form><input name=\"username\" autocomplete=\"username\"><input type=\"password\" autocomplete=\"current-password\"></form>" },
  { alert: 125, render: (url) => fixturePage(url.slice(1) || "a", { bodyPrefix: '<input id="field">' }), url: "/a", html: "<!doctype html><title>A</title><link rel=\"icon\" href=\"data:,\"><body><input id=\"field\">a</body>" },
  { alert: 126, render: (url) => fixturePage(url.slice(1) || "root", { bodyStyle: "font:40px sans-serif" }), url: "/p1", html: "<!doctype html><title>P1</title><link rel=\"icon\" href=\"data:,\"><body style=\"font:40px sans-serif\">p1</body>" },
  { alert: 127, render: (url) => shortcutPage(new URL(url, "http://x").search.slice(1) || "page"), url: "/?pin1", html: "<!doctype html><title>pin1</title><body style=\"font:20px system-ui\"><h1>pin1</h1><input id=f value=\"hello field\" style=\"position:fixed;left:20px;top:120px;width:300px;height:30px\">" },
  { alert: 128, render: (url) => fixturePage(url.slice(1) || "root", { bodyStyle: "font:40px sans-serif" }), url: "/p1", html: "<!doctype html><title>P1</title><link rel=\"icon\" href=\"data:,\"><body style=\"font:40px sans-serif\">p1</body>" },
  { alert: 129, render: (url) => fixturePage(url.slice(1)), url: "/one", html: "<!doctype html><title>ONE</title><link rel=\"icon\" href=\"data:,\"><body>one</body>" },
  { alert: 130, render: (url) => fixturePage(url.slice(1), { title: ({ a: "Inbox Mail", b: "Docs Editor", c: "News Today", d: "Daily Notes", e: "Recipe Box" })[url.slice(1)] ?? "?" }), url: "/a", html: "<!doctype html><title>Inbox Mail</title><link rel=\"icon\" href=\"data:,\"><body>a</body>" },
];

function rawRequest(server, url) {
  return new Promise((resolve, reject) => {
    const socket = connect(server.address().port, "127.0.0.1");
    let response = "";
    socket.setEncoding("utf8");
    socket.setTimeout(2000, () => socket.destroy(new Error("fixture response timed out")));
    socket.on("error", reject);
    socket.on("data", (chunk) => { response += chunk; });
    socket.on("end", () => resolve(response));
    socket.on("connect", () => socket.end(`GET ${url} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n`));
  });
}

for (const { alert, render, url, html } of fixtures) {
  test(`#${alert} fixture bytes stay unchanged for its normal request`, () => {
    assert.equal(render(url), html);
  });
  test(`#${alert} raw request values enter HTML only as escaped text`, async () => {
    const server = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(render(req.url));
    });
    try {
      await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
      const payload = `</title><img/src=x/onerror=alert(1)>&"'`;
      const response = await rawRequest(server, alert === 127 ? `/?${payload}` : `/${payload}`);
      assert.match(response, /^HTTP\/1\.1 200/);
      assert.doesNotMatch(response, /<img\/src=x/i);
      assert.match(response, /&amp;/);
      if (alert !== 127) {
        assert.match(response, /&lt;/);
        assert.match(response, /&gt;/);
        assert.match(response, /&quot;/);
        assert.match(response, /&#39;/);
      }
    } finally {
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  });
}
