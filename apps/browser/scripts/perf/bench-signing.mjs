import { execFileSync, spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const teamOnlyOrDevice = /^(com\.apple\.application-identifier|com\.apple\.developer\..*|keychain-access-groups|com\.apple\.security\.device\.(camera|audio-input))$/;
const loadsTeamFramework = "com.apple.security.cs.disable-library-validation";

export function benchEntitlements(granted, extra = []) {
  const added = [loadsTeamFramework, ...extra.filter((key) => key !== loadsTeamFramework)];
  const kept = granted.replace(/<key>([^<]+)<\/key>\s*(<true\/>|<false\/>|<string>[^<]*<\/string>|<array>[\s\S]*?<\/array>|<array\/>)/g, (all, key) =>
    teamOnlyOrDevice.test(key) || added.includes(key) ? "" : all,
  );
  return kept.replace(/<\/dict>\s*<\/plist>\s*$/, `${added.map((key) => `<key>${key}</key><true/>`).join("")}</dict></plist>\n`);
}

export function benchSignArgs(signatureInfo, entitlements, clone) {
  const hardened = /^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*\bruntime\b/m.test(signatureInfo);
  return ["--force", "--sign", "-", "--timestamp=none", ...(hardened ? ["--options", "runtime"] : []), "--entitlements", entitlements, clone];
}

export function resignForBench(app, clone, { entitlements = `${clone}.entitlements.plist`, extra = [] } = {}) {
  const info = spawnSync("codesign", ["-dvv", app], { encoding: "utf8" }).stderr;
  writeFileSync(entitlements, benchEntitlements(execFileSync("codesign", ["-d", "--entitlements", "-", "--xml", app], { encoding: "utf8" }), extra));
  execFileSync("codesign", benchSignArgs(info, entitlements, clone), { stdio: "inherit" });
}
