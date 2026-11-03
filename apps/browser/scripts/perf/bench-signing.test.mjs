import assert from "node:assert/strict";
import test from "node:test";
import { benchEntitlements, benchSignArgs } from "./bench-signing.mjs";

const developerID = `Executable=/x/Solara.app/Contents/MacOS/Solara
Identifier=network.benson.solara
CodeDirectory v=20500 size=64289 flags=0x10000(runtime) hashes=1998+7 location=embedded
Authority=Developer ID Application: andrew Benson (555T74U353)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=555T74U353
`;

const granted = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>555T74U353.network.benson.solara</string>
<key>com.apple.developer.team-identifier</key><string>555T74U353</string>
<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.personal-information.calendars</key><true/>
<key>keychain-access-groups</key><array><string>555T74U353.network.benson.solara.webauthn</string></array>
</dict></plist>
`;

const keys = (xml) => [...xml.matchAll(/<key>([^<]+)<\/key>/g)].map((m) => m[1]);

test("a team-signed export is re-signed ad hoc, so its isolated launch keeps the dev-eval harness", () => {
  const args = benchSignArgs(developerID, "/x/ent.plist", "/x/clone/Solara.app");
  assert.equal(args[args.indexOf("--sign") + 1], "-");
  assert.ok(!args.some((a) => a.includes("Developer ID") || a.includes("555T74U353")));
  assert.deepEqual(args.slice(args.indexOf("--options"), args.indexOf("--options") + 2), ["--options", "runtime"]);
  assert.deepEqual(args.slice(args.indexOf("--entitlements"), args.indexOf("--entitlements") + 2), ["--entitlements", "/x/ent.plist"]);
  assert.equal(args.at(-1), "/x/clone/Solara.app");
});

test("an ad hoc copy without hardened runtime stays without it", () => {
  const args = benchSignArgs(developerID.replace("flags=0x10000(runtime)", "flags=0x2(adhoc)"), "/x/ent.plist", "/x/c.app");
  assert.ok(!args.includes("--options"));
  assert.equal(args[args.indexOf("--sign") + 1], "-");
});

test("the copy drops the team-only and device entitlements and may load the team-signed framework", () => {
  const kept = keys(benchEntitlements(granted));
  assert.ok(!kept.includes("com.apple.application-identifier"));
  assert.ok(!kept.includes("com.apple.developer.team-identifier"));
  assert.ok(!kept.includes("keychain-access-groups"));
  assert.ok(!kept.includes("com.apple.security.device.camera"));
  assert.ok(!kept.includes("com.apple.security.device.audio-input"));
  assert.ok(kept.includes("com.apple.security.automation.apple-events"));
  assert.ok(kept.includes("com.apple.security.personal-information.calendars"));
  assert.equal(kept.filter((k) => k === "com.apple.security.cs.disable-library-validation").length, 1);
  assert.match(benchEntitlements(granted), /<\/dict>\s*<\/plist>\s*$/);
});

test("disable-library-validation is not added twice", () => {
  const already = granted.replace("</dict>", "<key>com.apple.security.cs.disable-library-validation</key><true/></dict>");
  assert.equal(keys(benchEntitlements(already)).filter((k) => k === "com.apple.security.cs.disable-library-validation").length, 1);
});

test("tab-actions' copy also lets the injected timing library load", () => {
  const kept = keys(benchEntitlements(granted, ["com.apple.security.cs.allow-dyld-environment-variables"]));
  assert.ok(kept.includes("com.apple.security.cs.allow-dyld-environment-variables"));
  assert.ok(kept.includes("com.apple.security.cs.disable-library-validation"));
  assert.ok(!kept.includes("keychain-access-groups"));
});
