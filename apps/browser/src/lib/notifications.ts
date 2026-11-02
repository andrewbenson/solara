import { notificationConsume, notificationWatch, onNotificationEvent } from "@solara/solaracore";

let started = false;

export function startNotifications() {
  if (started) return;
  started = true;
  let sequence = Promise.resolve();
  onNotificationEvent((event) => {
    sequence = sequence.then(async () => {
      const result = await notificationConsume(event);
      if (result.ok !== true) console.warn("[notifications] envelope rejected", result.error);
    }).catch((error) => {
      console.error("[notifications] native consumer failed", error);
    });
  });
  void notificationWatch().then((watch) => {
    if (watch.ok !== true) throw new Error(String(watch.error ?? "Notification watch rejected"));
  }).catch((error) => console.error("[notifications] watch failed", error));
}
