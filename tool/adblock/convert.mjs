// Converts ABP/EasyList sources into a Safari content-blocker rule list.
//
// Usage:
//   node tool/adblock/convert.mjs easylistchina.txt easylist.txt
//
// Outputs assets/adblock/rules.json.gz and assets/adblock/meta.json. The
// identifier embeds a hash of the compiled JSON, so an app update compiles a
// new list instead of reusing the stale one cached by WKContentRuleListStore.
//
// Only network rules and simple cosmetic selectors are emitted. Options that
// Safari cannot express ($redirect, $csp, $removeparam, dnstype, ...) drop the
// rule; a partially converted rule is never kept, because a rule with a
// missing domain scope blocks too much.

import { createHash } from 'crypto';
import { readFileSync, writeFileSync } from 'fs';
import { gzipSync } from 'zlib';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const outDir = join(root, 'assets', 'adblock');

const inputs = process.argv.slice(2);
if (inputs.length === 0) {
  console.error('usage: node convert.mjs <easylistchina.txt> [easylist.txt]');
  process.exit(1);
}

const typeMap = {
  script: 'script',
  image: 'image',
  stylesheet: 'style-sheet',
  font: 'font',
  media: 'media',
  xmlhttprequest: 'raw',
  subdocument: 'document',
  document: 'document',
  websocket: 'raw',
  ping: 'raw',
  object: 'raw',
  'object-subrequest': 'raw',
  other: 'raw',
  'xhr': 'raw',
};

// Options that change the meaning of the pattern in ways a Safari content
// blocker cannot reproduce. Keeping such a rule unqualified would over-block.
const unsafeOptions = new Set([
  'redirect', 'redirect-rule', 'csp', 'removeparam', 'replace', 'rewrite',
  'dnstype', 'dnsrewrite', 'client', 'cookie', 'header', 'method', 'to',
  'permissions', 'uritransform', 'inline-script', 'inline-font', 'popup',
  'elemhide', 'generichide', 'genericblock', 'specifichide', 'important',
  'badfilter', 'match-case', 'webrtc', 'empty', 'mp4', 'ghide', 'ehide',
  'shide', 'doc', 'all',
]);

// WebKit's content-blocker regex explicitly rejects disjunctions ("|"), so a
// pattern ending in ABP's separator has to become two triggers: one matching
// an actual separator character, one matching the end of the URL.
const separatorChar = '[^a-zA-Z0-9_\\-.%]';
const escapeRe = (text) => text.replace(/[.+?^${}()|[\]\\]/g, '\\$&');

function domainScope(values) {
  const include = [];
  const exclude = [];
  for (const raw of values.split('|')) {
    let value = raw.trim().toLowerCase();
    if (!value) continue;
    const negated = value.startsWith('~');
    if (negated) value = value.slice(1);
    // WebKit wants `*` for "this domain and subdomains"; a bare domain would
    // match only the exact host.
    if (!value.includes('*')) value = `*${value}`;
    if (!/^[\x20-\x7e]+$/.test(value)) continue;
    (negated ? exclude : include).push(value);
  }
  return { include, exclude };
}

function patternToRegexes(pattern) {
  let body = pattern;
  let prefix = '';
  let suffix = '';
  if (body.startsWith('||')) {
    prefix = '^https?://([^/]+\\.)?';
    body = body.slice(2);
  } else if (body.startsWith('|')) {
    prefix = '^';
    body = body.slice(1);
  }
  if (body.endsWith('|')) {
    suffix = '$';
    body = body.slice(0, -1);
  }
  const endsInSeparator = body.endsWith('^');
  if (endsInSeparator) body = body.slice(0, -1);
  // A `^` is ABP's separator, not a regex anchor. Only the trailing one can
  // also mean "end of URL", which is why that case expands into two regexes.
  body = body
    .split('^')
    .map(escapeRe)
    .join(separatorChar);
  body = body.replace(/\*/g, '.*');
  if (!body) return [];

  const base = prefix + body;
  const regexes = endsInSeparator
      ? [base + separatorChar + suffix, base + '$']
      : [base + suffix];
  return [...new Set(regexes)].filter((regex) => {
    if (regex.length > 900) return false;
    // Safari rejects look-around, backreferences and alternation. Keep the
    // guard even though the generator should never produce them.
    if (/\(\?[=!<]|\\[0-9]|\|/.test(regex)) return false;
    return true;
  });
}

function makeTrigger(regex, options) {
  const trigger = { 'url-filter': regex };
  const types = options.types;
  if (types.size > 0) trigger['resource-type'] = [...types];
  if (options.thirdParty === true) trigger['load-type'] = ['third-party'];
  if (options.thirdParty === false) trigger['load-type'] = ['first-party'];
  if (options.include.length > 0) trigger['if-domain'] = options.include;
  if (options.exclude.length > 0) trigger['unless-domain'] = options.exclude;
  return trigger;
}

function parseNetwork(line) {
  let exception = false;
  if (line.startsWith('@@')) {
    exception = true;
    line = line.slice(2);
  }
  let pattern = line;
  let optionText = '';
  // Options start at the last `$` so a regex-style `$` inside the pattern does
  // not swallow the options.
  const dollar = line.lastIndexOf('$');
  if (dollar > 0) {
    const candidate = line.slice(dollar + 1);
    if (/^[~a-z0-9_,=-]+$/i.test(candidate)) {
      pattern = line.slice(0, dollar);
      optionText = candidate;
    }
  }
  if (!pattern || pattern.length < 3) return null;
  // `/regex/` rules are not representable.
  if (/^\/.*\/$/.test(pattern)) return null;

  const options = {
    types: new Set(),
    thirdParty: null,
    include: [],
    exclude: [],
  };
  if (optionText) {
    const parts = optionText.split(',');
    const domainValues = [];
    for (const part of parts) {
      const token = part.trim().toLowerCase();
      if (!token) continue;
      const negated = token.startsWith('~');
      const name = negated ? token.slice(1) : token;
      const eq = name.indexOf('=');
      const key = eq === -1 ? name : name.slice(0, eq);
      const value = eq === -1 ? '' : name.slice(eq + 1);
      if (unsafeOptions.has(key)) return null;
      if (key === 'third-party') {
        options.thirdParty = !negated;
        continue;
      }
      if (key === 'domain') {
        domainValues.push(value);
        continue;
      }
      const type = typeMap[key];
      if (type) {
        if (!negated) options.types.add(type);
        continue;
      }
      // An option we do not understand must not silently widen the rule.
      return null;
    }
    if (domainValues.length > 0) {
      const scope = domainScope(domainValues.join('|'));
      options.include = scope.include;
      options.exclude = scope.exclude;
      // WebKit allows at most one domain condition per trigger. A rule that
      // needs both an allow-list and a deny-list cannot be represented, and
      // dropping it is safer than widening it.
      if (options.include.length > 0 && options.exclude.length > 0) {
        return null;
      }
    }
  }

  // Blocking a whole document without a site scope would break browsing.
  if (options.types.size === 1 && options.types.has('document') &&
      options.include.length === 0) {
    return null;
  }

  const regexes = patternToRegexes(pattern);
  if (regexes.length === 0) return null;
  return regexes.map((regex) => ({
    trigger: makeTrigger(regex, options),
    action: exception
      ? { type: 'ignore-previous-rules' }
      : { type: 'block' },
    _exception: exception,
  }));
}

const cosmeticReject = /:has\(|:contains\(|:-abp-|:style\(|:matches|:not\(|:is\(|:where\(|[{}]|\\/;

function parseCosmetic(line) {
  let separatorIndex = line.indexOf('#@#');
  if (separatorIndex !== -1) return null;
  // `#?#` is an extended selector; `#$#` is a style rule.
  if (line.includes('#?#')) return null;
  separatorIndex = line.indexOf('##');
  if (separatorIndex === -1) return null;
  const domainsRaw = line.slice(0, separatorIndex).trim();
  const selector = line.slice(separatorIndex + 2).trim();
  if (!selector || selector.length > 180) return null;
  if (cosmeticReject.test(selector)) return null;
  // Attribute selectors with quotes survive; bare `#` ids are fine.
  if (!/^[#.\w\s:>+~*[\]=^$|(),'"-]+$/.test(selector)) return null;

  const include = [];
  const exclude = [];
  if (domainsRaw) {
    for (let domain of domainsRaw.split(',')) {
      domain = domain.trim().toLowerCase();
      if (!domain) continue;
      const negated = domain.startsWith('~');
      if (negated) domain = domain.slice(1);
      if (!domain.includes('*')) domain = `*${domain}`;
      if (!/^[\x20-\x7e]+$/.test(domain)) continue;
      (negated ? exclude : include).push(domain);
    }
  }
  if (domainsRaw && include.length === 0 && exclude.length === 0) return null;
  // Same one-condition limit as network triggers.
  if (include.length > 0 && exclude.length > 0) return null;
  const trigger = { 'url-filter': '.*' };
  if (include.length > 0) trigger['if-domain'] = include;
  if (exclude.length > 0) trigger['unless-domain'] = exclude;
  return {
    trigger,
    action: { type: 'css-display-none', selector },
    _exception: false,
  };
}

const blocks = [];
const exceptions = [];
const cosmetic = [];
const seen = new Set();

function add(rule) {
  // Sort key deliberately ignores the action so a blocking rule and an ABP
  // exception for the same trigger stay distinct.
  const key = JSON.stringify(rule.trigger) + rule.action.type;
  if (seen.has(key)) return false;
  seen.add(key);
  if (rule.action.type === 'css-display-none') cosmetic.push(rule);
  else if (rule._exception) exceptions.push(rule);
  else blocks.push(rule);
  return true;
}

const stats = { lines: 0, block: 0, exception: 0, cosmetic: 0, dropped: 0 };

for (const input of inputs) {
  const text = readFileSync(input, 'utf8');
  for (let raw of text.split(/\r?\n/)) {
    raw = raw.trim();
    if (!raw || raw.startsWith('!') || raw.startsWith('[')) continue;
    stats.lines++;
    let rule = null;
    if (raw.includes('##') || raw.includes('#@#') || raw.includes('#?#')) {
      rule = parseCosmetic(raw);
    } else {
      rule = parseNetwork(raw);
    }
    if (!rule) {
      stats.dropped++;
      continue;
    }
    for (const one of Array.isArray(rule) ? rule : [rule]) {
      if (!add(one)) continue;
      stats[one._exception
        ? 'exception'
        : one.action.type === 'css-display-none'
          ? 'cosmetic'
          : 'block']++;
    }
  }
}

// Caps keep compile time and memory sane on older phones. Blocking rules are
// more valuable than cosmetics, so generic cosmetics get the tightest budget.
const MAX_BLOCK = 46000;
const MAX_COSMETIC = 6000;
const MAX_EXCEPTIONS = 9000;

const trimGenericCosmetic = (rules) => {
  // Site-scoped selectors are more precise; keep them ahead of globals.
  return [...rules].sort((a, b) => {
    const aScoped = a.trigger['if-domain'] ? 0 : 1;
    const bScoped = b.trigger['if-domain'] ? 0 : 1;
    return aScoped - bScoped;
  });
};

const chosenBlocks = blocks.slice(0, MAX_BLOCK);
const chosenCosmetic = trimGenericCosmetic(cosmetic).slice(0, MAX_COSMETIC);
const chosenExceptions = exceptions.slice(0, MAX_EXCEPTIONS);

// Cleanup internal flags, and keep exceptions last: `ignore-previous-rules`
// only cancels rules that precede it in the list.
const clean = (rule) => ({ trigger: rule.trigger, action: rule.action });
const output = [
  ...chosenBlocks.map(clean),
  ...chosenCosmetic.map(clean),
  ...chosenExceptions.map(clean),
];

const json = JSON.stringify(output);
const digest = createHash('sha256').update(json).digest('hex').slice(0, 10);
const identifier = `so-adblock-${digest}`;
const meta = {
  name: 'EasyList China + EasyList',
  identifier,
  rules: output.length,
  blocks: chosenBlocks.length,
  cosmetic: chosenCosmetic.length,
  exceptions: chosenExceptions.length,
  sources: inputs.map((input) => input.split(/[\\/]/).pop()),
  generatedAt: new Date().toISOString(),
  bytes: Buffer.byteLength(json),
};

writeFileSync(join(outDir, 'rules.json.gz'), gzipSync(Buffer.from(json), { level: 9 }));
writeFileSync(join(outDir, 'meta.json'), JSON.stringify(meta, null, 2) + '\n');

// Network-only fallback for the rare case WebKit rejects the cosmetic CSS.
// A content-blocker list is compiled as a unit: one bad selector would
// otherwise cost the whole feature.
const liteBlocks = blocks.slice(0, 12000);
const liteOutput = [...liteBlocks.map(clean), ...exceptions.map(clean)];
const liteJson = JSON.stringify(liteOutput);
const liteDigest = createHash('sha256').update(liteJson).digest('hex').slice(0, 10);
const liteMeta = {
  name: 'EasyList China + EasyList (network only)',
  identifier: `so-adblock-lite-${liteDigest}`,
  rules: liteOutput.length,
  blocks: liteBlocks.length,
  cosmetic: 0,
  exceptions: exceptions.length,
  sources: inputs.map((input) => input.split(/[\\/]/).pop()),
  generatedAt: meta.generatedAt,
  bytes: Buffer.byteLength(liteJson),
};
writeFileSync(join(outDir, 'rules-lite.json.gz'), gzipSync(Buffer.from(liteJson), { level: 9 }));
writeFileSync(join(outDir, 'meta-lite.json'), JSON.stringify(liteMeta, null, 2) + '\n');

console.log(JSON.stringify({ stats, meta }, null, 2));
