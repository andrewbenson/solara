import { createHash } from 'node:crypto';
import { isIP } from 'node:net';
import { readFile, writeFile, mkdir, readdir, copyFile } from 'node:fs/promises';
import { resolve, relative, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const version = '2026.1110.1816';
export const archiveSHA256 = '85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03';
export const maxRules = 140000;
const resourceUniverse = ['main_frame', 'sub_frame', 'stylesheet', 'script', 'image', 'font', 'object', 'xmlhttprequest', 'ping', 'csp_report', 'media', 'websocket', 'other'];
const resourceMap = { stylesheet: 'style-sheet', script: 'script', image: 'image', font: 'font', media: 'media' };
const rawTypes = ['object', 'xmlhttprequest', 'ping', 'csp_report', 'websocket', 'other'];
const conditionKeys = new Set(['urlFilter', 'regexFilter', 'isUrlFilterCaseSensitive', 'resourceTypes', 'excludedResourceTypes', 'domainType', 'requestDomains', 'initiatorDomains', 'excludedInitiatorDomains']);
const documentTypes = ['main_frame', 'sub_frame'];
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export const digest = data => createHash('sha256').update(data).digest('hex');
const reject = reason => ({ rules: [], decisions: [], reason });

export function canonicalHost(value) {
  if (typeof value !== 'string' || value.length > 253) return null;
  if (isIP(value) === 6) return new URL(`http://[${value}]/`).hostname;
  if (value.startsWith('[') && value.endsWith(']') && isIP(value.slice(1, -1)) === 6) return new URL(`http://${value}/`).hostname;
  const host = value.toLowerCase().replace(/\.$/, '');
  if (!host || !/^[a-z0-9.-]+$/.test(host)) return null;
  if (host.split('.').some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return null;
  return host;
}

export function hostExpression(host) {
  const authority = host.startsWith('[') ? escape(host) : `([a-z0-9_-]+\\.)*${escape(host)}\\.?`;
  return `^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*@)?${authority}[:/?#]`;
}

function canonicalRequestHost(value) {
  const canonical = canonicalHost(value);
  if (canonical) return canonical;
  if (typeof value !== 'string' || value.length > 253) return null;
  const host = value.toLowerCase().replace(/\.$/, '');
  return host.split('.').every(label => /^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$/.test(label)) ? host : null;
}

export function trustedRule(hosts) {
  const domains = [...new Set(hosts.map(canonicalHost).filter(Boolean))].sort();
  return domains.length ? { trigger: { 'url-filter': '.*', 'if-top-url': domains.map(host => hostExpression(host).replace('^[a-zA-Z][a-zA-Z0-9+.-]*://', '^https?://')) }, action: { type: 'ignore-previous-rules' } } : null;
}

function urlExpressions(filter) {
  if (typeof filter !== 'string' || !filter || filter.length > 1024 || /[^\x20-\x7e]/.test(filter) || filter.includes('||', 2)) return null;
  let source = filter;
  let prefix = '';
  let suffix = '';
  if (source.startsWith('||')) {
    prefix = '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*@)?([a-z0-9_-]+\\.)*';
    source = source.slice(2);
    if (!/^[a-z0-9-]/i.test(source)) return null;
  } else if (source.startsWith('|')) {
    prefix = '^';
    source = source.slice(1);
  }
  if (source.endsWith('|')) { suffix = '$'; source = source.slice(0, -1); }
  if (source.includes('|') || (source.match(/\^/g) || []).length > 4) return null;
  let expressions = [prefix];
  const ended = [];
  for (let index = 0; index < source.length; index++) {
    const character = source[index];
    if (character === '*') expressions = expressions.map(value => value + '.*');
    else if (character === '^') {
      if (/^[*^]*$/.test(source.slice(index + 1))) ended.push(...expressions.map(value => value + '$'));
      expressions = expressions.map(value => value + '[^a-zA-Z0-9_%.-]');
    } else expressions = expressions.map(value => value + escape(character));
  }
  return [...new Set([...expressions.map(value => value + suffix), ...ended])];
}

function safeRegex(expression) {
  if (typeof expression !== 'string' || !expression || expression.length > 1024 || /[^\x20-\x7e]/.test(expression)) return false;
  if (/\(\?|[{}|]|\\(?:[A-Za-z0-9])/.test(expression)) return false;
  if (/[*+?][*+?]/.test(expression) || /(?<!\\)\^(?![^[]*\])/.test(expression.slice(1)) || /(?<!\\)\$(?!$)/.test(expression)) return false;
  try { new RegExp(expression); } catch { return false; }
  return true;
}

function resources(condition) {
  if (condition.resourceTypes && condition.excludedResourceTypes) return { reason: 'resource-type:conflict' };
  for (const key of ['resourceTypes', 'excludedResourceTypes']) {
    if (condition[key] && (!Array.isArray(condition[key]) || !condition[key].length)) return { reason: 'resource-type:shape' };
    for (const type of condition[key] || []) if (!resourceUniverse.includes(type)) return { reason: `resource-type:${type}` };
  }
  const types = condition.resourceTypes || resourceUniverse.filter(type => (condition.excludedResourceTypes || type !== 'main_frame') && !(condition.excludedResourceTypes || []).includes(type));
  const raw = types.filter(type => rawTypes.includes(type));
  if (raw.length && raw.length !== rawTypes.length) return { reason: 'resource-type:partial-raw' };
  const ordinary = [...new Set(types.map(type => resourceMap[type]).filter(Boolean))];
  if (raw.length) ordinary.push('raw');
  const triggers = ordinary.length ? [{ 'resource-type': ordinary }] : [];
  const contexts = [];
  if (types.includes('main_frame')) contexts.push('top-frame');
  if (types.includes('sub_frame')) contexts.push('child-frame');
  if (contexts.length) triggers.push({ 'resource-type': ['document'], 'load-context': contexts });
  return { triggers };
}

export function convertRule(rule) {
  if (!rule || !Number.isInteger(rule.id) || rule.id < 1 || !Number.isInteger(rule.priority ?? 1) || (rule.priority ?? 1) < 1 || !rule.condition || typeof rule.condition !== 'object') return reject('shape');
  if (Object.keys(rule).some(key => !['id', 'priority', 'action', 'condition'].includes(key))) return reject('shape');
  const action = rule.action?.type;
  if (!['block', 'allow', 'upgradeScheme', 'allowAllRequests'].includes(action)) return reject(`action:${action || 'missing'}`);
  if (Object.keys(rule.action).some(key => key !== 'type')) return reject('action:parameters');
  const condition = rule.condition;
  for (const key of Object.keys(condition)) if (!conditionKeys.has(key)) return reject(`condition:${key}`);
  if (condition.domainType && !['firstParty', 'thirdParty'].includes(condition.domainType)) return reject('domain-type');
  if (condition.isUrlFilterCaseSensitive !== undefined && typeof condition.isUrlFilterCaseSensitive !== 'boolean') return reject('case-sensitive');
  if (condition.urlFilter && condition.regexFilter) return reject('url-filter:conflict');
  if (action === 'upgradeScheme' && !(condition.urlFilter?.startsWith('|http://') || condition.regexFilter?.startsWith('^http://'))) return reject('unsafe-upgrade');
  let expressions;
  if (condition.requestDomains) {
    if (condition.urlFilter || condition.regexFilter) return reject('request-domain-conjunction');
    if (!Array.isArray(condition.requestDomains) || !condition.requestDomains.length || condition.requestDomains.some(host => !canonicalRequestHost(host))) return reject('request-domain');
    expressions = [...new Set(condition.requestDomains.map(canonicalRequestHost))].map(hostExpression);
  } else if (condition.regexFilter !== undefined) {
    if (!safeRegex(condition.regexFilter)) return reject('regex');
    expressions = [condition.regexFilter];
  } else {
    expressions = condition.urlFilter === undefined ? ['.*'] : urlExpressions(condition.urlFilter);
    if (!expressions) return reject('url-filter');
  }
  if (condition.initiatorDomains && condition.excludedInitiatorDomains) return reject('initiator-domain-conjunction');
  let frame = null;
  for (const [key, field] of [['initiatorDomains', 'if-frame-url'], ['excludedInitiatorDomains', 'unless-frame-url']]) {
    if (condition[key] === undefined) continue;
    if (!Array.isArray(condition[key]) || !condition[key].length || condition[key].some(host => !canonicalRequestHost(host))) return reject(`condition:${key}`);
    frame = { [field]: [...new Set(condition[key].map(canonicalRequestHost))].sort().map(hostExpression) };
  }
  if (action === 'allowAllRequests') {
    const types = condition.resourceTypes;
    if (frame || condition.domainType || condition.excludedResourceTypes || !Array.isArray(types) || !types.length || types.some(type => !documentTypes.includes(type))) return reject('allow-all-requests:shape');
    const rules = [];
    const decisions = [];
    for (const [type, field] of [['main_frame', 'if-top-url'], ['sub_frame', 'if-frame-url']]) {
      if (!types.includes(type)) continue;
      const trigger = { 'url-filter': '.*', [field]: expressions };
      rules.push({ trigger, action: { type: 'ignore-previous-rules' } });
      decisions.push({ trigger, priority: rule.priority ?? 1, action: 'allow' });
    }
    return { rules, decisions, frameScoped: true };
  }
  const mapped = resources(condition);
  if (mapped.reason) return reject(mapped.reason);
  let triggers = mapped.triggers;
  if (frame) {
    const documents = triggers.filter(resource => resource['resource-type']?.includes('document'));
    triggers = triggers.filter(resource => !documents.includes(resource)).map(resource => ({ ...resource, ...frame }));
    if (!triggers.length) return reject('initiator-frame-document');
  }
  const rules = [];
  const decisions = [];
  for (const expression of expressions) for (const resource of triggers) {
    const trigger = { 'url-filter': expression, ...resource };
    if (condition.isUrlFilterCaseSensitive === true) trigger['url-filter-is-case-sensitive'] = true;
    if (condition.domainType) trigger['load-type'] = [condition.domainType === 'firstParty' ? 'first-party' : 'third-party'];
    rules.push({ trigger, action: { type: { block: 'block', allow: 'ignore-previous-rules', upgradeScheme: 'make-https' }[action] } });
    decisions.push({ trigger, priority: rule.priority ?? 1, action });
  }
  return frame ? { rules, decisions, frameScoped: true } : { rules, decisions };
}

function anchoredHosts(condition) {
  if (Array.isArray(condition?.requestDomains)) return condition.requestDomains.map(canonicalRequestHost).filter(Boolean);
  const match = typeof condition?.urlFilter === 'string' && /^\|\|([a-z0-9_.-]+)(?:[\^/:]|$)/i.exec(condition.urlFilter);
  const host = match && canonicalRequestHost(match[1]);
  return host ? [host] : [];
}

export function convertRules(input) {
  if (!Array.isArray(input)) throw new Error('DNR rules must be an array');
  const conversions = input.map(convertRule);
  const filterKey = rule => {
    if (typeof rule?.condition?.urlFilter === 'string' && rule.condition.regexFilter === undefined) return `url:${rule.condition.urlFilter}`;
    if (typeof rule?.condition?.regexFilter === 'string' && rule.condition.urlFilter === undefined) return `regex:${rule.condition.regexFilter}`;
    return null;
  };
  const unsupportedExceptions = new Map();
  const unsupportedExceptionHosts = new Map();
  const raise = (map, key, priority) => map.set(key, Math.max(priority, map.get(key) || 0));
  for (let index = 0; index < input.length; index++) {
    const rule = input[index];
    const priority = rule?.priority ?? 1;
    if (rule?.action?.type !== 'allow' || !conversions[index].reason || !Number.isInteger(priority) || priority < 1) continue;
    const key = filterKey(rule);
    if (key) raise(unsupportedExceptions, key, priority);
    for (const host of anchoredHosts(rule.condition)) if (host.includes('.')) raise(unsupportedExceptionHosts, host, priority);
  }
  const hostException = host => unsupportedExceptionHosts.get(host) || 0;
  const withoutLosingHosts = (rule, converted) => {
    const priority = rule.priority ?? 1;
    if (converted.reason || rule.action.type !== 'block') return { converted, withheld: 0 };
    if ((unsupportedExceptions.get(filterKey(rule)) || 0) >= priority) return { converted: reject('unsupported-exception-conflict'), withheld: 0 };
    const domains = rule.condition.requestDomains;
    if (!Array.isArray(domains)) return { converted: anchoredHosts(rule.condition).some(host => hostException(host) >= priority) ? reject('unsupported-exception-conflict') : converted, withheld: 0 };
    const kept = domains.filter(host => hostException(canonicalRequestHost(host)) < priority);
    if (kept.length === domains.length) return { converted, withheld: 0 };
    return { converted: kept.length ? convertRule({ ...rule, condition: { ...rule.condition, requestDomains: kept } }) : reject('unsupported-exception-conflict'), withheld: kept.length ? domains.length - kept.length : 0 };
  };
  const result = { rules: [], decisions: [], report: { input: input.length, converted: 0, dropped: 0, emitted: 0, reasons: {}, requestDomainsWithheld: 0, frameScoped: 0 } };
  for (let index = 0; index < input.length; index++) {
    const rule = input[index];
    const { converted, withheld } = withoutLosingHosts(rule, conversions[index]);
    result.report.requestDomainsWithheld += withheld;
    if (converted.reason) {
      result.report.dropped++;
      result.report.reasons[converted.reason] = (result.report.reasons[converted.reason] || 0) + 1;
    } else {
      result.report.converted++;
      if (converted.frameScoped) result.report.frameScoped++;
      result.rules.push(...converted.rules);
      result.decisions.push(...converted.decisions);
    }
  }
  result.report.emitted = result.rules.length;
  return result;
}

export function exceptionRules(decisions, priority, kind) {
  if (kind === 'cosmetic') return [];
  const suppresses = decision => decision.priority > priority || (decision.priority === priority && (decision.action === 'allow' || (kind === 'upgradeScheme' && decision.action === 'block')));
  const unique = new Map();
  for (const decision of decisions.filter(suppresses)) {
    const key = JSON.stringify(decision.trigger);
    unique.set(key, { trigger: decision.trigger, action: { type: 'ignore-previous-rules' } });
  }
  return [...unique.values()];
}

export function pruneDecisions(decisions, buckets) {
  return decisions.filter(decision => buckets.some(bucket => bucket.kind !== 'cosmetic' && (decision.priority > bucket.priority || (decision.priority === bucket.priority && (decision.action === 'allow' || (bucket.kind === 'upgradeScheme' && decision.action === 'block'))))));
}

export function splitRules(rules, suffix = [], limit = maxRules) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 150000) throw new Error('invalid rule limit');
  const capacity = limit - suffix.length;
  if (capacity <= 0) throw new Error('exception suffix exceeds rule limit');
  const chunks = [];
  for (let offset = 0; offset < rules.length; offset += capacity) chunks.push([...rules.slice(offset, offset + capacity), ...suffix]);
  return chunks;
}

export function selectedLists(groups, state) {
  if (state?.stats?.ready !== true || typeof state.enabled !== 'boolean' || !Array.isArray(state.lists)) throw new Error('shared settings are not ready');
  if (!state.enabled) return [];
  const enabled = new Set(state.lists.filter(list => list.enabled === true).map(list => list.id));
  return groups.filter(group => group.uboIds.length && enabled.has(group.uboIds[0]));
}

export function composeChunks(groups, trusted = [], limit = maxRules) {
  const decisions = groups.flatMap(group => group.decisions);
  const buckets = new Map();
  for (const group of groups) for (let i = 0; i < group.rules.length; i++) {
    const decision = group.decisions[i];
    if (decision.action === 'allow') continue;
    const key = `${decision.priority}:${decision.action}`;
    const bucket = buckets.get(key) || { priority: decision.priority, kind: decision.action, rules: [] };
    bucket.rules.push(group.rules[i]);
    buckets.set(key, bucket);
  }
  const trust = trustedRule(trusted);
  return [...buckets.values()].flatMap(bucket => splitRules(bucket.rules, [...exceptionRules(decisions, bucket.priority, bucket.kind), ...(trust ? [trust] : [])], limit));
}

export const listMap = {
  'ublock-filters': ['ublock-filters', 'ublock-unbreak', 'ublock-quick-fixes'],
  'pgl': ['plowe-0'], 'urlhaus-full': ['urlhaus-1'],
  'annoyances-ai': ['fanboy-ai-suggestions'],
  'annoyances-cookies': ['fanboy-cookiemonster', 'ublock-cookies-easylist'],
  'annoyances-overlays': ['easylist-newsletters', 'ublock-annoyances'],
  'annoyances-social': ['fanboy-social'], 'annoyances-widgets': ['easylist-chat'],
  'annoyances-others': ['easylist-annoyances'], 'annoyances-notifications': ['easylist-notifications'],
};
const defaultIds = ['ublock-filters', 'ublock-badware', 'ublock-privacy', 'ublock-unbreak', 'ublock-quick-fixes', 'easylist', 'easyprivacy', 'urlhaus-1', 'plowe-0'];

async function contained(root, file) {
  if (typeof file !== 'string' || file.startsWith('//') || file.includes('\\') || file.split('/').some(part => part === '.' || part === '..')) throw new Error(`invalid asset path ${file}`);
  const full = resolve(root, file.replace(/^\//, ''));
  if (!relative(root, full) || relative(root, full).startsWith('..') || relative(root, full).startsWith('/')) throw new Error(`invalid asset path ${file}`);
  return full;
}

export async function convertRelease(root, output, assets) {
  root = resolve(root);
  const input = JSON.parse(await readFile(join(root, 'manifest.json'), 'utf8'));
  if (input.version !== version || input.manifest_version !== 3 || !Array.isArray(input.declarative_net_request?.rule_resources)) throw new Error('pinned release manifest mismatch');
  const { convertCosmetics, genericContext } = await import('./ubol-cosmetics.mjs');
  const cosmeticsContext = await genericContext(root);
  const known = assets ? JSON.parse(await readFile(assets, 'utf8')) : null;
  const manifest = { schema: 1, version, archiveSHA256, lists: [] };
  const coverage = { version, archiveSHA256, lists: [], unsupportedFiles: [] };
  await mkdir(output, { recursive: true });
  async function asset(file, data) {
    const bytes = typeof data === 'string' ? data : JSON.stringify(data);
    await writeFile(join(output, file), bytes);
    return { file, sha256: digest(bytes) };
  }
  const ids = new Set();
  for (const source of input.declarative_net_request.rule_resources) {
    if (!/^[a-z0-9][a-z0-9_-]{0,79}$/.test(source.id) || ids.has(source.id)) throw new Error(`invalid/duplicate ruleset ${source.id}`);
    ids.add(source.id);
    const id = source.id;
    const files = [source.path];
    for (const folder of ['regex', 'redirect', 'removeparam', 'modify-headers', 'urlskip', 'strictblock']) {
      const path = `rulesets/${folder}/${id}.json`;
      try { await readFile(join(root, path)); if (!files.includes(path)) files.push(path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    const inputRules = [];
    for (const file of files) {
      const rules = JSON.parse(await readFile(await contained(root, file), 'utf8'));
      if (!Array.isArray(rules)) throw new Error(`unsupported DNR container ${file}`);
      if (file.startsWith('rulesets/urlskip/')) {
        coverage.unsupportedFiles.push({ ruleset: id, file, reason: 'unsupported-urlskip', entries: rules.length });
        continue;
      }
      inputRules.push(...rules);
    }
    const converted = convertRules(inputRules);
    const uboIds = listMap[id] || Object.keys(known || {}).filter(key => key.toLowerCase() === id.toLowerCase());
    if (!uboIds.length && defaultIds.includes(id)) uboIds.push(id);
    const group = { id, uboIds, defaultEnabled: uboIds.length > 0 && uboIds.every(key => defaultIds.includes(key)), chunks: [], decisions: await asset(`${id}.decisions.json`, converted.decisions), scriptlets: [] };
    const buckets = new Map();
    for (let i = 0; i < converted.rules.length; i++) {
      const decision = converted.decisions[i];
      if (decision.action === 'allow') continue;
      const key = `${decision.priority}-${decision.action}`;
      const bucket = buckets.get(key) || { priority: decision.priority, kind: decision.action, rules: [] };
      bucket.rules.push(converted.rules[i]);
      buckets.set(key, bucket);
    }
    let part = 0;
    for (const bucket of buckets.values()) for (const rules of splitRules(bucket.rules, [], 50000)) {
      group.chunks.push({ ...await asset(`${id}.${part++}.json`, rules), rules: rules.length, priority: bucket.priority, kind: bucket.kind });
    }
    const cosmetics = await convertCosmetics(root, id, cosmeticsContext);
    for (const rules of splitRules(cosmetics.rules, [], 50000)) group.chunks.push({ ...await asset(`${id}.${part++}.json`, rules), rules: rules.length, priority: 1, kind: 'cosmetic' });
    for (const script of cosmetics.scriptlets) group.scriptlets.push(await asset(`${script.name}.js`, script.source));
    if (!uboIds.length) coverage.unsupportedFiles.push({ ruleset: id, reason: 'no uBO list mapping; group not selectable' });
    coverage.lists.push({ id, uboIds, files, ...converted.report, cosmetics: cosmetics.report, chunks: group.chunks.length, scriptlets: group.scriptlets.length });
    if (uboIds.length) manifest.lists.push(group);
  }
  if (known) {
    const represented = new Set(manifest.lists.flatMap(group => group.uboIds));
    const missing = defaultIds.filter(id => !represented.has(id));
    coverage.unsupportedDefaults = missing;
  }
  const buckets = manifest.lists.flatMap(group => group.chunks.filter(chunk => chunk.kind !== 'cosmetic'));
  coverage.decisions = { input: 0, retained: 0 };
  for (const group of manifest.lists) {
    const decisions = JSON.parse(await readFile(join(output, group.decisions.file), 'utf8'));
    const pruned = pruneDecisions(decisions, buckets);
    coverage.decisions.input += decisions.length;
    coverage.decisions.retained += pruned.length;
    group.decisions = await asset(group.decisions.file, pruned);
  }
  const license = (await readdir(root)).find(file => /^licen[sc]e(?:\.txt)?$/i.test(file));
  if (!license) throw new Error('release license missing');
  await copyFile(join(root, license), join(output, 'UPSTREAM-LICENSE.txt'));
  await asset('coverage.json', coverage);
  await asset('manifest.json', manifest);
  return coverage;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [root, output, assets] = process.argv.slice(2);
  if (!root || !output) throw new Error('usage: node ubol-converter.mjs <release-dir> <output-dir> [uBO-assets.json]');
  process.stdout.write(JSON.stringify(await convertRelease(root, output, assets), null, 2) + '\n');
}
