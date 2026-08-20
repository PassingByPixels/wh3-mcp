# WH3-MCP

Let an AI agent play and test Total War: WARHAMMER III. Built for mod
developers who want fast iteration: the agent boots the game, loads a save,
triggers your content, reads what appeared on screen (as text, no vision
needed), checks for script errors and reports back.

This repo is the tooling half. The game-side mod (`wh3_mcp_server.pack`)
ships on the Steam Workshop; its Lua source is in `pack/` here.

## How it works

The mod polls `wh3_mcp_command.json` in the WH3 install folder once per
second. Your agent writes a command into that file; the mod executes it (in
frontend, campaign and battle context) and writes `wh3_mcp_result.json`.
Two text files, no sockets, no injection. Any script can drive it. The MCP
server in this repo wraps the protocol in about 80 typed tools for AI models.

## Setup

Requirements: Windows, WH3 on Steam, Node.js 18+.

1. Subscribe to the mod on the Steam Workshop and enable it. Then set
   `user.script.txt` (in `%APPDATA%\The Creative Assembly\Warhammer3\scripts\`)
   to read-only so the launcher stops rewriting your mod list.
2. Install the server:
   ```
   git clone https://github.com/PassingByPixels/wh3-mcp
   cd wh3-mcp/server
   npm install
   ```
3. Register it with your MCP client.

   Claude Code:
   ```
   claude mcp add wh3 -- node C:\path\to\wh3-mcp\server\index.js
   ```
   Claude Desktop or any other MCP client, in its config JSON:
   ```json
   { "mcpServers": { "wh3": { "command": "node", "args": ["C:\\path\\to\\wh3-mcp\\server\\index.js"] } } }
   ```
4. Done. The server finds your WH3 install by itself (standard Steam paths,
   then the registry) and deploys the docs corpus for `cm_search` into the
   game folder on startup. First calls to try: `wh3_start` boots the game,
   `wh3_ping` confirms the mod is answering.

## Driving it without the MCP server

`tools/send-cmd.ps1` writes a command and waits for the result:

```powershell
.\tools\send-cmd.ps1 -Json '{"command":"ping","params":{}}'
.\tools\send-cmd.ps1 -Json '{"command":"load_campaign","params":{"filename":"my_test.save"}}'
.\tools\send-cmd.ps1 -Json '{"command":"get_situation","params":{}}'
```

`tools/send-eval.mjs` sends raw Lua from a file, so there is no shell
quoting pain:

```
node tools/send-eval.mjs my_snippet.lua
```

## What the agent can do

- Start, load and save campaigns from the main menu. Custom factions and
  Mixu lords work: `select_race` / `select_lord` take plain faction keys.
- Read the scene as text: `get_situation` returns context, turn, faction,
  gold and an ordered list of everything blocking play (dialogs, dilemmas
  with full text and choices, battle panels, occupation choices, declare
  war prompts).
- Trigger dilemmas and incidents by key, including targeted at the player's
  legendary lord. Read, answer, dismiss.
- Move armies, attack, autoresolve or retreat, occupy settlements.
- Fight real battles on the battle map: `fight_battle` clicks Attack,
  fights the whole battle at ten times speed, closes the results and
  returns to the campaign.
- Cheat for test setups: buildings, regions, research, levels, skills.
- Soak test: `soak_turns` plays N turns unattended and reports.
- `check_errors` reads the script error logs from disk. The mod hooks the
  game's `script_error`, so every scripted error is captured with a turn
  stamp. Works even after a crash.
- `cm_search` looks up any of 5,325 indexed campaign (cm) and battle (bm)
  functions from inside the game, and live-probes whether each one exists
  on your build.
- `eval` sends raw Lua straight into the running game.

The full tool list with parameters is in the MCP server's tool
descriptions (`server/index.js`).

## Building the pack from source

The Lua source is `pack/script/_lib/mod/wh3_mcp.lua`. `build.ps1` packs and
deploys it, but expects an RPFM MCP server on `127.0.0.1:45127`; packing the
single file manually with RPFM works just as well (path inside the pack:
`script/_lib/mod/wh3_mcp.lua`). Kill WH3 before deploying, or the pack file
is locked. `tools/check-lua.js` (needs `npm i luaparse`) gates the source:
Lua 5.1 parse plus a ban on plain-flag `string.find`, which corrupts the
game's string subsystem.

## Notes

- The game keeps running unfocused; the agent works in the background.
- No network, no telemetry. The mod reads and writes two JSON files in the
  game folder and nothing else.

## License

MIT
