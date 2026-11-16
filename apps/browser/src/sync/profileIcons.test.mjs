import assert from "node:assert/strict";
import { test } from "node:test";

globalThis.__DEV__ = false;

const { useBrowser } = await import("../store/browser.ts");
const { Clock, emptyScope, syncScope } = await import("@solara/sync");
const { profilesAdapter } = await import("./adapters.ts");
const { syncRedesign } = await import("./redesignSwitch.ts");
const { withApplier } = await import("../store/nativeStore.ts");
const S = () => useBrowser.getState();
const links = () => ({ default: { syncId: "personal" } });
const records = { known: () => true };

class IconMac {
  constructor(id, files) {
    S().hydrate({});
    this.id = id;
    this.browser = S();
    this.files = files;
    this.scope = emptyScope();
    this.scope.joined = id === "a";
    this.clock = new Clock(id);
  }

  async with(action) {
    useBrowser.setState(this.browser, true);
    try {
      return await action();
    } finally {
      this.browser = S();
    }
  }

  async sync() {
    return this.with(() => syncScope({ scope: "app", state: this.scope, clock: this.clock, device: this.id,
      adapters: [profilesAdapter(links)], transport: {
        read: async (_scope, known) => ({ files: [...this.files].filter(([id]) => !known.includes(id)).map(([id, payload]) => ({ id, payload })), pending: [], damaged: [], present: [...this.files.keys()] }),
        write: async (_scope, payload) => { const id = `${this.id}-${this.files.size}`; this.files.set(id, payload); return id; },
        remove: async (_scope, ids) => { for (const id of ids) this.files.delete(id); },
      } }));
  }
}

test("profile symbols emoji unknown symbols and clearing round trip between Macs in both sync lanes", async () => {
  const previous = S();
  const lane = syncRedesign.on;
  try {
    for (const redesigned of [false, true]) {
      syncRedesign.on = redesigned;
      const files = new Map();
      const a = new IconMac("a", files);
      const b = new IconMac("b", files);
      for (const icon of ["symbol:briefcase.fill", "🍌", "symbol:future.symbol.fill", null]) {
        await a.with(() => S().updateProfile("default", { icon }));
        await a.sync();
        await b.sync();
        await a.sync();
        assert.equal(a.browser.profiles.default.icon, icon);
        assert.equal(b.browser.profiles.default.icon, icon);
        assert.equal(b.scope.records["prof:personal"].v.i, icon);
      }
    }
  } finally {
    syncRedesign.on = lane;
    withApplier(() => useBrowser.setState(previous, true));
  }
});

test("profile metadata without an icon leaves the local icon while explicit null clears it", () => {
  const previous = S();
  try {
    S().hydrate({});
    S().updateProfile("default", { icon: "symbol:star.fill" });
    const adapter = profilesAdapter(links);
    const apply = (value) => adapter.apply(new Map([["prof:personal", value]]), new Set(["prof:personal"]), () => undefined, records);
    apply({ n: "Renamed", c: "green" });
    assert.equal(S().profiles.default.name, "Renamed");
    assert.equal(S().profiles.default.icon, "symbol:star.fill");
    apply({ n: "Renamed", c: "green", i: null, future: "ignored" });
    assert.equal(S().profiles.default.icon, null);
  } finally {
    withApplier(() => useBrowser.setState(previous, true));
  }
});
