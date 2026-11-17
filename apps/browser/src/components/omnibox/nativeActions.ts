export type NativeActionOwnership = { nativeActions?: boolean };

let disabled = false;
let received: Record<string, number> = {};
let executed: Record<string, number> = {};

export function runOmniboxFallback(name: string, ownership: NativeActionOwnership | undefined, run: () => void): void {
  if (ownership?.nativeActions) return;
  if (__DEV__) received[name] = (received[name] ?? 0) + 1;
  if (__DEV__ && disabled) return;
  if (__DEV__) executed[name] = (executed[name] ?? 0) + 1;
  run();
}

export const omniboxActionDriver = {
  disableJS(value: boolean) {
    if (__DEV__) disabled = value;
  },
  reset() {
    received = {};
    executed = {};
  },
  state: () => ({ disabled, received: { ...received }, executed: { ...executed } }),
};
