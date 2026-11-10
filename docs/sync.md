# Sync

End-to-end-encrypted sync with no server, no account and no Apple entitlement. Every Mac reads
and writes sealed files in a folder the user picks; any service that syncs a folder carries them
between Macs. The default is `iCloud Drive › Solara Sync`
(`~/Library/Mobile Documents/com~apple~CloudDocs/Solara Sync`: iCloud Drive syncs any folder
under it, with no CloudKit container and no entitlement). Dropbox, a NAS or a USB drive work
the same way.

The UX follows Dia's sync (Settings › Account › Sync in Dia 1.50.1; its strings are quoted from
its binary below). Dia's data sits on its servers and devices pair with a 6-character code; here
the folder takes the servers' place. A new Mac joins by pairing with a Mac that already syncs,
through the same folder, comparing a 6-character code on both, or by entering the recovery phrase.

Code:
- `packages/sync/ios/Core`: plain Swift, also built by `packages/sync/Package.swift`.
  - `RecoveryPhrase.swift`: the phrase (BIP-39).
  - `SyncCrypto.swift`: keys, the file format and names.
  - `SyncVault.swift`: the folder, with file coordination and partial files.
  - `SyncKeyStore.swift`: Keychain.
  - `RecoveryKit.swift`: PDF, text sheet and QR code.
  - `PairingFormat.swift`, `PairingCrypto.swift`, `PairingSession.swift`, `PairingMailbox.swift`:
    pairing's files, keys, state machine and folder IO. `PairingDurableStore.swift` keeps each
    Mac's pairing bookkeeping in its own data folder (`Application Support/sync-pairing`), never
    in the sync folder.
- `packages/sync/ios/PairingCoordinator.swift`: runs one joining and one trusted pairing at a time
  and asks for Touch ID or the login password before Allow sends anything.
- `packages/sync/ios/SyncModule.swift`: the Expo module (`SolaraSyncAdapter`). It also reads this app's saved passwords.
- `packages/sync/src`: the merge, in TypeScript with no dependencies.
  - `scope.ts`: replica, logs, snapshots, compaction.
  - `hlc.ts`: hybrid logical clocks.
  - `order.ts`: fractional positions.
- `apps/browser/src/sync`:
  - `adapters.ts`: store ↔ records.
  - `pinned.ts`: the pinned area (`pin:`, `pinn:`, `pinrow:`, `pord:g:`, `tilefold:`, `pgc:`, `pgh:`). `pinnedAreaAdapters` gives
    its five adapters in the order they have to run: tile folders, rows, the row order, pinned group tabs' homes, then
    the pins.
  - `engine.ts`: state, setup flows, the cycle.
  - `menu.ts`: the overflow menu's synced devices.
- `native/SolaraKit/Sources/SolaraUI/Settings/Panes/SyncPane.swift` and `SyncSheets.swift`: Settings › Sync.

## Threat model

Protected against anyone who can read or write the sync folder but doesn't have the phrase:
Apple, Dropbox, whoever has the NAS or finds the USB drive, malware that reads cloud files.

- They can't read synced data. File contents are AES-256-GCM. Folder and file names are keyed
  (HMAC) or random, and say nothing about profiles, sites or data kinds. Pairing is the one
  exception, and only for a Mac's name: see Pairing below.
- They can't change anything undetected. Every file is authenticated. The associated data binds a
  file to its folder and name, so a file can't be renamed, moved or truncated without failing to
  open. Files that fail are never applied.
- Contents are padded to 1 KiB steps and not compressed. The size of a file says little, and
  attacker-chosen page titles can't be used to probe passwords through compression
  (CRIME-style).

What they do see (metadata): how many profiles sync (one folder each) and how many devices; when
and how much each writes (file count, times, sizes to 1 KiB); and that it's Solara sync data
(the `NNS1` magic and `.nns` extension). Pairing adds its own, listed below.

What they can do: delete or withhold files (denial of service). Withheld files show as
"waiting for N files to download". They can also replay an old file under its own name, which is
harmless: files are immutable, a replayed op merges as a no-op, and an old snapshot can't bring back
a record whose deletion was already applied (see Compaction). They can't forge, reorder
within a file, or move data between profiles.

Not protected against:
- Someone with the phrase. The phrase is the key, like Dia's.
- Someone with the unlocked Mac. They have the data in the clear anyway.
- A compromised Solara binary.

### Pairing

Settings › Sync says it in short: "Pairing shows this Mac’s name to the Mac you’re pairing with
before you compare codes, even if you cancel. Anyone who can open your sync folder could start a
pairing. Pairing files show when a pairing happened and how it ended, but none of your synced
data." In full:

- **The Mac's name goes out before the codes match.** Each Mac sends its real name, encrypted to
  the Mac it paired up with, before either shows the code. That Mac is whoever answered in the
  folder, not necessarily yours. The joining Mac takes the answer when exactly one has arrived
  (with two or more it takes none, and the attempt runs out); a trusted Mac answers only the request its owner selected while Connect another Mac or
  Review request is open (one 120-second window), and sends its name only after the joining Mac's
  has arrived. Cancelling, denying or deleting the files doesn't take the name back: the other
  side can keep it, and so can iCloud. The owner accepted this on 2026-11-01, because a name
  helps people recognize the right Mac.
- **Anyone who can write to the sync folder can start a pairing.** They can post a request, or
  answer one. They don't need the phrase. What they can get is the name above; the synced data
  stays out of reach, because it goes only after the code matches on both Macs, Allow is chosen on
  the trusted Mac, and Touch ID or the login password confirms it there.
- **A passive reader doesn't get the name.** Names travel AES-256-GCM sealed under keys from an
  X25519 exchange between the two Macs, padded to a fixed size so the length doesn't show. The
  request and the answer carry only the fixed labels "New Mac" and "Trusted Mac" and a salted
  hash of the name.
- **A name is only a claim.** Both sheets show it in quotes as "Unverified until the codes match".
  A matching code proves that this connection is the one the other Mac sees, not who owns it.

What pairing files show anyone who can read the folder:
- Where: `Solara Pairing v2/<chain tag>/<request id>/`. The chain tag is the phrase's chain
  folder name, so a pairing is tied to one sync; the request id is random, and each answer's id
  (in its file names) is random.
- That a pairing happened, when, and how far it got. Every file name says what it is: `request`,
  `offer`, `select`, `reveal`, `confirm`, `j-name`, `t-name`, `approval`, `receipt`,
  `j-terminal`, `t-terminal`, each `.spj`. Each kind has one fixed size (`request` 197 bytes,
  `offer` 233, `select`, `reveal` and `receipt` 156, `confirm` 124, the names 376 each, `approval`
  1160, the terminals 125). So the folder shows how many Macs answered, whether one was approved
  and whether the new Mac confirmed it installed.
- In the clear: a 60-byte header (the `SPJ2` magic, version, kind, length, and the chain tag,
  request id and answer id), each side's X25519 public key and random session id, the request's and
  each answer's created and expiry times (five minutes apart), the commitments and their openings, and the
  confirmations. A terminal file also says why the attempt ended: cancelled, denied, expired or a
  protocol failure.
- Sealed: the two names and the approval. The approval carries the phrase's entropy, sealed under
  that exchange's key.

What a folder writer can do to a pairing: withhold, delete or flood the files (the attempt fails
or times out), answer a request to learn the joining Mac's name, or post one to learn a trusted
Mac's name if its owner selects it. A wrong Mac gets past the code about once in 2^30 attempts,
and a trusted Mac takes one attempt per window.

Cleanup is best effort. Each Mac deletes the files it wrote once the attempt ends (a terminal or
receipt a minute later). A Mac that quits or loses the folder mid-attempt leaves its files, and a
copy iCloud kept is out of reach. No promise rests on deleting them.

The phrase's entropy is in each Mac's login Keychain (`Solara Sync Key`, this device only,
never iCloud Keychain). Losing every Mac and the Recovery Kit loses the synced data. There's no
reset by email, because there's no one to email.

## Recovery phrase and keys

- 24 BIP-39 English words encode 256 bits from `SecRandomCopyBytes` plus an 8-bit checksum (the
  first byte of their SHA-256). The same format as Dia's (its errors: "Recovery phrase must be
  exactly 24 words.", "This recovery phrase is not valid. Please check for typos.", "“%@” is not
  a valid recovery phrase word.").
- Input is lenient: case, punctuation, the kit's numbering ("1. abandon") and 4-letter prefixes
  are all accepted.
- The wordlist is the standard one; a test checks its SHA-256
  (`2f5eed53…dbda`) and Trezor's reference vectors.
- Keys: HKDF-SHA256 over the entropy, salt `netnyahoo-sync/v1`. The magic and the salt keep the app's old name
  for good: every Mac on any version reads the same files (`SyncFormat` in `packages/sync/ios/Core/SyncFormat.swift`).
  - `file-key` (AES-256-GCM) seals every file.
  - `name-key` (HMAC-SHA256) names folders: the chain tag is `HMAC("chain")` and a scope's tag
    is `HMAC("scope/<scope id>")`, each cut to 128 bits and written in base32.
  - The phrase already has 256 bits of entropy, so no password stretching is needed.
- Where the entropy is kept: the login Keychain, as a generic password (`Solara Sync Key`,
  account = this device's sync id, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
  synchronizable).
  - Despite "ThisDeviceOnly", the item is saved without `kSecUseDataProtectionKeychain`, so it lives
    in the file-based login keychain. Migration Assistant and disk clones copy it, and a copied Mac
    keeps both the key and the device id. The owner approved moving the item to the
    data-protection keychain, so it's truly this device's only (2026-10-27). The move is scheduled
    after the sync redesign ships (docs/sync-redesign.md § Implementation plan, step 13).
  - Test instances (`SOLARA_DATA_DIR`) keep it in a 0600 file in their data folder instead,
    as Chrome's mock keychain does for them.
  - A Debug build can't read an item an earlier build saved (no prompt, by design). Sync then
    shows "not syncing" with Enter Recovery Phrase…, and the same device carries on.
- The key never crosses to JS. The words do, only for the Recovery Kit and Connect Another Device
  sheets, or when the user types them.
- Showing, copying, sharing or saving the phrase asks for Touch ID or the login password first
  (`DeviceOwnerCheck`, one approval covers 60 s; Stop Syncing, Turn On Sync and Enter Recovery
  Phrase end it). A Mac with no login password can't answer that, so the sheets say the phrase
  can't be shown until a login password is set in System Settings › Users & Groups.

A wrong phrase is caught in one of two ways. A typo fails the checksum. A valid but different
phrase derives a chain tag that isn't in the folder: "This recovery phrase doesn’t match the
synced data in this folder".

## Folder layout and file format

```
<sync folder>/
  <chain tag>/                 one per phrase (several people can share one folder)
    <scope tag>/               "app" (settings, profiles, devices) or "p:<profile sync id>"
      <file id>.nns            128 random bits, base32
  Solara Pairing v2/           pairing's files, cleaned up best effort
    <chain tag>/
      <request id>/            128 random bits, hex
        request.spj            the joining Mac's request
        <answer id>.<kind>.spj one per step, see Threat model › Pairing
```

A file is `"NNS1" | nonce (12) | AES-GCM ciphertext | tag (16)`.
- AAD: `"NNS1" + "<chain>/<scope>/<file>"`.
- Plaintext: `length (u32 BE) | UTF-8 JSON | zero padding` to the next 1024 bytes.

The JSON is one of:

```jsonc
// A log: a batch of one device's changes. seq counts up per device and scope.
{ "v": 1, "kind": "log", "device": "<id>", "seq": 7, "at": 1790000000000,
  "ops": [{ "k": "bm:<uuid>", "h": "<hlc>", "v": { … } }, { "k": "h:https://…", "h": "…", "v": null }] }
// A snapshot: a device's whole merged replica, and the seqs it covers per device.
{ "v": 1, "kind": "snapshot", "device": "<id>", "at": …, "vv": { "<device>": 41, … },
  "seen": { "<device>": <ms> }, "records": { "<key>": { "h": "<hlc>", "v": …, "o": ["<device>", <seq>] } } }
```

Writing:
- A device only ever creates files, each under a fresh random name, and never changes one. Two
  Macs never write the same file, so the sync service never sees a conflict.
- A file is written whole in a same-volume temporary folder, then moved in inside a coordinated
  write (`NSFileCoordinator`, `.forReplacing`). The sync client never sees half a file under a
  real name.
- A log's seq is never reused. A batch gets its seq and is saved, sealed, to its own
  `sync-journal-b-<scope in hex>-<seq>.nns` in the app's data folder before it's written (`persist`);
  a batch whose write fails stays queued with its seq. After a crash, `restoreJournal` puts the
  journalled batches back into the last saved state and the next cycle writes them again, byte for
  byte, before anything new. If the first write did land, the folder has the same batch twice, which
  reads as a no-op on every version. The journal is local only (no format change); a batch file goes
  once the saved state has its batch. A batch file is sealed for its scope and seq, so it opens as no
  other; one from another device, or one that won't open, is deleted at load (with the redesign
  switch on, one that won't open pauses the ledger migration instead, like the old journal). Batches
  in the older single `sync-journal.nns` are loaded as before, and that file is emptied once the
  saved state has every one of them.

Reading (`SyncVault.read`) handles files that aren't there in full yet:
- iCloud placeholders (`.<id>.nns.icloud` stubs, or dataless files whose
  `ubiquitousItemDownloadingStatus` isn't current) are reported as pending, and
  `startDownloadingUbiquitousItem` is asked for them.
- Files mid-copy (Dropbox, SMB) and empty files fail to open. They're reported as damaged, with
  their age, and retried next cycle; a file that still fails after a day is given up on.
- Everything else is read in a coordinated read.
- Nothing half-arrived is ever applied.

## Merge

Each scope holds a replica: `key → { h: HLC, v: value | null, o: [device, seq] }`.

- **Last writer wins per record** by hybrid logical clock. The HLC is
  `wall(ms, base 36, 9 digits).counter(4).device`, fixed width, so string comparison is clock
  comparison and the device id breaks ties.
- A deletion is a record with `v: null`, a tombstone.
- Merging is a join: commutative, associative and idempotent. Devices converge whatever order
  files arrive in, and a file read twice changes nothing.
- **Clock skew.** A clock never goes below the newest timestamp it has seen, so an edit made
  after seeing another device's edit is newer even if this Mac's clock is behind. Only truly
  concurrent edits are ordered by the (possibly skewed) wall clocks. A Mac whose clock is days
  ahead wins edits concurrent with it, but the next edit anywhere after it syncs wins again (tested).
- **Base, three-way.** Each scope keeps `base`: what the local store held after the last publish
  or apply. A local value different from base is a local edit and becomes an op. A key in base
  but gone locally is a local deletion. Remote changes are applied only over keys with no
  unpublished edits. Each adapter publishes and then applies, with no wait in between, so an
  edit made while files were being read wins and isn't overwritten (tested).
- **Joining.** Local data is published before remote data is applied, so joining is a union: no
  local bookmark, visit or password is lost. Settings and profile names are the exception
  (`adoptRemoteOnJoin`): a joining Mac takes the synced values and doesn't publish its defaults
  until it has read another device's file (`awaitRemote`). Data that existed before sync was
  turned on (passwords, history) is published with its own creation time
  (`Clock.at(editedAt)`), so it doesn't beat a later edit made elsewhere.
- **Version vectors.** `vv[device]` is the highest seq such that every file of that device up to
  it is in the replica. Seqs that arrive out of order wait in `extra` until the gap fills
  (tested).

### Compaction

- **When.** A device writes a snapshot of its replica when a scope has more than 40 files and no
  snapshot has been written in 10 minutes.
- **What it leaves out.** Tombstones older than 45 days are dropped from the snapshot, and so are
  history records older than 90 days.
- **What it removes.** Then it removes, once they're an hour old, the files the snapshot covers:
  logs `(d, s)` with `s ≤ vv[d]`, and snapshots whose `vv` it dominates.
- **Why that's safe.** A snapshot is self-contained, so any device can start from it, and
  concurrent compactions only remove files covered by their own snapshot.
- **Missing logs keep tombstones.** While a replica is missing a log that a later one from the
  same device skipped past (its version vector has a gap), compaction keeps tombstones up to
  90 days instead of 45, since that log could hold an older write that would otherwise come
  back. A log that never shows up holds them for 90 days at most (tested).
- **Known residuals** (each pinned in a test):
  - A log delivered after the hold (45 days, or 90 while this replica sees a gap) can bring a
    deleted record back.
  - A snapshot doesn't carry its writer's gaps, so a Mac that joins from it while a log is still
    missing, and doesn't see a later log of that device itself, holds tombstones 45 days, not 90.
  - A log that never arrives keeps its gap open, and the later logs of its device that the gap
    keeps from being covered stay in the folder.
- **Not done: causal stability.** Dropping a tombstone only once every device has applied it and
  everything written before it would close these, but it's a separate project. An attempt
  (reverted in 7b334d07) showed what it has to get right: stability must count writers whose files
  haven't arrived yet; rebasing a device must not clear the base adapters rely on (the passwords
  adapter then republished an old password over a newer one); a device's incarnation and its
  journal must be saved together, or a restart drops a durable batch; and a restored backup
  must not reuse an incarnation and sequence numbers, or its edits are ignored. It also has to
  run its upkeep in small scopes (under 40 files) and not trust wall clocks for retirement.
- **Collected tombstones.** A device that missed a deletion whose tombstone has since been
  collected still learns of it. Applying a snapshot drops every local record whose origin file
  the snapshot covers but which the snapshot doesn't contain (`ingestSnapshot`). A log a snapshot
  covers is never replayed after it, so a collected deletion can't come back.
- **Old snapshots.** The same holds the other way round. A snapshot record whose origin this
  replica has already applied (its version vector, which is never collected), for a key the
  replica no longer has, is a deletion already applied and is skipped. So a snapshot put back in
  the folder after its tombstones were collected (a replay, a late backup restore) brings nothing
  back (tested). There's no format change. A 0.2.10 Mac still takes such records in, but the
  next snapshot from a newer Mac covers them and leaves them out, which removes them there again.
- **A device offline for weeks.** It reads the newest snapshot and whatever logs came after,
  applies them, and publishes its offline edits (tested). The one gap: an edit made offline to a
  record that was deleted elsewhere, whose tombstone was collected more than 45 days ago, comes
  back as a new record.

### Order

Bookmark folders and the pinned container are ordered by fractional positions (`order.ts`,
base 62, never ending in "0"). A move changes the moved item's position only. Positions are
assigned by keeping the longest increasing run of known positions, so two Macs reordering
different items merge. Equal positions (two inserts in the same place) sort by id and are
separated on the next publish.

## What syncs

Per profile: each synced profile is its own scope, with its own opt-in (Settings › Sync ›
Profiles).
- On joining, Personal pairs with the synced default profile and other profiles pair by name.
- A synced profile this Mac lacks is offered as "Add to This Mac".
- Profiles that share another's data (Dia's "Share data with another profile") sync their tabs;
  the shared data syncs with the profile that owns it.
- Which profile's data a profile shares travels as `share:<sync id>` (the owner's sync id), so "Add to This Mac" makes
  it share this Mac's own copy of that owner, adding the owners it leads to first when this Mac lacks them (the whole
  chain is worked out before anything is created). When an owner's `prof:` record hasn't arrived yet, the profile
  waits ("Waiting for the profile it shares data with to sync") rather than getting data of its own. Records from
  different Macs can disagree, even into a cycle; the lowest sync id in a cycle owns the data, so every Mac resolves it
  alike. A profile already here keeps the data it has.
- A profile's sharing is fixed for its life, so `share:` is written once: a Mac publishes it for a profile that shares a
  synced owner's data only while the scope has no record of that key (one a 0.2.38 Mac kept unapplied counts), and
  only once this session has pulled the app scope with no download and no damaged file still unresolved
  (`publishAfterPull`; either stops counting after a day, a download from when the scope first saw it pending, kept as
  `pendingSince`; a time ahead of the clock counts as now, so a file iCloud never brings down can't hold it back for good), so a Mac back on an older saved
  state sees what's out there first. A sharing profile's `prof:` goes out with its `share:`, in the same batch, so no
  Mac offers it without its sharing. Never as a tombstone, so a deleted profile offered again by "Add to This Mac"
  shares as before, and never over a value this Mac has. Known residual: a value another Mac published that this Mac
  hasn't pulled yet can lose to this Mac's, when a profile's owner starts syncing here mid-session (the cycle's first
  publish runs before its pull); both Macs then keep their own data.
- Limit: a profile that shares the data of an owner deleted on its Mac publishes no `share:`; on other Macs it gets
  data of its own, as before 0.2.39. That data group's bookmarks, history and passwords no longer sync from that Mac
  anyway: only a profile without `dataId` syncs data.
- Remove from Sync (0.1.5). Deleting a profile on a Mac leaves its `prof:` record, so other Macs keep offering it. A
  row under "On your other devices" has "Remove from Sync…", which asks first and then tombstones `prof:` for that
  profile and every live profile whose `share:` chain leads to it through live profiles (a sharing cycle goes as one
  set; a chain through a profile already removed isn't followed, and that dependent waits as below). The alert names
  them all. Nothing is offered for removal when any profile in the set has a link on this Mac, in any state
  (syncing, not syncing, being retired), or is the synced default (`d`: a joining Mac's bootstrap needs exactly one).
  - The request (`removing` in `sync.json`: the profile picked, the set's sync ids and each `prof:` record's stamp
    `h` at the click) is one-shot. It runs only in a cycle's publish after the app scope's pull, from a read of the
    folder that started after the click, while no app file is still downloading or damaged (each stops counting
    after a day, as elsewhere), and only when the set and every stamp still match what was confirmed. A request that
    no longer matches is dropped on any cycle, complete or not, and the row comes back for a new decision: a rename,
    a holder republishing, a new dependent, a link here, or another Mac's tombstone all void it. The alert carries a
    token of the set and stamps, so a row that changed while the alert was open is refused (Settings then gets the
    engine's rows again). Adding the profile here first drops the request; so does stopping or resetting sync.
    It's settled only once this Mac's tombstones for the whole set are in its state with nothing left to send, so
    they're in the folder; a journal lost in a crash (see the backlog) can't lose it, and it runs again. The first look after launch
    and a rebuild drop removals from their extraction, so the request waits for them to finish.
  - Only `prof:` is tombstoned. `share:` stays live: every version publishes it only while its key is unknown, and a
    tombstone counts as known, so a holder that brings `prof:` back could never bring its sharing back. `pth:` stays
    too, so a profile that comes back keeps its theme. Neither makes a row without a live `prof:`.
  - A Mac that still has the profile, with sync on for it, publishes `prof:` again after the tombstone reaches it
    (applying it clears that Mac's base), normally in its next cycle, and every Mac offers it again; the alert says
    so. A Mac with sync off for it keeps it and publishes nothing until it's turned on. No version deletes or unlinks
    a local profile on a `prof:` tombstone (its apply skips a missing record; checked in 0.0.1, 0.1.0, 0.1.4 and the
    native redesign), and older Macs just stop offering it (tested against the 0.1.4 engine and adapters).
  - A dependent that comes back alone (its holder republished it after its owner was removed) shows as waiting for
    the profile it shares data with; that row can be removed too.
  - The profile's data stays in the sync folder after Remove from Sync: its `pth:` theme record in the app scope, and
    its whole `p:<sync id>` scope (its bookmarks, history, tabs and passwords files). Remove from Sync only stops
    Macs offering the profile. Why: a Mac that still has the profile keeps writing to that scope and brings the
    profile back with its theme, so deleting the files would destroy data a Mac is still using, and that can't be
    undone; and nothing reads a scope no Mac links, so the files cost only folder space. Cleaning up a scope no live
    `prof:` names is a backlog item.
  - Residuals: its tombstones are collected like any other (Compaction), so a Mac away longer than that that still
    has the profile offers it again; a quit before `sync.json` is written loses the request, and the row comes back.
    Not ported to the native sync redesign yet.

| Key | Scope | What | Notes |
|---|---|---|---|
| `set:<name>` | app | the settings that follow the user (`SYNCED_SETTINGS`: search engine and custom engines, appearance, address bar, tab layout and behavior, bookmarks bar, full URL, muted sites, clean-up, keyboard shortcuts…) | not window sizes, battery saver, extension engines or the default profile id. A setting this Mac doesn't follow yet (one added in a newer version, received while it ran an older one, which counted it applied) takes the synced value once it does, unless it was chosen on this Mac: each cycle reapplies any synced setting whose value differs from this Mac's and that this Mac never chose (tested) |
| `prof:<sync id>` | app | a profile's name, color, icon (`d` for the default) | deleting a profile on one Mac doesn't delete it on another; Remove from Sync tombstones it (above). A `th` field written by development builds of 0.2.40 is read once, as the profile's theme, when it has none |
| `pth:<sync id>` | app | a profile's custom theme `{ t }`, or `{ preset: true }` after going back to a preset color | its own record, so a rename and a theme change on two Macs both survive, and Macs before 0.2.40, which rebuild `prof:` from what they know, never strip or republish it (tested with a 0.2.38 adapter). Written once a profile has had a custom theme. A profile paired on joining takes the synced theme (or a legacy `th`) before it can publish its own, and a legacy `th` never applies once a `pth:` record is known (tested). A profile paired on joining or added from sync is adopting (`themeAdopting` on its link in `sync.json`, so a restart keeps it): its theme isn't published, with no time limit, until its `pth:` record is applied (also by an older build: a valid `pth:` already in the base ends it at launch and on each cycle), a pull with nothing downloading, damaged or given up as bad shows there is none, or the user edits its theme or picks a preset on this Mac. Turning the profile's sync off and on keeps it adopting. Other profiles, and links from before this flag, publish edits at once, whatever else is still downloading; none publishes over a `pth:` record that has arrived but isn't applied yet (tested). Older Macs keep showing the preset color, which choosing a custom theme doesn't change |
| `share:<sync id>` | app | `{ o }`: the sync id of the profile whose data this one shares | its own key, not a field of `prof:`, so Macs before 0.2.39 keep it untouched instead of republishing `prof:` without it on every cycle; written once, while both sync; never deleted |
| `dev:<device id>` | app | a device's name | removed when it stops syncing |
| `bm:<sync key>` | profile | `{ k, p (parent: its sync key, "bar" or "other"), t, u, a (added), pos }` | Bookmarks are Chrome's (BookmarkModel). A node's sync key is its Chrome UUID, or, for a bookmark synced before 0.2.20, its old id (`bm-…`, kept on Chrome's node as meta info `ac_sync_key`); every Mac makes an old key the node `bookmarkUuidFor` gives it, so Macs on either version name a bookmark alike (no renames, no duplicates; tested). Favicons stay local. A node whose folder was deleted elsewhere lands in Other Bookmarks; a cycle from two concurrent moves is broken the same way on every Mac (tested). Native ownership journals the desired tree and edit facts; JS sync waits for native readyForSync, including migration confirmation and recovery holds. Document and remote record stamps are accepted atomically before the sync base advances |
| `h:<url>` | profile | `{ t, n (visits), vt (last 50 visit times) }` for pages visited in the last 90 days | History is Chrome's (HistoryService). Applying a record adds the visits Chrome lacks; a local edit is a visit the record doesn't have, so Macs settle on the union of their visits (tested). Not deletions: older history (it stays on the Mac that has it and is dropped from snapshots), Chrome's 90-day expiry, URLs past the newest 5,000 the app reads, and pages Chrome doesn't keep (`solara://`) |
| `tabs:<device id>` | profile | `{ n (device name), tabs: [{ u, t }] }`: that device's 30 most recent open tabs | only its device writes it. It feeds the overflow menu's "Your Devices" |
| `pin:t:<tab id>`, `pin:g:<group id>` | profile | pinned tabs `{ g, u, t, i, ti, pos }` and pinned groups `{ n, i, c, pos }` (Dia's pinned container) | they arrive as unloaded tiles in the window showing the profile and load when selected; when no window shows the profile they join its parked pins. A pinned group's members always live in the group's window, and sync never moves a tab between two open windows: a pin synced into a parked group is parked with it, a parked member joins a group open in a window, a group whose member is open in another window moves to that page's window (the mirror then gives the profile's other windows unloaded copies), and a member open in a third window stays there as a regular tab while the group gets an unloaded copy. A key resolves to the profile's pinned tab or pinned-group member; only when there is none does it fall back to a regular tab that still carries the key (a pin unpinned on this Mac, kept open), preferring one with a page, so another Mac's re-pin takes that page back instead of adding a second tab. A tab sync pins as a tile or row leaves any regular group it was in, as pinning it here would. A member whose pinned group has a tombstone (unpinned or deleted elsewhere) becomes a standalone pin, even if a regular group with that id is still here; one whose group has no record yet (its batch hasn't arrived) shows as a standalone pin meanwhile, its record keeps that group and position while local edits to its other fields (a rename, a new icon) still publish, and it joins the group when the group arrives. A missing group counts as not arrived only when this Mac never had it, has no record of it, and first saw the wait less than 90 days ago, by its own clock (the deadline is saved with the session), as long as a gap holds tombstones (Compaction). Past it the member publishes as a standalone pin, checked on every sync, so an idle Mac gets there too (tested). A tombstone removes only what is still in the pinned container: a group or tab this Mac already kept as regular stays. A pinned group record for a group this Mac keeps as regular (it unpinned it, and another Mac restyled or re-pinned the pinned one) becomes a separate pinned group, so the regular group keeps its name, style and tabs (tested); a member record that names such a group while its pinned group has a tombstone leaves the regular member where it is. One conflict is left: a page change on a member made while another Mac unpins its group can win the member's record. Depending on which Mac syncs first, the member then either follows the unpin, or stays pinned on its own and the unpinning Mac's regular group goes if that was its only tab; both Macs agree and the tab is kept (tested). Settling it needs placement times in the records. Pinning, unpinning into or out of a pinned group, moving a tab between tiles, rows and groups, re-pinning a group or moving a pin to another profile records a pending placement choice (`pinChoices`, like the row choices), so the next sync republishes that record with a fresh timestamp even when its value is unchanged and a later explicit choice outranks an older edit still in transit. A pin's page is published as 0.2.38 does: a member sends the page its copy shows, a tile sends its home URL, both send the copy's title, and applying a record sets the page of a copy that isn't loaded. The copy published is the one in the profile's frontmost window. Known residual: two Macs with the same pin loaded at different pages keep sending their own page on each sync, so the record moves back and forth between them (tested). Nothing is lost, and it stops once either copy unloads or both show the same page. Earlier builds held a page back until it changed locally, but every version of that (a per-copy baseline) let a real navigation go unsent in some case, so it's gone. The group a member waits for and its deadline live in `pinSync`, a side table by profile and pin key saved with the session and pruned like `pinChoices`, so parking, reopening, mirroring and relaunching keep them. A pull applies the view it took before it applied anything, so a pinned-group member added here in between has no record in it: it stays where it was put, in the innermost group it joined and that group's parents as the view nests them, and becomes a tile, keeping its pinned page, when another Mac deleted every group it was in (tested, nested groups included). Known residual: a local removal or move of a member the view already lists is undone by that apply, as the view's placement of a key it knows still wins (pinned as a todo test in sync/pinnedFrozenMembers.test.mjs). Unpinning on one Mac removes the tile on the others. A record's key is matched only to that profile's tabs and groups: when the id is already another profile's tab or group on this Mac (a pin moved between profiles), the pin gets a new local id with the key kept as `pinKey`, so neither profile's records touch the other's pin. A group's `c`, here and in a nested pinned group's `pinn:g:` record, is `null` for Neutral or one of Chrome's nine colors, the values every released version can draw; a group set to None (no background or outline, issue #206) sends `null` there and its None in a `pgc:` record |
| `pinrow:<tab id>` | profile | `1` for a pinned tab shown as a row, `0` for one this Mac chose as a tile | Rows are pinned tabs: their `pin:t:` record is the same as a tile's (order included), so a Mac on a version before rows shows them as tiles, and since it never writes `pinrow:` keys its edits can't turn a row into a tile. A Mac publishes `0` for a tile once it has seen a mark for it. Each tile or row the user chooses there (pins it, or moves it between tiles and rows) is a pending choice kept per profile and pin key (`pinChoices`, saved with the session, so closing windows, parking and mirroring can't lose it); the next sync republishes its mark with a fresh timestamp even when the value is unchanged (unless that mark is already queued in the scope's outbox or journal), and drops the choice only once that batch is on disk, so a later choice outranks an older mark still in transit and survives a crash. A pin moved to another profile takes a new choice there, and the source keeps its own while a window there (or the parked set) still has the pin; a choice goes when its pin is unpinned or its profile deleted (also when loading a session, which also raises the generation counter above every loaded choice); a tile it only received publishes nothing, and a mark for a tab it has never had is never deleted. A mark that arrives before its tab is applied when the tab's `pin:t:` record lands, also when that tab is still open there from before an unpin. Unpinning deletes the mark (the rows adapter runs before `pin:`, so it still sees the tab's `pin:t:` record). A mark deleted by a pull (an unpin on another Mac, or a snapshot that left it out) changes nothing here: the `pin:` adapter applies the unpin, so the tab is never turned into a tile first and sent back over the deletion as a local edit (a pinned row deleted on another Mac while this one was away past tombstone retention came back as a tile; tested). A tab unpinned on an older Mac leaves its mark behind, unused unless that tab id is pinned again |
| `tilefold:<tab id>`, `tilefold:n:<folder id>` | profile | `{ f }`: the tile folder a pinned tile is in; `{ n }`: a folder's name | Tiles can sit in a folder tile in Top Apps (2026-10-23). A member's `pin:t:` record is a tile's (order included), so a Mac on a released version shows the folder's tabs as plain tiles side by side and loses none of them; it never writes `tilefold:` keys, so its edits (rename, reorder, close) leave the folder alone, and its unpin takes the tab out of the folder here. Member records carry membership only. A folder's name lives in its `tilefold:n:` record alone, so the newest write wins, by the record's sync timestamp like any record. A Mac writes it only for a name chosen on it (a rename, or a new folder given a name); a name it took from sync, or a folder whose name hasn't arrived yet (it shows as "Folder"), writes nothing, so joining, waiting or tidying can never make an older name look newer. Like `pinrow:`, the folder adapter runs before `pin:`: a mark that arrives before its tab files the tab when its `pin:t:` record lands, a mark for a tab never seen is never deleted, and an unpin deletes the mark, here or on any Mac (a released Mac's unpin leaves a `pin:t:` tombstone, and the mark goes with it). A folder's name record is deleted by the Mac that sees the folder go. A folder left with one tab on any Mac becomes that tile again there, parked pins included, and the deleted marks carry that to the others; a member moved to another profile leaves its folder. Tested against the 0.2.38 adapter, delayed files (concurrent renames, a name arriving after its tabs), a Mac joining and parked pins (sync/tileFolders.test.mjs) |
| `pgc:<group key>` | profile | `"none"` while a pinned group (top-level or nested) is set to None | Released top strips look a group's color up in a table of nine and throw on any other value, so `pin:g:` and `pinn:g:` carry None as `null` (Neutral, which those builds draw, and which since #154 shows no box at rest) and this record says it's None. No released version's prefix starts it, so older Macs keep it unapplied. A group is None here only while its `c` is `null` and this record is live: a color chosen on an older Mac (a non-null `c`) wins over a stale record, and the next current Mac to sync deletes the record; a rename there sends `null` again and keeps None. The record is deleted when the group here takes any other color, or when both its group records are deleted; one for a group this Mac doesn't have yet is kept. Its adapter runs before `pin:`, and `pin:` reads it when it applies a group, so a group arriving with its record arrives as None (sync/pinned.test.mjs, with the 0.2.40 adapters) |
| `pgh:<pin key>` | profile | the home URL of a tab in a pinned group, as a string (the page it was on when it joined, or the one Replace Pin or Edit Pinned Page set) | Tiles and rows keep their home in `pin:t:`'s `u`; a member's `pin:t:` still sends its current page, as 0.2.38 reads it, so this record carries the home beside it. No released version's prefix starts it (their pin adapter claims every `pin…` key, so it can't be one), so older Macs keep the records unapplied in their replica and snapshots and never delete them. The homes adapter runs before `pin:`: a tab that lands in the same pull as its home gets that home, and one already here is updated, unless its home was changed here since the last sync (that edit is published and wins). A Mac that gets a member before its home takes the page as its home, and publishes a home only over its own last synced one or when the scope has no live record for it, and only after a pull with nothing downloading or damaged this session, so a guess never replaces a home chosen elsewhere that it has seen. A member that leaves its pinned groups here deletes the record, and so does an unpin from any Mac, an older one included (its `pin:t:` tombstone). A deletion pulled from elsewhere changes no tab; the `pin:` adapter decides where the tab goes. Known residual: a home chosen in a Mac's first cycle of a session goes out in the batch after its pin's, and a Mac that has read the pin and not that batch, with no download pending, sends its guess (the pin's page, usually the same URL). Tested with a member arriving with its home, an edit, and the 0.2.40 adapters (sync/pinned.test.mjs) |
| `pord:g:<group key>` | profile | `{ a }`: the pin key of the row a top-level pinned group follows in the pinned section, or `null` above every row | Since 0.2.40 rows and pinned groups share one order. The `pin:` records keep the older shape and order (tiles, then rows, then groups, each in the user's order), so Macs on older versions, which sort rows ahead of groups, find nothing to correct and never publish their sorted order back; the interleaving lives only in these records, which they don't read, own or tombstone (no key of theirs starts with `pord`). Applying sorts rows and groups by `pin:` and then puts each group after its row, so an older Mac's reorder among rows or among groups still comes through and the groups follow their rows; a group with no record, or whose row is gone, goes after the last row. Published from the profile's frontmost window, or from its parked pins when no window shows it, and applied to both. A record whose group hasn't arrived yet is kept, and so is one whose row isn't a row here yet: it is never republished while it waits, with no deadline and nothing read from the local clock. The row counts as arrived only as a row (a tile that another Mac turned into a row waits for its `pinrow:` marker), and the wait ends early only on evidence, newer than the order record, that the row stopped being one: its `pin:t:` tombstone, a `pin:t:` record putting it in a group, or a `pinrow:` marker saying it's a tile. Any other change to the row (its title, its icon) and anything older than the order record leave the wait alone. Meanwhile every group whose record names a row this Mac doesn't have goes after the last row, in `pin:` order, so Macs holding the same records show the same order; a group with no record at all keeps the place `pin:` gives it. Only an explicit local choice replaces it: moving a pinned group or row on this Mac (a drag, Move Up/Down, a menu command, pinning or unpinning into a place) marks the groups whose place among the rows changed as chosen (`order:<group>` in `pinChoices`; rows added or removed, sync's own changes and the waiting fallback never do), and the next sync republishes their records with a fresh timestamp and clears the mark. A row deleted for good, whose tombstone was compacted away, leaves its record waiting until someone moves the group. Known and accepted: a Mac that was away past tombstone retention gets that deletion from a snapshot, which leaves no tombstone, so it can't tell the departed row from one still on its way and keeps the group waiting after the last row, so the group can sit in a different place there than on Macs that saw the tombstone, until someone moves it (skipped test in sync/adapters.test.mjs). Only the group's own `pin:g:` tombstone removes a record, never not finding it (tested against a pre-0.2.40 adapter, 0.2.38, out-of-order delivery and parked pins) |
| `pw:<origin>\n<username>` | profile | `{ o, u, p }` | see below |
| `ext:<id>`, `ext:v:<id>` | profile | an extension: `{ on, inc, pin }`, or `{ removed: true }` once the user removes it; and the newest version approved anywhere with its permissions, `{ v, fps }` | Chrome Web Store extensions only; see below |

Native pin publication settlement waits behind a held user transaction and compares stamps when it runs,
preserving a newer local choice. The 10 s hold limit has no timer: a stale hold is closed by the next relevant
store operation. A persistence flush can complete while settlement remains queued; an unchanged pending stamp
can therefore survive a restart and be published again.

### Extensions

What Chrome Sync does for extensions, through our folder (`packages/sync/src/extensions.ts`, the app's host in
`apps/browser/src/sync/extensions.ts`, Chrome's side in `engine/chromium/…/solara/ac_extensions_sync.cc`).
- **What syncs.** Extensions from the Chrome Web Store that Chrome itself would sync (`sync_util::ShouldSync`:
  installed by the user from the store, not by default, policy or a component, not blocklisted, no other update
  URL), and not themes or apps. Unpacked extensions, Solara Scripts and uBlock Origin (bundled) stay on their Mac. Per
  extension: on or off (the user's choice, Chrome's `DISABLE_USER_ACTION`), allowed in private windows, pinned to
  the toolbar (Chrome's saved pin, not whether it shows now). Not synced: its data and settings (`storage.sync`
  included), site access.
- **Installing.** A record for an extension this Mac lacks hands Chrome a sync install
  (`PendingExtensionManager::AddFromSync`, as `ExtensionSyncService` does); its updater fetches it from the Web
  Store with no prompt. Chrome 155's updater would grant the permissions of whatever version it fetched, so the
  install goes in with no version and Chrome installs it disabled whenever it has permission warnings. It is turned
  on only when the fetched version is the one approved on another Mac and its permissions (Chrome's permission ids
  and their hosts, `fps`) are among those approved for it (`ext:v:`); otherwise it stays off for its new permissions
  and the user turns it on with Chrome's prompt. A Mac publishes `ext:v:` only for a version whose permissions are
  granted there: a newer version replaces the record, the same version read with other permissions (another Chrome
  version) adds its reading to `fps`. The record is last-writer-wins, so two Macs approving different versions at
  once can briefly regress it; the newer Mac republishes its version on its next cycle. A record that arrives while
  an install is pending changes it before it lands, and an install isn't published until it has taken the synced
  state (its pin, which Chrome may have set by default). One that never lands is retried once per session, then
  hourly.
- **Removing.** Only the user's own removal (Settings › Extensions, the extension's menu, the Web Store, Chrome's
  extension page) is recorded, from the event Chrome reports (never from an extension going missing), with a
  revision Chrome's side mints so a quick remove and reinstall isn't lost. The record becomes `{ removed: true }`, a
  live value rather than a tombstone, so compaction and older Macs keep it. Sync never uninstalls anything: the
  other Macs keep their copy, stop installing it, cancel a sync install of it that's still waiting, and don't
  publish their copy back. An install of it that was already downloading still lands there, and isn't counted as
  the user's. Installing it again anywhere writes a newer record, which wins.
- **Joining** is a union: a joining Mac takes the synced state for extensions both have, keeps its own (and
  publishes them, also one the record says was removed). A Mac that was already syncing before this version
  doesn't publish an extension it holds a record for until it has applied that record.
- **Older Macs** (0.2.38, the 0.2.39 nightlies) keep `ext:` records in their replica and snapshots without
  applying them. A build whose engine lacks `ac_extensions_sync_*` publishes and applies nothing for extensions.
- Settings › Sync › What Syncs › Extensions turns it off; a profile that shares another's data has its owner's
  extensions.

### Passwords

Saved passwords are Chrome's (its password manager).
- **Reading.** Chrome's own API (`passwordsPrivate`) reveals a password only after device
  authentication, so sync reads the profile's `Login Data` with the importer's reader
  (`ChromiumSecrets`, `packages/import`). Chrome's key is its "Solara Safe Storage" item, or
  the mock keychain's where SolaraCoreHost uses that (test instances, ad hoc builds). No Touch ID prompt is needed each cycle, and no
  Chromium change.
  - The reader copies `Login Data` and its `-journal` and `-wal` (Chrome holds the file with an
    exclusive lock, so no second connection can read it). A copy taken while Chrome commits could
    hold half a transaction, and missing logins would read as deletions. So the copy is kept only
    when the files' sizes and modification times are the same before and after it, and otherwise
    retried, 50 times 20 ms apart, before the read gives up. On a volume with whole-second times
    (HFS+) that check can't see a commit in the same second, so the files are copied twice and the
    two copies must match byte for byte (`SQLiteSnapshot.copyUnchanged`, in packages/import and
    the native port's SolaraImport).
- **Writing.** Writes go through Chrome's API (`savePassword`, `deletePassword` in
  `@solara/solaracore`), so Chrome's in-memory store and autofill see them at once. A changed
  password is a delete plus an add: the update API needs the device check.
- **Safety.**
  - A read that finds any row it can't decrypt is skipped (a partial list would read as
    deletions).
  - After applying, sync waits until Chrome's store on disk shows the change before reading it
    again.
  - A login changed here but not read yet isn't overwritten.
  - Turning sync off, or turning Passwords off, never removes a password. Only a password
    deleted on another Mac is deleted here.
- **Cadence.** Passwords are read at most every 30 s (and at once with Sync Now).
- **Plain text in JS, until redesign step 11.** Until redesign step 11, with the redesign switch off, saved
  passwords pass through the app's JS in plain text during sync and are held in its memory and in the locally
  sealed sync state (sync-state.nns and sync-journal.nns, encrypted under the sync key in the Keychain); the sync
  folder holds them only inside chain-encrypted files. With the switch on, the native module seals each password
  for its login and JS only holds the sealed value; once sealing is on it stays on until the app quits, and the
  plain read refuses. The guarantee that even a compromised JS can't read a password lands with step 11, which
  removes the plain path.
- **The switch.** `SOLARA_SYNC_REDESIGN=1` in the environment turns the redesign on, through `LaunchSwitches`. Only an
  instance with its own data folder (`SOLARA_DATA_DIR`; `SOLARA_BACKGROUND` alone isn't enough, since that launch still
  opens the real folder) of a build not signed for distribution reads it. A
  Developer ID build ignores it, and so does any launch on the real data folder, including the owner's ad hoc builds,
  because turning it on is one-way for that data (the ledger goes to v2, and the state and journal are sealed under
  ids older builds can't open). It is never stored or shown in Settings › Experimental. JS gets it from the native
  store's `status()` before the store starts.
- **Sealed values (switch on).** A pw: value in JS is `{ o, u, s }`, never `{ o, u, p }`.
  - `s` is the password sealed under the chain's password key, bound to its origin and username and padded to 32
    bytes; the same password seals to the same `s`, so JS can still compare and digest it.
  - The folder format doesn't change: native seals pw: values as it reads files and opens them as it writes, so
    older Macs keep syncing. A write with a plain `p`, or an `s` that doesn't open, is refused, and the cycle
    stalls with a fault that names only `pw:`.
  - The local state and journal are sealed under new ids (`state.v2`, `journal.v2`); an older build can't open
    them and starts fresh instead of reading sealed values as passwords.
  - The password ledger (sync-pw-ledger.json) is v2, its digests over `s`. A v1 ledger is migrated natively once
    Login Data reads cleanly and the state is known; until then password sync pauses rather than rebuilding. A
    journal that exists but doesn't open keeps it paused for the rest of the session, because its unsent batches
    may hold records the migration would otherwise read as published.
  - Before a login is offered, its `s` is checked against this chain's key. One that doesn't open is left out of
    the cycle (not published, not removed, not stamped, not overwritten by a newer record) and offered again next
    cycle.
  - Saving opens `s` natively (`saveSealedPassword`); JS never gets the password back.

## UX (from Dia's binary)

Settings › Sync. Dia puts sync in Account › Sync, with the section icon
`arrow.triangle.2.circlepath`.

- **Off.** The row reads "Sync · Off", with **Turn On Sync** and **Enter Recovery Phrase…**. If
  the folder already has sync data, the primary button is **Enter Recovery Phrase…**, next to
  **Other Options** (Dia's menu: "Set Up Without Another Device", "Enter Recovery Phrase").
  Below is the sync folder, with Choose…. If iCloud Drive is off it says so, links to iCloud
  settings, and offers another folder; test instances never default to iCloud Drive.
- **Turn On Sync** makes a phrase and shows **Save Your Recovery Kit**, with Dia's copy:
  - "Your Recovery Kit contains all you need to recover your data should you lose access to
    this device."
  - "Save a copy of your Recovery Kit to another device or to the cloud. You'll need it if you
    lose access to this device.", with "another" underlined.
  - A preview of the page.
  - Buttons: Save…, Close, and Other Options (Copy, Share…, Save as Text…).
  - The PDF is "Solara Recovery Kit.pdf", US Letter as Dia's, with the 24 words and a QR code.
- **Connect with Recovery Phrase.**
  - Dia's copy: "Enter your 24-word recovery phrase to sync with another device.", the
    placeholder "Enter your 24-word recovery phrase", the "%d/%d words" counter, "too many
    words", and Connect / "Connecting…" / Cancel.
  - It also shows the folder the phrase is checked against, with Change….
- **On.**
  - The status line uses Dia's words: "starting up", "updating", "updated just now", "not
    syncing · last synced %@" and "offline" (the folder isn't there: a drive is unplugged, or
    iCloud Drive is off). Downloads still to come add "· waiting for N files to download".
  - **Connect Another Device…** offers Connect another Mac, with "On the new Mac, open Solara and
    choose Use Solara from your other Mac. Then arm this Mac to compare the codes and approve."
    (see Pairing a new Mac below). Use Recovery Phrase… keeps the old way: the steps for the other
    Mac and a QR code of the phrase, to scan with an iPhone and paste on the Mac with Universal
    Clipboard, plus Show Words and Copy Words. The pairing code is not that QR code. Dia's version
    is an OTP between signed-in devices, which needs its server.
  - **Advanced…** has Save Recovery Kit…, Copy Recovery Code (Dia's ⌥ item, copied as
    `org.nspasteboard.ConcealedType`), Sync Now, Show Sync Folder in Finder and Stop Syncing….
  - Then Profiles (toggles, and Add to This Mac), What Syncs (Bookmarks, History, Open Tabs,
    Pinned Tabs and Groups, Passwords, Extensions, Settings) and Devices (each with "last synced …").
- **Stop Syncing This Device?** Dia's copy, plus "Everything on this Mac stays as it is", with
  Save Recovery Kit / Cancel / Stop Syncing.
  - Then **Delete Sync Data?**: "Would you also like to permanently delete your synced data
    from the sync folder? …", the checkbox "I understand this cannot be undone", and Keep Sync
    Data / Delete My Sync Data.
  - Stopping removes this Mac's tabs and name from the other devices and forgets the key. It
    keeps all local data.
  - Deleting removes this phrase's chain folder. The other Macs then show Dia's "This device is
    out of sync. Sync may have been reset from another device." and stop, keeping their data.
- **Pairing a new Mac.** The new Mac's onboarding finds the sync in the folder and offers "Use
  Solara from your other Mac". It says "Open Solara on your other Mac and choose Connect another
  Mac or Review request." On the other Mac, a request shows only a quiet indicator: no sheet, no
  notification, no name. Connect another Mac or Review request opens a 120-second window to
  select the request, with "Only continue if you just started connecting your other Mac." and an
  "I didn't request this" that keeps the indicator hidden until the owner opens pairing again.
  Both Macs then show the same six characters and the other's claimed name. "The code matches on
  my other Mac" must be checked before Allow, which asks for Touch ID or the login password. A
  mismatch says "The codes don't match. Nothing was connected." The recovery phrase still works
  everywhere instead.
- **Overflow menu.** One other device with open tabs shows "Your %@ Tabs" (the kind of Mac, from
  its name: "Your MacBook Pro Tabs"). Several roll up into **Your Devices**
  (`macbook.and.iphone`), a submenu per device. Each lists "Recent Tabs"; picking one opens it
  in a new tab. The fallback name is "Unknown Device".

## Cycle

The engine (`apps/browser/src/sync/engine.ts`) runs a cycle 15 s after the last one, 3 s after a
bookmark, settings, profile or group edit, and on Sync Now. A cycle:
1. Checks the chain folder: gone means reset elsewhere; the folder missing means offline.
2. Syncs the app scope and links profiles.
3. Syncs each synced profile's scope, publishing, flushing, pulling, and then publishing and
   applying per adapter.
4. Compacts when due.
5. Saves `sync.json` (in the app's data folder): links, settings of sync and the last seq written
   per scope; and the sealed state: the replica, base, version vectors and known files.

### The saved state on disk

- `sync-state.nns` is the full state, a compaction. Besides the scopes it holds `~n` (a counter that only goes up),
  `~epoch` (random, new at every compaction) and `~device`. An older build skips those keys.
- Each later save writes only what changed since the last one landed, as
  `sync-state-d-<device>-<n>-<epoch>-<g>.nns` with `g` = 1, 2, ...: per scope, the changed and removed keys of
  `records`, `base` and `files`, the small fields that changed, and a long list of keys (`unapplied`) as what left
  and what joined. Each is sealed for its own name, so a delta can't be replayed as another.
- A compaction happens on the first save after a launch, after 200 deltas or 1 MB of them, after an hour, when a
  scope is added, removed or replaced, when the device changes (turning on, joining) and after a gap. Its deltas
  are removed one compaction later, so a power cut that keeps the removal but loses the new full state still finds
  the previous state's deltas.
- At load, deltas of the full state's `n` and `epoch` are replayed in order. One from another device, or more than
  one compaction old, is deleted. A full state with no `~n` (an older build saved it) deletes every delta. A
  missing `g`, a delta that doesn't open or doesn't apply, a delta of a later `n` or another epoch (a lost
  compaction), or a name under the delta prefix that doesn't parse (a newer build's) is a gap: replay stops there,
  every scope rebuilds as after a lost state, the ledger migration waits for a full cycle as it does then, and the
  next save compacts.
- An older build reads only `sync-state.nns`, at most one compaction old, and takes the rolled-back path below.
- Stop clears the full state and every delta; a delta that lands after that belongs to a dead generation and is
  deleted at the next load.

### After a load: lost and rolled-back state

The saved state can come back older than the folder (a lost save, a restored backup) or not at
all (unreadable, foreign, malformed). Either way its base no longer says what this Mac published,
so a plain diff would send stale local values over newer edits made elsewhere. The guard around
each scope's cycle (`guard` in `engine.ts`) holds that back.

- **What this Mac had.** At launch, before the state loads (so edits made while locked count), the
  engine notes what each adapter extracts, for every data type except history and passwords when
  they're off. Passwords are read last, so a slow keychain doesn't hold up the rest. Bookmarks and
  history are noted as soon as they load; extensions at their first extraction. A key the note
  doesn't have counts as changed only against the kept note. Derived positions (`pos`) don't
  count when comparing.
- **The first look after a load.** For each adapter:
  - the first cycle publishes nothing until it has pulled;
  - the held outbox and an older build's revived batches go out after the pull, under a seq past
    every one of this Mac's seqs in the folder;
  - a value that differs from base goes out, unless it matches a value the pull delivered,
    stamped after the state's own record, or the key is still waiting to be applied. That is what
    a rolled-back copy looks like. A value the user changed since the note always goes out.
  - While a file is still downloading or can't be read yet, a fresh scope publishes and applies
    nothing, for up to ten minutes after the load. A rolled-back state can't see its own newer
    batches or another Mac's newer edits until they arrive. On a healthy Mac this delays its first
    publish after a launch while iCloud catches up.
- **Known gaps in this guard** (review5, being replaced by docs/sync-redesign.md):
  - A type turned on mid-session skips the first look.
  - A stuck download holds every launch for ten minutes.
  - An edit made during that wait, followed by a relaunch inside it, can be reverted.

- **Rebuild.** A lost state, or one found behind its own seqs in the folder, gets a rebuild marker,
  saved with the state and settled per adapter prefix. Until a prefix settles:
  - it publishes keys the folder never had (not while a download younger than a day or a damaged
    file is pending);
  - it publishes values changed this session, unless the folder's record already has them;
  - it publishes values changed against the kept note in an earlier session only if the folder
    never delivered them;
  - everything else takes the folder's value.
  While a download younger than a day or a damaged file is pending, a rebuilding prefix applies
  nothing either: the bookmarks adapter rebuilds the whole tree from what's visible, so applying a
  partial replica would remove the rest locally. The kept note is saved in the marker as digests,
  so a relaunch doesn't forget an edit made after the loss. A prefix settles once the pull is complete, its adapter is ready, nothing is
  unapplied, and no value disagrees with the folder; disagreeing values are queued for apply. The
  marker stays while a data type is off, so turning it on later is still guarded.
- **Known residuals** (each from a review or the convergence oracle):
  - On a healthy relaunch, a setting chosen here that equals a value another Mac once had, in
    batches this Mac hadn't pulled, is taken for a rolled-back copy and loses to that Mac's later
    value.
  - A rolled-back state that wrote nothing after the backup goes undetected once compaction has
    removed the values it took.
  - A rebuild an older build started forgets that build's baseline.
  - A rolled-back state whose own batch is still downloading after the ten-minute wait can reuse
    its seq.
  - Passwords saved while a rebuilding Mac can't read them are taken as stale.
  - A rolled-back state with a password it couldn't apply yet resends its older copy, because a
    password waiting to be applied isn't taken as stale: passwords can be edited while unreadable.

## Tests

- `pnpm --filter @solara/sync test`:
  - `swift test`: 5 tests. BIP39 reference vectors; tampering and truncation are detected; the
    wrong phrase opens nothing; the folder holds no plaintext in names or contents; deleting one
    chain leaves another.
  - `node --test`: 28 tests. Extensions (19): install with state and approval, no echo; on/off,
    incognito and pin both ways; a removal as a live record, never reinstalled, beaten by a reinstall; an uninstall and
    reinstall before publishing; union on joining; a joiner takes the synced state; no grant for a newer store version
    or other permissions; a grant for a Mac that already has the approved version; a missing or null record and an
    ineligible extension never remove anything; nothing before Chrome is ready; a lost pending install retried; a
    change while pending; a removal cancels a pending install; an older Mac keeps the records through its snapshots;
    an upgraded Mac doesn't republish a copy whose removal it held; another Chrome's reading of the same version's
    permissions is added without a loop; an install still settling isn't published; on a framework without the engine
    calls nothing is published or applied and the records wait. The rest (9): Concurrent edits converge in any order; deletes, re-adds and
    edit-after-delete; clock skew; late, out-of-order and half-copied files; an edit during a read;
    an old snapshot put back after its tombstones were collected; a tombstone kept past its age
    limit while an older log is missing, for twice the limit at most; a write that fails before or
    after the file lands; 40 randomized three-device runs with flaky delivery, compaction and crashes.
- `pnpm --filter @solara/browser test` runs `src/sync/adapters.test.mjs` (4 tests against the real
  store: delete versus add, concurrent moves that would make a cycle, parked pinned tabs, passwords
  both ways), `src/sync/pinned.test.mjs` (the pinned area's adapters in their order: a row and a tile folder land as
  such, an unpin deletes the marks with the pin, the app's old names are read as today's, pinned group tabs' homes go across and
  survive a Mac on the previous version) and `src/sync/engine.test.mjs` (the engine against a fake native module: a crash the
  moment a batch lands re-sends the journalled batches byte for byte and numbers the next one after
  them; nothing is published before its journal is on disk). `src/sync/engineSafety.test.mjs` and
  `src/sync/engineRecovery.test.mjs` pin each engine bug a review or the oracle found (B1–B74), each
  failing on the commit before its fix.
- Convergence oracle: `node apps/browser/scripts/native/engineScenario.mjs --oracle <n> --seed <s>`
  runs two Macs in separate processes against the real engine, store and adapters. They edit,
  crash, lose, damage or roll back their state, go locked and fail writes at random, then settle.
  Both must end with the same data, the latest choice for each key by stamp must win, and no seq
  may carry two different batches (`--help` lists what it excuses). It also hides the newest folder
  files from one Mac as pending or damaged for up to nine minutes, inside the fresh scope's wait. It doesn't cover extensions (no fake of
  Chrome's engine calls).
- End to end: `node packages/sync/scripts/e2e.mjs [Debug app] [work dir]` drives two hidden
  instances (then a third) with their own data folders through a temporary sync folder, never
  iCloud Drive, over the dev harness. It checks 54 things, and all 54 passed on 2026-10-21 (Debug
  build), including pinned rows, tiles and a pinned group, an unpin, and B quit and relaunched.
  - Extensions, with real Chrome Web Store extensions over the network (Picture-in-Picture by Google, Google
    Translate): A installs one through Chrome's updater with no prompt; it comes in off for its permissions until
    A's user accepts Chrome's prompt; then it reaches B approved and on (same version, same permissions). A's
    disable turns it off on B; B's enable and pin reach A. B quit while an install was pending installs it after
    relaunching. B's removal makes the record `{ removed: true }` on both; B doesn't install it again, and A keeps its
    copy without publishing it back.
  - B rejects four wrong phrases: someone else's valid phrase ("mismatch"), two words swapped
    (checksum), a word not on the list, and 23 words. Then it joins with the kit's numbered, upper-case lines.
  - After joining: A's bookmarks, history, pinned tab (unloaded) and password (in Chrome's password
    manager) are on B, and B's own bookmark and password are on A. B took the synced settings.
    The two converge.
  - B's rename, delete and new bookmark, history delete and new visit, settings (a null one
    included), and password change and delete all reach A. A's move out of a folder, folder
    delete, new bookmark in Other Bookmarks, new pinned tab and new password reach B.
  - Open tabs: A shows B's tabs but not its pinned ones. "Your … Tabs" with "Recent Tabs" for one
    device, "Your Devices" for two.
  - Concurrent edits to one bookmark, one setting and one password converge, and the later edit
    wins. Idle rounds write no files.
  - A half-copied file and an iCloud placeholder aren't applied ("waiting for 1 file"). Both apply
    once whole.
  - The folder: no plaintext in names or contents (13 strings searched: titles, URLs, the password,
    usernames, device and setting names), every file padded to 1 KiB. Each Mac's own sync state
    holds no plaintext password.
  - A third Mac joins from the folder as it is (logs and a snapshot) and converges.
  - Turning sync off on B keeps its bookmarks, history, settings, pinned tabs and passwords, and
    removes its key. A drops B's device and tabs, and what B does while off stays on B.
  - Delete My Sync Data on A empties the folder. C shows Dia's reset message and stops, and A and C
    keep all their data.

  The runs found and fixed:
  - Settings whose value is null bounced between Macs: a null record is a tombstone, so settings
    are now wrapped.
  - Two instances launched in the same millisecond made the same store ids: `newId` now has a
    random part.
- Pairing end to end: `METRO_PORT=<your Metro> node packages/sync/scripts/pairing-e2e.mjs <Debug .dev app> [work dir]
  [--only=<case,…>] [--keep] [--require-all]` drives a trusted Mac and a joining Mac, two hidden instances with
  their own data folders, through one scratch sync folder, using the typed probes (`onboarding.sync`,
  `sync.enable`, `pairing.trusted.*`). Its scanner's unit tests:
  `node --test packages/sync/scripts/pairing-scan.test.mjs` (16).
  - Discovery (6): an empty or missing folder continues setup, one chain leads with pairing, two need a choice, an
    unreadable folder is "permission denied", malformed entries aren't chains; the joining probe drives onboarding.
  - Mailbox isolation (4), with T unarmed: a request tampered under the same name (public key, name, commitments), a
    partial request completed later, a foreign or stale replay across a restart, and a flood of 300 requests with
    oversized, truncated and symlinked entries. Both Macs stay unjoined, T stays enabled with its chain bytes
    unchanged and never answers, and a file outside the pairing namespace survives.
  - Pairing (5): pair, deny, not me, cancel while comparing, and a crash after commit. Pairing refuses while the
    screen is locked, so these fail at once on a locked screen. Allow needs the owner's password or Touch ID, which a
    hidden instance can't give: the cases that need it run to Allow, check that it is refused and that T is still
    comparing with nothing recorded, and end in an owner check, printed at the end with the steps to finish by hand
    (the join itself, and the resume after a crash). An owner check is neither a skip nor a failure.
  - Privacy: after each case and over the whole work dir at the end, every byte of the sync folder, the logs,
    `Application Support/sync-pairing` and each instance's data (Chromium's state included; only its named caches
    are skipped, and the bytes skipped are printed) is searched for T's root key and phrase, the comparison code,
    the claimed name and this Mac's name, raw and encoded. A leak names only what and where.
  - Mismatched codes, an expired request and a cancel that can't be recorded are left to the native pairing tests
    (`packages/sync/tests/Pairing*Tests.swift`).
  - 2026-11-02, Hill Studio, screen locked, f5859483: discovery, mailbox isolation and the privacy scan passed
    (12/12) twice; the pairing cases failed fast on the lock. Still to run: the full `--require-all` run on an
    unlocked screen, which must pass everything up to Allow and print two owner checks.

## Left for a person

A real two-Mac run over iCloud Drive: turn on sync on one Mac, save the kit, enter the phrase on
the other, and watch bookmarks, history, pinned tabs, passwords and settings go both ways. Also
check the iCloud Drive permission prompt, if macOS shows one the first time. Then pair a third
Mac over iCloud Drive: the request reaching the other Mac, an offline Mac, sleep and wake, and
pairing finishing inside five minutes. The tests use a temporary folder, never iCloud Drive.

## Bookmark ownership in 0.3.0

The application selects native bookmark authority once per process, before catalog observation or raw admission.
Distribution ignores environment and stored attempts to disable ownership. An isolated development launch can
opt in with `SOLARA_NATIVE_BOOKMARKS=1`; off, partial scope, API skew, failed claim and teardown never choose a
JS writer. Reload subscribes to the same native lifetime. API version 3 requires ownership and projection feeds.

The coordinator journals local edit facts; the existing JS Cycle mints HLCs and owns transport and publication.
The native bookmark adapter synchronously accepts the document and remote record observations in one durable
transaction. Refusal does not advance the bm prefix/base. A visible view is not sync readiness: migration and
read-only recovery hold `readyForSync`, including the existing full-prefix rebuild/download hold.

The legacy source is a baseline, not a newly timed local edit. Journal intent and original consumed identities
survive relaunch; neither a stale display cache nor a retained source may recreate an imported deletion.
The migration pump must push and confirm a real Chrome read before releasing readiness. Safe mode uses a
read-only journal decoder and projection: show/open remain available, edits and sync pause with a notice,
and no bookmark journal, source, backup or cache is written or renamed.

URLs use Chrome's GURL spelling with preserved wire provenance and no new sync edit for adoption. Bookmark
wire strings retain arbitrary JavaScript UTF-16 code units. Last-profile deletion/reset discards the engine's
unsynced edits; a surviving alias remap still preserves and drains pending intent.

Returning to 0.3.0 resumes native journal authority idempotently. Downgrading to 0.2.5 is unsupported. There is
no handback protocol, downgrade marker or attempt to make an older binary understand pending native intent.
