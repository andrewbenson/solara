import assert from "node:assert/strict";
import { test } from "node:test";
const { showMenu } = await import("@solara/shell");
const { useBrowser } = await import("../../store/browser.ts");
const { cardHoverProps, dismissHover } = await import("../sidebar/hover.ts");
const { setSidebarUi, useSidebarUi } = await import("../sidebar/state.ts");
const { usePages } = await import("./pageState.ts");
const { followPeekHold } = await import("./peekHold.ts");

const stores = { browser: useBrowser, pages: usePages, sidebarUi: useSidebarUi };

function countListeners() {
  const live = Object.fromEntries(Object.keys(stores).map((name) => [name, 0]));
  const restore = Object.entries(stores).map(([name, store]) => {
    const subscribe = store.subscribe;
    store.subscribe = (listener) => {
      live[name]++;
      const stop = subscribe(listener);
      return () => {
        live[name]--;
        stop();
      };
    };
    return () => (store.subscribe = subscribe);
  });
  return { live, restore: () => restore.forEach((undo) => undo()) };
}

function follow(floating) {
  const seen = [];
  const stop = followPeekHold("w", floating, (held) => seen.push(held));
  return { seen, stop, held: () => seen.at(-1) };
}

const hoverOn = (windowId) => setSidebarUi({ hover: { windowId, kind: "tab", id: "t", anchor: { x: 0, y: 0, width: 10, height: 10 } } });

test("a docked or full-screen sidebar keeps no peek-hold listener and is never held", async () => {
  const { live, restore } = countListeners();
  try {
    const f = follow(false);
    assert.deepEqual(live, { browser: 0, pages: 0, sidebarUi: 0 });
    const menu = showMenu([]);
    hoverOn("w");
    cardHoverProps.onMouseEnter();
    usePages.setState({ popover: { t: "site" } });
    await menu;
    assert.deepEqual(f.seen, [false]);
    f.stop();
  } finally {
    restore();
    cardHoverProps.onMouseLeave();
    dismissHover();
    usePages.setState({ popover: {} });
  }
});

test("a floating sidebar holds while a menu is open and lets go when it closes", async () => {
  const { live, restore } = countListeners();
  try {
    const f = follow(true);
    assert.equal(f.held(), false);
    assert.ok(live.browser === 1 && live.pages === 1 && live.sidebarUi === 1, JSON.stringify(live));
    const menu = showMenu([]);
    assert.equal(f.held(), true);
    await menu;
    assert.equal(f.held(), false);
    f.stop();
    assert.deepEqual(live, { browser: 0, pages: 0, sidebarUi: 0 });
  } finally {
    restore();
  }
});

test("a floating sidebar holds while the pointer is on its hover card, and lets go when it leaves", () => {
  const f = follow(true);
  try {
    hoverOn("w");
    assert.equal(f.held(), false);
    cardHoverProps.onMouseEnter();
    assert.equal(f.held(), true);
    cardHoverProps.onMouseLeave();
    assert.equal(f.held(), false);
  } finally {
    f.stop();
    dismissHover();
  }
});

test("another window's hover card doesn't hold this sidebar", () => {
  const f = follow(true);
  try {
    hoverOn("other");
    cardHoverProps.onMouseEnter();
    assert.equal(f.held(), false);
  } finally {
    f.stop();
    cardHoverProps.onMouseLeave();
    dismissHover();
  }
});

test("a sidebar that starts floating with a menu already open starts held", async () => {
  const menu = showMenu([]);
  const f = follow(true);
  assert.deepEqual(f.seen, [true]);
  await menu;
  assert.equal(f.held(), false);
  f.stop();
});
