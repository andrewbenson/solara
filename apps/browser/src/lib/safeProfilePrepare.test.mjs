import assert from "node:assert/strict";
import { declaration, runNative, source } from "../test-native/safe-host/run.mjs";
import { test } from "node:test";

test("a profile Chrome loads gets its content blocker before anything can open a window in it or hear of it", () => {
  const host = source("packages/solaracore/ios/SolaraCoreHost.mm");
  const functions = ["NSString *RegularProfileName(SolaraCoreProfile *profile)", "SolaraCoreProfile *ChromeProfileAtPath(SolaraCoreEngine *engine, NSString *path)", "void PrepareLoadedProfile(SolaraCoreProfile *profile)", "void PrepareEngineProfile(SolaraCoreProfile *profile)", "void RememberLoadedProfiles()"].map((signature) => declaration(host, signature)).join("\n");
  const newBrowser = declaration(host, "- (SolaraCoreWindow *)engineWindowForNewBrowserOfProfile:(SolaraCoreProfile *)profile type:(NSString *)type");
  const production = `namespace {\n${functions}\n}\n@interface EngineDelegate : NSObject\n@end\n@implementation EngineDelegate\n${newBrowser}\n@end`;
  const results = runNative("ProfilePrepare.mm", production);
  assert.deepEqual(results.didLoad.synchronous, ["blocker:work:registered", "downloads:work", "keepAwake"], "registration, blocker and holds happen in one step, and no one hears of the profile yet");
  assert.deepEqual(results.didLoad.all, [...results.didLoad.synchronous, "notification:work", "profileLoaded:work"], "a second load of the same profile prepares nothing again");
  assert.deepEqual(results.remember.synchronous, ["blocker:side:registered", "downloads:side", "keepAwake", "blocker::registered", "downloads:", "keepAwake"], "profiles found at launch go through the same preparation");
  assert.deepEqual(results.remember.all, [...results.remember.synchronous, "notification:side", "profileLoaded:side", "notification:", "profileLoaded:"]);
  assert.deepEqual(results.newBrowser, [
    "blocker:dormant:registered", "downloads:dormant", "keepAwake", "window:Profile dormant:after-blocker", "window:Profile dormant:after-blocker",
    "blocker:quiet:registered", "downloads:quiet", "keepAwake", "stray:private:after-blocker",
    "notification:dormant", "profileLoaded:dormant", "notification:quiet", "profileLoaded:quiet",
  ], "a profile Chrome opens a window for on its own (a notification click on a dormant profile) is prepared first, once, and a private window prepares its regular profile");
  assert.deepEqual(results.dropped, ["blocker:gone:registered", "downloads:gone", "keepAwake"], "a profile destroyed before the announcement is never announced, and a deleted one is never prepared");
});
