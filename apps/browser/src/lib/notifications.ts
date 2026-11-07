import { notificationConsume, notificationWatch, onNotificationEvent } from "@solara/solaracore";

const SUPERSEDED = "stale notification envelope";
let started = false;

export function startNotifications() {
  if (started) return;
  started = true;
  let sequence = Promise.resolve();
  onNotificationEvent((event) => {
    sequence = sequence.then(async () => {
      const result = await notificationConsume(event);
      if (result.ok === true) return;
      if (result.error === SUPERSEDED) console.debug("[notifications] envelope from an earlier watch", event.kind);
      else console.warn("[notifications] envelope rejected", result.error);
    }).catch((error) => {
      console.error("[notifications] native consumer failed", error);
    });
  });
  void notificationWatch().then((watch) => {
    if (watch.ok !== true) throw new Error(String(watch.error ?? "Notification watch rejected"));
  }).catch((error) => console.error("[notifications] watch failed", error));
}
