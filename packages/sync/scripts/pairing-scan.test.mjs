import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, linkSync, rmSync, openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { evidenceFiles, findLeaks, phraseFor, readEvidenceFile, secretNeedles } from "./lib/pairing-scan.mjs";

const words = Array.from({ length: 2048 }, (_, i) => `word${i}`);

test("BIP39 checksum includes the entropy checksum bits", () => {
  const phrase = phraseFor(Buffer.alloc(32), words).split(" ");
  assert.equal(phrase.length, 24);
  assert.deepEqual(phrase.slice(0, 23), Array(23).fill("word0"));
  assert.equal(phrase[23], "word102");
  assert.throws(() => phraseFor(Buffer.alloc(31), words));
  assert.throws(() => phraseFor(Buffer.alloc(32), words.slice(1)));
});

test("scanner detects binary, hex, base64, UTF16, grouped SAS and names without echoing them", () => {
  const root = Buffer.from("0123456789abcdef0123456789abcdef");
  const needles = [...secretNeedles("E", root), ...secretNeedles("phrase", "a special recovery phrase"), ...secretNeedles("SAS", "ABC DEF"), ...secretNeedles("name", "Alice’s Mac")];
  for (const bytes of [root, Buffer.from(root.toString("hex")), Buffer.from(root.toString("base64")), Buffer.from("a special recovery phrase", "utf16le"), Buffer.from("ABCDEF"), Buffer.from("Alice’s Mac")]) {
    const leaks = findLeaks(bytes, needles);
    assert.ok(leaks.length);
    assert.ok(!JSON.stringify(leaks).includes("Alice"));
  }
  assert.deepEqual(findLeaks(Buffer.from("New Mac / Trusted Mac"), needles), []);
});

test("evidence traversal never follows symlinks and fails closed on scan bounds", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-helper-"));
  try {
    mkdirSync(join(root, "inside"));
    writeFileSync(join(root, "inside", "one"), "safe");
    symlinkSync("/etc", join(root, "outside"));
    const result = evidenceFiles(root);
    assert.deepEqual(result.files.map((f) => f.relative), ["inside/one"]);
    assert.deepEqual(result.links, ["outside"]);
    assert.throws(() => evidenceFiles(root, { entries: 1 }), /bound/);
    assert.throws(() => evidenceFiles(root, { bytes: 1 }), /bound/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("bounded evidence reads reject growth without allocating from the grown size", () => {
  let reads = 0;
  assert.throws(() => readEvidenceFile(0, 3, (fd, buffer, offset, length) => {
    reads++;
    buffer.fill(65, offset, offset + length);
    return length;
  }), /grew/);
  assert.equal(reads, 2);
});

test("scanner detects JSON Unicode escape spelling of a real name", () => {
  const needles = secretNeedles("name", "Alice’s Mac");
  assert.deepEqual(findLeaks(Buffer.from("Alice\\u2019s Mac"), needles), ["name"]);
});

test("evidence scan refuses a replaced namespace root symlink", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-root-"));
  try {
    mkdirSync(join(root, "outside"));
    symlinkSync(join(root, "outside"), join(root, "namespace"));
    assert.throws(() => evidenceFiles(join(root, "namespace")), /root/);
    assert.throws(() => evidenceFiles(join(root, "namespace") + "/"), /root/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("privacy scanner finds phrase word arrays and lowercase SAS", () => {
  assert.deepEqual(findLeaks(Buffer.from('["one","two","three"]'), secretNeedles("phrase", "one two three")), ["phrase"]);
  assert.deepEqual(findLeaks(Buffer.from("abc def"), secretNeedles("SAS", "ABC DEF")), ["SAS"]);
});

test("evidence includes the final byte at an exact byte bound", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-tail-"));
  try {
    const payload = Buffer.concat([Buffer.alloc(128 * 1024, 65), Buffer.from("LAST SECRET")]);
    writeFileSync(join(root, "large"), payload);
    const result = evidenceFiles(root, { entries: 1, bytes: payload.length });
    assert.deepEqual(result.files[0].bytes, payload);
    assert.deepEqual(findLeaks(result.files[0].bytes, secretNeedles("name", "LAST SECRET")), ["name"]);
    assert.throws(() => evidenceFiles(root, { bytes: payload.length - 1 }), /bound/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("evidence rejects invalid limits rather than bypassing scan bounds", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-limits-"));
  try {
    for (const value of [-1, NaN, Infinity, 0.5, "2"]) {
      assert.throws(() => evidenceFiles(root, { entries: value }), /bound/);
      assert.throws(() => evidenceFiles(root, { bytes: value }), /bound/);
    }
    assert.deepEqual(evidenceFiles(root, { entries: 0, bytes: 0 }), { files: [], links: [], skipped: [] });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("evidence skips file and dangling symlinks and rejects hard links", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-links-"));
  try {
    writeFileSync(join(root, "one"), "safe");
    symlinkSync("one", join(root, "file-link"));
    symlinkSync("missing", join(root, "dangling"));
    const result = evidenceFiles(root);
    assert.deepEqual(result.links, ["dangling", "file-link"]);
    assert.deepEqual(result.files.map(file => file.relative), ["one"]);
    linkSync(join(root, "one"), join(root, "hard"));
    assert.throws(() => evidenceFiles(root), /nonregular/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("evidence reads handle partial reads and fail closed on shrinkage", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-reads-"));
  let fd;
  try {
    writeFileSync(join(root, "one"), "abcdefgh");
    fd = openSync(join(root, "one"), "r");
    assert.deepEqual(readEvidenceFile(fd, 8), Buffer.from("abcdefgh"));
    assert.throws(() => readEvidenceFile(fd, 9), /shrank/);
    let calls = 0;
    assert.deepEqual(readEvidenceFile(0, 4, (descriptor, data, offset, length, position) => {
      calls++;
      if (position === 4) return 0;
      assert.equal(position, offset);
      data[offset] = 65 + position;
      return 1;
    }), Buffer.from("ABCD"));
    assert.equal(calls, 5);
    assert.throws(() => readEvidenceFile(0, 2, () => 3), /read/);
  } finally {
    if (fd !== undefined) closeSync(fd);
    rmSync(root, { recursive: true, force: true });
  }
});

test("scanner detects short claimed names and returns labels once", () => {
  const needles = secretNeedles("name", "Bo");
  assert.deepEqual(findLeaks(Buffer.from("Bo Bo"), needles), ["name"]);
  assert.deepEqual(findLeaks(Buffer.from("ordinary"), needles), []);
  assert.deepEqual(secretNeedles("empty", ""), []);
});

test("BIP39 checksum matches the all-ones entropy vector", () => {
  const phrase = phraseFor(Buffer.alloc(32, 255), words).split(" ");
  assert.deepEqual(phrase.slice(0, 23), Array(23).fill("word2047"));
  assert.equal(phrase[23], "word1967");
});

test("scanner detects grouped spelling of an ungrouped native SAS", () => {
  const needles = secretNeedles("SAS", "ABCDEF");
  assert.deepEqual(findLeaks(Buffer.from("ABC DEF"), needles), ["SAS"]);
  assert.deepEqual(findLeaks(Buffer.from("abc def"), needles), ["SAS"]);
});

test("scanner keeps unique nonempty representations", () => {
  const needles = secretNeedles("name", "Alices Mac");
  assert.equal(new Set(needles.map(needle => needle.bytes.toString("hex"))).size, needles.length);
  assert.ok(needles.every(needle => needle.bytes.length > 0));
});

test("evidence skips only the directories the caller names", () => {
  const root = mkdtempSync(join(tmpdir(), "pairing-helper-"));
  try {
    mkdirSync(join(root, "case", "T", "Chromium"), { recursive: true });
    writeFileSync(join(root, "case", "T", "Chromium", "big"), "x".repeat(64));
    writeFileSync(join(root, "case", "T", "app.out.log"), "log");
    const skipDirectory = (relative) => relative === "case/T/Chromium";
    const result = evidenceFiles(root, { bytes: 8, skipDirectory });
    assert.deepEqual(result.files.map((f) => f.relative), ["case/T/app.out.log"]);
    assert.deepEqual(result.skipped, [{ relative: "case/T/Chromium", bytes: 64 }]);
    assert.throws(() => evidenceFiles(root, { bytes: 8 }), /bound/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
