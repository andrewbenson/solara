import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pruneDecisions, canonicalHost, convertRule, convertRules, splitRules, exceptionRules, trustedRule, selectedLists, composeChunks } from './ubol-converter.mjs';

const rule = (action = 'block', condition = {}, priority = 1) => ({ id: 1, priority, action: { type: action }, condition });
const actionOf = value => convertRule(value).rules[0].action.type;

test('block, allow and safe HTTP upgrade shapes', () => {
  assert.equal(actionOf(rule()), 'block');
  assert.equal(actionOf(rule('allow')), 'ignore-previous-rules');
  assert.equal(actionOf(rule('upgradeScheme', { urlFilter: '|http://example.test/' })), 'make-https');
  assert.equal(convertRule(rule('upgradeScheme')).reason, 'unsafe-upgrade');
});

test('URL wildcards, anchors, separator and case survive conversion', () => {
  const result = convertRule(rule('block', { urlFilter: '||ads.example^', isUrlFilterCaseSensitive: true }));
  assert.equal(result.rules.length, 4);
  const expressions = result.rules.map(r => new RegExp(r.trigger['url-filter']));
  for (const url of ['https://ads.example/a', 'https://sub.ads.example:8080/a', 'wss://ads.example/socket']) assert(expressions.some(r => r.test(url)));
  for (const url of ['https://ads.example.evil/a', 'https://evilads.example/a', 'https://else.test/ads.example']) assert(!expressions.some(r => r.test(url)));
  assert.equal(result.rules[0].trigger['url-filter-is-case-sensitive'], true);
  const anchored = new RegExp(convertRule(rule('block', { urlFilter: '|https://x.test/ad*|' })).rules[0].trigger['url-filter']);
  assert(anchored.test('https://x.test/ad.js'));
  assert(!anchored.test('xhttps://x.test/ad.js'));
});

test('separators end a pattern only where nothing else must follow, as WebKit requires', () => {
  for (const filter of ['||maxmind.com^*/geoip.js', '||ads.test^', '/banner^ad', '||x.test^^', '|https://a.test/^|', '^ad^']) {
    const converted = convertRule({ id: 1, action: { type: 'block' }, condition: { urlFilter: filter } });
    assert.equal(converted.reason, undefined, filter);
    for (const emitted of converted.rules) assert(!/\$./.test(emitted.trigger['url-filter'].replace(/\\\$/g, '')), `${filter}: ${emitted.trigger['url-filter']}`);
  }
  const [rule] = convertRule({ id: 1, action: { type: 'block' }, condition: { urlFilter: '||maxmind.com^*/geoip.js' } }).rules;
  assert(new RegExp(rule.trigger['url-filter']).test('https://maxmind.com/app/geoip.js'));
  const ends = convertRule({ id: 1, action: { type: 'block' }, condition: { urlFilter: '||ads.test^' } }).rules.map(r => new RegExp(r.trigger['url-filter']));
  assert(ends.some(r => r.test('https://ads.test')));
  assert(ends.some(r => r.test('https://ads.test/x')));
  assert(!ends.some(r => r.test('https://ads.tester/x')));
});

test('request domains are matched against request URL, never top domain', () => {
  const result = convertRule(rule('block', { requestDomains: ['ads.example', 'tracker.test'] }));
  assert.equal(result.rules.length, 4);
  assert(!('if-domain' in result.rules[0].trigger));
  const expression = new RegExp(result.rules[0].trigger['url-filter']);
  assert(expression.test('https://sub.ads.example/pixel'));
  assert(!expression.test('https://ads.example.evil/pixel'));
  assert.equal(convertRule(rule('block', { requestDomains: ['x.test'], urlFilter: '/ad/' })).reason, 'request-domain-conjunction');
  assert.equal(convertRule(rule('block', { excludedRequestDomains: ['site.test'] })).reason, 'condition:excludedRequestDomains');
});

test('resource mapping preserves document context and party', () => {
  const result = convertRule(rule('block', { resourceTypes: ['script', 'image', 'sub_frame'], domainType: 'thirdParty' }));
  assert.deepEqual(result.rules[0].trigger['resource-type'], ['script', 'image']);
  assert.deepEqual(result.rules[1].trigger['resource-type'], ['document']);
  assert.deepEqual(result.rules[1].trigger['load-context'], ['child-frame']);
  assert.deepEqual(result.rules[0].trigger['load-type'], ['third-party']);
  assert(convertRule(rule('block', { excludedResourceTypes: ['image'] })).rules.some(r => r.trigger['load-context']?.includes('top-frame')));
  const defaultRules = convertRule(rule()).rules;
  assert(defaultRules.every(r => !r.trigger['load-context']?.includes('top-frame')));
  assert.equal(convertRule(rule('block', { resourceTypes: ['xmlhttprequest'] })).reason, 'resource-type:partial-raw');
  assert(convertRule(rule('block', { resourceTypes: ['object', 'xmlhttprequest', 'ping', 'csp_report', 'websocket', 'other'] })).rules.some(r => r.trigger['resource-type'].includes('raw')));
  assert.equal(convertRule(rule('block', { resourceTypes: ['webtransport'] })).reason, 'resource-type:webtransport');
});

test('restricted regex accepted; lookarounds, backrefs and non-ASCII dropped', () => {
  assert(!convertRule(rule('block', { regexFilter: '^https://ads[0-9]+[.]example/' })).reason);
  for (const regexFilter of ['(?=ads)', '(ads)\\1', 'a|b', 'a{2}', '\\bads', 'é']) assert.equal(convertRule(rule('block', { regexFilter })).reason, 'regex');
  assert.equal(convertRule(rule('block', { regexFilter: 'x'.repeat(1025) })).reason, 'regex');
});

test('initiator domains scope a rule to the requesting frame, never the top document', () => {
  const blocked = convertRule(rule('block', { urlFilter: '||ads.test^', initiatorDomains: ['Site.test', 'site.test'] }));
  assert.equal(blocked.reason, undefined);
  assert.equal(blocked.frameScoped, true);
  for (const emitted of blocked.rules) {
    assert(!('if-top-url' in emitted.trigger));
    assert.deepEqual(emitted.trigger['if-frame-url'].length, 1);
    assert(!emitted.trigger['resource-type'].includes('document'));
    const frame = new RegExp(emitted.trigger['if-frame-url'][0]);
    assert(frame.test('https://www.site.test/page'));
    assert(!frame.test('https://site.test.evil/page'));
  }
  const allowed = convertRule(rule('allow', { urlFilter: '||cdn.test^', excludedInitiatorDomains: ['other.test'], resourceTypes: ['script'] }, 30));
  assert.equal(allowed.reason, undefined);
  assert.equal(allowed.rules[0].action.type, 'ignore-previous-rules');
  assert(new RegExp(allowed.rules[0].trigger['unless-frame-url'][0]).test('https://other.test/'));
  assert.equal(convertRule(rule('allow', { urlFilter: '||cdn.test^', initiatorDomains: ['site.test'], resourceTypes: ['sub_frame'] })).reason, 'initiator-frame-document');
  const narrowed = convertRule(rule('allow', { urlFilter: '||cdn.test^', initiatorDomains: ['site.test'] }, 30));
  assert.equal(narrowed.reason, undefined);
  assert(narrowed.rules.every(emitted => !emitted.trigger['resource-type'].includes('document') && emitted.trigger['if-frame-url']));
  assert.equal(convertRule(rule('block', { initiatorDomains: ['a.test'], excludedInitiatorDomains: ['b.a.test'] })).reason, 'initiator-domain-conjunction');
  const frameOnly = convertRule(rule('block', { urlFilter: '||ads.test^', initiatorDomains: ['site.test'], resourceTypes: ['sub_frame'] }));
  assert.equal(frameOnly.reason, 'initiator-frame-document');
});

test('allowAllRequests exempts the matching document and everything it loads', () => {
  const top = convertRule(rule('allowAllRequests', { requestDomains: ['shop.test'], resourceTypes: ['main_frame', 'sub_frame'] }, 40));
  assert.equal(top.reason, undefined);
  assert.deepEqual(top.rules.map(emitted => Object.keys(emitted.trigger).sort()), [['if-top-url', 'url-filter'], ['if-frame-url', 'url-filter']]);
  assert(top.rules.every(emitted => emitted.action.type === 'ignore-previous-rules' && emitted.trigger['url-filter'] === '.*'));
  assert(top.decisions.every(decision => decision.action === 'allow' && decision.priority === 40));
  assert(new RegExp(top.rules[0].trigger['if-top-url'][0]).test('https://www.shop.test/cart'));
  assert.equal(convertRule(rule('allowAllRequests', { urlFilter: '||shop.test^' })).reason, 'allow-all-requests:shape');
  assert.equal(convertRule(rule('allowAllRequests', { urlFilter: '||shop.test^', resourceTypes: ['script'] })).reason, 'allow-all-requests:shape');
});

test('unsupported action/condition/shape drops are counted once per DNR rule', () => {
  const result = convertRules([rule(), rule('redirect'), rule('modifyHeaders'), rule('allowAllRequests'), rule('block', { requestMethods: ['post'] }), rule('block', { tabIds: [1] }), { ...rule(), priority: 0 }]);
  assert.equal(result.report.input, 7);
  assert.equal(result.report.converted, 1);
  assert.equal(result.report.dropped, 6);
  assert.equal(Object.values(result.report.reasons).reduce((a, b) => a + b, 0), 6);
});

test('splitting reserves exception and trusted suffix for each list', () => {
  const rules = Array.from({ length: 11 }, () => ({ trigger: { 'url-filter': 'ad' }, action: { type: 'block' } }));
  const suffix = [{ trigger: { 'url-filter': 'ok' }, action: { type: 'ignore-previous-rules' } }];
  const parts = splitRules(rules, suffix, 5);
  assert.deepEqual(parts.map(p => p.length), [5, 5, 4]);
  assert(parts.every(p => p.at(-1) === suffix[0]));
  assert.throws(() => splitRules(rules, suffix, 1), /suffix/);
  assert.throws(() => splitRules(rules, [], 150001), /limit/);
  const real = splitRules(Array(150000).fill(rules[0]), suffix);
  assert(real.every(p => p.length <= 140000));
});

test('trusted rule uses top URL with domain boundaries and ports', () => {
  const trusted = trustedRule(['Site.Test', 'site.test', '*.evil.test', 'https://bad.test/', '#comment']);
  assert.equal(trusted.action.type, 'ignore-previous-rules');
  assert.equal(trusted.trigger['if-top-url'].length, 1);
  const re = new RegExp(trusted.trigger['if-top-url'][0]);
  for (const url of ['https://site.test/', 'https://a.site.test:8080/p', 'http://site.test/']) assert(re.test(url));
  for (const url of ['https://site.test.evil/', 'https://evilsite.test/', 'https://else.test/site.test']) assert(!re.test(url));
  assert.equal(trustedRule([]), null);
});

test('off switch attaches no groups; a merged group follows its main list', () => {
  const groups = [{ id: 'a', uboIds: ['x'] }, { id: 'b', uboIds: ['y', 'z'] }];
  const state = { enabled: true, stats: { ready: true }, lists: [{ id: 'x', enabled: true }, { id: 'y', enabled: true }, { id: 'z', enabled: false }] };
  assert.deepEqual(selectedLists(groups, state).map(g => g.id), ['a', 'b']);
  assert.deepEqual(selectedLists(groups, { ...state, lists: [{ id: 'x', enabled: true }, { id: 'y', enabled: false }, { id: 'z', enabled: true }] }).map(g => g.id), ['a']);
  assert.deepEqual(selectedLists(groups, { ...state, enabled: false }), []);
  assert.throws(() => selectedLists(groups, { ...state, stats: { ready: false } }), /ready/);
});

test('global selected decisions suppress only lower-priority winners', () => {
  const trigger = { 'url-filter': 'allow' };
  const decisions = [{ priority: 2, action: 'allow', trigger }, { priority: 3, action: 'block', trigger: { 'url-filter': 'important' } }, { priority: 1, action: 'allow', trigger }];
  assert.equal(exceptionRules(decisions, 2, 'block').length, 2);
  assert.equal(exceptionRules(decisions, 3, 'block').length, 0);
  assert.equal(exceptionRules(decisions, 3, 'upgradeScheme').length, 1);
  assert.equal(exceptionRules(decisions, 1, 'cosmetic').length, 0);
});

test('cross-list allows and trusted exception are repeated in each chunk', () => {
  const block = convertRules([rule('block', { urlFilter: 'ad' })]);
  const allow = convertRules([rule('allow', { urlFilter: 'safe' }, 2)]);
  const out = composeChunks([{ rules: block.rules, decisions: block.decisions }, { rules: allow.rules, decisions: allow.decisions }], ['site.test'], 5);
  assert(out.length > 0);
  for (const part of out) {
    assert.equal(part.at(-1).trigger['if-top-url'].length, 1);
    assert(part.some(r => r.trigger['url-filter'] === 'safe' && r.action.type === 'ignore-previous-rules'));
  }
});


test('trusted IPv6 is exact and DNS trailing dots are normalized', () => {
  assert.equal(canonicalHost('[0:0:0:0:0:0:0:1]'), '[::1]');
  assert.equal(canonicalHost('Site.Test.'), 'site.test');
  const rule = trustedRule(['[::1]', 'Site.Test.']);
  const expressions = rule.trigger['if-top-url'].map(value => new RegExp(value));
  for (const url of ['https://[::1]:8080/', 'https://site.test./', 'https://user@site.test/']) assert(expressions.some(re => re.test(url)));
  for (const url of ['https://[::2]/', 'https://site.test@evil.test/']) assert(!expressions.some(re => re.test(url)));
});

test('decision pruning preserves every cross-list bucket suppressor', () => {
  const decisions = [
    { trigger: { 'url-filter': 'ordinary' }, priority: 10, action: 'block' },
    { trigger: { 'url-filter': 'important' }, priority: 40, action: 'block' },
    { trigger: { 'url-filter': 'exception' }, priority: 30, action: 'allow' },
    { trigger: { 'url-filter': 'irrelevant' }, priority: 1, action: 'allow' },
  ];
  const buckets = [{ priority: 10, kind: 'block' }, { priority: 40, kind: 'block' }];
  const pruned = pruneDecisions(decisions, buckets);
  assert.deepEqual(pruned.map(value => value.trigger['url-filter']), ['important', 'exception']);
  for (const bucket of [...buckets, { priority: 10, kind: 'upgradeScheme' }]) {
    const applicable = pruneDecisions(decisions, [...buckets, bucket]);
    assert.deepEqual(exceptionRules(applicable, bucket.priority, bucket.kind), exceptionRules(decisions, bucket.priority, bucket.kind));
  }
});

test('request domain aggregates accept underscore authority labels without weakening trusted hosts', () => {
  const converted = convertRule({ id: 1, action: { type: 'block' }, condition: { requestDomains: ['fb_servpub-a.akamaihd.net', 'tracker.test'], resourceTypes: ['script'] } });
  assert.equal(converted.reason, undefined);
  assert.equal(converted.rules.length, 2);
  assert(new RegExp(converted.rules[0].trigger['url-filter']).test('https://sub_domain.fb_servpub-a.akamaihd.net/a.js'));
  assert(!new RegExp(converted.rules[0].trigger['url-filter']).test('https://notfb_servpub-a.akamaihd.net/a.js'));
  assert.equal(canonicalHost('fb_servpub-a.akamaihd.net'), null);
});

test('unsupported same-list winning exceptions remove matching URL blocks conservatively', () => {
  const blocked = rule('block', { urlFilter: '||maxmind.com^*/geoip.js' }, 10);
  const exception = rule('allow', { urlFilter: '||maxmind.com^*/geoip.js', requestMethods: ['get'] }, 30);
  const converted = convertRules([blocked, exception]);
  assert.equal(converted.rules.length, 0);
  assert.equal(converted.report.converted, 0);
  assert.equal(converted.report.reasons['unsupported-exception-conflict'], 1);
  assert.equal(converted.report.reasons['condition:requestMethods'], 1);
  assert.equal(convertRules([blocked, { ...exception, priority: 10 }]).rules.length, 0);
  assert(convertRules([blocked, { ...exception, priority: 9 }]).rules.length > 0);
  assert(convertRules([blocked, rule('allow', { urlFilter: 'different', requestMethods: ['get'] }, 30)]).rules.length > 0);
  assert(convertRules([blocked]).rules.length > 0);
  const accepted = convertRules([blocked, rule('allow', { urlFilter: '||maxmind.com^*/geoip.js' }, 30)]);
  assert.equal(accepted.report.dropped, 0);
});

test('unsupported winning exceptions remove blocks anchored on the same host', () => {
  const exception = rule('allow', { urlFilter: '||maxmind.com^*/geoip.js', requestMethods: ['get'] }, 30);
  const overlapping = rule('block', { domainType: 'thirdParty', urlFilter: '||maxmind.com/app/' }, 10);
  const aggregate = rule('block', { requestDomains: ['maxmind.com'] }, 10);
  const converted = convertRules([overlapping, aggregate, exception]);
  assert.equal(converted.rules.length, 0);
  assert.equal(converted.report.reasons['unsupported-exception-conflict'], 2);
  for (const other of ['||js.maxmind.com^', '||notmaxmind.com^', '||maxmind.community^', '||com^']) assert(convertRules([rule('block', { urlFilter: other }, 10), exception]).rules.length > 0, other);
  assert(convertRules([overlapping, { ...exception, priority: 9 }]).rules.length > 0);
  const partial = convertRules([rule('block', { requestDomains: ['maxmind.com', 'tracker.test'] }, 10), exception]);
  assert.equal(partial.report.converted, 1);
  assert.equal(partial.report.requestDomainsWithheld, 1);
  assert(partial.rules.length > 0);
  for (const converted of partial.rules) {
    assert(new RegExp(converted.trigger['url-filter']).test('https://tracker.test/a.js'));
    assert(!new RegExp(converted.trigger['url-filter']).test('https://maxmind.com/a.js'));
  }
  const domains = rule('allow', { requestDomains: ['tracker.test'], requestMethods: ['get'] }, 30);
  assert.equal(convertRules([rule('block', { urlFilter: '||tracker.test/a.js' }, 10), domains]).rules.length, 0);
  const suffix = rule('allow', { requestDomains: ['com'], requestMethods: ['get'] }, 30);
  assert(convertRules([rule('block', { urlFilter: '||tracker.com^' }, 10), rule('block', { requestDomains: ['com'] }, 10), suffix]).rules.length > 0);
});

test('unsupported same-list winning regex exceptions remove matching regex blocks conservatively', () => {
  const condition = { regexFilter: '^https://tracker[.]test/ad' };
  const converted = convertRules([rule('block', condition, 10), rule('allow', { ...condition, requestMethods: ['get'] }, 30)]);
  assert.equal(converted.rules.length, 0);
  assert.equal(converted.report.reasons['unsupported-exception-conflict'], 1);
});
