// Mine db keys from a WH3 pack via the RPFM MCP server (:45127).
// Usage: start RPFM MCP, create a session (see build.ps1 init flow), then:
//   node mine-db-keys.mjs <mcp-session-id>
// Edit the dump() calls at the bottom for other tables/patterns. Raw grep on
// packs FAILS (compressed) - this is the reliable route.
import { writeFileSync } from 'fs';
const BASE = 'http://127.0.0.1:45127/mcp';
const SESSION = process.argv[2];
const OUT_DIR = new URL('../docs/research', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const PACK = 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Total War WARHAMMER III\\data\\db.pack';

async function rpc(id, name, args) {
  const res = await fetch(BASE, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'mcp-session-id': SESSION,
    },
    body: JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }),
  });
  const text = await res.text();
  const line = text.split('\n').find(l => l.startsWith('data: {'));
  if (!line) throw new Error('no data line');
  return JSON.parse(line.slice(6));
}

async function dump(table, pattern, outFile) {
  const r = await rpc(40, 'get_packed_file_raw_data', { pack_key: PACK, value: `db/${table}/data__` });
  const txt = r?.result?.content?.[0]?.text;
  const bytes = JSON.parse(txt).VecU8;
  const src = Buffer.from(bytes).toString('latin1');
  const keys = [...new Set(src.match(pattern) || [])].sort();
  writeFileSync(`${OUT_DIR}/${outFile}`, keys.join('\n') + '\n');
  console.log(`${outFile}: ${keys.length} keys`);
}

await dump('character_skills_tables', /wh[a-z0-9_]*skill[a-z0-9_]*/g, 'vanilla_skill_keys.txt');
await dump('building_levels_tables', /wh[a-z0-9_]+/g, 'vanilla_building_keys.txt');
process.exit(0);
