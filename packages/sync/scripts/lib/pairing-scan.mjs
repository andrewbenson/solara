import assert from "node:assert/strict";
import { constants, openSync, closeSync, fstatSync, readSync, readdirSync, lstatSync, realpathSync } from "node:fs";
import { join, relative, isAbsolute, resolve } from "node:path";
import { createHash } from "node:crypto";

export function readEvidenceFile(fd, size, read = readSync) {
  const data = Buffer.alloc(size);
  let offset = 0;
  while (offset < size) {
    const count = read(fd, data, offset, size - offset, offset);
    assert.ok(count > 0, "evidence shrank while reading");
    offset += count;
  }
  assert.equal(read(fd, Buffer.alloc(1), 0, 1, size), 0, "evidence grew while reading");
  return data;
}

export function directoryBytes(root, { entries = 1000000 } = {}) {
  let visited = 0, total = 0;
  const walk = (dir) => {
    for (const entry of readdirSync(dir)) {
      assert.ok(++visited <= entries, "skipped directory entry bound exceeded");
      const stat = lstatSync(join(dir, entry));
      if (stat.isDirectory()) walk(join(dir, entry));
      else if (stat.isFile()) total += stat.size;
    }
  };
  walk(root);
  return total;
}

export function evidenceFiles(root, { entries = 8192, bytes = 64 * 1024 * 1024, skipDirectory = () => false } = {}) {
  assert.ok(Number.isSafeInteger(entries) && entries >= 0, "invalid evidence entry bound");
  assert.ok(Number.isSafeInteger(bytes) && bytes >= 0, "invalid evidence byte bound");
  root = resolve(root);
  const rootInfo = lstatSync(root);
  assert.ok(rootInfo.isDirectory() && !rootInfo.isSymbolicLink(), "evidence root must be a real directory");
  const canonical = realpathSync(root);
  const files = [], links = [], skipped = [];
  let visited = 0, read = 0;
  const inside = (file) => {
    const rel = relative(canonical, realpathSync(file));
    assert.ok(!isAbsolute(rel) && rel !== ".." && !rel.startsWith("../"), "evidence escaped scratch");
  };
  const walk = (dir) => {
    inside(dir);
    const directory = lstatSync(dir);
    assert.ok(directory.isDirectory() && !directory.isSymbolicLink(), "evidence directory changed");
    for (const entry of readdirSync(dir).sort()) {
      assert.ok(++visited <= entries, "evidence entry bound exceeded");
      const file = join(dir, entry), rel = relative(canonical, file), stat = lstatSync(file);
      if (stat.isSymbolicLink()) { links.push(rel); continue; }
      inside(file);
      if (stat.isDirectory()) { if (skipDirectory(rel)) skipped.push({ relative: rel, bytes: directoryBytes(file) }); else walk(file); continue; }
      assert.ok(stat.isFile() && stat.nlink === 1, "nonregular evidence file");
      const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const opened = fstatSync(fd);
        assert.ok(opened.isFile() && opened.nlink === 1 && opened.ino === stat.ino && opened.dev === stat.dev, "evidence changed while opening");
        read += opened.size;
        assert.ok(read <= bytes, "evidence byte bound exceeded");
        const data = readEvidenceFile(fd, opened.size);
        assert.equal(data.length, opened.size, "evidence changed while reading");
        files.push({ relative: rel, bytes: data });
      } finally { closeSync(fd); }
    }
    const after = lstatSync(dir);
    assert.ok(after.isDirectory() && after.ino === directory.ino && after.dev === directory.dev, "evidence directory changed");
  };
  walk(canonical);
  return { files, links, skipped };
}

export function secretNeedles(label, value) {
  const raw = Buffer.isBuffer(value) ? value : Buffer.from(value);
  const values = [raw, Buffer.from(raw.toString("hex")), Buffer.from(raw.toString("hex").toUpperCase()), Buffer.from(raw.toString("base64")), Buffer.from(raw.toString("base64url"))];
  if (!Buffer.isBuffer(value)) {
    const code = label === "SAS" ? value.replaceAll(" ", "") : "";
    const grouped = code.length === 6 ? code.slice(0, 3) + " " + code.slice(3) : code;
    for (const text of new Set([value, value.normalize("NFC"), value.normalize("NFD"), ...(label === "SAS" ? [code, grouped, value.toLowerCase(), code.toLowerCase(), grouped.toLowerCase()] : []), ...(label.startsWith("phrase") ? [JSON.stringify(value.split(/\s+/)), value.split(/\s+/).join("\n"), value.split(/\s+/).map((word, i) => `${i + 1}. ${word}`).join("\n")] : [])])) {
      values.push(Buffer.from(text), Buffer.from(text, "utf16le"), Buffer.from(JSON.stringify(text).slice(1, -1)), Buffer.from(text.replace(/[^\x20-\x7e]/g, (character) => "\\u" + character.charCodeAt(0).toString(16).padStart(4, "0"))));
    }
  }
  const unique = new Map(values.filter((bytes) => bytes.length > 0).map((bytes) => [bytes.toString("hex"), bytes]));
  return [...unique.values()].map((bytes) => ({ label, bytes }));
}

export function findLeaks(bytes, needles) {
  return [...new Set(needles.filter((needle) => bytes.includes(needle.bytes)).map((needle) => needle.label))];
}

export function phraseFor(entropy, words) {
  assert.equal(entropy.length, 32);
  assert.equal(words.length, 2048);
  const checksum = createHash("sha256").update(entropy).digest()[0];
  const bits = [...entropy, checksum].map((b) => b.toString(2).padStart(8, "0")).join("");
  return bits.match(/.{11}/g).map((part) => words[parseInt(part, 2)]).join(" ");
}
