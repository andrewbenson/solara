import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import test from 'node:test';
import { convertCosmetics } from './ubol-cosmetics.mjs';

async function fixture(t, files) {
  const root = await mkdtemp(path.join(tmpdir(), 'ubol-cosmetics-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  for (const [relative, source] of Object.entries(files)) {
    const target = path.join(root, 'rulesets/scripting', relative);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, source);
  }
  return root;
}

function generated({ args = [['onmousedown', 'a', 'stay']], hosts = [['example.com', 0]], exceptions = [['private.example.com', 0]], entities = [] } = {}) {
  return `(() => { const argsList = ${JSON.stringify(args)}; const hostnamesMap = new Map(${JSON.stringify(hosts)}); const exceptionsMap = new Map(${JSON.stringify(exceptions)}); const entitiesMap = new Map(${JSON.stringify(entities)}); throw new Error('upstream must never execute'); })();`;
}

function execute(source, { hostname = 'example.com', protocol = 'https:', frame = false, readyState = 'complete', version = 1 } = {}) {
  const removed = [];
  const listeners = new Map();
  const observers = [];
  const element = { removeAttribute(name) { removed.push(name); } };
  const document = {
    readyState,
    querySelectorAll(selector) {
      assert.equal(selector, 'a');
      return [element];
    },
    addEventListener(name, callback) { listeners.set(name, callback); },
    removeEventListener(name, callback) { if (listeners.get(name) === callback) listeners.delete(name); },
  };
  const context = { document, location: { hostname, protocol }, MutationObserver: class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
  } };
  context.top = frame ? {} : context;
  const sandbox = vm.createContext(context);
  vm.runInContext(`globalThis[Symbol.for('solara.ubol.version')] = ${JSON.stringify(version)};`, sandbox);
  vm.runInContext(source, sandbox, { timeout: 1000 });
  const cleanups = vm.runInContext("globalThis[Symbol.for('solara.ubol.cleanup')]", sandbox);
  return { removed, listeners, observers, cleanups };
}

test('converts standard generic selectors and rejects procedural selectors and unsafe declarations', async t => {
  const root = await fixture(t, { 'generichigh/default.css': '.ad, div > a[data-ad="yes"] { display: none !important; }\n.bad:has-text(ad), .good {display:none!important;}\n.visible {display:block;}' });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules, ['.ad', 'div > a[data-ad="yes"]', '.good'].map(selector => ({ trigger: { 'url-filter': '^https?://' }, action: { type: 'css-display-none', selector } })));
  assert.equal(result.report.cosmetics.converted, 3);
  assert.equal(result.report.cosmetics.unsupported, 2);
  assert.equal(result.report.cosmetics.reasons['unsupported-selector'], 1);
  assert.equal(result.report.cosmetics.reasons['unsupported-declaration'], 1);
});

test('accepts raw selector lists and excludes invalid CSS syntax without weakening selectors', async t => {
  const root = await fixture(t, { 'generichigh/default.css': '.ad, #banner, [data-x="a,b"], .box:hover, .foo\\:bar, .a > > .b' });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules.map(rule => rule.action.selector), ['.ad', '#banner', '[data-x="a,b"]']);
  assert.equal(result.report.cosmetics.unsupported, 3);
});

test('emits a domain gated remove-attr adaptation without executing upstream code', async t => {
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': generated() });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.scriptlets.length, 1);
  assert.equal(result.scriptlets[0].name, 'default.remove-attr');
  assert.deepEqual(execute(result.scriptlets[0].source).removed, ['onmousedown']);
  assert.deepEqual(execute(result.scriptlets[0].source, { hostname: 'news.example.com' }).removed, ['onmousedown']);
  for (const options of [{ hostname: 'private.example.com' }, { hostname: 'sub.private.example.com' }, { hostname: 'notexample.com' }, { protocol: 'file:' }, { frame: true }]) {
    assert.deepEqual(execute(result.scriptlets[0].source, options).removed, []);
  }
  assert.equal(result.report.scriptlets.argumentsConverted, 1);
});

test('runs document-start adaptations once the DOM exists and observes stay arguments', async t => {
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': generated() });
  const { scriptlets } = await convertCosmetics(root, 'default');
  const page = execute(scriptlets[0].source, { readyState: 'loading' });
  assert.deepEqual(page.removed, []);
  page.listeners.get('DOMContentLoaded')();
  assert.deepEqual(page.removed, ['onmousedown']);
  assert.equal(page.observers.length, 1);
  page.observers[0].callback();
  assert.deepEqual(page.removed, ['onmousedown', 'onmousedown']);
});

test('skips unsupported names, unsafe arguments and entity targeting with explicit reasons', async t => {
  const root = await fixture(t, {
    'scriptlet/default.set-constant.js': generated(),
    'scriptlet/default.remove-attr.js': generated({ args: [['onmousedown', 'a', 'stay'], ['bad]name', 'a'], ['ping', 'a:has-text(x)'], ['ping', 'a', 'asap']] }),
  });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.scriptlets.length, 1);
  assert.equal(result.report.scriptlets.argumentsSeen, 4);
  assert.equal(result.report.scriptlets.argumentsConverted, 1);
  assert.equal(result.report.scriptlets.reasons['unsupported-scriptlet-name'], 1);
  assert.equal(result.report.scriptlets.reasons['unsupported-arguments'], 3);
  const entitiesRoot = await fixture(t, { 'scriptlet/default.remove-attr.js': generated({ entities: [['example', 0]] }) });
  const entitiesResult = await convertCosmetics(entitiesRoot, 'default');
  assert.deepEqual(entitiesResult.scriptlets, []);
  assert.equal(entitiesResult.report.scriptlets.reasons['unsupported-entity-targeting'], 1);
});

test('rejects executable data expressions, duplicate declarations, invalid mappings and drift', async t => {
  const valid = generated();
  const invalid = [
    valid.replace('[["onmousedown","a","stay"]]', '[(globalThis.extracted = true)]'),
    valid.replace('const argsList =', 'const argsList = []; const argsList ='),
    generated({ hosts: [['example.com', 90]] }),
    generated({ hosts: [['*', 0]] }),
    generated({ hosts: [['example.com', 0], ['example.com', 0]] }),
    valid.replace('const exceptionsMap = new Map([])', 'const unexpectedMap = new Map([])').replace('const entitiesMap', 'const changedEntitiesMap'),
  ];
  for (const source of invalid) {
    const root = await fixture(t, { 'scriptlet/default.remove-attr.js': source });
    const result = await convertCosmetics(root, 'default');
    assert.deepEqual(result.scriptlets, []);
    assert.equal(result.report.scriptlets.reasons['unsupported-generated-schema'], 1);
  }
});

test('extracts quoted literal data and ignores data declaration text in upstream strings', async t => {
  const source = `const distraction = 'const argsList = ["unsafe"];'; const argsList = [['onmousedown','a','stay'],]; const hostnamesMap = new Map([['example.com',[0]],]); const exceptionsMap = new Map([]); const entitiesMap = new Map([]);`;
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': source });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.scriptlets.length, 1);
  assert.deepEqual(execute(result.scriptlets[0].source).removed, ['onmousedown']);
});

test('reports missing input and rejects ruleset path traversal', async t => {
  const root = await fixture(t, {});
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules, []);
  assert.deepEqual(result.scriptlets, []);
  assert.equal(result.report.cosmetics.reasons['missing-generic-file'], 1);
  assert.equal(result.report.scriptlets.reasons['missing-scriptlet-directory'], 1);
  await assert.rejects(convertCosmetics(root, '../default'), /ruleset/);
});

test('applies exceptions per argument and keeps argument indices after unsupported rows', async t => {
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': generated({
    args: [['bad]name', 'a'], ['onmousedown', 'a'], ['ping', 'a']],
    hosts: [['example.com', [0, 1, 2]]],
    exceptions: [['private.example.com', 1]],
  }) });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(execute(result.scriptlets[0].source).removed, ['onmousedown', 'ping']);
  assert.deepEqual(execute(result.scriptlets[0].source, { hostname: 'private.example.com' }).removed, ['ping']);
  assert.equal(result.report.scriptlets.argumentsConverted, 2);
  assert.equal(result.report.scriptlets.reasons['unsupported-arguments'], 1);
});

test('rejects oversized upstream files before conversion', async t => {
  const root = await fixture(t, {
    'generichigh/default.css': ' '.repeat(2 * 1024 * 1024 + 1),
    'scriptlet/default.remove-attr.js': ' '.repeat(2 * 1024 * 1024 + 1),
  });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules, []);
  assert.deepEqual(result.scriptlets, []);
  assert.equal(result.report.cosmetics.reasons['unsupported-input-size'], 1);
  assert.equal(result.report.scriptlets.reasons['unsupported-input-size'], 1);
});

test('reports the emitted rule count when the selector budget is reached', async t => {
  const root = await fixture(t, { 'generichigh/default.css': Array.from({ length: 20001 }, (_, index) => `.ad${index}`).join(',') });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.rules.length, 20000);
  assert.equal(result.report.cosmetics.converted, 20000);
  assert.equal(result.report.cosmetics.reasons['selector-limit'], 1);
});

test('accepts explicit empty Map constructors for empty generated targeting maps', async t => {
  const source = generated({ exceptions: [] }).replaceAll('new Map([])', 'new Map()');
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': source });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.scriptlets.length, 1);
  assert.deepEqual(execute(result.scriptlets[0].source).removed, ['onmousedown']);
});


test('version tagged cleanup removes pending document readiness work and guards queued callbacks', async t => {
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': generated() });
  const { scriptlets } = await convertCosmetics(root, 'default');
  const page = execute(scriptlets[0].source, { readyState: 'loading', version: 6 });
  const queuedStart = page.listeners.get('DOMContentLoaded');
  assert.equal(page.cleanups.length, 1);
  assert.equal(page.cleanups[0].version, 6);
  page.cleanups[0].stop();
  page.cleanups[0].stop();
  assert.equal(page.listeners.has('DOMContentLoaded'), false);
  queuedStart();
  assert.deepEqual(page.removed, []);
  assert.equal(page.observers.length, 0);
});

test('cleanup disconnects stay observers and blocks already queued observer callbacks', async t => {
  const root = await fixture(t, { 'scriptlet/default.remove-attr.js': generated() });
  const { scriptlets } = await convertCosmetics(root, 'default');
  const page = execute(scriptlets[0].source, { version: 7 });
  assert.deepEqual(page.removed, ['onmousedown']);
  assert.equal(page.observers.length, 1);
  assert.equal(page.cleanups[0].version, 7);
  page.cleanups[0].stop();
  assert.equal(page.observers[0].disconnected, true);
  page.observers[0].callback();
  assert.deepEqual(page.removed, ['onmousedown']);
});

function genericData({ low = [[1, '.ad,\n.banner']], high = '.sponsor', exceptions = ['.ad'], hostnames = ['allowed.test'], hasEntities = false } = {}) {
  return `(()=>{const lowlyGeneric = new Map(${JSON.stringify(low)});const highlyGeneric = ${JSON.stringify(high)};const exceptions = ${JSON.stringify(exceptions)};const hostnames = ${JSON.stringify(hostnames)};const hasEntities = ${hasEntities};throw Error('upstream must never execute');})();`;
}

test('current release generic literals honor cross-list selector and generichide exceptions without execution', async t => {
  const root = await fixture(t, {
    'generic/default.js': genericData(),
    'generic/other.js': genericData({ low: [], high: '', exceptions: ['.sponsor'], hostnames: ['another.test'] }),
  });
  await writeFile(path.join(root, 'rulesets/generic-details.json'), JSON.stringify([['other', { unhide: ['skip.test'], hide: ['specific.skip.test'] }]]));
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules.filter(rule => rule.action.type === 'css-display-none').map(rule => rule.action.selector), ['.banner']);
  assert(result.rules.every(rule => rule.trigger['load-context'].includes('top-frame')));
  assert.equal(result.rules.at(-1).action.type, 'ignore-previous-rules');
  assert(result.rules.at(-1).trigger['if-top-url'].some(pattern => new RegExp(pattern).test('https://sub.skip.test/')));
  assert.equal(result.report.cosmetics.reasons['selector-exception'], 2);
  assert.equal(result.report.cosmetics.genericHideHosts, 1);
});

test('current release generic data rejects executable fields', async t => {
  const root = await fixture(t, { 'generic/default.js': genericData().replace("const highlyGeneric = \".sponsor\"", "const highlyGeneric = fetch('https://invalid.test')") });
  const result = await convertCosmetics(root, 'default');
  assert.equal(result.rules.length, 0);
  assert.equal(result.report.cosmetics.reasons['unsupported-generated-schema'], 1);
});

test('current release accepts an undefined empty low generic Map payload', async t => {
  const root = await fixture(t, { 'generic/default.js': genericData({ low: [], high: '.sponsor', exceptions: [], hostnames: [] }).replace('new Map([])', 'new Map(undefined)') });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules.map(rule => rule.action.selector), ['.sponsor']);
});

test('commas within unsupported functional selectors never become unconditional selector fragments', async t => {
  const root = await fixture(t, { 'generichigh/default.css': '.ad:not(html, body, :empty), .good, div:has(.ad, section) {display:none!important;}' });
  const result = await convertCosmetics(root, 'default');
  assert.deepEqual(result.rules.map(rule => rule.action.selector), ['.good']);
  assert.equal(result.report.cosmetics.unsupported, 2);
});
