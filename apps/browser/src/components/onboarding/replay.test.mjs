import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

const require = createRequire(import.meta.url);
const ts = require("typescript");
const { createStore } = require("zustand/vanilla");

function load(path, imports) {
  const module = { exports: {} };
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
  }).outputText, {
    exports: module.exports,
    require: (name) => {
      if (name in imports) return imports[name];
      throw new Error(`Unexpected import: ${name}`);
    },
    __DEV__: false,
  });
  return module.exports;
}

function fixture() {
  const browser = { windows: { B: { kind: "main" } }, ui: { focusOrder: ["B"] }, windowOrder: ["B"], settings: {} };
  const model = load("../../store/model.ts", { "@solara/core": {}, "./settings": { DEFAULT_PROFILE_ID: "default" } });
  const settings = { hostedKinds: () => ["onboarding"], SolaraHostedView: () => null };
  const state = load("./state.ts", {
    "@solara/settings": settings,
    "@solara/shell": { readDocument: () => null, writeDocument: () => {} },
    "../../lib/persistLatch": {},
    zustand: { create: (initialize) => {
      const store = createStore(initialize);
      return Object.assign((select) => select(store.getState()), store);
    } },
    "../../store/browser": { useBrowser: { getState: () => browser } },
    "../../store/model": model,
    "./sites": {},
    "./tour/state": { endToolTour: () => {} },
    "../../store/nativeStore": {},
    "@solara/store": {},
  });
  const overlay = load("./OnboardingOverlay.tsx", {
    "react/jsx-runtime": require("react/jsx-runtime"),
    "@solara/settings": settings,
    "react-native": { StyleSheet: { absoluteFill: {} } },
    "../../store/hooks": { useWindowId: () => "B" },
    "./state": state,
    "./tour/ToolTour": { ToolTour: () => null },
  });
  const handlers = load("../settings/native/onboarding.ts", {
    "@solara/shell": {},
    "@solara/settings": settings,
    "../../../store/browser": { useBrowser: { getState: () => browser } },
    "../../../store/model": model,
    "../../import/module": {},
    "../../onboarding/sites": {},
    "../../onboarding/state": state,
    "../../onboarding/tour/state": { endToolTour: () => {} },
    "../windows": {},
  }).onboardingHandlers;
  return { ...state, dismissed: handlers["onboarding.dismissed"], props: () => overlay.OnboardingOverlay().props.children[0].props };
}

test("closed-window replay keeps its request ID through resolution and the hosted overlay", () => {
  const f = fixture();
  f.startOnboarding("A", "intro", "presentation-1");
  assert.equal(f.useOnboarding.getState().windowId, "B");
  assert.equal(f.props().windowId, "B");
  assert.equal(f.props().state, "presentation-1");
});

test("an automatic start cannot reuse an earlier presentation ID", () => {
  const f = fixture();
  f.startOnboarding("B", "intro", "presentation-1");
  f.startOnboarding("B");
  assert.equal(f.useOnboarding.getState().requestId, null);
  assert.equal(f.props().state, "");
});

test("an automatic resume cannot reuse an earlier presentation ID", () => {
  const f = fixture();
  f.startOnboarding("B", "intro", "presentation-1");
  f.resumeOnboarding({ startedAt: 1, completedAt: null, step: "tabs" });
  assert.equal(f.useOnboarding.getState().requestId, null);
  assert.equal(f.props().state, "");
});

test("a delayed dismissal from request 1 preserves request 2 in the same window", () => {
  const f = fixture();
  f.startOnboarding("B", "intro", "presentation-1");
  f.startOnboarding("B", "tabs", "presentation-2");
  const active = f.useOnboarding.getState();
  f.dismissed("B", "presentation-1");
  assert.equal(f.useOnboarding.getState(), active);
  assert.equal(f.props().state, "presentation-2");
});

for (const requestId of [undefined, null, ""]) {
  test(`an explicit presentation rejects a dismissal without an ID (${String(requestId)})`, () => {
    const f = fixture();
    f.startOnboarding("B", "tabs", "presentation-2");
    const active = f.useOnboarding.getState();
    f.dismissed("B", requestId);
    assert.equal(f.useOnboarding.getState(), active);
  });
}

test("a presentation started with an empty ID closes on its own empty-ID dismissal", () => {
  const f = fixture();
  f.startOnboarding("B", "intro", "");
  assert.equal(f.useOnboarding.getState().requestId, null);
  f.dismissed("B", "");
  assert.equal(f.useOnboarding.getState().windowId, null);
});

test("a matching presentation ID cannot dismiss another window", () => {
  const f = fixture();
  f.startOnboarding("B", "tabs", "presentation-2");
  const active = f.useOnboarding.getState();
  f.dismissed("A", "presentation-2");
  assert.equal(f.useOnboarding.getState(), active);
});

test("an accepted dismissal clears its presentation ID and leaving state", () => {
  const f = fixture();
  f.startOnboarding("B", "tabs", "presentation-2");
  f.useOnboarding.setState({ leaving: true, tourAfter: true });
  const session = f.useOnboarding.getState().session;
  f.dismissed("B", "presentation-2");
  const current = f.useOnboarding.getState();
  assert.equal(current.windowId, null);
  assert.equal(current.requestId, null);
  assert.equal(current.step, "intro");
  assert.equal(current.leaving, false);
  assert.equal(current.tourAfter, false);
  assert.equal(current.session, session);
});

for (const requestId of [undefined, null, ""]) {
  test(`automatic onboarding accepts a legacy dismissal without an ID (${String(requestId)})`, () => {
    const f = fixture();
    f.startOnboarding("B", "tabs");
    f.dismissed("B", requestId);
    assert.equal(f.useOnboarding.getState().windowId, null);
    assert.equal(f.useOnboarding.getState().requestId, null);
    assert.equal(f.useOnboarding.getState().step, "intro");
  });
}

test("automatic onboarding rejects a stale explicit presentation dismissal", () => {
  const f = fixture();
  f.startOnboarding("B", "tabs");
  const active = f.useOnboarding.getState();
  f.dismissed("B", "presentation-1");
  assert.equal(f.useOnboarding.getState(), active);
});
