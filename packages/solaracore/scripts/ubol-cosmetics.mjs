import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';

const maximumBytes = 2 * 1024 * 1024;
const maximumItems = 20000;
const identifier = '-?[_a-zA-Z][_a-zA-Z0-9-]*';
const simplePseudo = /^(?:first-child|last-child|only-child|first-of-type|last-of-type|only-of-type|empty|root)\b/;

function reason(report, name, count = 1) {
  report.reasons[name] = (report.reasons[name] || 0) + count;
  report.unsupported += count;
}

async function readBounded(filename) {
  const info = await stat(filename);
  if (!info.isFile() || info.size > maximumBytes) throw new Error('unsupported-input-size');
  const source = await readFile(filename, 'utf8');
  if (Buffer.byteLength(source, 'utf8') > maximumBytes) throw new Error('unsupported-input-size');
  return source;
}

function splitSelectors(text) {
  const result = [];
  let quote = '';
  let brackets = 0;
  let parentheses = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (quote) {
      if (char === quote && text[i - 1] !== '\\') quote = '';
    } else if (char === '"' || char === "'") {
      quote = char;
    } else if (char === '[') {
      brackets++;
    } else if (char === ']') {
      brackets--;
    } else if (char === '(' && brackets === 0) {
      parentheses++;
    } else if (char === ')' && brackets === 0) {
      parentheses--;
    } else if (char === ',' && brackets === 0 && parentheses === 0) {
      result.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  if (quote || brackets !== 0 || parentheses !== 0) return [text.trim()];
  result.push(text.slice(start).trim());
  return result;
}

function safeSelector(selector) {
  if (!selector || selector.length > 1024 || /[^\x20-\x7e]|[\\{};]/.test(selector)) return false;
  let position = 0;
  const take = pattern => {
    const match = pattern.exec(selector.slice(position));
    if (!match) return false;
    position += match[0].length;
    return true;
  };
  const attribute = new RegExp(`^\\[\\s*${identifier}(?:\\s*(?:[~|^$*]?=)\\s*(?:"[^"\\\\\\r\\n]*"|'[^'\\\\\\r\\n]*'|${identifier})(?:\\s+[is])?)?\\s*\\]`);
  const name = new RegExp(`^${identifier}`);
  while (position < selector.length) {
    let components = 0;
    if (selector[position] === '*') {
      position++;
      components++;
    } else if (take(name)) {
      components++;
    }
    while (position < selector.length) {
      const char = selector[position];
      if (char === '.' || char === '#') {
        position++;
        if (!take(name)) return false;
      } else if (char === '[') {
        if (!take(attribute)) return false;
      } else if (char === ':') {
        position++;
        if (!take(simplePseudo)) return false;
      } else {
        break;
      }
      components++;
    }
    if (components === 0) return false;
    if (position === selector.length) return true;
    const beforeSpace = position;
    while (selector[position] === ' ') position++;
    const spaced = position > beforeSpace;
    if ('>+~'.includes(selector[position] || '\0')) {
      position++;
      while (selector[position] === ' ') position++;
    } else if (!spaced) {
      return false;
    }
    if (position === selector.length) return false;
  }
  return false;
}

function convertCSS(source, report) {
  const rules = [];
  const seen = new Set();
  const text = source.replace(/\/\*[\s\S]*?\*\//g, '').trim();
  const groups = [];
  if (!text) return rules;
  if (text.includes('{') || text.includes('}')) {
    const block = /([^{}]+)\{([^{}]*)\}/gy;
    let offset = 0;
    while (offset < text.length) {
      while (/\s/.test(text[offset] || '') && offset < text.length) offset++;
      if (offset === text.length) break;
      block.lastIndex = offset;
      const match = block.exec(text);
      if (!match) {
        reason(report, 'unsupported-css-format');
        return [];
      }
      groups.push([match[1], /^\s*display\s*:\s*none\s*!\s*important\s*;?\s*$/i.test(match[2])]);
      offset = block.lastIndex;
    }
  } else {
    groups.push([text, true]);
  }
  for (const [selectors, declarationAllowed] of groups) {
    for (const selector of splitSelectors(selectors)) {
      report.selectorsSeen++;
      if (report.selectorsSeen > maximumItems) {
        reason(report, 'selector-limit');
        report.converted = rules.length;
        return rules;
      }
      if (!declarationAllowed) {
        reason(report, 'unsupported-declaration');
      } else if (!safeSelector(selector)) {
        reason(report, 'unsupported-selector');
      } else if (!seen.has(selector)) {
        seen.add(selector);
        rules.push({ trigger: { 'url-filter': '^https?://' }, action: { type: 'css-display-none', selector } });
      } else {
        report.duplicates++;
      }
    }
  }
  report.converted = rules.length;
  return rules;
}

function tokensFor(source) {
  const tokens = [];
  let position = 0;
  function quoted(quote) {
    const start = position++;
    while (position < source.length) {
      const char = source[position++];
      if (char === '\\') position++;
      else if (char === quote) return source.slice(start, position);
      else if (char === '\n' || char === '\r') throw new Error('string');
    }
    throw new Error('string');
  }
  function template() {
    position++;
    while (position < source.length) {
      const char = source[position++];
      if (char === '\\') position++;
      else if (char === '`') return;
      else if (char === '$' && source[position] === '{') {
        position++;
        let depth = 1;
        while (position < source.length && depth > 0) {
          const nested = source[position];
          if (nested === "'" || nested === '"') quoted(nested);
          else if (nested === '`') template();
          else {
            position++;
            if (nested === '{') depth++;
            if (nested === '}') depth--;
          }
        }
        if (depth !== 0) throw new Error('template');
      }
    }
    throw new Error('template');
  }
  while (position < source.length) {
    const char = source[position];
    if (/\s/.test(char)) {
      position++;
    } else if (source.startsWith('//', position)) {
      const end = source.indexOf('\n', position + 2);
      position = end < 0 ? source.length : end + 1;
    } else if (source.startsWith('/*', position)) {
      const end = source.indexOf('*/', position + 2);
      if (end < 0) throw new Error('comment');
      position = end + 2;
    } else if (char === "'" || char === '"') {
      tokens.push({ kind: 'string', text: quoted(char) });
    } else if (char === '`') {
      template();
      tokens.push({ kind: 'template', text: '`' });
    } else if (char === '/' && (!tokens.length || ['=', '(', '[', ',', ':', 'return', '!', '{', ';'].includes(tokens.at(-1).text))) {
      position++;
      let bracket = false;
      let closed = false;
      while (position < source.length) {
        const part = source[position++];
        if (part === '\\') position++;
        else if (part === '[') bracket = true;
        else if (part === ']') bracket = false;
        else if (part === '/' && !bracket) { closed = true; break; }
        else if (part === '\n' || part === '\r') break;
      }
      if (!closed) throw new Error('regex');
      while (/[a-z]/i.test(source[position] || '') && position < source.length) position++;
      tokens.push({ kind: 'regex', text: '/' });
    } else {
      const match = /^(?:[$A-Z_a-z][$\w]*|\d+)/.exec(source.slice(position));
      const text = match ? match[0] : char;
      tokens.push({ kind: match ? 'word' : 'punctuation', text });
      position += text.length;
    }
    if (tokens.length > 200000) throw new Error('tokens');
  }
  return tokens;
}

function literalString(text) {
  let result = '';
  for (let i = 1; i < text.length - 1; i++) {
    const char = text[i];
    if (char !== '\\') { result += char; continue; }
    const escaped = text[++i];
    const escapes = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', '0': '\0', '\\': '\\', "'": "'", '"': '"' };
    if (Object.hasOwn(escapes, escaped)) {
      if (escaped === '0' && /\d/.test(text[i + 1] || '')) throw new Error('escape');
      result += escapes[escaped];
    } else if (escaped === 'x' || escaped === 'u') {
      const length = escaped === 'x' ? 2 : 4;
      const digits = text.slice(i + 1, i + 1 + length);
      if (digits.length !== length || !/^[\da-f]+$/i.test(digits)) throw new Error('escape');
      result += String.fromCharCode(parseInt(digits, 16));
      i += length;
    } else {
      throw new Error('escape');
    }
  }
  return result;
}

function genericData(source) {
  const tokens = tokensFor(source);
  const fields = new Set(['lowlyGeneric', 'highlyGeneric', 'exceptions', 'hostnames', 'hasEntities']);
  const data = {};
  let count = 0;
  function literal(start, depth = 0) {
    if (++count > maximumItems * 10 || depth > 4) throw new Error('generic-data-limit');
    const token = tokens[start];
    if (token?.kind === 'string') return { value: literalString(token.text), end: start + 1 };
    if (token?.text === 'true' || token?.text === 'false') return { value: token.text === 'true', end: start + 1 };
    if (token?.kind === 'word' && /^(?:0|[1-9]\d*)$/.test(token.text)) return { value: Number(token.text), end: start + 1 };
    if (token?.text !== '[') throw new Error('generic-literal');
    const value = [];
    let cursor = start + 1;
    while (tokens[cursor]?.text !== ']') {
      const parsed = literal(cursor, depth + 1);
      value.push(parsed.value);
      cursor = parsed.end;
      if (tokens[cursor]?.text === ',') cursor++;
      else if (tokens[cursor]?.text !== ']') throw new Error('generic-separator');
    }
    return { value, end: cursor + 1 };
  }
  for (let i = 0; i < tokens.length - 2; i++) {
    if (!['const', 'let', 'var'].includes(tokens[i].text) || !fields.has(tokens[i + 1].text)) continue;
    const field = tokens[i + 1].text;
    if (tokens[i].text !== 'const' || Object.hasOwn(data, field) || tokens[i + 2].text !== '=') throw new Error('generic-declaration');
    let start = i + 3;
    if (field === 'lowlyGeneric') {
      if (tokens[start]?.text !== 'new' || tokens[start + 1]?.text !== 'Map' || tokens[start + 2]?.text !== '(') throw new Error('generic-map');
      start += 3;
    }
    const parsed = field === 'lowlyGeneric' && tokens[start]?.text === 'undefined' ? { value: [], end: start + 1 } : literal(start);
    let end = parsed.end;
    if (field === 'lowlyGeneric' && tokens[end++]?.text !== ')') throw new Error('generic-map');
    if (tokens[end]?.text !== ';') throw new Error('generic-declaration-end');
    data[field] = parsed.value;
  }
  if (Object.keys(data).length !== fields.size || !Array.isArray(data.lowlyGeneric) || typeof data.highlyGeneric !== 'string' || !Array.isArray(data.exceptions) || !Array.isArray(data.hostnames) || data.hostnames.length !== data.exceptions.length || typeof data.hasEntities !== 'boolean') throw new Error('generic-schema');
  if (data.lowlyGeneric.some(entry => !Array.isArray(entry) || entry.length !== 2 || !Number.isSafeInteger(entry[0]) || typeof entry[1] !== 'string') || [...data.exceptions, ...data.hostnames].some(value => typeof value !== 'string')) throw new Error('generic-schema');
  return data;
}

export async function genericContext(releaseRoot) {
  const directory = path.join(releaseRoot, 'rulesets', 'scripting', 'generic');
  const excluded = new Set();
  try {
    for (const filename of (await readdir(directory)).sort()) {
      if (!filename.endsWith('.js')) continue;
      const data = genericData(await readBounded(path.join(directory, filename)));
      for (const selectors of data.exceptions) for (const selector of selectors.split('\n')) excluded.add(selector);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  let details = [];
  try { details = JSON.parse(await readBounded(path.join(releaseRoot, 'rulesets', 'generic-details.json'))); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!Array.isArray(details)) throw new Error('generic-details-schema');
  const unhide = new Set();
  for (const entry of details) {
    if (!Array.isArray(entry) || entry.length !== 2 || !entry[1] || typeof entry[1] !== 'object') throw new Error('generic-details-schema');
    for (const hostname of entry[1].unhide || []) {
      if (typeof hostname !== 'string' || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(hostname)) throw new Error('generic-hide-hostname');
      unhide.add(hostname);
    }
  }
  return { excluded, unhide: [...unhide].sort() };
}

async function convertGeneric(releaseRoot, rulesetId, report, context) {
  const source = await readBounded(path.join(releaseRoot, 'rulesets', 'scripting', 'generic', `${rulesetId}.js`));
  const data = genericData(source);
  context ??= await genericContext(releaseRoot);
  const selectors = [...data.lowlyGeneric.map(entry => entry[1]), data.highlyGeneric].filter(Boolean).join(',\n');
  const rules = convertCSS(selectors, report).filter(rule => {
    if (!context.excluded.has(rule.action.selector)) return true;
    reason(report, 'selector-exception');
    return false;
  });
  report.converted = rules.length;
  report.genericHideHosts = context.unhide.length;
  for (const rule of rules) {
    rule.trigger['resource-type'] = ['document'];
    rule.trigger['load-context'] = ['top-frame'];
  }
  if (rules.length && context.unhide.length) {
    rules.push({ trigger: { 'url-filter': '^https?://', 'resource-type': ['document'], 'load-context': ['top-frame'], 'if-top-url': context.unhide.map(host => `^https?://([^/?#]*@)?([a-z0-9-]+\\.)*${host.replace(/\./g, '\\.')}\\.?[:/?#]`) }, action: { type: 'ignore-previous-rules' } });
  }
  return rules;
}

function extractGeneratedData(source) {
  const tokens = tokensFor(source);
  const fields = new Set(['argsList', 'hostnamesMap', 'exceptionsMap', 'entitiesMap']);
  const data = {};
  let valuesRead = 0;
  function arrayAt(start, depth = 0) {
    if (depth > 6 || tokens[start]?.text !== '[') throw new Error('array');
    const result = [];
    let cursor = start + 1;
    while (tokens[cursor]?.text !== ']') {
      const token = tokens[cursor];
      if (!token || ++valuesRead > maximumItems * 10) throw new Error('array');
      if (token.text === '[') {
        const parsed = arrayAt(cursor, depth + 1);
        result.push(parsed.value);
        cursor = parsed.end;
      } else if (token.kind === 'string') {
        result.push(literalString(token.text));
        cursor++;
      } else if (/^(?:0|[1-9]\d*)$/.test(token.text) && token.kind === 'word') {
        const number = Number(token.text);
        if (!Number.isSafeInteger(number)) throw new Error('number');
        result.push(number);
        cursor++;
      } else {
        throw new Error('literal');
      }
      if (tokens[cursor]?.text === ',') cursor++;
      else if (tokens[cursor]?.text !== ']') throw new Error('separator');
    }
    return { value: result, end: cursor + 1 };
  }
  for (let i = 0; i < tokens.length - 2; i++) {
    if (!['const', 'let', 'var'].includes(tokens[i].text) || !fields.has(tokens[i + 1].text)) continue;
    const field = tokens[i + 1].text;
    if (tokens[i].text !== 'const' || Object.hasOwn(data, field) || tokens[i + 2].text !== '=') throw new Error('declaration');
    let start = i + 3;
    if (field !== 'argsList') {
      if (tokens[start]?.text !== 'new' || tokens[start + 1]?.text !== 'Map' || tokens[start + 2]?.text !== '(') throw new Error('map');
      start += 3;
    }
    const parsed = field !== 'argsList' && tokens[start]?.text === ')' ? { value: [], end: start } : arrayAt(start);
    let end = parsed.end;
    if (field !== 'argsList' && tokens[end++]?.text !== ')') throw new Error('map');
    if (tokens[end]?.text !== ';') throw new Error('declaration-end');
    data[field] = parsed.value;
  }
  if (Object.keys(data).length !== fields.size || data.argsList.length > maximumItems) throw new Error('missing-data');
  return data;
}

function validateMap(entries, argumentCount, allowEntities = false) {
  if (entries.length > maximumItems) throw new Error('map-size');
  const seen = new Set();
  return entries.map(entry => {
    if (!Array.isArray(entry) || entry.length !== 2) throw new Error('map-entry');
    const [hostname, value] = entry;
    if (typeof hostname !== 'string' || hostname.length > 253 || hostname !== hostname.toLowerCase() || !(allowEntities ? /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/ : /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/).test(hostname) || hostname.split('.').some(label => label.length > 63) || seen.has(hostname)) throw new Error('hostname');
    seen.add(hostname);
    const indices = Array.isArray(value) ? value : [value];
    if (indices.length === 0 || indices.length > argumentCount || indices.some(index => !Number.isInteger(index) || index < 0 || index >= argumentCount) || new Set(indices).size !== indices.length) throw new Error('indices');
    return [hostname, indices];
  });
}

function safeArguments(args) {
  if (!Array.isArray(args) || args.length < 1 || args.length > 3 || args.some(value => typeof value !== 'string')) return null;
  const names = args[0].split('|');
  if (names.length > 16 || names.some(name => !/^[A-Za-z_][A-Za-z0-9_-]{0,63}$/.test(name))) return null;
  const selector = args[1] || names.map(name => `[${name}]`).join(',');
  if (selector.length > 4096 || !splitSelectors(selector).every(safeSelector)) return null;
  const behavior = args[2] || '';
  if (behavior !== '' && behavior !== 'stay') return null;
  return { names, selector, stay: behavior === 'stay' };
}

function removeAttributeSource(argumentsList, hosts, exceptions) {
  const data = JSON.stringify({ argumentsList, hosts, exceptions });
  return `(()=>{"use strict";if(globalThis.top!==globalThis||!/^https?:$/.test(location.protocol))return;const data=${data};const hostname=location.hostname.toLowerCase();const matches=domain=>hostname===domain||hostname.endsWith("."+domain);const excluded=new Set(data.exceptions.filter(entry=>matches(entry[0])).flatMap(entry=>entry[1]));const selected=new Set(data.hosts.filter(entry=>matches(entry[0])).flatMap(entry=>entry[1]));const registryKey=Symbol.for("solara.ubol.cleanup");if(globalThis[registryKey]!==undefined&&!Array.isArray(globalThis[registryKey]))return;const registry=globalThis[registryKey]||(globalThis[registryKey]=[]);const pending=new Set();const observers=new Set();let active=true;const stop=()=>{if(!active)return;active=false;for(const callback of pending)document.removeEventListener("DOMContentLoaded",callback);pending.clear();for(const observer of observers)observer.disconnect();observers.clear();};registry.push({version:globalThis[Symbol.for("solara.ubol.version")],stop});for(const index of selected){if(excluded.has(index))continue;const entry=data.argumentsList[index];if(!entry)continue;const run=()=>{if(!active)return;try{for(const element of document.querySelectorAll(entry.selector)){for(const name of entry.names)element.removeAttribute(name);}}catch{}};const start=()=>{if(!active)return;pending.delete(start);run();if(entry.stay&&active){const observer=new MutationObserver(run);observers.add(observer);observer.observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:entry.names});}};if(document.readyState==="loading"){pending.add(start);document.addEventListener("DOMContentLoaded",start,{once:true});}else start();}})();`;
}

async function convertScriptlets(directory, rulesetId, report) {
  let filenames;
  try {
    filenames = await readdir(directory);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    reason(report, 'missing-scriptlet-directory');
    return [];
  }
  const result = [];
  for (const filename of filenames.sort()) {
    if (!filename.startsWith(`${rulesetId}.`) || !filename.endsWith('.js')) continue;
    report.files++;
    const name = filename.slice(rulesetId.length + 1, -3);
    if (name !== 'remove-attr') {
      reason(report, 'unsupported-scriptlet-name');
      continue;
    }
    let data;
    let hosts;
    let exceptions;
    try {
      data = extractGeneratedData(await readBounded(path.join(directory, filename)));
      hosts = validateMap(data.hostnamesMap, data.argsList.length, false);
      exceptions = validateMap(data.exceptionsMap, data.argsList.length, false);
      validateMap(data.entitiesMap, data.argsList.length, true);
    } catch (error) {
      reason(report, error.message === 'unsupported-input-size' ? error.message : 'unsupported-generated-schema');
      continue;
    }
    report.argumentsSeen += data.argsList.length;
    if (data.entitiesMap.length) {
      reason(report, 'unsupported-entity-targeting');
      continue;
    }
    const used = new Set(hosts.flatMap(entry => entry[1]));
    const argumentsList = data.argsList.map((args, index) => {
      const converted = safeArguments(args);
      if (!converted) reason(report, 'unsupported-arguments');
      else if (!used.has(index)) reason(report, 'unmapped-arguments');
      else report.argumentsConverted++;
      return converted && used.has(index) ? converted : null;
    });
    if (!argumentsList.some(Boolean)) continue;
    result.push({ name: `${rulesetId}.${name}`, source: removeAttributeSource(argumentsList, hosts, exceptions) });
    report.converted++;
  }
  return result;
}

export async function convertCosmetics(releaseRoot, rulesetId, context) {
  if (typeof rulesetId !== 'string' || !/^[a-z0-9_-]{1,80}$/.test(rulesetId)) throw new Error('Invalid ruleset identifier');
  const report = {
    cosmetics: { files: 0, selectorsSeen: 0, converted: 0, duplicates: 0, unsupported: 0, reasons: {} },
    scriptlets: { files: 0, converted: 0, argumentsSeen: 0, argumentsConverted: 0, unsupported: 0, reasons: {} },
  };
  const scripting = path.join(releaseRoot, 'rulesets', 'scripting');
  let rules = [];
  try {
    const source = await readBounded(path.join(scripting, 'generichigh', `${rulesetId}.css`));
    report.cosmetics.files++;
    rules = convertCSS(source, report.cosmetics);
  } catch (error) {
    if (error.code === 'ENOENT') {
      try {
        rules = await convertGeneric(releaseRoot, rulesetId, report.cosmetics, context);
        report.cosmetics.files++;
      } catch (genericError) {
        if (genericError.code === 'ENOENT') reason(report.cosmetics, 'missing-generic-file');
        else if (genericError.message === 'unsupported-input-size') reason(report.cosmetics, genericError.message);
        else reason(report.cosmetics, 'unsupported-generated-schema');
      }
    }
    else if (error.message === 'unsupported-input-size') reason(report.cosmetics, error.message);
    else throw error;
  }
  const scriptlets = await convertScriptlets(path.join(scripting, 'scriptlet'), rulesetId, report.scriptlets);
  for (const world of ['main', 'isolated']) {
    try {
      await readBounded(path.join(scripting, 'scriptlet', world, `${rulesetId}.js`));
      report.scriptlets.files++;
      reason(report.scriptlets, 'unsupported-bundled-scriptlets');
    } catch (error) {
      if (error.code !== 'ENOENT') reason(report.scriptlets, error.message === 'unsupported-input-size' ? error.message : 'unsupported-generated-schema');
    }
  }
  return { rules, scriptlets, report };
}
