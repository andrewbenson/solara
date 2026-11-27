import { create } from "zustand";
import {
  defaultBrowserCheckInDoneAt,
  defaultBrowserTrialStartedAt,
  recordDefaultBrowserCheckInDone,
} from "../components/onboarding/state";
import { sendFeedback } from "./appIntegration";
import { PRODUCT } from "./productName";

export const CHECK_IN_AFTER_MS = 7 * 24 * 60 * 60 * 1000;

export const CHECK_IN_COPY = { title: `How are you liking ${PRODUCT}?`, action: "Leave us feedback" } as const;

type CheckIn = { trialStartedAt: number | null; doneAt: number | null };

const useCheckIn = create<CheckIn>(() => ({ trialStartedAt: defaultBrowserTrialStartedAt(), doneAt: defaultBrowserCheckInDoneAt() }));

export function checkInDue({ trialStartedAt, doneAt }: CheckIn, now = Date.now()): boolean {
  return trialStartedAt !== null && doneAt === null && now - trialStartedAt >= CHECK_IN_AFTER_MS;
}

export function dismissDefaultBrowserCheckIn() {
  recordDefaultBrowserCheckInDone();
  useCheckIn.setState({ doneAt: Date.now() });
}

export function useDefaultBrowserCheckIn(windowId: string) {
  const due = useCheckIn(checkInDue);
  return {
    visible: due,
    leaveFeedback() {
      dismissDefaultBrowserCheckIn();
      void sendFeedback(windowId).catch((error) => {
        console.warn("Default-browser check-in feedback failed", error);
      });
    },
    dismiss: dismissDefaultBrowserCheckIn,
  };
}

if (__DEV__) (globalThis as { acCheckIn?: unknown }).acCheckIn = { store: useCheckIn, due: () => checkInDue(useCheckIn.getState()) };
