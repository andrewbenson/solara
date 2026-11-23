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
const releaseNotes = await import("../components/ntp/releaseNotes.ts");

test("with persistence refused, onboarding and release notes write nothing, whichever caller saves", () => {
  docs.set("onboarding.json", JSON.stringify({ version: 1, completedAt: 1 }));
  docs.set("release-notes.json", JSON.stringify({ version: 1, lastVersion: "0.9", pending: null }));
  const before = new Map(docs);
  refusePersistence("the native store: test");
  const changes = documentChanges.length;
  onboarding.recordDefaultBrowserTrial();
  onboarding.recordDefaultBrowserCheckInDone();
  onboarding.saveIntroMusicMuted(true);
  const windowId = useBrowser.getState().createWindow({});
  onboarding.startOnboarding(windowId);
  assert.equal(onboarding.useOnboarding.getState().windowId, null, "onboarding never mounts, so its native session can't write either");
  onboarding.resumeOnboarding({ version: 1, completedAt: null, startedAt: 1, step: "look" });
  assert.equal(onboarding.useOnboarding.getState().windowId, null, "an automatic resume doesn't mount it either");
  releaseNotes.applyPendingReleaseNotes({ version: "1.0", since: 1 });
  releaseNotes.retireReleaseNotes();
  assert.deepEqual(documentChanges.slice(changes).filter((change) => /onboarding\.json|release-notes\.json/.test(change)), []);
  assert.equal(docs.get("onboarding.json"), before.get("onboarding.json"));
  assert.equal(docs.get("release-notes.json"), before.get("release-notes.json"));
});
