#!/usr/bin/env node
// Build the cm_search docs corpus (wh3_mcp_docs.tsv) from chadvandy/tw_autogen EmmyLua stubs.
//
// Usage: node build-docs-corpus.js <path-to-tw_autogen>/output/wh3 [out.tsv]
// Default output: ../server/data/wh3_mcp_docs.tsv (committed; server deploys it to the WH3 root).
//
// Output is TAB-separated, one record per line, NO header:
//   contexts \t class \t name \t signature \t returns \t description
// contexts is a comma-joined set (campaign,battle,frontend,global,events).
// The file is PURE ASCII (typographic chars transliterated, the rest
// stripped) so it stays safe through every ASCII-only link in the chain
// (PS 5.1 tooling, the mod's file protocol, terminals).
// Line-oriented on purpose: the mod stream-filters it; it must never need a
// full json.decode of a megabyte.

const fs = require('fs');
const path = require('path');

const srcRoot = process.argv[2];
const outFile = process.argv[3] || path.join(__dirname, '..', 'server', 'data', 'wh3_mcp_docs.tsv');
if (!srcRoot || !fs.existsSync(srcRoot)) {
  console.error('Usage: node build-docs-corpus.js <tw_autogen>/output/wh3 [out.tsv]');
  process.exit(1);
}

// folder -> context tag; special files override below
const FOLDERS = { campaign: 'campaign', battle: 'battle', frontend: 'frontend', global: 'global' };
const SKIP_FILES = new Set(['all.lua', 'lua.lua']); // aliases / Lua stdlib
const FILE_CONTEXT = { 'script_interfaces.lua': 'campaign', 'events.lua': 'events', 'tw_events_and_interfaces.lua': 'events' };

const DESC_MAX = 260;

// Transliterate typographic characters, then strip anything still non-ASCII.
const TRANSLIT = new Map(Object.entries({
  '‘': "'", '’': "'", '‚': "'", '“': '"', '”': '"', '„': '"',
  '–': '-', '—': '-', '―': '-', '…': '...', ' ': ' ',
  '×': 'x', '°': ' degrees', '→': '->', '←': '<-',
}));
let translitCount = 0, strippedCount = 0;
function toAscii(s) {
  let out = '';
  for (const ch of s) {
    if (ch.charCodeAt(0) < 128) { out += ch; continue; }
    const t = TRANSLIT.get(ch);
    if (t !== undefined) { out += t; translitCount++; }
    else {
      // accented letters -> base letter via NFD decomposition, else drop
      const base = ch.normalize('NFD').replace(/[^\x00-\x7f]/g, '');
      out += base;
      if (base) translitCount++; else strippedCount++;
    }
  }
  return out;
}

function clean(s) {
  return toAscii(s.replace(/<br\s*\/?>/g, ' ')).replace(/\s+/g, ' ').replace(/\t/g, ' ').trim();
}
function truncate(s, n) {
  if (s.length <= n) return s;
  // cut at a sentence end if one lands in the back half, else hard cut
  const cut = s.slice(0, n);
  const dot = cut.lastIndexOf('. ');
  return (dot > n / 2 ? cut.slice(0, dot + 1) : cut.trimEnd() + '...');
}

// key "class\0name" -> record {contexts:Set, class, name, signature, returns, desc}
const records = new Map();

function addRecord(context, klass, name, signature, returns, desc) {
  const key = klass + '\0' + name;
  const existing = records.get(key);
  if (existing) {
    existing.contexts.add(context);
    // keep the longest description seen
    if (desc.length > existing.desc.length) existing.desc = desc;
    return;
  }
  records.set(key, { contexts: new Set([context]), class: klass, name, signature, returns, desc });
}

const RE_FUNC = /^\s*function\s+(?:([\w_]+)[.:])?([\w_]+)\s*\(([^)]*)\)\s*end\s*$/;
const RE_PARAM = /^---@param\s+(\S+)\s+(\S+)(?:\s+#?(.*))?$/;
const RE_RETURN = /^---@return\s+(\S+)(?:\s+#?(.*))?$/;
const RE_FIELD_FUN = /^---@field\s+([\w_]+)\s+fun\(([^)]*)\)(?::(\S+))?\s*$/;
const RE_DOC = /^\s*---\s?(?!@)(.*)$/;
const RE_CLASS = /^---@class\s+([\w_]+)/;

function parseFile(filePath, context) {
  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  let doc = [];       // accumulated --- description lines
  let params = [];    // {name, type}
  let returns = [];   // type strings
  let lastClass = ''; // from ---@class, for @field context fallback

  const reset = () => { doc = []; params = []; returns = []; };

  for (const line of lines) {
    let m;
    if ((m = line.match(RE_CLASS))) { lastClass = m[1]; reset(); continue; }
    if ((m = line.match(RE_DOC))) { if (m[1]) doc.push(m[1]); continue; }
    if ((m = line.match(RE_PARAM))) { params.push({ name: m[1], type: m[2] }); continue; }
    if ((m = line.match(RE_RETURN))) { returns.push(m[1]); continue; }
    if ((m = line.match(RE_FIELD_FUN))) {
      // script_interfaces style: ---@field name fun(self:CLASS, a:type):ret
      const args = m[2].split(',').map(s => s.trim()).filter(Boolean);
      let klass = lastClass;
      const rest = [];
      for (const a of args) {
        const [an, at] = a.split(':').map(s => s.trim());
        if (an === 'self') { if (at) klass = at; continue; }
        rest.push(at ? `${an}: ${at}` : an);
      }
      addRecord(context, klass, m[1], `(${rest.join(', ')})`, m[3] || '',
        truncate(clean(doc.join(' ')), DESC_MAX));
      reset();
      continue;
    }
    if ((m = line.match(RE_FUNC))) {
      const klass = m[1] || '';
      const name = m[2];
      const argNames = m[3].split(',').map(s => s.trim()).filter(Boolean);
      const typed = argNames.map(an => {
        const p = params.find(p => p.name === an);
        return p ? `${an}: ${p.type}` : an;
      });
      addRecord(context, klass, name, `(${typed.join(', ')})`, returns.join(', '),
        truncate(clean(doc.join(' ')), DESC_MAX));
      reset();
      continue;
    }
    // any other line breaks the doc-block accumulation
    if (line.trim() !== '') reset();
  }
}

let fileCount = 0;
for (const [folder, defaultCtx] of Object.entries(FOLDERS)) {
  const dir = path.join(srcRoot, folder);
  if (!fs.existsSync(dir)) continue;
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.lua'))) {
    if (SKIP_FILES.has(f)) continue;
    parseFile(path.join(dir, f), FILE_CONTEXT[f] || defaultCtx);
    fileCount++;
  }
}

const rows = [...records.values()]
  .sort((a, b) => a.class.localeCompare(b.class) || a.name.localeCompare(b.name))
  .map(r => [[...r.contexts].sort().join(','), r.class, r.name, r.signature, r.returns, r.desc].join('\t'));

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, rows.join('\n') + '\n', 'utf8');

const byCtx = {};
for (const r of records.values()) for (const c of r.contexts) byCtx[c] = (byCtx[c] || 0) + 1;
console.log(`parsed ${fileCount} files -> ${rows.length} records -> ${outFile}`);
console.log('records per context:', JSON.stringify(byCtx));
