import { Cef } from "./native";

export type NotificationEnvelope = Record<string, unknown>;

export const onNotificationEvent = (listener: (event: NotificationEnvelope) => void) => Cef.addListener("onNotificationEvent", listener);
export const notificationWatch = () => Cef.notificationWatch();
export const notificationConsume = (event: NotificationEnvelope) => Cef.notificationConsume(event);
