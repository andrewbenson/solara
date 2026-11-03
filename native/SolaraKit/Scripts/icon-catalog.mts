const HELP = `Writes the icon picker's catalog, Sources/SolaraUI/Sidebar/IconCatalogData.swift, from Unicode's emoji list and CLDR's
English emoji names and keywords.

  node native/SolaraKit/Scripts/icon-catalog.mts <emoji-test.txt> <annotations.json> <annotationsDerived.json> <CLDR version>

  emoji-test.txt           https://unicode.org/Public/emoji/latest/emoji-test.txt
  annotations.json         cldr-json: cldr-annotations-full/annotations/en/annotations.json
  annotationsDerived.json  cldr-json: cldr-annotations-derived-full/annotationsDerived/en/annotations.json
  CLDR version             the "version" in cldr-annotations-full/package.json

The catalog in the tree was made from Unicode emoji 18.0 (emoji-test.txt dated 2026-04-30) and CLDR 49.0.0.

Every fully-qualified emoji goes in, in Unicode's order and groups, except the skin-tone and hair components and the
skin-tone variants of people (the base emoji stays). Each carries its CLDR name and keywords for search. The SF Symbols
set and its keywords are listed here. The catalog goes in as one raw-string JSON literal, decoded when the picker
first opens, so SolaraUI needs no resource bundle (the same as BangList.swift). The app drops emoji that Apple Color
Emoji doesn't draw as one glyph, so a newer list than the system's font is safe.`;

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}
if (args.length !== 4) {
  console.error(HELP);
  process.exit(64);
}

const GROUP_SYMBOLS: Record<string, string> = {
  "Smileys & Emotion": "face.smiling",
  "People & Body": "person",
  "Animals & Nature": "pawprint",
  "Food & Drink": "fork.knife",
  "Travel & Places": "car",
  "Activities": "soccerball",
  "Objects": "lightbulb",
  "Symbols": "heart",
  "Flags": "flag",
};

const SYMBOLS: [string, [string, string][]][] = [
  ["Favorites", [
    ["star", "favorite star"], ["heart", "love like heart"], ["bookmark", "bookmark save"], ["flag", "flag mark"], ["pin", "pin"],
    ["bolt", "lightning fast bolt"], ["flame", "fire hot flame"], ["sparkles", "magic new sparkles"], ["crown", "crown king best"],
    ["checkmark.seal", "verified done check"], ["tag", "tag label"], ["bell", "bell notification alert"],
  ]],
  ["Work", [
    ["briefcase", "work job briefcase"], ["building.2", "office company building"], ["doc.text", "document doc text"],
    ["folder", "folder files"], ["tray", "inbox tray"], ["archivebox", "archive box"], ["paperclip", "attachment paperclip"],
    ["calendar", "calendar date"], ["clock", "time clock"], ["alarm", "alarm time"], ["timer", "timer"], ["envelope", "mail email"],
    ["paperplane", "send paper plane"], ["bubble.left", "chat message"], ["bubble.left.and.bubble.right", "chat conversation"],
    ["phone", "phone call"], ["video", "video call"], ["person", "person user"], ["person.2", "people team"],
    ["person.3", "group team people"], ["chart.bar", "chart data"], ["chart.line.uptrend.xyaxis", "chart growth stocks"],
    ["chart.pie", "pie chart"], ["list.bullet", "list"], ["checklist", "checklist todo tasks"], ["checkmark.circle", "done check"],
    ["pencil", "pencil edit write"], ["highlighter", "highlight marker"], ["printer", "print printer"], ["signature", "signature sign"],
  ]],
  ["Money", [
    ["cart", "shopping cart"], ["bag", "shopping bag"], ["creditcard", "card pay"], ["dollarsign.circle", "money dollar"],
    ["eurosign.circle", "money euro"], ["sterlingsign.circle", "money pound"], ["yensign.circle", "money yen"],
    ["banknote", "money cash"], ["gift", "gift present"], ["percent", "sale percent discount"], ["building.columns", "bank"],
  ]],
  ["Tech", [
    ["laptopcomputer", "laptop computer"], ["desktopcomputer", "desktop computer"], ["iphone", "phone mobile iphone"],
    ["keyboard", "keyboard type"], ["terminal", "terminal code shell"], ["chevron.left.forwardslash.chevron.right", "code html"],
    ["curlybraces", "code json braces"], ["server.rack", "server rack"], ["cpu", "chip cpu"], ["memorychip", "memory ram"],
    ["externaldrive", "drive disk"], ["icloud", "cloud icloud"], ["wifi", "wifi network"], ["antenna.radiowaves.left.and.right", "antenna signal"],
    ["network", "network"], ["globe", "world web globe internet"], ["safari", "safari browser compass"], ["link", "link url"],
    ["lock", "lock secure"], ["key", "key password"], ["shield", "shield security"], ["ant", "bug ant"], ["ladybug", "bug ladybug"],
    ["hammer", "build hammer"], ["wrench.and.screwdriver", "tools fix"], ["gearshape", "settings gear"], ["puzzlepiece", "extension puzzle"],
    ["shippingbox", "package box"], ["testtube.2", "test lab science"], ["flask", "science flask"], ["brain", "brain think ai"],
  ]],
  ["Media", [
    ["music.note", "music song"], ["headphones", "headphones music"], ["speaker.wave.2", "sound speaker audio"], ["mic", "microphone mic"],
    ["play.circle", "play video"], ["film", "film movie"], ["tv", "tv watch"], ["camera", "camera photo"], ["photo", "photo image picture"],
    ["paintbrush", "paint art design"], ["paintpalette", "palette art design color"], ["pencil.and.ruler", "design ruler"],
    ["book", "book read"], ["books.vertical", "books library"], ["newspaper", "news paper"], ["magazine", "magazine"],
    ["gamecontroller", "game play controller"], ["dice", "dice game"], ["theatermasks", "theater drama"], ["guitars", "guitar music"],
  ]],
  ["Places", [
    ["house", "home house"], ["building", "building"], ["map", "map travel"], ["mappin", "location place pin"],
    ["location", "location navigation"], ["airplane", "travel plane flight"], ["car", "car drive"], ["bus", "bus transit"],
    ["tram", "train tram transit"], ["bicycle", "bike cycling"], ["ferry", "boat ferry"], ["fuelpump", "gas fuel"],
    ["fork.knife", "food restaurant eat"], ["cup.and.saucer", "coffee tea cafe"], ["wineglass", "wine drink bar"],
    ["bed.double", "hotel bed sleep"], ["tent", "camping tent outdoors"], ["mountain.2", "mountain hike"], ["beach.umbrella", "beach holiday"],
    ["graduationcap", "school graduate education"], ["cross.case", "health medical"], ["stethoscope", "doctor health"],
  ]],
  ["Nature", [
    ["leaf", "leaf nature plant"], ["tree", "tree nature"], ["camera.macro", "flower macro"], ["pawprint", "pet paw animal"],
    ["dog", "dog pet"], ["cat", "cat pet"], ["bird", "bird"], ["fish", "fish"], ["tortoise", "turtle tortoise slow"], ["hare", "rabbit hare fast"],
    ["sun.max", "sun day"], ["moon", "moon night"], ["cloud", "cloud weather"], ["cloud.rain", "rain weather"], ["snowflake", "snow cold"],
    ["drop", "water drop"], ["wind", "wind"], ["globe.americas", "earth world"], ["sparkle", "star sparkle"],
  ]],
  ["Activities", [
    ["figure.run", "run running fitness"], ["figure.walk", "walk"], ["figure.yoga", "yoga"], ["dumbbell", "gym fitness weights"],
    ["sportscourt", "sport court"], ["soccerball", "football soccer sport"], ["basketball", "basketball sport"],
    ["tennis.racket", "tennis sport"], ["trophy", "trophy win award"], ["medal", "medal award"], ["target", "target goal"],
    ["flag.checkered", "race finish"], ["party.popper", "party celebrate"], ["balloon", "balloon party birthday"],
  ]],
  ["Shapes", [
    ["circle.fill", "circle dot"], ["square.fill", "square"], ["triangle.fill", "triangle"], ["diamond.fill", "diamond"],
    ["hexagon.fill", "hexagon"], ["seal.fill", "seal badge"], ["star.fill", "star filled"], ["heart.fill", "heart filled"],
    ["lightbulb", "idea bulb"], ["questionmark.circle", "question help"], ["exclamationmark.triangle", "warning important"],
    ["info.circle", "info"], ["number", "number hash"], ["at", "at mention"], ["infinity", "infinity forever"],
    ["eye", "eye look watch"], ["hand.thumbsup", "thumbs up like"], ["face.smiling", "smile happy face"],
  ]],
];

const SKIN_OR_HAIR = /[\u{1F3FB}-\u{1F3FF}\u{1F9B0}-\u{1F9B3}]/u;

const [testPath, annPath, derivedPath, cldr] = args;
const annotations = JSON.parse(readFileSync(annPath!, "utf8")).annotations.annotations as Record<string, { default?: string[]; tts?: string[] }>;
const derived = JSON.parse(readFileSync(derivedPath!, "utf8")).annotationsDerived.annotations as Record<string, { default?: string[]; tts?: string[] }>;
const lookup = (emoji: string) => annotations[emoji] ?? derived[emoji] ?? annotations[emoji.replace(/\u{FE0F}/gu, "")] ?? derived[emoji.replace(/\u{FE0F}/gu, "")];

const lines = readFileSync(testPath!, "utf8").split("\n");
const version = lines.find((l) => l.startsWith("# Version:"))?.slice("# Version:".length).trim() ?? "";
const groups: { name: string; symbol: string; items: [string, string][] }[] = [];
let group: (typeof groups)[number] | null = null;
for (const line of lines) {
  const heading = line.match(/^# group: (.+)$/);
  if (heading) {
    const name = heading[1]!.trim();
    group = GROUP_SYMBOLS[name] ? { name, symbol: GROUP_SYMBOLS[name]!, items: [] } : null;
    if (group) groups.push(group);
    continue;
  }
  if (!group) continue;
  const row = line.match(/^[0-9A-F ]+;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$/);
  if (!row) continue;
  const [, emoji, name] = row as unknown as [string, string, string];
  if (SKIN_OR_HAIR.test(emoji)) continue;
  const words = new Set<string>([name.toLowerCase()]);
  for (const word of lookup(emoji)?.default ?? []) words.add(word.toLowerCase());
  group.items.push([emoji, [...words].join(" | ")]);
}
if (groups.length !== Object.keys(GROUP_SYMBOLS).length || groups.some((g) => !g.items.length)) throw new Error("emoji-test.txt is missing a group");

const catalog = {
  unicode: version,
  cldr,
  emoji: groups,
  symbols: SYMBOLS.map(([name, items]) => ({ name, items: items.map(([symbol, words]) => [symbol, words]) })),
};
const json = JSON.stringify(catalog);
if (json.includes("\r")) throw new Error("a carriage return would not survive a Swift multi-line literal");
let hashes = "#";
while (json.includes(`"${hashes}`) || json.includes(`\\${hashes}`)) hashes += "#";
const out = join(dirname(fileURLToPath(import.meta.url)), "../Sources/SolaraUI/Sidebar/IconCatalogData.swift");
writeFileSync(out, `let iconCatalogJSON = ${hashes}"""\n${json}\n"""${hashes}\n`);
const count = groups.reduce((n, g) => n + g.items.length, 0);
console.log(`${out}: ${count} emoji in ${groups.length} groups (Unicode ${version}, CLDR ${cldr}), ${SYMBOLS.reduce((n, [, s]) => n + s.length, 0)} symbols, ${json.length} bytes`);
for (const g of groups) console.log(`  ${g.name}: ${g.items.length}`);
for (const [name, items] of SYMBOLS) console.log(`  symbols ${name}: ${items.length}`);
