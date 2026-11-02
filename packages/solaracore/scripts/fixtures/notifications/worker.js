self.addEventListener("install", (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("message", (event) => {
  const { run, phase } = event.data;
  const port = event.ports[0];
  event.waitUntil((async () => {
    port.postMessage({ state: "started", entered: true });
    try {
      await self.registration.showNotification(`${run}:${phase}`, { body: "from service worker", tag: `${run}:${phase}`, data: { run }, silent: true, requireInteraction: true });
      port.postMessage({ state: "shown" });
    } catch (error) {
      port.postMessage({ state: "error", error: String(error) });
    }
  })());
});
const report = async (event, kind) => {
  const { run } = event.notification.data;
  const response = await fetch(`./event?${new URLSearchParams({ run, kind, title: event.notification.title })}`, { cache: "no-store" });
  if (!response.ok) throw new Error(`worker event report failed: ${response.status}`);
};
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(report(event, "click"));
});
self.addEventListener("notificationclose", (event) => event.waitUntil(report(event, "close")));
