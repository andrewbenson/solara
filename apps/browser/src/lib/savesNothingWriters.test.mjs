import assert from "node:assert/strict";
import { test } from "node:test";
import { registerHooks } from "node:module";

const reactNativeFake = new URL("../test-native/reactNative.ts", import.meta.url).href;
const reactNative = `data:text/javascript,${encodeURIComponent(`export * from ${JSON.stringify(reactNativeFake)}; export const unstable_batchedUpdates = (run) => run();`)}`;
registerHooks({ resolve: (specifier, context, next) => (specifier === "react-native" ? { url: reactNative, shortCircuit: true } : next(specifier, context)) });

const { docs, documentChanges } = await import("../test-native/index.ts");
const { useBrowser } = await import("../store/browser.ts");
const { refusePersistence } = await import("./persistLatch.ts");
const onboarding = await import("../components/onboarding/state.ts");

test("with persistence refused, onboarding writes nothing, whichever caller saves", () => {
  docs.set("onboarding.json", JSON.stringify({ version: 1, completedAt: 1 }));
  const before = new Map(docs);
  refusePersistence("the native store: test");
  const changes = documentChanges.length;
  onboarding.saveIntroMusicMuted(true);
  const windowId = useBrowser.getState().createWindow({});
  onboarding.startOnboarding(windowId);
  assert.equal(onboarding.useOnboarding.getState().windowId, null, "onboarding never mounts, so its native session can't write either");
  onboarding.resumeOnboarding({ version: 1, completedAt: null, startedAt: 1, step: "look" });
  assert.equal(onboarding.useOnboarding.getState().windowId, null, "an automatic resume doesn't mount it either");
  assert.deepEqual(documentChanges.slice(changes).filter((change) => /onboarding\.json/.test(change)), []);
  assert.equal(docs.get("onboarding.json"), before.get("onboarding.json"));
});
