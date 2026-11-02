import assert from "node:assert/strict";
import { test } from "node:test";
import { listedPaths, podSourceGlobs, podSources, staleSources } from "./pods-sources.mjs";

const pods = "/repo/apps/browser/macos/Pods";

const pbxproj = `// !$*UTF8*$!
{
	objects = {

/* Begin PBXFileReference section */
		AA00000000000001 /* AppModule.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = AppModule.swift; sourceTree = "<group>"; };
		AA00000000000002 /* RCTTouchHandler+Pages.mm */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.cpp.objcpp; path = "RCTTouchHandler+Pages.mm"; sourceTree = "<group>"; };
		AA00000000000003 /* Theme.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = Theme.swift; sourceTree = "<group>"; };
		AA00000000000004 /* SolaraShell */ = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; name = SolaraShell; path = libSolaraShell.a; sourceTree = BUILT_PRODUCTS_DIR; };
		AA00000000000005 /* Podfile */ = {isa = PBXFileReference; explicitFileType = text.script.ruby; includeInIndex = 1; name = Podfile; path = ../Podfile; sourceTree = SOURCE_ROOT; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
		BB00000000000001 = {
			isa = PBXGroup;
			children = (
				AA00000000000005 /* Podfile */,
				BB00000000000002 /* Development Pods */,
			);
			sourceTree = "<group>";
		};
		BB00000000000002 /* Development Pods */ = {
			isa = PBXGroup;
			children = (
				BB00000000000003 /* SolaraShell */,
				BB00000000000005 /* SolaraCore */,
			);
			name = "Development Pods";
			sourceTree = "<group>";
		};
		BB00000000000003 /* SolaraShell */ = {
			isa = PBXGroup;
			children = (
				AA00000000000001 /* AppModule.swift */,
				BB00000000000004 /* Core */,
			);
			name = SolaraShell;
			path = ../../../../packages/shell/ios;
			sourceTree = "<group>";
		};
		BB00000000000004 /* Core */ = {
			isa = PBXGroup;
			children = (
				AA00000000000003 /* Theme.swift */,
			);
			path = Core;
			sourceTree = "<group>";
		};
		BB00000000000005 /* SolaraCore */ = {
			isa = PBXGroup;
			children = (
				AA00000000000002 /* RCTTouchHandler+Pages.mm */,
			);
			name = SolaraCore;
			path = ../../../../packages/solaracore/ios;
			sourceTree = "<group>";
		};
/* End PBXGroup section */
	};
	rootObject = CC00000000000001 /* Project object */;
		CC00000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				LastUpgradeCheck = 1600;
			};
			buildConfigurationList = DD00000000000001 /* Build configuration list for PBXProject "Pods" */;
			mainGroup = BB00000000000001;
		};
}
`;

test("the Pods project's files resolve through their groups to repo paths, quoted names included", () => {
  const listed = listedPaths(pbxproj, pods);
  assert.ok(listed.has("/repo/packages/shell/ios/AppModule.swift"));
  assert.ok(listed.has("/repo/packages/shell/ios/Core/Theme.swift"));
  assert.ok(listed.has("/repo/packages/solaracore/ios/RCTTouchHandler+Pages.mm"));
  assert.ok(listed.has("/repo/apps/browser/macos/Podfile"));
  assert.ok(!listed.has("/repo/packages/shell/ios/Theme.swift"), "a file in a subgroup isn't listed at the pod root");
  assert.ok(![...listed].some((p) => p.endsWith("libSolaraShell.a")), "built products aren't source files");
});

test("a podspec's source_files globs are read, braces and lists included", () => {
  assert.deepEqual(podSourceGlobs("  s.source_files   = '**/*.{h,m,swift}'\n"), ["**/*.{h,m,swift}"]);
  assert.deepEqual(podSourceGlobs("  s.source_files   = 'ImportModule.swift', 'Core/**/*.swift'\n"), ["ImportModule.swift", "Core/**/*.swift"]);
  assert.deepEqual(podSourceGlobs("  s.source_files = \"*.{h,mm,swift}\"\n"), ["*.{h,mm,swift}"]);
});

test("only the files a podspec's globs select are pod sources", () => {
  const files = ["AppModule.swift", "Core/Theme.swift", "Core/Deep/Nested.m", "README.md", "Tests/Thing.swift", "Other.swift"];
  assert.deepEqual(podSources(["*.{h,mm,swift}"], files), ["AppModule.swift", "Other.swift"]);
  assert.deepEqual(podSources(["**/*.{h,m,swift}"], files), ["AppModule.swift", "Core/Theme.swift", "Core/Deep/Nested.m", "Tests/Thing.swift", "Other.swift"]);
  assert.deepEqual(podSources(["AppModule.swift", "Core/**/*.swift"], files), ["AppModule.swift", "Core/Theme.swift"]);
});

test("a pod source the Pods project doesn't list is stale, and the listed ones aren't", () => {
  const pods_ = [
    { dir: "/repo/packages/shell/ios", globs: ["**/*.{h,m,swift}"], files: ["AppModule.swift", "Core/Theme.swift", "WebKitSessionResources.swift"] },
    { dir: "/repo/packages/solaracore/ios", globs: ["*.{h,mm,swift}"], files: ["RCTTouchHandler+Pages.mm"] },
  ];
  assert.deepEqual(staleSources(pbxproj, pods, pods_), ["/repo/packages/shell/ios/WebKitSessionResources.swift"]);
  assert.deepEqual(staleSources(pbxproj, pods, pods_.slice(1)), []);
});

test("a file listed under another pod's group doesn't count for this one", () => {
  const moved = [{ dir: "/repo/packages/solaracore/ios", globs: ["*.swift"], files: ["AppModule.swift"] }];
  assert.deepEqual(staleSources(pbxproj, pods, moved), ["/repo/packages/solaracore/ios/AppModule.swift"]);
});
