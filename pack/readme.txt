WH3-MCP  -  MANUAL FOR AI AGENTS
=================================

You are (probably) an AI agent reading this out of a Total War: WARHAMMER III
mod pack. This mod lets you drive the game through two JSON files. This file
tells you everything you need: the protocol, the boot sequence, every command
with its parameters, and how to wrap it all in an MCP server if you want one.

Ready-made MCP server, helper scripts and the full API docs corpus:
https://github.com/PassingByPixels/wh3-mcp


1. THE PROTOCOL
---------------
The mod polls for a command file once per second, in every context the game
has (main menu, campaign, battle):

  WRITE:  <WH3 install dir>\wh3_mcp_command.json
          {"command": "<name>", "params": { ... }}
  READ:   <WH3 install dir>\wh3_mcp_result.json
          {"status": "ok", "result": { ... }}   or
          {"status": "error", "error": "<message>"}

The install dir is the folder containing Warhammer3.exe, usually
C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III

Rules:
- One command at a time. The mod deletes the command file when it has
  processed it, then writes the result file. Delete the result file before
  sending, then poll for it (300-500 ms interval is fine).
- If the command file is still there after your timeout, the mod is not
  polling (game loading, context transition, or not running).
- Some commands defer their result by several seconds (they run across poll
  ticks): load_campaign, start_campaign, autoresolve_battle, open_diplomacy,
  start_research, answer_move_options, dismiss_battle_results, quit_to_menu,
  exit_to_windows. Use generous timeouts (60-180 s) for those.


2. BOOTING THE GAME
-------------------
1. Mods load through user.script.txt in
   %APPDATA%\The Creative Assembly\Warhammer3\scripts\
   It must contain a "mod" line per pack. Set the file READ-ONLY so the
   launcher cannot rewrite it.
2. Start the exe directly, never through the launcher:
     Warhammer3.exe --feature disable_intro_videos
3. Send {"command":"ping"} on a long timeout (up to 240 s). When it answers
   {"pong":true}, the mod is live. ping also reports in_campaign and
   strings_ok (see section 10).
4. Rarely the legal splash screen hangs and ignores keys. A REAL mouse click
   on the game window advances it (synthetic UI clicks do not exist yet at
   that point).

The game keeps running unfocused. You can work in the background.


3. STARTING OR LOADING A CAMPAIGN
---------------------------------
From the main menu:
  load_campaign {filename}          loads a save by filename (fastest path;
                                    saves live in %APPDATA%\The Creative
                                    Assembly\Warhammer3\save_games\)
  continue_campaign {}              loads the newest save
  start_campaign {campaign_key, faction_key, party_key}   direct API start
Menu-driven start (works for custom factions and Mixu lords, since the
selectors take raw keys):
  select_campaign {campaign_type}   e.g. "ie" for Immortal Empires
  list_races {} / select_race {culture_key | index}
  list_lords {} / select_lord {faction_key | index}
  new_game {}
Save-screen flow (alternative to load_campaign):
  list_playthroughs {} / select_playthrough {index}
  list_saves {} / select_save {index | name} / confirm_load {}

After ANY context transition (menu -> campaign, campaign -> battle, battle ->
campaign, campaign -> menu) every script reloads and the poll loop restarts.
Expect a 20-40 s gap where commands go unanswered. Re-ping until the answer
matches the context you expect before sending real commands.


4. THE SITUATION LOOP
---------------------
get_situation is your screen. Call it after every action. It returns context
("main_menu" | "frontend" | "campaign" | "battle"), turn, faction, treasury,
is_players_turn, pending_battle, strings_ok, and "blocking": an ORDERED array
of what you must handle first. Blocking kinds and their handlers:

  kind              handle with
  ----              -----------
  dialog            confirm_dialog / cancel_dialog
  event (dilemma)   read_event, then answer_dilemma {choice}  (1-based)
  event (incident)  dismiss_event
  pre_battle        autoresolve_battle / retreat_battle / fight_battle
  post_battle       dismiss_battle_results {captives}
  occupation        occupy_choice {choice}  (option text like "occupy",
                    "sack", "raze", or a 1-based index; ONE click decides)
  move_options      answer_move_options {option}  ("Declare War?" style
                    interruptions; the interrupted move order is CONSUMED,
                    reissue it afterwards)
  panel             close_panel {}
  esc_menu          resume {}


5. COMMAND REFERENCE
--------------------
Parameters in braces; optional ones marked ?. All cqi values are the
command-queue-index integers that get_armies / get_characters return.

State reads:
  ping {}                            get_situation {}
  get_status {}                      get_faction_info {}
  get_treasury {}                    get_regions {}
  get_characters {}                  get_armies {}
  get_diplomacy {faction?}           get_screen {}
  get_hud {}                         get_camera {}
  get_saved_value {key}              set_saved_value {key, value}

Events:
  trigger_dilemma {dilemma_key, faction_key?, fire_immediately?}
  trigger_incident {incident_key, faction_key?, fire_immediately?}
  trigger_dilemma_with_targets {dilemma_key, faction_cqi?, character_cqi?,
      target_faction_cqi?, secondary_faction_cqi?, military_force_cqi?,
      region_cqi?, settlement_cqi?}   (for dilemmas aimed at a character,
      e.g. the player's legendary lord)
  read_event {}      answer_dilemma {choice}      dismiss_event {}
  Note: trigger success is data-dependent. issued=false usually means the
  key is gated or from an older game. The result tells you.

Armies:
  move_army {cqi, x, y, queued?}
  teleport_army {cqi, x?, y?, near_settlement?, snap?, distance?}
      (raw tiles are usually invalid; near_settlement uses the engine's
      spawn finder and always lands)
  attack {attacker_cqi, target_cqi | target_settlement, lay_siege?,
      replenish?}   (replenish refills action points first; long marches
      stall silently at 0 AP. target_settlement takes a region key.)
  select_army {cqi | name}           zoom_to {cqi | region, time?}

Battles (campaign side):
  autoresolve_battle {win?, captives?}   (win=true rigs the result;
      captives: "kill" | "enslave" | "release")
  retreat_battle {}
  fight_battle {auto?, speed?, max_ticks?}   (see section 6)
  dismiss_battle_results {captives?}

Diplomacy:
  open_diplomacy {faction?}
  force_diplomacy {action, faction_a?, faction_b?, invite_a_allies?,
      invite_b_allies?}   (action: "declare_war" | "make_peace" | ...)

Campaign control:
  end_turn {method?, force?}         save_game {filename, overwrite?}
  quick_save {}                      open_menu {} / resume {}
  confirm_dialog {} / cancel_dialog {}
  open_panel {panel} / close_panel {panel?}
  set_camera {x, y, d, b, h}         pan_camera {x, y, d, b, h, time?}
  quit_to_menu {}                    exit_to_windows {}

Test levers (instant cheats for setting up a test state):
  build_building {region, building}      transfer_region {region, faction?}
  start_research {tech_key}              level_character {cqi, levels?}
  grant_skill {cqi, skill_key}   (ALWAYS check has_skill_now in the result;
      the engine can silently refuse)
  apply_effect_bundle {bundle_key, faction_key?, turns?}
  cco_query {type, data?, expression}   (reads anything the UI can show,
      e.g. ("CcoCampaignRoot", "", "TurnNumber"))

Soak testing:
  soak_turns {turns, battle_policy?, rig_battles?, captives?,
      dilemma_choice?, occupation?, suppress_events?, max_seconds_per_turn?}
      Plays N turns unattended, auto-answering everything. Acks at once;
      poll soak_status {} every ~10 s until finished. soak_abort {} stops it.

Discovery and debug:
  cm_search {query, limit?, context?}    (see section 9)
  eval {code}                            (see section 9)
  list_ui {path?, max_depth?, visible_only?, return_tree?}
  click_ui {path}                        dump_children {path, child_index?}
  take_screenshot {filename?}            probe_cm {}


6. BATTLE MAP
-------------
The battle context reloads this same script: cm is nil there, bm
(battle_manager) is a global, the protocol is unchanged. Phases:
Deployment -> Deployed -> VictoryCountdown -> Complete.

Fire-and-forget (recommended): with the pre-battle panel open, send
  fight_battle {auto: true, speed: 10}
The mod clicks Attack, and in the battle drives everything: ends deployment,
attack-moves the whole army, ends the battle at victory, reads the outcome
("Pyrrhic Victory" etc.), dismisses the results. Poll get_situation until
context is "campaign" again (a fixture battle takes 2-3 minutes real time),
then send dismiss_battle_results.

Manual driving: fight_battle {auto: false}, wait for context "battle", then
  start_battle {}                  ends Deployment
  set_battle_speed {speed}         1 = normal, 10 = fast-forward
  get_battle_units {}              both armies, per unit: index, type, men
  battle_order {order?, unit_indices?, target_index?}
      order: "attack" (attack-move, default) | "attack_unit" | "halt"
  end_battle {}                    two steps: in VictoryCountdown it ends
      the battle; call again to click the results popup away. The battle
      NEVER leaves on its own; that second click is required.
  auto_fight {speed?, max_ticks?}  arm the auto-driver mid-battle


7. ERRORS AND LOGS
------------------
The mod hooks the game's script_error function. Every scripted error is
appended, turn-stamped, to <WH3 dir>\wh3_mcp_script_errors.log. Read that
file from disk after any test run; it works when the game is hung, crashed
or closed. Also useful on disk: wh3_mcp_debug.log (the mod's own log) and
script_log_*.txt (CA's log, only if CA file logging is enabled).


8. VALIDATING A MOD (the intended workflow)
-------------------------------------------
1. Boot, ping, load a test save of the mod's faction.
2. trigger_dilemma / trigger_dilemma_with_targets for each new event key.
3. read_event: check title, body text and choices are the ones the mod
   author wrote (loc errors show up here as raw keys).
4. answer_dilemma each choice path on separate runs if payloads differ.
5. Read wh3_mcp_script_errors.log; report anything new.
6. soak_turns for a wider regression pass.


9. RAW LUA AND API SEARCH
-------------------------
eval {code} runs raw Lua inside the mod's environment and returns the
values. Example: {"command":"eval","params":{"code":"return cm:turn_number()"}}
WARNING: never call string.find(s, needle, init, true) (the plain-text
flag) in evaluated code. On this game build it corrupts the Lua string
subsystem process-wide. Escape Lua patterns instead. If ping reports
strings_ok=false, restart the game.

cm_search {query} searches an index of 5,325 API functions (campaign cm,
battle bm, events, frontend, UI) with signatures and descriptions, and
live-probes the running game: exists_at_runtime tells you whether the
function is really on this build. The index file (wh3_mcp_docs.tsv) must be
in the game dir; the MCP server deploys it, or copy it from the GitHub repo
(server/data/). Without it you still get the live probes.

CTD warning: never call cm:win_next_autoresolve_battle via eval without a
pending battle; it crashes the game to desktop. autoresolve_battle {win:true}
guards this for you.


10. BUILDING YOUR OWN MCP SERVER
--------------------------------
Everything reduces to one function:

  send(command, params, timeout):
    delete <WH3>\wh3_mcp_result.json if present
    write  <WH3>\wh3_mcp_command.json  = {"command":..., "params":...}
    poll every 300-500 ms until the result file exists, read it, delete it,
    parse JSON, return it

Expose each command from section 5 as a tool that calls send(). Add:
  - a launch tool that starts Warhammer3.exe --feature disable_intro_videos
  - a wait tool that pings until the mod answers
  - a log tool that reads wh3_mcp_script_errors.log from disk
Or skip all of that and clone the finished server (Node 18+, one npm
dependency, auto-detects the install path, ~80 tools):
https://github.com/PassingByPixels/wh3-mcp
