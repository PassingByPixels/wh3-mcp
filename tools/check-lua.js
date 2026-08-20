// Syntax-check a Lua 5.1 file with luaparse. Usage: node check-lua.js <file>
const fs = require('fs');
const luaparse = require('luaparse');
const file = process.argv[2];
if (!file) { console.error('usage: node check-lua.js <file>'); process.exit(2); }
const src = fs.readFileSync(file, 'utf8');
try {
  luaparse.parse(src, { luaVersion: '5.1', comments: false });
} catch (e) {
  console.error('SYNTAX ERROR: ' + e.message);
  process.exit(1);
}

// Ban plain-flag string.find: s:find(needle, init, true) corrupts the game's
// Lua string subsystem process-wide (root-caused 2026-08-21). Use the mod's
// plain_find helper instead.
const plainFinds = [];
src.split(/\r?\n/).forEach((line, i) => {
  if (/[:.]find\s*\([^()]*,[^()]*,\s*true\s*\)/.test(line)) plainFinds.push(`${i + 1}: ${line.trim()}`);
});
if (plainFinds.length) {
  console.error('PLAIN-FLAG string.find BANNED (corrupts the game string subsystem; use plain_find):');
  plainFinds.forEach(l => console.error('  line ' + l));
  process.exit(1);
}
console.log('OK: ' + file + ' parses as Lua 5.1, no plain-flag finds');
