import { Clock, editHLC, emptyScope, syncScope, type Adapter, type ScopeState, type Transport } from "@solara/sync";
import { ackBookmarkFacts, bookmarkWriterErrorCode, bookmarkWriterSnapshot, bookmarkWriterState, setBookmarkSyncLinks } from "@solara/settings";
import { useBrowser } from "../store/browser";
import { bookmarkUuidFor } from "../store/bookmarks";
import { bookmarkWriter } from "../lib/bookmarkWriter";
import { bookmarksAdapter } from "../sync/adapters";

const expect = (value: unknown, message: string) => { if (!value) throw new Error(message); };
const h = (at: number, device: string, counter = 0) => `${at.toString(36).padStart(9, "0")}.${counter.toString(36).padStart(4, "0")}.${device}`;
const snapshot = (profile: string) => {
  const value = bookmarkWriterSnapshot(profile);
  return { ...value, document: JSON.parse(value.document) as { nodes: Record<string, { title: string; url?: string }> } };
};
const ready = async (profile: string) => {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const value = snapshot(profile);
      if (value.readyForSync ?? value.ready) return value;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("Native bookmark profile never became ready");
};

class Folder {
  private files = new Map<string, string>();
  private next = 0;
  writes = 0;
  transport: Transport = {
    write: async (_scope, payload) => {
      this.writes++;
      const id = `bm-schedule-${++this.next}`;
      this.files.set(id, payload);
      return id;
    },
    read: async (_scope, known) => ({
      files: [...this.files].filter(([id]) => !known.includes(id)).map(([id, payload]) => ({ id, payload })),
      pending: [], damaged: [], present: [...this.files.keys()],
    }),
    remove: async (_scope, ids) => { ids.forEach((id) => this.files.delete(id)); },
  };
  async remote(ops: { k: string; h: string; v: unknown }[], at: number) {
    await this.transport.write("bookmark-acceptance", JSON.stringify({ v: 1, kind: "log", device: "foreign-acceptance", seq: 1, at, ops }));
  }
}

async function fixture(name: string) {
  expect(bookmarkWriterState().state === "owned", "Production native owner is required");
  const profile = useBrowser.getState().createProfile({ name: `Bookmark sync ${name}` });
  await ready(profile);
  let link = `acceptance-${profile}`;
  const links = async () => expect(await setBookmarkSyncLinks({ [profile]: link }), "Native sync link checkpoint refused");
  await links();
  const id = await bookmarkWriter.addBookmark({ profileId: profile, title: "Base", url: `https://bookmark-sync-acceptance.example/${profile}` });
  const key = `bm:${id}`;
  const device = "native-acceptance";
  const adapter = () => bookmarksAdapter(profile, { device, link: () => link });
  const folder = new Folder();
  const state = emptyScope();
  const clock = new Clock(device);
  const cycle = (next = adapter(), current: ScopeState = state) => syncScope({ scope: "bookmark-acceptance", state: current, transport: folder.transport, adapters: [next], clock, device });
  await cycle();
  expect(!snapshot(profile).facts[key], "Baseline publication must clear its actual native fact");
  expect(state.records[key]?.v != null, "Baseline did not publish through the real adapter");
  return {
    profile, id, key, device, adapter, folder, state, cycle,
    async changeLink(next: string) { link = next; await links(); },
    async nativeLink(next: string) { expect(await setBookmarkSyncLinks({ [profile]: next }), "Native link change refused"); },
    link: () => link,
    async edit(title: string) { await bookmarkWriter.updateBookmark(profile, id, { title }); return snapshot(profile); },
    async cleanup() { await setBookmarkSyncLinks({}); useBrowser.getState().deleteProfile(profile); },
  };
}

async function failedAckAtSameMillisecond() {
  const f = await fixture("same-ms ack");
  try {
    const edited = await f.edit("Pending after rejected ack");
    const fact = edited.facts[f.key];
    expect(fact, "Local edit must have a real durable native fact");
    const known = h(fact!.at, f.device, 7);
    const base = JSON.parse(f.state.base[f.key]!);
    const adapter = f.adapter();
    const extraction = await adapter.extract(() => base, () => false, Date.now(), () => true, () => base, () => known, () => false);
    expect(extraction?.stamp?.(f.key), "Pending local fact must compete with the same-ms self record");
    await f.nativeLink(`${f.link()}-unavailable`);
    let rejected = false;
    try { rejected = await ackBookmarkFacts(f.profile, edited, [{ key: f.key, seq: fact!.seq, mintedHLC: known }], f.link()) === false; }
    catch { rejected = true; }
    expect(rejected, "Changed native link must reject the actual ack transaction");
    await extraction?.published?.(new Set([f.key]), new Map([[f.key, known]]));
    expect(snapshot(f.profile).facts[f.key]?.seq === fact!.seq, "A refused published callback must keep native intent");
    await f.nativeLink(f.link());
    f.state.records[f.key] = { h: known, v: base, o: [f.device, 1] };
    const result = await f.cycle();
    const record = f.state.records[f.key]!;
    expect(record.h > known, "The same-ms self record must not make pending intent lose after ack refusal");
    expect(record.h === editHLC({ at: fact!.at, after: known }, f.device), "Republish must preserve native time and advance the known self predecessor");
    expect((record.v as { t: string }).t === "Pending after rejected ack", "Republished native value was lost");
    expect(!snapshot(f.profile).facts[f.key], "Successful durable publication must settle the accepted sequence");
    return { nativeAt: fact!.at, rejectedAck: rejected, previousHLC: known, publishedHLC: record.h, published: result.published };
  } finally { await f.cleanup(); }
}

async function zeroPublicationRefusalAndAtomicReplacement() {
  const f = await fixture("zero publication");
  try {
    const edited = await f.edit("Older local");
    const fact = edited.facts[f.key]!;
    const beforeBase = JSON.stringify(f.state.base);
    const remoteTime = fact.at + 1000;
    const remoteHLC = h(remoteTime, "foreign-acceptance");
    const base = JSON.parse(f.state.base[f.key]!);
    const other = `bm:${bookmarkUuidFor(`acceptance-other-${f.profile}`)}`;
    await f.folder.remote([
      { k: f.key, h: remoteHLC, v: { ...base, t: "Foreign newer" } },
      { k: other, h: remoteHLC, v: { ...base, t: "Foreign second", u: "https://bookmark-sync-acceptance.example/second", pos: "z" } },
    ], remoteTime);
    let refusals = 0;
    let preflightHolds = 0;
    let zeroPublication = false;
    const writes = f.folder.writes;
    const deadline = Date.now() + 30000;
    while (refusals === 0 && Date.now() < deadline) {
      const adapter = f.adapter();
      let preflightHeld = false;
      let unexpected: { error: unknown } | undefined;
      const scheduled: Adapter = {
        ...adapter,
        apply: async (...args) => {
          await f.nativeLink(`${f.link()}-changed-before-acceptance`);
          try {
            const applied = await adapter.apply(...args);
            if (applied === false) { preflightHeld = true; preflightHolds++; }
            return applied;
          } catch (error) {
            if (bookmarkWriterErrorCode(error) === "staleBinding") refusals++;
            else unexpected = { error };
            throw error;
          } finally { await f.nativeLink(f.link()); }
        },
      };
      const result = await f.cycle(scheduled);
      if (unexpected) throw unexpected.error;
      zeroPublication = result.published === 0;
      expect(zeroPublication && f.folder.writes === writes, "A losing local edit must publish no substitute value");
      expect(JSON.stringify(f.state.base) === beforeBase, "Native refusal must leave the whole bookmark base unadvanced");
      expect([f.key, other].every((key) => f.state.unapplied.includes(key)), "Native refusal must retain every bookmark prefix key as unapplied");
      const held = snapshot(f.profile);
      expect(held.document.nodes[f.id]?.title === "Older local", "Refused native replacement changed the desired document");
      expect(held.facts[f.key]?.seq === fact.seq, "Zero-publication refusal cleared pending native intent");
      expect((refusals as number) === 1 || preflightHeld, "The production native replacement must actually refuse the captured old link");
      if (preflightHeld) await new Promise((resolve) => setTimeout(resolve, 25));
    }
    expect(refusals === 1, "The production native replacement must actually refuse the captured old link");
    await f.cycle();
    const accepted = snapshot(f.profile);
    expect(accepted.document.nodes[f.id]?.title === "Foreign newer", "Foreign newer winner was not accepted natively");
    expect(accepted.document.nodes[other.slice(3)]?.title === "Foreign second", "Atomic whole-document acceptance omitted the second key");
    expect(!accepted.facts[f.key], "Accepted foreign winner did not settle losing native intent");
    expect([f.key, other].every((key) => !f.state.unapplied.includes(key)), "Accepted native replacement did not release every held prefix key");
    const later = await f.edit("After atomic remote acceptance");
    expect(later.facts[f.key]?.after === remoteHLC, "The first postreplacement native edit must already observe the remote record stamp");
    return { refusedNativeTransactions: refusals, preflightHolds, zeroPublication, heldPrefixKeys: [f.key, other], foreignWinner: true, atomicRecordPredecessor: later.facts[f.key]?.after };
  } finally { await f.cleanup(); }
}

async function oldLinkCannotApplyOrAck() {
  const f = await fixture("link lifetime");
  try {
    const edited = await f.edit("Current local");
    const fact = edited.facts[f.key]!;
    const adapter = f.adapter();
    const base = JSON.parse(f.state.base[f.key]!);
    const extraction = await adapter.extract(() => base, () => false, Date.now(), () => true, () => base, () => f.state.records[f.key]!.h, () => false);
    expect(extraction?.published, "The actual adapter must capture a pending native publication callback");
    await f.changeLink(`${f.link()}-new`);
    await extraction?.published?.(new Set([f.key]), new Map([[f.key, h(fact.at + 10000, f.device)]]));
    const applied = await adapter.apply(new Map([[f.key, { ...base, t: "Old link remote" }]]), new Set([f.key]), () => base, { known: () => true, stamp: () => h(fact.at + 10000, "old-chain"), now: Date.now(), horizon: 0, joined: true });
    expect(applied === false, "A revoked link must refuse old-scope document application");
    expect(await adapter.extract(() => base, () => false, Date.now(), () => true, () => base, () => f.state.records[f.key]!.h, () => false) === null, "A revoked link must hold extraction");
    const after = snapshot(f.profile);
    expect(after.document.nodes[f.id]?.title === "Current local", "Old link replaced the current native document");
    expect(after.facts[f.key]?.seq === fact.seq, "Old link acknowledged the current native fact");
    return { staleApplyRefused: applied === false, factSequenceRetained: fact.seq };
  } finally { await f.cleanup(); }
}

export async function run() {
  return {
    sameMillisecondFailedAck: await failedAckAtSameMillisecond(),
    zeroPublicationAndAtomicReplacement: await zeroPublicationRefusalAndAtomicReplacement(),
    linkLifetime: await oldLinkCannotApplyOrAck(),
  };
}
