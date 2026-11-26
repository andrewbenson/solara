# Sync redesign: the edit journal and publishing chains

Status: proposal, revised after the design review (D1–D11, against 9f61ca29), the re-review
(ten items, against b916ad7c), the final review and review5, and the re-check of ef3db5da (the
rollback audit), and its re-check (b4d491af). It replaces
the load guard described in docs/sync.md (§ After a load) as of 095f633c. Four reviews and the
convergence oracle kept finding new holes in that guard because it decides "changed here" by
comparing snapshots of the store (notes and baselines). Those snapshots are taken at the wrong time,
from the wrong inputs, or are lost with the state. This design removes that inference.

## The problem in one paragraph

A Mac's sync state (`sync-state.nns`: records, base, version vectors, seq) can come back lost
(unreadable, foreign, malformed) or older than the folder (a lost save, a restored backup, a
corrupted journal). Then two things go wrong:
- Base no longer says what this Mac last published or applied. Any local value that differs from
  it looks like an edit, and goes out stamped "now", over newer edits made elsewhere.
- The seq no longer says which numbers this Mac has used. The next batch can reuse one with
  different contents.

The current guard guesses which differences are real edits, and every guess has a counterexample.

## Invariants

1. **Only the edit journal says "changed here".** A local value or deletion is published only if
   the journal holds an entry for its `(scope, key)`. The op carries the entry's stamp. A
   difference with no entry is never published: the folder's value is applied over it, and apply
   never touches a key that has a live entry (any adapter, `adoptRemoteOnJoin` ones included). The
   one exception is a journal proven lost (§ 1, Durability). Then differences are published as a
   union bounded by the last time this Mac was in step with the folder. Device observations
   (`tabs:` of this device, pin titles and favicons) aren't edits; they're published by diff.
2. **A seq is used once per chain.** This Mac publishes under a chain id. When a load can't prove
   that its state knows every seq the chain has used, it mints a new chain before writing anything.
3. **Every hold has an age limit**, counted from when the file was first seen and kept with the file
   whatever the listing later says (pending, damaged or gone).
4. **Settling is per data type.** A type that's off isn't part of a rebuild. When it's turned on, it
   is judged by the journal.
5. **Every Solara doc that decides a claim is anchored.** A doc whose rollback could turn a value
   sync applied into a claimed edit either carries a generation that Chrome's own data also holds
   (Login Data's `meta` row for the password ledger, the bar node's `solara_shadow` for the bookmark
   shadow and intents), or rolls back in one write with the data it describes. A mismatch is a
   rebuild that claims nothing Solara could have written (§ Rollback audit).

Consequence: what a rolled-back or rebuilt Mac sends is only what its user changed, stamped by one
monotonic clock. It can't collide with a batch already written.

## 1. The local edit journal

**Entry.** `(scope, key) → { v: value | null, h: HLC, seen: digest of the record's value when the
edit was made, or null if there was no record }`, holding the latest user edit to that key. A
deletion is `v: null`.

**Which profiles** (D10, lead's rule).
- A profile deleted on this Mac drops its entries when it retires, and nothing of it is published.
- A profile whose sync is turned off, but which is kept, goes on journaling as normal.
- When its sync is turned back on, each entry publishes under the same conflict rule as passwords:
  - **No conflict:** the record's digest still equals the entry's `seen`. The edit or deletion goes
    out with its edit-time stamp.
  - **Conflict:** the record changed since. The entry goes out stamped at its edit time, and last
    writer wins. So a deletion made while off holds only if nobody touched the item elsewhere after
    it, and a rename made while off loses only to a later one.
- The same rule covers a rejoin after Stop Syncing, since the journal kept running.

**What's journaled: user commands only** (re-review 9). These are the store commands a user
action runs: settings, profiles, bookmarks, pins, groups, a history delete, and imports.
- Device observations stay outside the journal and are published by diff, as today: `tabs:<this
  device>`, and a pin's page title and favicon. No observation writes the journal, so a navigation
  never does synchronous IO.
- `tabs:<this device>` is owned by this device. A diff of it can't send another Mac's choice back.
- **Pins mix both** (final review 5). A `pin:t:` record holds observations (`ti` page title, `i`
  favicon) and choices (`g` group, `pos` position, `u` home, `t` custom title).
  - When only observation fields differ from the record, the record is published by diff, with the
    record's own choice fields.
  - When a choice field differs too and there's no journal entry, nothing is published. The
    folder's value lands first, and the next cycle publishes the observation over it.
  - So a title change never carries a stale group or position over a move made elsewhere, and a
    rolled-back Mac can't either.

**Where it lives: three files in Solara's data folder, outside `sync-state.nns`.**

| File | Holds | Written |
| --- | --- | --- |
| `sync-edits.json` | the entries; the journal generation `g`; the newest `h` | synchronously on each user command, before its gen doc |
| `sync-edits.gen` | `g`; the last in-step time `T`, with the version vector of every synced scope at `T` | right after `sync-edits.json` (same `g`), and after each in-step cycle (new `T` and vv) |
| `sync-pw-ledger.json` | per key: the last 4 digests, `h`, `modified`; the ledger generation `L` and the time `t` of its write; Login Data's inode and creation time | after every apply or publish that touches passwords, right after the meta row |
| `bookmarks-cache.json` | the shadow and its generation `G` | on every shadow write (§ Bookmarks) |
| `bookmarks-pushed.json` | intents, `node → { value, tag }` | before each push; pruned after each shadow write |
| the store's own docs (shell.docs) | each store-backed type's items, with the journal generation `g` they reflect and the ever-seen keys of those types | by the store's persist, as today, in the same write as the items |

Two more pieces live in Chrome's own data, so they roll back only with it (§ Rollback audit):
- **Login Data:** a row `solara_sync_ledger = L@t` in its `meta` table, written through SolaraCore
  **before** `sync-pw-ledger.json` (final review 1).
- **Bookmarks:** the generation `G` in the bookmark bar node's meta info (`solara_shadow`), and on
  each node whose record this Mac applied or published, that record's last origin
  (`solara_origin = device.seq`). They're written through `applyBookmarkOps`, the way the node's
  sync key already is (ac_bookmarks.cc:327-329): inside the push itself, or as a meta-only call
  after a read or a publish. Chrome's Bookmarks file holds the tree and its marks from one write. The bar node is used because this Chromium's codec doesn't persist the invisible root's
  meta info; it encodes only the three permanent folders, each with its own (bookmark_codec.cc:56-77,
  204-206), and `SetNodeMetaInfo` refuses the root outright (bookmark_model.cc:792). Extensions
  can't read or write meta info.

- **Journal check at load.**
  - `sync-edits.json` unreadable, or its `g` below the gen doc's or below the `g` the store's docs
    reflect, means a lost journal. The store's `g` is the anchor when the journal and its gen doc
    roll back together.
  - A journal ahead of the gen doc, by any amount, is valid: a crash between the two writes, or a
    gen doc rolled back alone. The gen doc is rewritten from it, and nothing falls back.
  - A missing `sync-edits.gen` with a readable journal is valid too, the same way.
  - **A lost journal with no gen doc** has no `T` and no `vv(T)`, so there's no union fallback
    (re-check 4). Nothing is published. Every key takes the folder's value, and a local item the
    folder lacks is kept, unpublished, only if its key was never seen. An ever-seen key the folder
    lacks is removed. A kept never-seen item stays local and unpublished until the user's next
    command on it journals it.
  - **A store older than `T`** is the same case (step 4 review 3). Each session save stamps the
    store with `journalT`, the last `T` this launch reached in step. If the store's `journalT` is
    below the gen doc's `T`, its docs were written before `T`, so they may hold values sync replaced
    after a backup while `vv(T)` covers those replacements. That happens when the journal and the
    store roll back together under a current gen doc. The union fallback would then publish the
    restored values over the newer ones, so it doesn't run: nothing is published, as with no gen
    doc. A comparison of journal generations can't see this, since sync applies don't move the
    journal's `g`.
    - Until a launch reaches step, its saves keep the `journalT` the store had (or 0), whether or
      not the journal was lost. A save during a "nothing" launch, or after the store alone was
      restored from a backup or a copied session.json, can't stamp an older store as current and
      turn a later loss's fallback into union.
    - `T` only moves forward: each in-step point is `max(now, floor + 1)`, where the floor starts at
      the larger of the gen doc's `T` and the store's `journalT`. A wall clock set back, even with
      the gen doc lost, can't make a store saved earlier pass for one saved later.
- **Ledger check on each read.** The meta row and the logins are read from the same copy of Login
  Data, one read of the file, so a restore between the two can't mix them.
  - **Row equal to `L@t`:** consistent; detection by ledger, below.
  - **Anything else is a mismatch, and the passwords type rebuilds** (re-check 1). That covers:
    - a row above `L`, by one or more: `sync-pw-ledger.json` rolled back, alone or with all of
      shell.docs, while Login Data didn't, or a crash between the row write and the ledger's;
    - a row below `L`, missing, or a different inode: Login Data restored, razed or replaced.
  - **A rebuild claims only what Chrome stamped after Solara's last write.** A login whose
    `date_password_modified` is later than both the row's `t` and the ledger's `t` was changed by
    the user after every write sync made, so it's an edit, stamped `Clock.at(modified)` and merged
    by the conflict rule below. Every other login is judged against the folder, and nothing of it is
    claimed: equal is seeded; different takes the folder's value; missing locally is applied from
    the folder. A login the folder has neither a record nor a tombstone for is an addition and is
    published: sync never writes a login without a record, so it can't be a value sync applied.
    Nothing is published as deleted. The ledger is then rewritten at the row's `L + 1`.
  - **This departs from "claim nothing"** on purpose. A strictly claim-nothing rebuild would apply
    the folder's value over a password the user changed after sync's last write and before the
    rebuild read it. AUDIT-pw-docs-user-edit covers it.
  - Why both times: after a docs rollback the row's `t` is the newer, so a value sync applied after
    the backup (modified at or before that write) isn't claimed. After a Login Data restore the
    ledger's `t` is the newer, so an old login carried back by the restore isn't either.
  - **What `t` is** (second re-check 1).
    - Sync's write to Login Data is applied, then `date_password_modified` is read back for every
      login the write covers. `t = max(now, the newest date read back)`, taken after that read-back.
      The max guards against the wall clock stepping back (an NTP correction) between Chrome's
      write and `t`: `t` is still at or after every date the write produced.
    - An apply whose read-back never confirms every covered login (the 5 s settle runs out) writes
      no row and no ledger. Its keys stay unapplied and are offered again next cycle.
    - Dates compare at millisecond precision with a strict "later than": a login is claimed only if
      its date, floored to the millisecond, is later than `max(row t, ledger t)`. A date in the
      same millisecond as `t` is not later.
    - Chrome stores the date as microseconds since 1601, about 1.3 × 10^16, past JavaScript's
      exact integers (2^53). The native read converts it to Unix milliseconds, floored, and never
      hands JS the raw value. Today's reader passes only `created` (SyncModule.swift:197); it gains
      `modified`.
  - **The order matters.** The row goes first, so a crash between the two writes leaves a row
    ahead of the ledger, a mismatch, never an old row that would pass.

**Durability** (D4, re-review 4).
- Write-through, in the order in the table above. The reverse order would turn a crash into a lost
  journal.
- **Last in-step time.** The end of the last cycle in which a pull completed with nothing unapplied,
  for every synced type. It's saved in `sync-edits.gen` after each such cycle, together with each
  scope's version vector at that moment, `vv(T)`.
- **Fallback on a lost journal: a union bounded by what this Mac had seen at `T`** (final review 3).
  - **A local value that differs from its record** is published at `Clock.at(T)`, but only where the
    record's origin `(device, seq)` is covered by `vv(T)`. That means this Mac had already applied
    that record when it was last in step, so the difference was made here after `T`.
  - **A record whose origin isn't covered** wins, and its value is applied, whatever its stamp says.
    That includes a late file: Mac C's 9:00 rename arriving at 10:30, after A's `T` of 10:00, still
    beats A's stale title.
  - **A local item the folder lacks** is kept and published at `Clock.at(T)` only if its key has
    never been seen in this Mac's records (the ever-seen set, below) and has no tombstone. An
    ever-seen key the folder lacks was deleted or collected, so the item is removed. The ever-seen
    set it reads is the one that rolls back with the items: in the store's docs for store-backed
    types, in Chrome's nodes for bookmarks, the ledger and Login Data's own keys for passwords. So
    an item applied by sync after a backup can't be both present and unseen.
  - Nothing is published as deleted.

**How it's written.** The store's command layer writes entries for commands not tagged
`fromSync`:
- Each command's changed entities are compared by value with what they were before, in their
  extracted form. Each changed entity maps to its sync key through the key functions the adapters
  use, moved to a shared module so they can't disagree.
- Sync applies run under `fromSync`. Settings and pins already do; bookmarks, history and profiles
  get the flag.
- **Ordering in applies** (re-review 6). A history apply does its `fromSync` store update before it
  calls `addHistoryVisits` and `deleteHistoryUrls` (adapters.ts:438-439, today it's after). The
  engine's echo then finds the store already matching, and nothing is journaled.
- **NativeStore** (D11). When it owns the workspace, the journal lives on the Swift side, which sees
  each command and its per-key `fromSync` flag. Replica revs that reach JS carry a tag per changed
  key.
- **One clock** (D9): stamps come from the sync clock.

**History** (re-review 6).
- Visits are append-only, carry their own times, and are published by the history adapter as today.
- A history delete the user makes is journaled.
- Two removals are not deletions and must never be journaled or published:
  - the store's 5,000-entry cap (store/history.ts:53, lib/history.ts `setView`);
  - Chrome's 90-day expiry. SolaraCore passes `DeletionInfo::is_from_expiration()` through, and
    expired URLs go to the adapter's ignore rule (adapters.ts:397-401), which already ignores entries
    older than the window or below the floor.

**Bookmarks: Chrome's model is the source** (D5, re-review 5). User edits made inside Chrome (the
extension `chrome.bookmarks` API, Chrome's importers) arrive only when `lib/bookmarks.ts` re-reads
the tree, and so does the echo of sync's pushes.
- **The shadow** is Chrome's tree as last read or pushed (`state.shadow`, lib/bookmarks.ts:252,
  256, 266), not the store's tree.
- Each read journals `diff(fetched, shadow)` per node, by value. The diff is taken before `readTree`
  replays pending store edits over the fetched tree (:249-251), so a concurrent extension edit is
  journaled and isn't hidden.
- **Echo filter: pushed values, recorded as intents** (abbfd475, revised for the final review's
  item 6 and the re-check's items 2 and 3).
  - The bridge keeps a **shadow generation** `G`, saved with the shadow in `bookmarks-cache.json`,
    and Chrome keeps its own copy, `solara_shadow` on the bar node (above), read back with every
    tree fetch as `G_c`.
  - **Every shadow write is one generation step, and advances `G`** (re-check 2 and 3): a push
    (lib/bookmarks.ts:256, 266) and a read that changes the shadow (:252). A read whose fetched tree
    equals the shadow writes nothing. A step, in order:
    1. for a read, write the journal entries for its diff;
    2. write an intent per node the step changes, `node → { value, tag: G + 1 }`, synchronously:
       the pushed value for a push, the fetched value for a read;
    3. call `applyBookmarkOps`: for a push its first op sets `solara_shadow = G + 1` inside the same
       grouped change, so Chrome records the generation even when a later op fails part way; for a
       read it's a meta-only call that sets just the mark;
    4. write the shadow with `G + 1`, synchronously, success or failure (a failed push writes the
       tree fetched after it);
    5. prune the intents tagged `≤ G + 1`, synchronously. A clear is never in memory only.
  - A failed push's intent therefore can't stay live: step 4 runs anyway, and step 5 clears it
    (I3-failed-push).
  - **During a session**, a fetched node equal to a live intent's value isn't journaled.
  - **Failed pushes back off** (shipped in 308bfb4f, ahead of the redesign). A push Chrome refused
    used to set `needRead`, whose replay pushed the same ops again with no delay; I3-failed-push
    counted 381 to 626 refused calls a second. Now the first failure re-reads at once, as before,
    and later ones wait 1.5 s, doubling to a minute, until a push succeeds.
- **Marks can't loop** (read, mark, change event, read). Three things stop it, any one enough:
  - Chrome sends no notification for a meta-info write that changes nothing: `SetNodeMetaInfo`
    returns before its observers when the value is the same (bookmark_model.cc:795-797).
  - SolaraCore's watcher doesn't forward meta-info changes at all. It overrides only node, move,
    reorder and removal events, not `BookmarkMetaInfoChanged` (ac_bookmarks.cc:120-150;
    bookmark_model_observer.h:105). It also drops every event while `ac_bookmarks_apply` runs
    (ac_bookmarks.cc:153, 406, 428), and a mark is only ever written inside that call.
  - The bridge marks only on a step, and a read is a step only when the fetched tree differs from
    the shadow. A meta-only change doesn't alter any node's value, so a read it caused would write
    nothing.
  - MARK-settles counts the bridge's apply and tree calls after one extension edit, then requires
    none in the next 200 ms. When the new bridge lands, the Chrome fake also emits a change event
    for every apply, meta-only ones included, so the test proves the third guard alone settles.
- **At launch, Chrome's `G_c` is compared with the cache's `G`.**
  - **Equal:** the cache is current. Intents still on disk are stale (their push never reached
    Chrome's file) and are dropped. The first read's diff is journaled like any other, so an
    extension edit made while the app was down isn't lost (RR5).
  - **`G_c = G + 1`, with intents tagged `G + 1`:** a crash after Chrome took the step's mark and
    before its shadow write (case a). A node equal to either its saved-shadow value or its intent
    isn't journaled; anything else that differs is. Either value is allowed because a push can fail
    part way after its mark: the nodes whose ops didn't land still hold their shadow value, and they
    aren't edits. For a read's step, the intents are the values it already journaled, so they
    aren't journaled again with newer stamps.
  - **Anything else** (re-check 2): `G_c` above `G` without those intents means the cache rolled
    back, alone or with all of shell.docs, while Chrome's Bookmarks didn't. `G_c` below `G`, or
    missing where the cache has one, means Chrome's Bookmarks rolled back, or its file write was
    lost in a crash. Either way **bookmarks rebuild and claim nothing**: nothing is journaled from
    this read, and every node with a record or tombstone takes the folder's value, **except a key
    with a live journal entry, which is never applied over** (second re-check 3). Chrome saves its
    Bookmarks file on a 2.5 s timer (bookmark_storage.h:40), so after a crash `G_c` below `G` is
    the common case, and the user's last edits, already journaled, would otherwise be reverted.
    Their nodes are pushed back to Chrome from the entries. A node the
    folder has neither for:
    - with a `solara_origin` was seen and has since been collected, so it's removed;
    - without one was never seen. Sync only creates nodes with their origin in the same call, so
      it isn't a value sync applied; it's journaled as an addition and published.
    The rebuild's first shadow write sets both generations.
  - **Upgrade:** no `G_c` and no cache generation, so the first read is a claim-nothing rebuild.
  - So an extension setting a node back to an old pushed value (case b) is journaled like any other
    edit: its intent's tag is at or below `G` and was pruned.
- **A launch diff keeps an existing stamp** (second re-check 4). A node whose launch value equals a live
  journal entry's `v`, or equals its record where the record's origin is any chain of this device
  (already published), isn't given a launch-time stamp: the live entry stays as it is, and a published value
  needs no entry. The case: a crash after a read step wrote its entries but before Chrome saved its
  mark. The launch re-reads the same edit, and a fresh stamp would put it over a newer edit made
  elsewhere since.
- **Why a read marks Chrome too.** Without it, a cache rolled back across reads only (no push)
  would still match `G_c`, and its older shadow would re-journal extension edits already published,
  with new stamps, over a rename made elsewhere since. A crash between a read's step 2 and its step
  4 is case (a), not a rebuild, so an extension edit made while the app was down is still read and
  journaled (RR5).

**Passwords: Chrome's Login Data is the source** (D1–D3, re-review 1–3).
- **Ledger.** `pwLedger`, kept in Solara's data folder:
  - `key → { digests: the last 4 digests seen for this key, newest first; h: the record's h when
    last published or applied; modified }`, where `modified` is `date_password_modified` read back
    after sync's write;
  - plus a ledger generation.
- **Login Data generation.** Whenever the ledger changes, its generation is also written into Login
  Data's own `meta` table (`solara_sync_ledger`), through a new SolaraCore call
  (`ac_passwords_mark`). Each read compares the two.
  - A mismatch means Login Data was restored, replaced or razed under the ledger. The inode and
    creation time can't see an in-place restore (`cp`, `rsync --inplace`); the meta row can.
  - The row also catches the reverse: the ledger rolled back (alone or with all of shell.docs)
    while Login Data didn't leaves the row ahead of `L`.
  - Any mismatch rebuilds the passwords type under the rule in the ledger check above: only a login
    Chrome stamped after both write times is claimed, everything else is judged against the folder,
    and nothing is published as deleted.
- **Equal to its record is never an edit** (second re-check 2). A local login whose digest equals its
  current record's is seeded into the ledger and never published, whether or not the ledger had
  the key, in a rebuild or not. That covers an apply whose read-back didn't confirm (no row was
  written, so the next read sees the applied value as new to the ledger).
- **Detection by ledger**, on each read:
  - **Addition:** a key not in the ledger.
  - **Deletion:** a ledger key missing locally.
  - **Edit:** a key whose digest isn't the ledger's newest.
  - **A digest matching an older one of the last 4** (final review 2) can be either case:
    - **A rollback:** an older copy of Login Data carries its old date, so `date_password_modified`
      is at or before the ledger's `modified`. It takes the folder's value.
    - **A deliberate revert:** a user going back to an earlier password gets `Now()` from Chrome,
      later than the ledger's `modified`. It's an edit like any other.
    Both dates come from this Mac's own clock, so skew doesn't enter.
- **Conflicts are decided by value** (re-review 3). For a deletion or an edit:
  - **No conflict** when the record's current digest equals the ledger's newest, meaning nothing
    elsewhere changed it since this Mac last agreed. The change is stamped
    `max(Clock.at(min(modified, now)), successor of the record's h)`. For a deletion, `modified` is
    the time of the read that noticed it.
  - **Conflict** when the record's digest differs. An edit is then stamped `Clock.at(modified)` (its
    real time) and merged by last writer wins against the record. A password changed here on day 1
    while unreadable loses to B's change on day 2.
  - **A conflicting deletion is dropped**: the login is applied back from the folder. A deletion
    goes out only over the value it removed. Another Mac republishing that same value (same digest,
    new `h`) is not a conflict, and the deletion still goes out.
- **Mass changes** (re-review 2). A read is judged per key.
  - The first time a read drops or edits more than half the ledger's keys (and more than 5),
    those keys are held, not published.
  - The Sync pane asks: "N passwords were removed or changed on this Mac. Remove or change them on
    your other Macs too, or restore them here?" The default is restore. Restore applies the folder's
    values; confirm publishes the held changes.
  - Keys under the threshold are published as usual. There's no "couldn't be read" message for this
    case.
- **Apply uses the ledger** (D3). `passwordsAdapter.apply` (adapters.ts:521) skips a login only
  while the ledger says it has an unpublished change here, never because of base.
- **Upgrade** (re-review 3).
  - A login equal to its record is seeded into the ledger.
  - A login that differs is claimed as an edit only if its `date_password_modified` is later than the
    record's wall time, from `h`; it's stamped `Clock.at(modified)`. Otherwise it takes the folder's
    value.
  - A login with no record is an addition.

**Extensions** already record intents (`host.intents()`). Those become their journal entries.

**Clearing an entry.** An entry is cleared when the op carrying exactly its `(key, h)` has been
written to the folder. A newer edit replaces the entry, so the clear leaves it alone. A crash between
the write and the clear re-sends the same op, which changes nothing.

**Publishing.** For each entry of an adapter's prefix, `publishAdapter` publishes `{k, h: entry.h,
v: entry.v}`, the value the command wrote, not the store's current value. A store doc rolled back
under a current journal therefore can't send an older value under a newer stamp; once the entry
clears, the store takes the folder's value like any other key. If the record already has `h >= entry.h`, the entry is stale and is
cleared. Observation keys (above) are still published by diff.
- **Bookmark positions** (D6, re-review 10) come from the records first and fall back to base, so a
  lost base never renumbers.

**Applying.** Every key with a difference and no live entry takes the folder's value. A key with a
live entry is never applied over, in any adapter (D11).
- **No adapter can skip a key and report success** (review5 P1).
  - `Adapter.apply` returns the set of keys it actually wrote, not a boolean. `applyAdapter` sets
    base and clears `unapplied` only for those. Every other key stays unapplied and is offered again
    next cycle.
  - **A key already equal to the folder's value counts as written** (re-check 5). Nothing needed
    writing, so it's applied; otherwise it would stay unapplied forever.
  - Today two adapters skip a key and return ok:
    - the passwords adapter's conflict check (adapters.ts:521, 538), after which `applyAdapter` sets
      base to the remote value (scope.ts:347-350) and the next look republishes the local one;
    - the pinned homes adapter `pgh:` (pinned.ts), found by inspection.
  - With the returned set, that sequence is impossible in any adapter. Passwords skip only for a
    live ledger change here, so those keys are published, not marked applied.
- **Bookmarks apply** (D7, re-review 10, final review 4) rebuilds the tree from what's visible. A
  local node that isn't visible is removed only when one of these holds:
  - its key has a tombstone in the records;
  - its key is in the **ever-seen set** with a saved origin `(device, seq)` that the current vv
    covers, and the record is gone. For bookmarks the set is the nodes' own `solara_origin` meta
    info in Chrome's tree, so it rolls back exactly with the nodes. A crash between a publish and
    its mark leaves the node unmarked until the next cycle, which finds the record and marks it. For store-backed types it is kept in the store's docs beside the
    items (the file table).
  Any other invisible node is kept: one never seen, or one whose origin's file hasn't arrived yet.
- So after a state loss:
  - a bookmark deleted elsewhere is removed once the file or snapshot that covers it has arrived,
    even when compaction collected its tombstone (45 days);
  - a bookmark whose file is still downloading is kept, however long the hold lasted;
  - a new local bookmark nobody has seen is kept.

**Joining and first sync** (re-review 8).
- When sync is turned on, or a profile or type is first linked, existing local items get entries
  stamped `Clock.at(editedAt)` where an item has one, else the turn-on time. On a rejoin, an
  existing newer entry is kept (D10).
- **Except the `adoptRemoteOnJoin` adapters** (`set:`, `prof:`, `pth:`, `share:`, `devmode:`): they
  get no seeded entries, so a joining Mac adopts the synced settings and profile names instead of
  overwriting everyone's with its own. A user command run during the join is journaled as an edit
  like any other.
- Passwords join through the ledger's upgrade mode, the same rule as a first run (§ 1, Upgrade): an
  equal login is seeded; a differing one is claimed only if Chrome modified it after the record's
  wall time, otherwise it takes the folder's value; a login the folder lacks is an addition. The
  ledger records the join it was written for (the folder, this join's device id and setup time,
  and the profile's sync id), so after Stop Syncing, a new folder or a rejoin that keeps the
  profile's sync id (step 10), an old ledger is never trusted and every login is judged again.

## 2. Publishing chains

- `doc.deviceId` stays the device's identity for `dev:` records, the device name and its tabs.
- Batches are published under `chain = <deviceId>.<n>`. vv, extra and seq are kept per chain. A chain
  is just another device string, so there's no format change for readers.
- **The chain is kept at load only when the state proves it is current.** All of these must hold:
  - the sealed state loaded, and its batch journal is readable;
  - after the first pull, `vv[chain]` doesn't exceed the state's seq, and no snapshot's vv does;
  - the first pull lists no file unknown to the state as pending or damaged;
  - the phrase wasn't just re-entered, and this is the Mac that `deviceId` was minted on (D8,
    re-review 7).
- **Twins.** The sync key's Keychain item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  but it is saved without `kSecUseDataProtectionKeychain` (SyncKeyStore.swift:16-21, 41). So it
  lives in the file-based login keychain, and Migration Assistant and disk clones carry it.
  The owner approved moving the item to the data-protection keychain (2026-10-27); that's step 13,
  after this redesign ships, so the redesign doesn't rely on it.
  - Instead, `deviceId` is saved with the Mac's `IOPlatformUUID`. At load, a different
    `IOPlatformUUID` means a copied Mac. It mints a new `deviceId` (a new identity for its `dev:`
    record and tabs) and a new chain. The original keeps both.
- Otherwise a new chain is minted before the first write. Re-sends (the batch journal, an older
  build's revived batches) keep their ops and stamps and get new seqs under the new chain.
- **A healthy Mac never waits.** It publishes in its first cycle, under its old chain if the checks
  pass, under a new one otherwise. Nothing holds publishing to protect seqs.
- **Cost:** one vv entry per load that can't prove currency. A placeholder at launch is common, so
  that will be frequent. A retired chain's vv entry is dropped from snapshots once no log of it is
  left and it is past the tombstone hold (90 days).

## 3. Holds, all bounded

One hold remains: a rebuilding type doesn't apply while its pull is incomplete.
- Each unreadable file the state doesn't know gets a first-seen time, saved in the state and kept
  whatever its listing says, including pending after damaged (Q1).
- After 10 minutes a file stops holding anything. The type then applies what it has. Under the
  bookmarks apply rule, an invisible node is removed only on a tombstone, or when the vv covers its
  last origin. A node whose file is still pending isn't covered, so it stays. Nothing local is
  published as deleted without a journal entry.
- The Sync pane shows "Waiting for N files" until a file arrives or is given up after a day.
- A healthy Mac is never under this hold.

## Timing rules for adapters

Three reviews in a row found the same kind of bug: a throttle or a gate that, under some sequence,
never opens again (step 1's password livelock, 3a's quiet-forever, and 3a's pull gate removed then
needed back). So every adapter follows one model, and its tests check each rule.

- **Throttled reads.** An adapter that reads an expensive source (Login Data, Chrome's history) may
  skip a read for a minimum interval (passwords: 30 s). The skip is only ever a delay:
  - a forced read (Sync Now, a resolved prompt, a cycle the engine marks forced) always reads,
    whatever the interval or quiet window says;
  - nothing else can set the next allowed read further out than one interval from now.
- **The quiet window.** After an apply whose read-back didn't confirm, reads pause (passwords: 30 s)
  so the source can finish writing. The window opens only when a key fails to confirm that didn't
  fail last time. A key that keeps failing doesn't reopen it, and a forced read passes it. A key that
  never confirms stays unapplied and is retried each cycle. It never holds the adapter's other keys.
- **Settle waits.** An apply may wait for its read-back (passwords: up to 5 s, 250 ms steps). It
  waits only for keys it wrote. A key it skipped (kept here, held, claimed) is never waited on.
- **The pull gate.** An adapter that claims changes by comparing local data with records never
  publishes before the cycle's pull (`publishOnlyAfterPull`). While a file first seen less than 10
  minutes ago is pending or damaged, the adapter's `extract` gets `downloading() === true` and holds
  back only its deletions. Edits and additions go out: last writer wins settles them the same way
  whether the other Mac's file is pending or visible, while a deletion stamped at read time would
  beat an edit still downloading (3a's pending-delete). A held deletion stays a live claim, so apply
  doesn't write the folder's value over it, and the next judgement decides it again. Past the
  10-minute first-seen limit (§ 3) `downloading()` is false and the deletion goes out (GATE-bound).
  The gate lives in `extract`, not around it: skipping `extract` while files hid left the adapter's
  claims stale and starved publishing (oracle seeds 22, 39, 198).
  - First-seen is when this Mac noticed the file, not the other Mac's stamp, so comparing a claim's
    stamp with it decides nothing; no such comparison is made.
  - An addition over a tombstone still downloading is stamped at its own modified time, or after
    the tombstone once the tombstone is visible. The two orders give different stamps for the
    addition, and both converge on the addition.
- **Persisted holds.** A hold that waits on the user (the mass-change prompt) is saved, and is
  lifted only by the user's choice or by the held change disappearing. Its size isn't recomputed
  against a changing denominator.
- **Every gate has a test** that drives the sequence keeping it shut (a key that never confirms,
  a cycle period shorter than the window, a pending file) and requires the adapter to make
  progress within a bounded number of cycles.

## 4. Per-type settle

- A rebuild is per data type: `rebuild.types` lists the types still rebuilding.
- A type settles once its pull is complete or past its limit, its adapters have extracted, and
  nothing of it is unapplied. For passwords, "unapplied" is judged against the ledger, so a lost base
  can't keep it from settling (R-unapplied).
- A type that's off isn't listed. Turning it on adds it, and it is judged by the journal.
- The marker is deleted when the list is empty.

## Clocks (D9)

- **One clock per Mac.** The journal, the scopes and `doc.clock` share it.
- **Counter overflow.** The HLC counter is 4 base-36 digits. Today, past `zzzz` it becomes `10000`,
  which sorts below `zzzz`. /private/tmp/design-review/hlc-counter-overflow.test.mjs shows that
  after 1,679,614 ticks behind a stamp in 2030, reachable because the clock ticks on every
  observation. The fix: on overflow, the clock carries into the wall time (`wall + 1 ms`, counter 0).
  That keeps the format and stays monotonic.
- **Skew** isn't bounded by anything here. A Mac whose wall clock runs ahead wins concurrent edits
  until the others observe its stamps, as today (docs/sync.md § Clock skew). The earlier claim that
  it's "bounded to that skew" was wrong and is withdrawn.

## Semantics, stated

- **Per record, last writer wins.** Two Macs editing different fields of one record (a bookmark's
  title on one, its folder on the other) keep only the later record whole.
- **A password rename** is published as the old key's deletion plus a new key. If another Mac
  changes the old login's password meanwhile, the deletion conflicts by value and is dropped. Both
  logins then survive, the renamed one and the changed one. Nothing is lost, and the user sees two
  entries.
- **A long-offline Mac's edit** has its edit-time stamp, so it loses to a later edit elsewhere. A
  password change that conflicts with a change elsewhere is decided by its real modified time too.
  A non-conflicting one is stamped after the record it replaces.

## Migration

- **Journal at upgrade.** It starts empty, and no edits are claimed. An older build's edits that
  weren't published before the upgrade are taken as stale. That includes edits made during an
  old-format rebuild (B-old). It's a one-time window of a few seconds, since an old build publishes
  within 3 s of an edit. The lead accepted it. guard-review2's B-old repro stays red as the record
  of it, named EXPECTED RED.
- **Password ledger at upgrade.**
  - Seeded from keys equal to their record.
  - A differing login is claimed only if Chrome modified it after the record's time (§ 1).
  - Login Data's `meta` generation is written on the first ledger write.
- `doc.rebuilding`, `rebuildBaseline`, `rebuild.noted` and `heldOutbox` are read and then dropped.
- **Older builds.** sync.json's `v` is bumped, so older builds (from 5b76b1f6 on) leave it alone, as
  in B35. Builds before 5b76b1f6 can't be guarded. Downgrading past it is unsupported.

## What's removed

- From the guard: the launch and load notes, `baselines`, `notedFor`, `keepNotes`,
  `noteDelivered`/`fromFolder`, `changedHere`, `backToBase`, `heldBack`,
  `EDITABLE_WHILE_UNREADABLE`, the fresh download hold and the stand-in base.
- The guard keeps pull-first on a fresh load, re-sending batches under the current chain, and
  per-type settle.

## Checked: Chromium's `date_password_modified`

Read in this tree's Chromium (`components/password_manager/core/browser`). Every path that changes a
password sets it to `Now()`:
- add (saved_passwords_presenter.cc:88-89);
- edit (:857-861);
- form saves, including the change-password and generated-password flows (form_saver_impl.cc:86,
  127, 139, 157);
- CSV import, both new logins and replaced conflicts (password_importer.cc:648, through the
  presenter).

A username-only edit keeps the old date and lands under a new key (:870-874). The design doesn't
rely on the date: detection is by ledger and stamping by the sync clock.

## Checked: store paths that bypass or echo through the journal

| Path | Handling |
| --- | --- |
| Launch hydrate (`browser.ts hydrate`) | not a command, so not journaled |
| Bookmarks re-read from Chrome's model (`lib/bookmarks.ts`), including extension and importer edits | diff of fetched against Chrome's last-read-or-pushed tree, before the replay; pushed-values echo filter; first read journaled like any other, with the shadow saved synchronously |
| History view (`lib/history.ts setView`): cap eviction and Chrome's 90-day expiry | not journaled; the adapter's ignore rule; `is_from_expiration` passed through |
| History apply echo | `fromSync` update before the engine calls |
| NativeStore replica revs | per-key tags; journal on the Swift side |
| Imports (`SolaraUI/Import` (E7a draft; formerly `components/import/apply.ts`)) | commands are journaled; passwords through the ledger |
| `tabs:` of this device, pin page title and favicon | observations: published by diff, never journaled |
| `bookmarksReady`, `historyReady` and other flags | no sync key, ignored |

## Holes I still see

- **A missed command path.** A user edit that bypasses the command layer is never published. Each
  native path above gets a test.
- **Login Data `meta` writes: checked in Chromium, they work but need an engine patch.**
  - `sql::MetaTable` (sql/meta_table.cc) is a plain key/value table. `Init` only creates it if it's
    missing (:153), `SetValue` inserts or replaces one key (:204), and nothing in
    `LoginDatabase::Init`, its migrations (:1196-1240, `FixVersionIfNeeded` :916) or its version
    checks (:1148-1160) touches keys other than the version pair. So a custom row survives
    migrations and version checks.
  - `DeleteAndRecreateDatabaseFile` (:1908-1929) deletes the file, row included. Its one caller is
    Chrome Sync's bridge (password_sync_bridge.cc:942), which Solara never runs. If it ever did, the
    missing row reads as a mismatch, which is the safe outcome.
  - A database too new for this Chrome fails `Init` (:1154): passwords are unreadable, not mismatched.
  - Login Data is opened with exclusive locking (`DatabaseOptions` default, sql/database.h:350), so
    a second SQLite connection can't write it while Chrome runs. The row has to be written through
    Chrome's own `LoginDatabase`, as an engine patch that adds a method reaching `meta_table_` on the
    password store's sequence, exposed as `ac_passwords_mark`. That's one more patch in the series.
- **Bookmark marks need an engine change, not a Chromium patch.** `ac_bookmarks_apply` gains an op
  that sets meta info on a node (`solara_shadow` on the bar node, `solara_origin` on any node), and
  `ac_bookmarks_tree` returns the bar node's `solara_shadow`. Both are in our own
  engine/chromium/src/chrome/browser/solara/ac_bookmarks.cc, which already reads and writes a node's
  sync key through meta info (:59, :327-329). Meta info is saved in Chrome's Bookmarks file with
  each node (bookmark_codec.cc:204-206), and the extensions API doesn't expose it.
- **Chrome's own cleanup of undecryptable logins.** With `kClearUndecryptablePasswords` on,
  `LoginDatabase` deletes logins it can't decrypt (login_database.cc:2266). It doesn't when Chrome
  runs with `--user-data-dir` (:1036). Solara always passes it (SolaraCoreHost.mm:638), and SolaraCore
  refuses to start without it (ac_main_delegate.cc:410). The ledger would read such a cleanup as
  deletions, so the dependency is pinned by a test that checks both lines (FR6).
- **Keychain class.** Twins are handled by `IOPlatformUUID`; the item still copies with the Mac.
  The owner approved moving it to the data-protection keychain (2026-10-27), after this redesign
  ships: step 13.
- **The mass-change prompt** waits on the user. Until they answer, the held keys aren't published,
  and the folder's values aren't applied over them.

## Rollback audit

The rule (re-check 6): a Solara doc whose rollback could turn a value sync applied into a claimed
edit is anchored in Chrome's own data, or its mismatch is a rebuild that claims nothing. Each doc is
taken three ways: rolled back alone; all of shell.docs rolled back while Chrome's data (Login Data,
the Bookmarks model, History) stays current; and the reverse, Chrome's data rolled back while
shell.docs stays current.

| Doc | Alone | All of shell.docs | Chrome's data instead | Anchor or rule | Tests |
| --- | --- | --- | --- | --- | --- |
| `sync-edits.json` (journal) | its `g` is below the gen doc's or the store's: a lost journal, so the vv(T)-bounded fallback. A value sync applied equals its record, so there's no difference to claim | rolls back with the store, ever-seen and state: one older snapshot. Revived entries lose to any record with `h ≥` theirs; a new chain is minted (I2) | not involved: Chrome-side changes are judged by the ledger and the shadow rows | the store's `g`; gen doc | guard-review r2, r4, A, A2, A3; RR4, FR3 |
| `sync-edits.gen` | the journal is ahead of it: valid, and the gen doc is rewritten. Nothing falls back | as the journal | not involved | none needed: it can only start the fallback, never claim | needs the journal (no gen doc today) |
| journal and gen doc together, store current | the store's `g` is above the journal's: a lost journal | — | — | the store's `g` | needs the journal |
| lost journal, no gen doc | no `T`: publish nothing; keep only never-seen keys (re-check 4) | — | — | rule | needs the journal |
| `sync-pw-ledger.json` | the row is above `L`: rebuild; only logins Chrome stamped after both write times are claimed | the same: the ledger is in shell.docs, so P1's "p3 equals the ledger" doesn't hold and P1 rebuilds | the row is below `L`, missing, or another inode: the same rebuild | Login Data's `meta` row `L@t` | P1, P1b (row at `L + 1`), AUDIT-pw-docs-two-writes (`L + 2`), seed 32144; FR1, RR1, D2a/b |
| `bookmarks-cache.json` (shadow, `G`) | `G_c` is above `G`: claim-nothing rebuild | the same, with the journal and intents rolled back too | `G_c` is below `G`: the same rebuild | `solara_shadow` on the bar node | AUDIT-docs-all, AUDIT-chrome-bookmarks; RR5-stale-cache |
| `bookmarks-pushed.json` (intents) | an older table's intents are at or below `G` and are dropped; a missing crash intent leaves `G_c = G + 1` without its intents: rebuild | as the cache | as the cache | `solara_shadow`; every shadow write prunes | I6a, I6b, I3-failed-push |
| ever-seen, bookmarks | lives on Chrome's nodes, so it can't roll back apart from them | not in shell.docs | rolls back with the nodes it describes | `solara_origin` per node | RR10, FR4 |
| ever-seen, store-backed types | lives in the store's docs with the items, same write | rolls back with the items: an item sync applied after the backup is absent from both | not involved | same write as the items | D7a, RR10 |
| store docs (items, `g`) | older values with no entry take the folder's value; an entry publishes its own `v`, not the store's | as the journal row | not involved | entries carry `v` | guard-review3 r1, r1b; D4a/b |
| `sync-state.nns` | own seqs or a snapshot above its seq: new chain. Publishing reads the journal, not base, so a lost base claims nothing | as the journal row | not involved | I2's checks | revsync4 R-rollback, R-rollback-outbox; guard-review r1, E; seed 35309; D8, RR7 |
| `sync.json` (sync on, types, per-profile links and opt-outs, device id, clock, joining) | today, a real loss path: a profile created after the backup has no link, so `linkProfiles` mints a new sync id (engine.ts:880) and the profile is published twice; a type or profile turned off after the backup quietly resumes, passwords included | consistent with the store, but a type turned off after the backup still resumes for Chrome-backed data | not involved | each profile's sync id and its "kept out of sync" flag live on the profile in the store's docs; every opt-out is also written beside the data it governs (below); each toggle has a monotonic counter in both copies and the higher counter wins; a missing anchor is no decision; a new sync id is minted only when neither copy has one | AUDIT-syncjson-profile, -type-off, -profile-off (red on HEAD), SPEC-opt-out |
| `sync-journal.nns` (batches not yet confirmed in the folder) | older batches come back and are re-sent with their own ops and stamps, under new seqs of the current chain, so they lose to anything newer; batches missing from it still have their journal entries, which are cleared only once their op is in the folder, so they're published again | as alone | not involved | rule: re-sends keep stamps, never seqs; entries outlive batches | guard-review r1, E; seed 35309; D4a/b |
| extension intents (`sync-extensions.json` today) | folded into `sync-edits.json`: each intent is a journal entry with its stamp, so it rolls back with the journal and is caught by the journal row. Chrome's own queue is in memory and cleared on read (ac_extensions_sync.cc:295), so the file is the only record | as the journal | an extension restored by a Chrome profile restore differs from its record with no entry: the folder's value applies | the journal row | needs the journal |
| `pinChoices`, `pinSync` (store) | `pinChoices` is a per-pin queue of the user's choices waiting to publish (pinned.ts:494-500): folded into the journal as entries and removed from the store. `pinSync` notes a pin whose record names a group this Mac hasn't received (pinned.ts:207-222, 313-319, 424): the pin shows standalone, and extraction keeps publishing the record's group for up to the 90-day horizon, then republishes the pin standalone (pinned.ts:110, 210). Dropped, since only journaled choices publish: the standalone display is an apply, not a command, so it's never published. The record keeps naming the group for good, and the Macs differ only in display (this Mac shows the pin standalone until the group arrives). The 90-day standalone republish goes away with it | as the journal | not involved | the journal row | FR5 |
| History (Chrome) | — | visits are unions with their own times; a republished visit set adds nothing new; a revived delete entry loses to the visit records after it | visits missing after a restore are never published as deleted (deletions are journaled commands only); the folder's visits are applied back | rule: no inferred deletions | AUDIT-history-restore; RR6 |

**Where each opt-out is anchored** (second re-check 5, revised by the third). Each toggle (sync on,
each type, each profile's "kept out of sync") carries a monotonic counter, bumped on every change.
The toggle and its counter are written to sync.json and beside the data the toggle governs, in the
same write as that data:
- store-backed types and the per-profile flag: the store's docs (the settings doc, the profile);
- passwords: Login Data's `meta` row gains `solara_sync_off`;
- bookmarks: the bar node's meta info gains `solara_sync_off`;
- history: History's own `meta` table (`sql::MetaTable`, as for Login Data) gains `solara_sync_off`,
  through a new SolaraCore call;
- extensions: the profile's Chrome prefs.
- **The effective state is the copy with the higher counter.** A rollback of either copy carries a
  lower counter and loses, in both directions: a sync.json rolled back to "on" doesn't resume a
  type turned off since, and one rolled back to "off" doesn't stop sync silently.
- **A missing anchor is no decision.** A settings doc that was reset (persist.ts reads it as null),
  or a Chrome profile not loaded yet, defers to sync.json. A missing anchor never means off.
- **An anchor is rewritten when it lags.** A type re-enabled while one Chrome profile is unloaded
  leaves that profile's anchor at the older counter; when the profile loads, the higher counter in
  sync.json wins and the anchor is brought up to it.
- **When the two copies disagree** after that resolution (equal counters, different values), the
  Sync pane says so and asks, and the type stays off until answered.
- **The anchor fields never sync.** They're kept out of `SYNCED_SETTINGS` and out of `prof:`
  records, so one Mac's toggle counters never reach another.
- **Sync ids.** Each profile's sync id is kept on the profile and in sync.json. A new one is minted
  only when neither has one, so a rolled-back sync.json takes the profile's id instead of minting.

Residuals the audit leaves, from this Mac's own clock or Chrome's lack of edit times:
- **Passwords, clock set back:** a user's change after Solara's last write can carry a
  `date_password_modified` before it. A rebuild then takes the folder's value over it.
- **Passwords, username-only rename during a rebuild:** Chrome keeps the old date under the new key
  (saved_passwords_presenter.cc:870-874). The new key has no record, so it's published as an
  addition, and the old key, missing locally, is applied back from the folder. The user sees both
  logins. Nothing is lost.
- **Bookmarks:** Chrome keeps no modified time for a title or URL, so a claim-nothing rebuild loses
  an extension or importer edit to an existing node made after the last mark and not yet read. A
  new node isn't lost: it has no origin, so it's published. Reads run on Chrome's change events, so
  the window is the time from the edit to the next read, or the time the app was down when Chrome's
  Bookmarks or shell.docs were restored.

## Repros mapped to the design

| Repro | What it shows | Removed by |
| --- | --- | --- |
| revsync4 R-baseline | baseline taken before stores are ready | invariant 1: no baseline |
| revsync4 R-passwords | rebuilt passwords republish the old one | ledger detection, ledger apply (D1–D3) |
| revsync4 R-unapplied | rebuild ends with keys unapplied; for passwords it never settles after a loss | per-type settle judged by the ledger (D3) |
| revsync4 R-lock | throw during baseline capture locks the Mac | no capture step |
| revsync4 R-pending | pending file holds the rebuild for 24 h | hold limited to 10 minutes, with the D7 apply rule |
| revsync4 R-rollback | readable rollback keeps the old base | invariant 1 |
| revsync4 R-rollback-outbox | rollback outbox reuses a seq | invariant 2 |
| guard-review r1 | rollback, own batch pending, seq reused | invariant 2: pending at first pull, so a new chain |
| guard-review r2 | relaunch undoes edits made after the loss | write-through journal with generation (D4) |
| guard-review r3 | healthy relaunch reverts the latest choice | write-through entry carries the edit's stamp (D4) |
| guard-review r4 | rollback, remote pending, stale resend | invariant 1 |
| guard-review2 A, A2, A3 | rollback after compaction resends stale | invariant 1; A is also a new chain |
| guard-review2 B-old | old-format rebuild loses an edit | migration window (accepted, one-time) |
| guard-review2 C1 | marker open while a type is off | per-type settle |
| guard-review2 C2 | edit while the type is off is overwritten | invariant 1 and per-type settle |
| guard-review2 D | stubbed note misses the shared profile | invariant 1: no note |
| guard-review2 E | own batch pending past 10 minutes, seq reused | invariant 2 |
| guard-review3 r1, r1b | setting chosen while unlocking or locked is lost | write-through journal at edit time |
| guard-review3 r2 | launch note stuck behind passwords | no note |
| guard-review3 r3 | passwords read with the type off | no note; passwords read only when on |
| guard-review3 r4 | launch cost with large history | no note |
| guard-review4 Q1 | damaged-then-pending holds applies forever | per-file first-seen age |
| guard-review4 Q3, Q3-pre | rolled-back password resent over newer | ledger outside the sync state; detection by digest; apply by ledger (D1–D3) |
| oracle 35309 | corrupt sync journal, seq reused | invariant 2 |
| oracle 25066 / B70 | partial apply wipes bookmarks, published as deleted | D7 apply rule; invariant 1 |
| oracle 43, 212, 390, 398 (strict) | tie repair rewrites whole records | separate tie-by-key fix |
| design review, HLC overflow | counter past `zzzz` sorts low | carry into wall time (D9) |
| review5 P1, P1b, oracle 32144 | all of shell.docs rolled back, so base and ledger both say p1; Login Data has p3 from sync's apply after the backup; B's p2: p3 ends everywhere | the ledger rolls back with the rest, so the row is at `L + 1`: a mismatch. Passwords rebuild; p3 was modified before the row's write time, so it isn't claimed, and p2 applies. Apply returns written keys |
| AUDIT-pw-docs-two-writes | the same two writes behind (row at `L + 2`) | the same rebuild; no rule special-cases a distance |
| AUDIT-docs-all | all of shell.docs rolled back with bookmarks; R1 applied by sync after the backup | `G_c` above the cache's `G`: claim-nothing rebuild, so R1 isn't journaled and B's R2 applies |
| AUDIT-chrome-bookmarks | Chrome's Bookmarks rolled back, shell.docs current | `G_c` below `G`: the same rebuild; the older title takes the folder's value |
| AUDIT-history-restore | Chrome's History rolled back to before some visits | no deletion without a journaled command; the folder's visits are applied back |
| review5 A3, A3s | rename or setting made during the 10-minute wait, then a relaunch inside it, reverted to B's older value | no wait; the edit is journaled at command time |
| review5 A1 | one stuck download holds every launch for 10 minutes | no wait |
| review5 C1 | reused seq, then a peer's compaction, deletes the user's own new bookmark | new chain (no reuse); the bookmarks apply removes a node only on a tombstone or a covered origin |
| review5 D1 | a rolled-back state with bookmarks off at launch republishes R1, taken from B after the backup, over B's R2 once bookmarks are turned on | no first look, and the turned-on type is judged by the journal. The journal alone isn't enough (re-check 2): the restore rolled back `bookmarks-cache.json` too, so R1 would read as an extension edit. Chrome's `solara_shadow` is above the cache's `G`, so bookmarks rebuild and claim nothing, and R2 applies |
| oracle 40636 | a healthy relaunch takes a coincident password for a rollback | detection by ledger, not by delivered values |
| oracle 35309 (review5: a stale batch-journal replay flushed before the pull) | seq reused | new chain: the replayed ops keep their stamps under new seqs, and their old stamps lose to anything newer |
| final review item 6 (a), (b) | pushed-values crash window; stale intent reverts an extension edit | intent before the push, shadow generations, persisted pruning |

## Today's accepted residuals

| Residual (as of 095f633c) | Under this design |
| --- | --- |
| Healthy Mac waits up to 10 minutes at launch | Gone: no seq hold; a new chain when currency is unproven |
| Healthy relaunch: a setting matching another Mac's unpulled old value is taken for a rollback (R3) | Gone: journal entry, not value comparison |
| Rolled-back state resends an older password (Q3, Q3-pre) | Gone: ledger detection and apply |
| Passwords saved while unreadable taken as stale | Gone: the ledger sees the change whenever passwords become readable |
| Rollback after compaction undetected (A2) | Gone: no detection needed |
| Old-format rebuild loses its baseline (B-old) | One-time migration window; the old build kept no record |
| Own batch downloading past 10 minutes reuses its seq (E) | Gone: new chain |
| Marker open while a type is off (C1) | Gone: per-type settle |
| Seed 35309 | Gone: new chain |
| Tombstones dropped after 45 days | Narrower: a returning Mac sends only journaled edits, and D7 removes collected deletions. A log replayed after the hold can still bring one back, as today |
| Tie repair rewrites records | Separate tie-by-key fix |

## Test plan

Every repro above is a failing-first test, and so is each finding. The suite is tracked in
apps/browser/src/sync/redesign/ and runs with `pnpm test`. Each test red on HEAD is marked
`{ todo: "step N" }` (§ Implementation plan); the oracle seeds run from `oracle-seeds.test.mjs`.

Harness notes:
- **Bookmarks with the engine** (rr5-bridge-engine.test.mjs) runs the real `lib/bookmarks.ts` over
  the Chrome bookmark fake, together with the engine. A gate on the fake's `ac_bookmarks_apply`
  holds an app edit pending.
- **The setTimeout shim.** The engine harness stubs `setTimeout` to return 0 and never fire. The
  bridge saves its cache at stop only when `cacheTimer` is truthy, so under that stub the cache is
  never written, and the first launch read replays the whole stale store over Chrome. That made a
  fake red result. Any test running the bridge must return a non-zero id for the 2 s cache timer
  (without firing it), and must let the 5 ms `reloadBookmarks` wait run on real time.
- **RR5 and RR5-stale-cache are guards.** They're green on today's bridge, which has no restore tag.
  The new code must keep them green. RR5-stale-cache also checks that a stale shadow doesn't resend
  this Mac's own pushed value.
- **D1:** a username-only rename survives an older tombstone of the new key, and a change here wins
  over a clock running an hour ahead.
- **D2:** Login Data losing most logins doesn't delete them everywhere.
- **D3:** with base lost, a differing login is applied and the type settles.
- **D4:** an edit just before a crash is published.
- **D6:** a lost base doesn't renumber positions.
- **D7:** a partial replica doesn't wipe bookmarks.
- **D8:** a copied Mac never reuses a seq.
- **D9:** the counter carry.
- **D10:**
  - A rename made while sync was off wins on rejoin over an older rename elsewhere.
  - A deletion made while a profile's sync was off goes out when it's turned back on, if the item
    is untouched.
  - The same deletion loses to a later rename elsewhere.
- **D11:** a setting changed while joining stands.

Re-review items:
- **RR1:**
  - Login Data restored in place (same inode, older content) reverts nothing anywhere.
  - A login changed back to an earlier digest is a rollback signal, not an edit.
- **RR2:**
  - A mass change holds only the keys over the threshold, edits counted too.
  - The prompt's default restores them.
  - No "couldn't be read" message appears.
- **RR3:**
  - Another Mac republishing the same value doesn't undo a deletion here.
  - A password changed here while unreadable on day 1 loses to B's change on day 2.
  - At upgrade, a login Chrome modified after its record is claimed, and an older one isn't.
- **RR4:** after a lost journal, a rename and a deletion made elsewhere after the last in-step time
  both win.
- **RR5:** an extension edit made before the first read at launch is published.
- **RR6:**
  - The 5,000-entry cap and Chrome's 90-day expiry publish no deletion.
  - A history apply's echo journals nothing.
- **RR7:** a copied Mac, with the Keychain item copied too, gets a new `deviceId` and chain from
  `IOPlatformUUID`.
- **RR8:** a joining Mac adopts the synced settings and profile names, and doesn't overwrite them.
- **RR9:** a navigation writes nothing to the journal.
- **RR10:**
  - Positions come from records, with base as the fallback.
  - The ever-seen set removes a bookmark whose tombstone was collected.

Final review:
- **FR1:** Login Data restored in place from one ledger write ago (row at `L - 1`), dropping 30
  of 70 logins applied in that write, deletes none elsewhere.
- **FR2:** a deliberate revert to an earlier password is published.
- **FR3 (RR4):** a late file older than `T` (C's 9:00 rename arriving at 10:30) wins over this
  Mac's stale title, and nothing stale is sent.
- **FR4:** the ever-seen set removes nothing whose file is still downloading.
- **FR5:** a pin's page-title change doesn't send its old group or position over a move made
  elsewhere.
- **FR6:** Solara always passes `--user-data-dir`.
- **I6a:** a crash after Chrome takes a push, before the cache write, doesn't resend the pushed
  value over a newer rename elsewhere.
- **I6b:** an extension setting a node back to an old pushed value just before quit is kept and
  published.

Both are guards today: no intent table exists, so neither failure can happen on today's bridge.

Re-check (rollback audit, § Rollback audit):
- **AUDIT-pw-docs-two-writes:** all of shell.docs rolled back two ledger writes behind Login Data
  (p3 and p4 applied after the backup), then B's p2: B keeps p2 and this Mac takes it. Red on HEAD:
  this Mac resends p4.
- **P1, P1b** are the one-write case (`L + 1`) and stay red on HEAD for their stated reason.
- **AUDIT-docs-all:** all of shell.docs rolled back with bookmarks after sync applied B's R1, then
  B's R2: nothing is resent for the key and R2 lands. Green on HEAD, so a guard: HEAD has no journal
  to claim R1 into. It's the test that keeps the `solara_shadow` comparison honest once the journal
  exists.
- **AUDIT-chrome-bookmarks:** Chrome's Bookmarks restored to before B's rename, shell.docs current:
  the restored older title isn't sent. Red on HEAD.
- **AUDIT-history-restore:** Chrome's History missing three of six recent URLs publishes no
  deletion. Red on HEAD.
- **I3-failed-push:** every push carrying one value is refused (Chrome never takes it), B renames
  again, then an extension sets the node to the refused value: the extension's value reaches B. A
  guard (no intents today). It also records today's unbounded retry.
- **Second re-check (of b4d491af):**
  - **SPEC-t, SPEC-t-unconfirmed, SPEC-t-precision, SPEC-t-sync-write, SPEC-t-bigint**
    (spec-rules.test.mjs): `t` is at or after every read-back date, an unconfirmed apply writes no
    row, comparison is strict at millisecond precision, and the raw date doesn't fit a Number. They
    run against a reference model of the rule; the ledger's commit ports them to its code.
  - **AUDIT-pw-equal-record:** after a whole-docs rollback, a login equal to its current record
    isn't published. Green on HEAD; a guard for second re-check 2.
  - **REBUILD-keeps-entries:** the user renames a bookmark, the push reaches Chrome's model, and a
    crash comes before Chrome saves its file. After the relaunch the rename reaches B and stays in
    Chrome. Red on HEAD: the launch read adopts Chrome's older title and the rename is lost. Its
    control (Chrome's file saved) is green.
  - **LAUNCH-keeps-stamp:** an extension edit already published, seen again at launch against a
    stale cache, is not resent and loses to B's newer rename. Green on HEAD; a guard for second re-check 4.
  - **AUDIT-syncjson-profile, -type-off, -profile-off:** sync.json rolled back alone. A profile
    linked after the backup isn't published twice; a type or profile turned off after the backup
    stays off. All three red on HEAD; the controls with sync.json current are green.
  - **SPEC-opt-out:** the higher counter wins in both directions; a missing anchor is no decision.
  - **SPEC-opt-out-settings-reset:** a reset settings doc (no anchor) keeps sync on.
  - **SPEC-opt-out-unloaded-profile:** a type re-enabled while one profile is unloaded is on for
    that profile once it loads, and its anchor is rewritten.
  - **SPEC-t-clock-step-back:** the wall clock stepping back during an apply still gives a `t` at or
    after every date the apply produced, so the applied values aren't claimed.
- **MARK-settles:** one extension edit costs a bounded number of apply and tree calls, then none for
  200 ms. A guard today (no marks); the new bridge must keep it green with the fake emitting a change
  event per apply.
- **AUDIT-pw-docs-user-edit:** after the two-write rollback, a password the user changes once the
  app is back up is published. Green on HEAD; a guard for the rebuild's "after both write times"
  rule.
- **Partial push then crash** (case a with a failed op): the Chrome fake stops at the first failed
  op, as Chrome does, so the setup is expressible. On HEAD it would only repeat I6a, since there's
  no mark to make the launch read it as case (a). It's written with the bridge's launch rule, in
  that commit.
- **Not expressible on HEAD,** since the journal and gen doc don't exist yet: a gen doc rolled back
  alone, the journal and gen doc rolled back together under a current store, a lost journal with no
  gen doc (re-check 4), and an adapter counting an already-equal key as written (re-check 5). Each
  is a unit test in the journal's own commit.
- **A test skipped in the scratch suite:** AUDIT-store-vs-journal needs the store's persisted docs
  in the harness (persist.ts), which it doesn't load.
The review5 repros (repros/guard-review5) are red on HEAD for their stated reasons: A1, A3, A3s,
C1, D1, P1 and P1b. So are seeds 32144, 40636 and 35309. Each is listed in the table above
with what removes it.

**Tie seeds.** The cited seeds come from a strict oracle, the tracked harness with the two
"repair counts as a choice" rules turned off (`ORACLE_STRICT=1` with scripts/native/engineScenario.mjs).
In its first 400 seeds, 43, 212, 390 and 398 fail on tie repairs. 265 no longer does, since the
settle phase and hidden-file steps changed what it generates. The tie-by-key fix's commit puts the
rules back to failures, so these pass on their merits.

## Implementation plan

Each step is one commit to main, or a short run of commits that land together. Each lands with its
tests turning green, and the full suite (`pnpm test`, the engine checks for the engine steps, the
oracle seeds) never goes backwards: no test that passed before a step fails after it. The riskiest
parts come first, the password ledger and journal durability, so their review and their soak in
nightlies start earliest. Nothing of the old guard is removed until what replaces it is in and green.

**Step 0. The redesign suite, tracked.** The scratch suite moves into `apps/browser/src/sync/`:
- `apps/browser/src/sync/redesign/`: the D, RR, FR, I, AUDIT, REBUILD, LAUNCH, MARK and SPEC test
  files, the review repros under `repros/`, and `oracle-seeds.test.mjs`. The strict oracle is
  `ORACLE_STRICT=1` on `engineScenario.mjs`, not a copy.
- Every test that's red on HEAD is marked `{ todo: "step N" }`, naming the step that turns it
  green. `todo` tests run and report but don't fail the suite, so a step can't silently leave its
  own tests red: the step's commit removes its `todo` marks, and a reviewer checks that the
  removed set matches this plan.
- B-old stays `todo` for good, as the accepted migration window.
- No product code. Risk: none.

**Step 1. `Adapter.apply` returns the keys it wrote** (§ 1, Applying).
- Every adapter returns a set; an already-equal key counts as written; `applyAdapter` sets base
  and clears `unapplied` only for those. The passwords conflict skip and `pgh:` stop returning ok.
- Green: the P1 apply half (P1 still needs step 3 to be fully green); unit tests per adapter.
- **What landed (0f09f36b, then the livelock fix):** `apply` may return a Set; `true` or nothing
  still means "every changed key written". Only the two adapters that skipped a key they'd otherwise
  write return a Set (passwords, `pgh:`). The rest were audited and keep `true`, since each writes
  every changed key or ignores keys outside what it syncs: `set:` (names outside `SYNCED_SETTINGS`),
  `prof:`, `pth:`, `share:`, `dev:`, `devmode:`, `bm:`, `h:` (URLs `keptInHistory` refuses, visits
  outside the window), `tabs:`, the pinned family (`pin`, `pord:`, `pinrow:`, `pgc:`, `tilefold:`)
  and `ext:`. Making a Set the only return type would mean editing every test's fake adapter,
  which the switch-off rule forbids; step 6, which needs per-key results everywhere, makes it so.
- **Kept keys don't hold the settle wait** (step 1 review). A login kept here over the folder's
  value is left out of the read-back wait. Otherwise, with the switch on, every 15 s cycle re-ran
  apply on it, waited 5 s, and pushed the 30 s quiet ahead, so the edit was never published
  (step1-pw-livelock tests, at 15, 29 and 31 s cycles).
- Small and mechanical, but it touches every adapter, so it goes first and alone.

**Step 2. Login Data's row and the dated read** (engine).
- An engine patch adds `LoginDatabase` access to `meta_table_` on the store's sequence, exposed as
  `ac_passwords_mark` (write `L@t`, plus `solara_sync_off`) and a read that returns the row with
  the logins from one read of the file. Logins gain `modified`, converted natively to Unix
  milliseconds. Incremental engine build under the chromium lock.
- Green: FR6 (the `--user-data-dir` pin) stays green; new engine-side tests for the row surviving
  a reopen, and a missing row on a recreated file.
- Risk: an engine patch on the password store. It ships dark: nothing reads the row yet.

**Step 3. The password ledger** (§ 1, Passwords; the ledger check; `t`).
- `sync-pw-ledger.json`, row-then-ledger order, detection by ledger, equal-to-record never an
  edit, the four-digest rollback rule, conflict by value, the mismatch rebuild claiming only after
  both times, the mass-change hold and prompt, upgrade seeding.
- Green: D1–D3, RR1, RR2, RR3a/b/c, FR1, FR2, Q3, Q3-pre, Q3-family, P1, P1b, the AUDIT-pw tests,
  the SPEC-t tests ported, seeds 32144 and 40636.
- Risk: the highest in the plan. It decides which passwords go out and which are overwritten.
  Independent review before and after (AGENTS.md › Second opinion), and a nightly with only this
  step before step 4 lands on top.

**Step 4. Journal durability** (§ 1, Where it lives, Durability).
- `sync-edits.json` and `sync-edits.gen`, synchronous write-through in order, the store docs'
  `g`, lost-journal detection, the vv(T)-bounded fallback, the no-gen rule, the ever-seen keys in
  the store docs. The journal is written but not yet read for publishing.
- Green: D4a/b, the journal SPEC tests (gen rolled back alone, journal and gen together, lost with
  no gen), RR4 and FR3 in their fallback half.
- Risk: synchronous IO on every user command. The perf ratchet (docs/perf) runs on this step.

**Step 5. The command layer writes the journal** (§ 1, How it's written; What's journaled).
- `fromSync` on bookmarks, history and profile applies; the shared key module; history's apply
  order; observations kept out; `pinChoices` folded in and `pinSync` dropped; extension intents
  folded in (`sync-extensions.json` read once and retired); joining seeds; the NativeStore
  journal on the Swift side with per-key tags.
- Green: RR6, RR9, D11a/b/c, FR5, the pin tests rewritten for the journal.
- Still publishing by diff: this step only fills the journal, so nothing user-visible changes.

**Step 6. Publish from the journal; apply never over an entry** (invariant 1).
- `publishAdapter` publishes entries (their own `v`), observations by diff, stale entries
  cleared; every adapter skips keys with live entries; the D10 rules for kept-off profiles and
  rejoins.
- Green: R3, A2, A3, A3s, D10a-conflict, D10b, R-baseline, R-rollback, guard-review r2/r3/r4,
  guard-review3 r1/r1b, seed 25066/B70.
- The old guard still runs alongside; it now only gates what it held before, so nothing it
  caught can slip through mid-plan.

**Step 7. Publishing chains and twins** (§ 2).
- Chain ids, the currency checks, re-sends under new seqs, `IOPlatformUUID` with the device id.
- Green: R1, R1b, E, E-peer, R-rollback-outbox, review5 C1, D8, RR7, seed 35309.
- Risk: the folder format is unchanged, but every reader must accept a chain as a device. The
  update test in the release skill (old stable reading new files) runs on this step.

**Step 8. Holds and per-type settle** (§ 3, § 4).
- First-seen per file, the 10-minute limit, the D7 bookmarks apply rule with ever-seen origins,
  per-type rebuild list.
- Green: A1, A2 (review5), Q1, C1 (guard-review2), C2, D7a/b, RR10, FR4, review5 D1 in its
  journal half.

**Step 9. The bookmark bridge's generations** (§ 1, Bookmarks).
- Engine: `ac_bookmarks_apply` gains meta ops (`solara_shadow`, `solara_origin`,
  `solara_sync_off`) and the tree read returns the bar node's mark; the Chrome fake gains meta
  info and a change event per apply.
- Bridge: generation steps for pushes and reads, the intents file, the launch rules, the
  claim-nothing rebuild that keeps live entries, launch diffs keeping stamps. Intents and marks are
  per Chrome profile.
- **Lessons from the interim unsaved-push replay** (reviewed and not shipped):
  - Sync publishes 3 s after an edit (`AFTER_EDIT_MS`), later than Chrome's 2.5 s save. Anything
    put back at launch must go out with the stamp of the edit that made it, from its journal entry,
    never a stamp taken at relaunch. Otherwise it beats a newer edit made elsewhere (SYNC-1, SYNC-2).
  - Node comparisons include the index within the parent. A reorder-only change is still a
    change (REORDER, LINGER+REORDER).
  - No age windows or timers decide what's honoured; the generation marks do. A single timer can't
    age a stream of records (TIMER).
  - Dropping an intent for a node drops every earlier one for that node, so a deleted bookmark
    can't come back from an older intent (GAP).
  - The tests fire the bridge's timers by hand and move `Date.now`, and cover crashes from 0 s to
    past Chrome's 2.5 s save, not one window.
- Green: I3, I6a/b, MARK-settles, AUDIT-docs-all, AUDIT-chrome-bookmarks, REBUILD-keeps-entries,
  LAUNCH-keeps-stamp, D5a, review5 D1, and from bridge-crash-review.test.mjs SYNC-1 and
  SYNC-control; its SYNC-2, REORDER, TIMER, LINGER+REORDER and GAP stay green.

**Step 10. sync.json anchors** (§ Rollback audit, opt-outs).
- Each profile's sync id and kept-out flag on the profile; opt-outs written beside their data
  (Login Data and the bar node through steps 2 and 9, History's meta table through a new
  SolaraCore call, extension prefs); toggle counters, the higher one wins, a missing anchor is no
  decision, a disagreement shown in the Sync pane.
- Green: AUDIT-syncjson-profile, -type-off, -profile-off, the SPEC-opt-out tests ported, and engine
  versions of the settings-reset and unloaded-profile cases.

**Step 11. The old guard goes, and the format bump** (§ What's removed, § Migration).
- Remove the launch and load notes, baselines, the delivered map, the fresh download wait and the
  stand-in base; bump sync.json's `v`; read and drop the old fields.
- Green: everything above stays green with the guard gone, which is the point of doing it last.
  B-old stays the one `todo`.

**Step 12. Small independent fixes,** anytime after step 0:
- the HLC counter carry (D9b);
- the tie-by-key fix (seeds 43, 212, 390, 398), with the strict oracle's rules restored.

**Step 13. The sync key moves to the data-protection keychain** (owner's decision, 2026-10-27),
after the redesign has shipped, not during it.
- `SyncKeyStore` saves "Solara Sync Key" with `kSecUseDataProtectionKeychain`, so the item is
  truly this device's only and no longer copies with Migration Assistant or a disk clone.
- **One-time migration:** read the old login-keychain item, write the new one, read the new one
  back and check it matches, and only then delete the old one.
- **Fallback:** if the key can't be read or moved, sync shows "not syncing" and asks for the
  recovery phrase. It never mints a new chain or a new key on its own.
- **Ad hoc signing:** owner builds are ad hoc signed, so the data-protection keychain is checked
  to work there (entitlements and access group) before the step lands.
- An independent review before and after the change.

Each step's commit message lists the `todo` marks it removed. A step that can't turn its tests
green without touching a later step's files is split again, not merged ahead of its order.
