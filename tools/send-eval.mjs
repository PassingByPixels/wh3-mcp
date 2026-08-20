// Send an eval command to the wh3_mcp mod with the Lua source read from a
// file - no shell-quoting pain. Usage: node send-eval.mjs <file.lua> [timeout_s]
// Also accepts a raw command JSON file: node send-eval.mjs --cmd <file.json>
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'fs';

const WH3 = 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Total War WARHAMMER III';
const CMD = WH3 + '\\wh3_mcp_command.json';
const RES = WH3 + '\\wh3_mcp_result.json';

let payload;
let timeoutS = 30;
if (process.argv[2] === '--cmd') {
  payload = readFileSync(process.argv[3], 'utf8');
  timeoutS = Number(process.argv[4] ?? 30);
} else {
  const code = readFileSync(process.argv[2], 'utf8');
  timeoutS = Number(process.argv[3] ?? 30);
  payload = JSON.stringify({ command: 'eval', params: { code } });
}

try { unlinkSync(RES); } catch {}
writeFileSync(CMD, payload, 'utf8');

const deadline = Date.now() + timeoutS * 1000;
while (Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 400));
  if (existsSync(RES)) {
    await new Promise((r) => setTimeout(r, 300)); // let the write settle
    const out = readFileSync(RES, 'utf8');
    try { unlinkSync(RES); } catch {}
    console.log(out);
    process.exit(0);
  }
}
console.log(JSON.stringify({ status: 'timeout', error: `no result within ${timeoutS}s` }));
process.exit(1);
