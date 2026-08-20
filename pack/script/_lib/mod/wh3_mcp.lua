-- WH3 MCP Server Mod
-- Polls a command file, executes game commands, writes results.
-- Part of WH3-MCP (https://github.com/PassingByPixels/wh3-mcp)
--
-- Protocol:
--   Agent writes wh3_mcp_command.json -> WH3 reads it -> executes -> wh3_mcp_result.json -> deletes command file
--   The external MCP server (Node.js) handles file watching and MCP protocol translation.
--
-- This script must be at script/_lib/mod/wh3_mcp.lua in the pack.
-- It loads automatically at game startup (main menu AND campaigns).
-- Uses core:get_tm():repeat_real_callback() for polling (works everywhere).

local COMMAND_FILE = "wh3_mcp_command.json"
local RESULT_FILE = "wh3_mcp_result.json"
-- Docs corpus for cm_search. Lives in the game root (NOT the pack) so it can
-- be updated without an RPFM rebuild; the MCP server deploys it on startup.
local DOCS_FILE = "wh3_mcp_docs.tsv"
local POLL_INTERVAL = 1000  -- milliseconds between polls
local DEBUG_LOG = "wh3_mcp_debug.log"
local CAMPAIGN_START_MARKER = "wh3_mcp_starting_campaign.marker"
local QUIT_MARKER = "wh3_mcp_quitting.marker"

-- Campaign start state machine
local campaign_start_pending = false
local campaign_start_params = {}
local campaign_start_time = 0
local CAMPAIGN_START_TIMEOUT = 120.0  -- seconds to wait for campaign load
local continue_wait_start = 0          -- when we first detected in_campaign (for Continue button wait)
local CONTINUE_BUTTON_TIMEOUT = 60.0   -- seconds to wait for Continue button after campaign detected
local heartbeat_count = 0

-- Quit / exit state machine (campaign -> main menu, or campaign -> desktop)
local quit_pending = false   -- true while a quit_to_menu / exit_to_windows sequence runs
local quit_mode = nil        -- "menu" (to main menu) or "windows" (to desktop)
local quit_stage = nil       -- "click_quit" -> "await_dialog" -> "await_transition"
local quit_ticks = 0
local QUIT_MAX_TICKS = 60    -- poll ticks (~1s each) before the sequence gives up

-- Autoresolve state machine (pre-battle panel -> results panel -> dismissed).
-- The panels need frames to appear, so autoresolve_battle defers its response
-- to the poll loop the same way the quit sequence does.
local autoresolve_pending = false
local autoresolve_stage = nil       -- "await_results" -> "dismiss" -> "await_close"
local autoresolve_ticks = 0
local autoresolve_captives = "kill" -- kill | enslave | release
local autoresolve_rigged = false    -- was cm:win_next_autoresolve_battle applied
local autoresolve_title = nil       -- battle result text, captured before dismissal
local autoresolve_clicked = nil     -- which button ended the results panel

-- Diplomacy screen state machine (radial click -> panel -> faction row click).
local diplomacy_pending = false
local diplomacy_stage = nil  -- "await_panel"
local diplomacy_ticks = 0
local diplomacy_faction = nil

-- Soak loop (unattended multi-turn run). Unlike the other machines it does
-- NOT block command reads and NEVER writes the result file from a tick: the
-- soak_turns command acks immediately and progress is read via soak_status.
-- That keeps the one-result-file protocol unambiguous during a run that can
-- last an hour.
local soak_pending = false
local soak = nil               -- config + counters while a soak runs (kept after finish for soak_status)
-- When set, finish_autoresolve hands its result to this callback instead of
-- writing the result file (used by the soak loop to consume battle outcomes).
local autoresolve_on_done = nil

-- start_research state machine (open tech panel -> click node -> verify).
local research_pending = false
local research_state = nil

-- answer_move_options state machine (bar click -> optional diplomacy war
-- confirmation -> close diplomacy -> result).
local moveopts_pending = false
local moveopts_state = nil

-- Battle harness (Phase 9). The battle context reloads this same script:
-- cm is nil there, bm (battle_manager) is a global, and the poll loop runs
-- unchanged (verified live 2026-08-22). Phase callbacks are hooked lazily on
-- the first poll tick in battle; auto_fight drives a whole battle by phase
-- and ends with the context transition back to campaign.
local battle_hooked = false
local battle_phase_log = {}   -- phase names in arrival order (the starting Deployment is never announced)
local battle_speed = 1        -- last speed set through set_battle_speed / auto_fight
local autofight = nil         -- config + counters while auto_fight drives the battle
local BATTLE_AUTO_MARKER = "wh3_mcp_battle_auto.marker"

-- UI navigation state machine for campaign start
local ui_nav_state = 0       -- 0=idle, 1=clicked campaign, 2=clicked new, 3=clicked start
local ui_nav_start_time = 0

-- Forward declarations.
-- write_campaign_success (below) uses these before their definitions appear in
-- the file. Without predeclaring them as locals here, the compiler would resolve
-- those uses as GLOBAL lookups, which are nil at call time.
local json
local read_file, write_file, delete_file
local debug_log

-- Helper: write successful campaign start result
local function write_campaign_success()
    campaign_start_pending = false
    ui_nav_state = 0
    continue_wait_start = 0
    core:remove_listener("Wh3McpCampaignStarted")
    delete_file(CAMPAIGN_START_MARKER)
    local result = json.encode({
        status = "ok",
        result = {
            method = campaign_start_params.method or "poll_detected",
            campaign = campaign_start_params.campaign_key,
            faction = campaign_start_params.faction_key,
            already_in_campaign = true,
        }
    })
    write_file(RESULT_FILE, result)
    debug_log("Campaign load complete, result written")
end

-- ---------------------------------------------------------------------------
-- Debug logging (writes to wh3_mcp_debug.log in WH3 working directory)
-- ---------------------------------------------------------------------------

debug_log = function(msg)
    local ok, err = pcall(function()
        local file = io.open(DEBUG_LOG, "a")
        if file then
            file:write(os.date("%H:%M:%S") .. " [wh3-mcp] " .. msg .. "\n")
            file:close()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder/decoder for Lua 5.x
-- Supports: nil, boolean, number, string, table (no circular refs)
-- ---------------------------------------------------------------------------
json = {}

function json.encode(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(val)
    elseif t == "number" then return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        local is_array = true
        local max_n = 0
        for k, v in pairs(val) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_n then max_n = k end
        end
        if is_array then
            local parts = {}
            for i = 1, max_n do
                parts[i] = json.encode(val[i], indent .. "  ")
            end
            return "[" .. table.concat(parts, ", ") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                parts[#parts + 1] = json.encode(tostring(k), indent .. "  ") .. ": " .. json.encode(v, indent .. "  ")
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
    else
        return '"' .. tostring(val) .. '"'
    end
end

function json.decode(str)
    if not str or #str == 0 then return nil end
    local pos = 1
    local function skip_ws()
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else break end
        end
    end
    local function parse_val()
        skip_ws()
        if pos > #str then return nil end
        local c = str:sub(pos, pos)
        if c == '"' then
            pos = pos + 1
            local s = ""
            while pos <= #str do
                local cc = str:sub(pos, pos)
                pos = pos + 1
                if cc == '"' then return s end
                if cc == '\\' then
                    local nc = str:sub(pos, pos)
                    pos = pos + 1
                    if nc == '"' then s = s .. '"'
                    elseif nc == '\\' then s = s .. '\\'
                    elseif nc == 'n' then s = s .. '\n'
                    elseif nc == 'r' then s = s .. '\r'
                    elseif nc == 't' then s = s .. '\t'
                    else s = s .. nc end
                else
                    s = s .. cc
                end
            end
            return s
        elseif c == '{' then
            pos = pos + 1
            local t = {}
            skip_ws()
            if str:sub(pos, pos) == '}' then pos = pos + 1; return t end
            while true do
                skip_ws()
                local key = parse_val()
                skip_ws()
                if str:sub(pos, pos) ~= ':' then break end
                pos = pos + 1
                local val = parse_val()
                t[key] = val
                skip_ws()
                local nc = str:sub(pos, pos)
                if nc == ',' then pos = pos + 1
                elseif nc == '}' then pos = pos + 1; break
                else break end
            end
            return t
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            local idx = 1
            while true do
                arr[idx] = parse_val()
                idx = idx + 1
                skip_ws()
                local nc = str:sub(pos, pos)
                if nc == ',' then pos = pos + 1
                elseif nc == ']' then pos = pos + 1; break
                else break end
            end
            return arr
        elseif c == 't' and str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4; return true
        elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5; return false
        elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4; return nil
        else
            local ns = ""
            while pos <= #str do
                local nc = str:sub(pos, pos)
                if nc == '-' or nc == '+' or nc == '.' or nc == 'e' or nc == 'E' or (nc >= '0' and nc <= '9') then
                    ns = ns .. nc; pos = pos + 1
                else break end
            end
            if #ns == 0 then return nil end
            return tonumber(ns)
        end
    end
    local result = parse_val()
    return result
end

-- ---------------------------------------------------------------------------
-- File I/O helpers
-- ---------------------------------------------------------------------------

read_file = function(filename)
    local file, err = io.open(filename, "r")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    return content
end

write_file = function(filename, content)
    local file, err = io.open(filename, "w")
    if not file then return false, err end
    file:write(content)
    file:close()
    return true
end

delete_file = function(filename)
    local ok, err = os.remove(filename)
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Command dispatch
-- ---------------------------------------------------------------------------

local function in_campaign()
    return core and core:is_campaign()
end

-- bm is created by the game's own battle bootstrap before this script answers
-- commands; during the battle loading screen it can briefly be nil, in which
-- case the context reads as frontend until it appears.
local function in_battle()
    return (core and core:is_battle() and bm ~= nil) and true or false
end

local function get_local_faction()
    if not in_campaign() then return nil end
    if not cm then return nil end
    local ok, faction = pcall(function() return cm:get_local_faction() end)
    if ok and faction then return faction end
    return nil
end

-- ---------------------------------------------------------------------------
-- UI helpers
--
-- uic:Find("id") is a RECURSIVE first-match search, so it can return a hidden
-- component from a different branch (this is why find_uicomponent("dialogue_box")
-- returns the hidden hud_campaign > rush_confirmation_holder > dialogue_box).
-- find_all_child_matches walks DIRECT children by index instead, which is the
-- only way to disambiguate same-id components.
-- ---------------------------------------------------------------------------

-- Collect every direct child of parent whose Id() equals id.
local function find_all_child_matches(parent, id)
    local matches = {}
    if not parent then return matches end
    local ok, cc = pcall(function() return parent:ChildCount() end)
    if not ok or not cc then return matches end
    for i = 0, cc - 1 do
        local ok2, child = pcall(function() return UIComponent(parent:Find(i)) end)
        if ok2 and child then
            local ok3, cid = pcall(function() return child:Id() end)
            if ok3 and cid == id then
                matches[#matches + 1] = child
            end
        end
    end
    return matches
end

-- Wrapped child lookup (recursive, scoped to uic). Always returns a UIComponent
-- or nil — never a raw Find() handle.
local function get_child(uic, id)
    if not uic then return nil end
    local ok, child = pcall(function() return UIComponent(uic:Find(id)) end)
    if ok and child then return child end
    return nil
end

-- Read a component's displayed text, or nil.
local function get_text(uic)
    if not uic then return nil end
    local ok, txt = pcall(function() return uic:GetStateText() end)
    if ok and txt and txt ~= "" then return tostring(txt) end
    return nil
end

-- True only if the component is on screen. VisibleFromRoot() also tests the
-- ancestor chain; fall back to Visible() where it is unavailable.
local function uic_visible(uic)
    if not uic then return false end
    local ok, v = pcall(function() return uic:VisibleFromRoot() end)
    if ok and v ~= nil then return v and true or false end
    local ok2, v2 = pcall(function() return uic:Visible() end)
    if ok2 then return v2 and true or false end
    return false
end

local function safe_click(uic)
    if not uic then return false end
    local ok = pcall(function() uic:SimulateLClick() end)
    return ok
end

-- First VISIBLE root-level child with this id, or nil. Panel roots only exist
-- (or are only visible) while their panel is open, so this is the reliable
-- "is panel X open" test — and unlike find_uicomponent it cannot match a
-- same-named component nested somewhere else in the tree.
local function find_root_child(id)
    if not core then return nil end
    local ok, ui_root = pcall(function() return core:get_ui_root() end)
    if not ok or not ui_root then return nil end
    local matches = find_all_child_matches(ui_root, id)
    for i = 1, #matches do
        if uic_visible(matches[i]) then return matches[i] end
    end
    return nil
end

-- Find the confirmation dialog the player can actually see.
-- Returns uic, dy_text (both nil when no dialog is up).
local function get_visible_dialogue_box()
    if not core then return nil, nil end
    local ok_root, ui_root = pcall(function() return core:get_ui_root() end)
    if not ok_root or not ui_root then return nil, nil end
    local boxes = find_all_child_matches(ui_root, "dialogue_box")
    local fallback, fallback_text = nil, nil
    for i = 1, #boxes do
        local box = boxes[i]
        if uic_visible(box) then
            local dy = get_child(box, "DY_text")
            if dy then
                return box, get_text(dy)
            elseif not fallback then
                fallback = box
            end
        end
    end
    return fallback, fallback_text
end

-- Click a dialog's confirm (button_tick) or cancel (button_cancel) button.
-- both_group is the "are you sure" variant, ok_group the acknowledge-only one.
local function click_dialog_button(box, which)
    if not box then return nil end
    local id = (which == "cancel") and "button_cancel" or "button_tick"
    local candidates = {}
    local both = get_child(box, "both_group")
    if both then
        candidates[#candidates + 1] = { uic = get_child(both, id), path = "both_group > " .. id }
    end
    if which ~= "cancel" then
        local okg = get_child(box, "ok_group")
        if okg then
            candidates[#candidates + 1] = { uic = get_child(okg, id), path = "ok_group > " .. id }
        end
    end
    -- Last resort: a DIRECT child of the dialog itself. Direct-children-only
    -- matters here: the hidden purchase_options group holds its own
    -- button_cancel, and a recursive search would find that one.
    local direct = find_all_child_matches(box, id)
    if #direct > 0 then
        candidates[#candidates + 1] = { uic = direct[1], path = id }
    end
    -- Prefer a button that is actually on screen. Only one button group is
    -- shown per dialog; the others stay in the layout but hidden, and clicking
    -- a hidden one does nothing while still looking like success.
    for pass = 1, 2 do
        for i = 1, #candidates do
            local c = candidates[i]
            if c.uic and (pass == 2 or uic_visible(c.uic)) then
                if safe_click(c.uic) then
                    return c.path .. ((pass == 2) and " (hidden)" or "")
                end
            end
        end
    end
    return nil
end

-- Build an indented tree listing (same format as the list_ui debug dump).
-- Returns an array of lines.
local function collect_tree(uic, max_depth, visible_only)
    local lines = {}
    local function walk(u, depth)
        if depth > max_depth then return end
        local visible = false
        local ok, v = pcall(function() return u:Visible() end)
        if ok then visible = v and true or false end
        if visible_only and not visible then return end
        local name = ""
        local ok2, n = pcall(function() return u:Id() end)
        if ok2 and n then name = n end
        if name ~= "" then
            local text = ""
            local txt = get_text(u)
            if txt then text = ' "' .. txt .. '"' end
            lines[#lines + 1] = string.rep("  ", depth) .. name .. (visible and "" or " (hidden)") .. text
        end
        local cc = 0
        local ok3, c = pcall(function() return u:ChildCount() end)
        if ok3 and c then cc = c end
        for i = 0, cc - 1 do
            local ok4, child = pcall(function() return UIComponent(u:Find(i)) end)
            if ok4 and child then walk(child, depth + 1) end
        end
    end
    if uic then walk(uic, 0) end
    return lines
end

-- ---------------------------------------------------------------------------
-- Campaign helpers
-- ---------------------------------------------------------------------------

-- cm:get_camera_position() returns five separate numbers: x, y, d, b, h.
local function read_camera()
    if not cm then return nil end
    local ok, x, y, d, b, h = pcall(function() return cm:get_camera_position() end)
    if ok and type(x) == "number" then
        return { x = x, y = y, d = d, b = b, h = h }
    end
    return nil
end

-- Name of the currently open panel ("technology_panel" etc.), or nil.
local function get_open_panel()
    if not cm then return nil end
    local ok, name = pcall(function()
        local uim = cm:get_campaign_ui_manager()
        if uim then return uim:get_open_panel() end
        return nil
    end)
    if ok and name and name ~= "" then return name end
    return nil
end

local function is_panel_open(name)
    if not cm or not name then return nil end
    local ok, open = pcall(function()
        local uim = cm:get_campaign_ui_manager()
        if uim then return uim:is_panel_open(name) end
        return nil
    end)
    if ok and open ~= nil then return open and true or false end
    return nil
end

-- get_forename() returns a localisation key on many characters; resolve it when
-- we can, otherwise hand back the raw value.
local function char_display_name(char)
    if not char then return nil end
    local ok, fn = pcall(function() return char:get_forename() end)
    if not ok or not fn or fn == "" then return nil end
    local ok2, loc = pcall(function() return common.get_localised_string(fn) end)
    if ok2 and loc and loc ~= "" then return tostring(loc) end
    return tostring(fn)
end

-- Nil-safe single-value pcall.
local function sf(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

-- NEVER call string.find with the plain flag (find(s, needle, init, true)) in
-- this mod. The game's patched string.find has a broken plain branch: it never
-- matches AND it corrupts the Lua string subsystem process-wide (reproduced on
-- demand 2026-08-21; this was the cause of every past "spontaneous" corruption
-- that forced a game restart). Use plain_find below instead: it escapes the
-- needle and uses a pattern find, which is healthy.
local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function plain_find(s, needle, init)
    return s:find(escape_pattern(needle), init or 1)
end

-- Error capture: wrap the global script_error so every scripted error also
-- lands in our own file in the game root, independent of whether CA's
-- log-to-file debug config is on. Libraries that captured script_error as a
-- local at lib-load time bypass the wrap; everything that resolves the global
-- at call time (most CA code and all mods) is caught. The MCP server reads
-- the file directly from disk (wh3_check_errors) - no game round-trip.
-- CA gives every script a layered environment: script_error is NOT in _G
-- (rawget(_G, "script_error") is nil; verified live 2026-08-21). The table
-- that owns it is the function's own environment - getfenv(script_error) -
-- which sits on the resolution chain of every script, so replacing it THERE
-- is what all later callers see.
local ERRORS_FILE = "wh3_mcp_script_errors.log"
do
    local ok_hook = pcall(function()
        if type(script_error) ~= "function" or not getfenv then return end
        local owner = getfenv(script_error)
        local orig = owner and rawget(owner, "script_error") or nil
        if type(orig) ~= "function" then return end
        rawset(owner, "script_error", function(msg, stack_level_modifier, suppress_assert)
            pcall(function()
                local f = io.open(ERRORS_FILE, "a")
                if f then
                    local stamp = string.format("%.1f", os.clock())
                    local turn = ""
                    if cm then
                        local ok_t, t = pcall(function() return cm:turn_number() end)
                        if ok_t then turn = " turn=" .. tostring(t) end
                    end
                    f:write("[" .. stamp .. turn .. "] " .. tostring(msg) .. "\n")
                    f:close()
                end
            end)
            return orig(msg, stack_level_modifier, suppress_assert)
        end)
    end)
    if not ok_hook then
        -- Never let error capture break the mod itself.
    end
end

-- Panel routes, all verified live (2026-08-18, Greenskins IE campaign):
--   open  = the HUD button that opens the panel
--   root  = the root-level component that exists while the panel is open
--   close = the panel's own close button
-- api_name is the string CampaignUI.ClosePanel accepts. Only technology_panel
-- is confirmed; for the others the open panel's name is read at runtime from
-- campaign_ui_manager:get_open_panel().
local PANELS = {
    technology = {
        open = { "hud_campaign", "faction_buttons_docker", "button_group_management", "button_technology" },
        root = "technology_panel",
        close = { "technology_panel", "button_ok_holder", "button_ok" },
        api_name = "technology_panel",
    },
    diplomacy = {
        open = { "hud_campaign", "faction_buttons_docker", "button_group_management", "button_diplomacy" },
        root = "diplomacy_dropdown",
        close = { "diplomacy_dropdown", "faction_panel", "faction_panel_bottom", "button_cancel" },
    },
    missions = {
        open = { "hud_campaign", "faction_buttons_docker", "button_group_management", "button_missions" },
        root = "objectives_screen",
        -- No close button on this panel: the radial button toggles it.
        close = { "hud_campaign", "faction_buttons_docker", "button_group_management", "button_missions" },
        close_is_toggle = true,
    },
    factions = {
        open = { "hud_campaign", "bar_small_top", "button_factions" },
        root = "clan",
        close = { "clan", "button_ok_holder", "button_ok" },
    },
}

-- Panel key whose root component is currently on screen, or nil.
local function detect_open_panel_key()
    for key, def in pairs(PANELS) do
        if find_root_child(def.root) then return key end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Situational awareness: string health, events, battles, diplomacy
--
-- Everything below feeds get_situation, the vision-free replacement for a
-- screenshot. Paths marked VERIFIED were executed live on 2026-08-20 (see
-- docs/RECON_2026-08-20.md).
-- ---------------------------------------------------------------------------

-- The in-game Lua string subsystem broke repeatedly mid-session (string.sub
-- and string.find returning garbage), which silently kills the JSON decode.
-- ROOT CAUSE (found 2026-08-21): any call to string.find with the plain flag
-- corrupts the subsystem process-wide - see plain_find above. This mod no
-- longer makes such calls; the check stays as a tripwire for other triggers.
-- False here means the game must be restarted; nothing else recovers it.
local function strings_ok()
    local ok, healthy = pcall(function()
        local sub_ok = ("abc"):sub(2, 2) == "b"
        local find_ok = ("xy"):find("y") == 2
        return sub_ok and find_ok
    end)
    return (ok and healthy) and true or false
end

-- Panel root by id. Prefers the VISIBLE root-level child (find_root_child
-- cannot match a same-named component nested elsewhere), and falls back to a
-- recursive search for panels that mount below the UI root.
local function find_panel_root(id)
    local uic = find_root_child(id)
    if uic then return uic end
    local found = sf(function() return find_uicomponent(id) end)
    if found and uic_visible(found) then return found end
    return nil
end

-- campaign_ui_manager:is_event_panel_open(), or nil when unavailable.
local function is_event_panel_open()
    if not cm then return nil end
    local ok, open = pcall(function()
        local uim = cm:get_campaign_ui_manager()
        if uim then return uim:is_event_panel_open() end
        return nil
    end)
    if ok and open ~= nil then return open and true or false end
    return nil
end

-- Every non-empty display string on a VISIBLE component in a subtree,
-- depth-capped. Hidden template rows carry placeholder text ("dy_text",
-- "dy_effect_bundle", bare numbers) that would drown the real strings.
local function collect_texts(uic, max_depth, out)
    out = out or {}
    if not uic or max_depth < 0 then return out end
    local ok_v, vis = pcall(function() return uic:Visible() end)
    if ok_v and not vis then return out end
    local txt = get_text(uic)
    if txt then out[#out + 1] = txt end
    local cc = sf(function() return uic:ChildCount() end) or 0
    for i = 0, cc - 1 do
        local ok, child = pcall(function() return UIComponent(uic:Find(i)) end)
        if ok and child then collect_texts(child, max_depth - 1, out) end
    end
    return out
end

-- First VISIBLE component with one of these ids under uic. Direct enumeration,
-- not uic:Find(id): panels keep hidden copies of these buttons, and clicking a
-- hidden one does nothing while still looking like success.
local function find_visible_descendant(uic, ids, max_depth)
    if not uic or max_depth < 0 then return nil, nil end
    local cc = sf(function() return uic:ChildCount() end) or 0
    for i = 0, cc - 1 do
        local ok, child = pcall(function() return UIComponent(uic:Find(i)) end)
        if ok and child then
            local id = sf(function() return child:Id() end)
            if type(id) == "string" then
                for j = 1, #ids do
                    if id == ids[j] and uic_visible(child) then return child, id end
                end
            end
        end
    end
    for i = 0, cc - 1 do
        local ok, child = pcall(function() return UIComponent(uic:Find(i)) end)
        if ok and child then
            local found, found_id = find_visible_descendant(child, ids, max_depth - 1)
            if found then return found, found_id end
        end
    end
    return nil, nil
end

-- 1-based choice index -> the ordinal suffix CA appends to a dilemma choice
-- entry id (CcoCdirEventsDilemmaChoiceDetailRecord<key><ORDINAL>). VERIFIED.
local DILEMMA_ORDINALS = { "FIRST", "SECOND", "THIRD", "FOURTH" }

-- The dilemma_list entry for a 1-based choice index, matched on the id SUFFIX
-- so the dilemma key itself never has to be hardcoded. Returns uic, id.
local function find_dilemma_choice(dilemma_list, index)
    local suffix = DILEMMA_ORDINALS[index]
    if not dilemma_list or not suffix then return nil, nil end
    local cc = sf(function() return dilemma_list:ChildCount() end) or 0
    for i = 0, cc - 1 do
        local ok, child = pcall(function() return UIComponent(dilemma_list:Find(i)) end)
        if ok and child then
            local id = sf(function() return child:Id() end)
            if type(id) == "string" and #id >= #suffix and id:sub(-#suffix) == suffix then
                return child, id
            end
        end
    end
    return nil, nil
end

-- The dilemma panel under an open events root, or nil. Returns the inner
-- "dilemma" component (VERIFIED path events > event_layouts > dilemma_active >
-- dilemma), falling back to dilemma_active itself.
local function get_open_dilemma(events)
    if not events then return nil end
    local layouts = get_child(events, "event_layouts")
    local active = layouts and get_child(layouts, "dilemma_active") or nil
    if not active or not uic_visible(active) then return nil end
    return get_child(active, "dilemma") or active
end

-- The {kind="event", ...} detail for an open incident/dilemma panel, or nil.
local function read_event_detail()
    local events = find_panel_root("events")
    if not events then
        if is_event_panel_open() then
            return {
                kind = "event",
                event_type = "other",
                note = "campaign_ui_manager reports an event panel but the events root is not on screen",
            }
        end
        return nil
    end
    local detail = { kind = "event", event_type = "other", panel = "events" }
    local dilemma = get_open_dilemma(events)
    if dilemma then
        detail.event_type = "dilemma"
        local title_holder = get_child(dilemma, "title_holder")
        local panel_title = title_holder and get_child(title_holder, "panel_title")
                            or get_child(dilemma, "panel_title")
        detail.title = get_text(panel_title and get_child(panel_title, "button_txt") or nil)
        local details_holder = get_child(dilemma, "details_holder")
        local details_text = details_holder and get_child(details_holder, "dy_details_text")
                             or get_child(dilemma, "dy_details_text")
        detail.text = get_text(details_text and get_child(details_text, "dy_description") or nil)
                      or get_text(details_text)
        local list = get_child(dilemma, "dilemma_list")
        local choices = {}
        for i = 1, #DILEMMA_ORDINALS do
            local entry, entry_id = find_dilemma_choice(list, i)
            if entry then
                local button = get_child(entry, "choice_button")
                choices[#choices + 1] = {
                    index = i,
                    id = entry_id,
                    text = get_text(button and get_child(button, "button_txt") or nil),
                    payloads = collect_texts(get_child(entry, "payload_list"), 4),
                }
            end
        end
        detail.choices = choices
        detail.choice_count = #choices
    else
        local layouts = get_child(events, "event_layouts")
        local incident = layouts and get_child(layouts, "incident") or nil
        if incident and uic_visible(incident) then
            detail.event_type = "incident"
            local list = get_child(incident, "list") or incident
            detail.title = get_text(get_child(list, "dy_title"))
            local background = get_child(list, "description_background")
            detail.text = get_text(background and get_child(background, "dy_details_text")
                                   or get_child(list, "dy_details_text"))
        end
    end
    -- Incidents are dismissed with the shared accept button; dilemmas keep it
    -- hidden and must be answered instead.
    local button_set = get_child(events, "button_set")
    local holder = button_set and get_child(button_set, "accept_holder") or nil
    local accept = holder and get_child(holder, "button_accept") or nil
    detail.dismissable = (detail.event_type == "incident") or uic_visible(accept)
    return detail
end

-- Pre-battle panel: the button set for the battle type on screen.
-- Returns uic, is_siege. Field battles use button_set_attack, sieges the
-- sibling button_set_siege. Both VERIFIED.
local function get_pre_battle_set(root)
    if not root then return nil, false end
    local attack = get_child(root, "button_set_attack")
    if attack and uic_visible(attack) then return attack, false end
    local siege = get_child(root, "button_set_siege")
    if siege and uic_visible(siege) then return siege, true end
    if attack then return attack, false end
    if siege then return siege, true end
    return nil, false
end

local PRE_BATTLE_BUTTONS = {
    attack = { "button_attack_container", "button_attack" },
    autoresolve = { "button_autoresolve" },
    retreat = { "button_retreat" },
}

-- A named button inside a pre-battle button set. Prefers a visible instance.
local function get_pre_battle_button(set, which)
    local ids = PRE_BATTLE_BUTTONS[which]
    if not set or not ids then return nil end
    for i = 1, #ids do
        local uic = get_child(set, ids[i])
        if uic and uic_visible(uic) then return uic end
    end
    for i = 1, #ids do
        local uic = get_child(set, ids[i])
        if uic then return uic end
    end
    return nil
end

-- The move_options interruption ("Declare War?" / "Cancel Move" and kin) that
-- a movement or attack order can raise. Structure (verified live 2026-08-21):
-- move_options > header > panel_title > title_frame (title text)
--              > text_frame > text_box (body text)
--              > panel > options_barN > button_txt (one bar per option;
--                hidden bars are unavailable options). Clicking a BAR picks
-- that option; the Declare War option then routes through the diplomacy
-- screen's war_declared subpanel (both_buttongroup > button_ok_declare /
-- button_cancel_declare) before the move resumes.
local function get_move_options_root()
    local mo = find_root_child and find_root_child("move_options") or find_uicomponent("move_options")
    if mo and uic_visible(mo) then return mo end
    return nil
end

local function read_move_options()
    local mo = get_move_options_root()
    if not mo then return nil end
    local header = get_child(mo, "header")
    local title = get_text(get_child(get_child(header, "panel_title"), "title_frame"))
    local text = get_text(get_child(get_child(mo, "text_frame"), "text_box"))
    local options = {}
    local panel = get_child(mo, "panel")
    if panel then
        for i = 1, 6 do
            local bar = get_child(panel, "options_bar" .. i)
            if bar and uic_visible(bar) then
                options[#options + 1] = {
                    index = i,
                    text = get_text(get_child(bar, "button_txt")),
                }
            end
        end
    end
    return {
        kind = "move_options",
        title = title,
        text = text,
        options = options,
        note = "answer with answer_move_options {option}; the last option is usually Cancel Move",
    }
end

-- The settlement_captured occupation-choice panel that appears AFTER the
-- post-battle results are dismissed when a settlement was taken (verified
-- live 2026-08-21, Gorger Rock). Structure:
-- settlement_captured > header_docker > panel_subtitle > settlement_name
--                     > button_parent > <numeric option record id> >
--                         option_button (the clickable; ONE click decides)
--                         + frame > icon_parent > dy_* effect values
--                         + option label in option_button sibling dy_option
-- The numeric ids are occupation-option db records and VARY by faction and
-- settlement - always match options by their dy_option TEXT.
local function read_settlement_captured()
    local root = find_root_child("settlement_captured")
    if not root or not uic_visible(root) then return nil end
    local header = get_child(root, "header_docker")
    local settlement = header and get_text(get_child(get_child(header, "panel_subtitle"), "settlement_name")) or nil
    local options = {}
    local parent = get_child(root, "button_parent")
    if parent then
        local cc = sf(function() return parent:ChildCount() end) or 0
        for i = 0, cc - 1 do
            local ok, opt = pcall(function() return UIComponent(parent:Find(i)) end)
            if ok and opt and uic_visible(opt) then
                local id = sf(function() return opt:Id() end)
                local btn = get_child(opt, "option_button")
                local label = btn and get_text(get_child(btn, "dy_option")) or nil
                if btn then
                    options[#options + 1] = { id = tostring(id), text = label }
                end
            end
        end
    end
    return {
        kind = "occupation",
        settlement = settlement,
        options = options,
        note = "choose with occupy_choice {choice: <option text or index>}; one click decides",
    }
end

local function read_pre_battle()
    local root = find_panel_root("popup_pre_battle")
    if not root then return nil end
    local set, is_siege = get_pre_battle_set(root)
    local regular = get_child(root, "regular_deployment")
    local list = regular and get_child(regular, "list") or nil
    local outcome = list and get_child(list, "autoresolve_outcome")
                    or (regular and get_child(regular, "autoresolve_outcome") or nil)
    return {
        kind = "pre_battle",
        siege = is_siege,
        button_set = set and sf(function() return set:Id() end) or nil,
        autoresolve_outcome = get_text(outcome),
        actions = {
            attack = uic_visible(get_pre_battle_button(set, "attack")),
            autoresolve = uic_visible(get_pre_battle_button(set, "autoresolve")),
            retreat = uic_visible(get_pre_battle_button(set, "retreat")),
        },
    }
end

-- Post-battle victory blocks on a captive choice. VERIFIED: button_accept and
-- button_dismiss exist in the same panel but stay hidden until applicable.
local CAPTIVE_OPTIONS = {
    kill = "button_captive_option_kill",
    enslave = "button_captive_option_enslave",
    release = "button_captive_option_release",
}

local function get_post_battle_panel(root)
    if not root then return nil end
    return get_child(root, "post_battle_results_panel") or root
end

local function get_post_battle_result_text(panel)
    if not panel then return nil end
    local header = get_child(panel, "header")
    local plaque = header and get_child(header, "title_plaque") or nil
    local tx = plaque and get_child(plaque, "tx_battle_results")
               or get_child(panel, "tx_battle_results")
    return get_text(tx)
end

local function read_post_battle()
    local root = find_panel_root("popup_battle_results")
    if not root then return nil end
    local panel = get_post_battle_panel(root)
    local detail = {
        kind = "post_battle",
        result = get_post_battle_result_text(panel),
        captive_options = {},
    }
    local win_set = get_child(panel, "button_set_win")
    if win_set and uic_visible(win_set) then
        detail.stage = "captive_choice"
        local cc = sf(function() return win_set:ChildCount() end) or 0
        for i = 0, cc - 1 do
            local ok, child = pcall(function() return UIComponent(win_set:Find(i)) end)
            if ok and child then
                local id = sf(function() return child:Id() end)
                if type(id) == "string" and id:find("button_captive_option_") == 1
                   and uic_visible(child) then
                    detail.captive_options[#detail.captive_options + 1] = id
                end
            end
        end
    else
        detail.stage = "dismiss"
    end
    return detail
end

-- The diplomacy faction row for a faction key. Row ids are
-- faction_row_entry_<faction_key> and only KNOWN factions appear. VERIFIED.
local function find_faction_row(faction_key)
    if not faction_key then return nil, nil end
    local root = find_panel_root("diplomacy_dropdown")
    if not root then return nil, nil end
    local sortable = get_child(root, "sortable_list_factions")
    local box = sortable and get_child(sortable, "list_box") or get_child(root, "list_box")
    if not box then return nil, nil end
    local exact = "faction_row_entry_" .. faction_key
    local cc = sf(function() return box:ChildCount() end) or 0
    -- Two passes: an exact id anywhere in the list beats a loose suffix match
    -- earlier in it (faction keys are suffixes of one another, e.g.
    -- grn_greenskins inside wh_main_grn_greenskins).
    for pass = 1, 2 do
        for i = 0, cc - 1 do
            local ok, child = pcall(function() return UIComponent(box:Find(i)) end)
            if ok and child then
                local id = sf(function() return child:Id() end)
                if type(id) == "string" then
                    if pass == 1 and id == exact then
                        return child, id
                    elseif pass == 2 and #id >= #faction_key
                           and id:sub(-#faction_key) == faction_key then
                        return child, id
                    end
                end
            end
        end
    end
    return nil, nil
end

-- faction:at_war_with takes a faction OBJECT, not a key string.
local function read_at_war(a_key, b_key)
    local ok, at_war = pcall(function()
        local a = cm:get_faction(a_key)
        local b = cm:get_faction(b_key)
        if not a or not b then return nil end
        return a:at_war_with(b)
    end)
    if ok and at_war ~= nil then return at_war and true or false end
    return nil
end

-- Faction keys from a niladic FACTION_LIST accessor, or nil when the accessor
-- is unavailable on this build.
local function collect_faction_keys(getter)
    local ok, keys = pcall(function()
        local list = getter()
        if not list then return nil end
        local out = {}
        for i = 0, list:num_items() - 1 do
            local faction = list:item_at(i)
            if faction then
                local name = faction:name()
                if name then out[#out + 1] = tostring(name) end
            end
        end
        return out
    end)
    if ok and keys then return keys end
    return nil
end

-- One structured read of everything an agent would otherwise need a screenshot
-- for. blocking is ordered by what must be handled FIRST.
-- ---------------------------------------------------------------------------
-- Battle harness helpers (Phase 9). Everything here assumes in_battle(). bm
-- method calls are pcall-wrapped: battle_manager forwards unknown names to
-- the battle interface via an __index FUNCTION that RAISES on missing
-- members (verified live: bm["player_victory"] errors instead of nil).
-- ---------------------------------------------------------------------------

local function battle_player_army()
    return sf(function() return bm:get_player_army() end)
end

local function battle_enemy_army()
    return sf(function() return bm:get_non_player_alliance():armies():item(1) end)
end

local function battle_phase()
    return sf(function() return bm:get_current_phase_name() end)
end

-- Per-unit list + total men for one army. All collections are 1-based.
local function battle_army_units(army)
    if not army then return nil, 0 end
    local list, total = {}, 0
    local ok = pcall(function()
        local units = army:units()
        for i = 1, units:count() do
            local u = units:item(i)
            local men = u:number_of_men_alive()
            total = total + men
            list[#list + 1] = {
                index = i,
                type = tostring(u:type()),
                men = men,
            }
        end
    end)
    if not ok then return nil, 0 end
    return list, total
end

-- The in-battle results popup that follows bm:end_battle() (phase Complete).
-- in_battle_results_popup > background > non_spectator_parent > title_plaque
-- > DY_text carries the outcome text ("Pyrrhic Victory"); button_background >
-- button_parent > button_dismiss_results ("End Battle") starts the campaign
-- reload (verified live 2026-08-22). The battle does NOT leave on its own
-- after end_battle - this click is required.
local function battle_results_popup()
    local p = find_uicomponent("in_battle_results_popup")
    if p and uic_visible(p) then return p end
    return nil
end

local function read_battle_results()
    local p = battle_results_popup()
    if not p then return nil end
    local bg = get_child(p, "background")
    local nsp = bg and get_child(bg, "non_spectator_parent") or nil
    local plaque = nsp and get_child(nsp, "title_plaque") or nil
    local outcome = plaque and get_text(get_child(plaque, "DY_text")) or nil
    return { outcome = outcome }
end

-- The battle branch of get_situation. Replaces the campaign structure
-- entirely: phase (Deployment / Deployed / VictoryCountdown / Complete),
-- phase history, speed, and both sides' strength.
local function read_battle_situation()
    local phase = battle_phase()
    local p_list, p_men = battle_army_units(battle_player_army())
    local e_list, e_men = battle_army_units(battle_enemy_army())
    local s = {
        context = "battle",
        strings_ok = strings_ok(),
        phase = phase,
        phase_log = battle_phase_log,
        speed = battle_speed,
        player = { units = p_list and #p_list or 0, men = p_men },
        enemy = { units = e_list and #e_list or 0, men = e_men },
        blocking = {},
        note = "battle commands: start_battle, set_battle_speed, battle_order, " ..
               "get_battle_units, end_battle (VictoryCountdown only), auto_fight",
    }
    if autofight then s.auto_fight = autofight.stage end
    local results = read_battle_results()
    if results then
        s.blocking[#s.blocking + 1] = {
            kind = "battle_results",
            outcome = results.outcome,
            note = "end_battle clicks End Battle on the results popup and returns to campaign",
        }
    elseif phase == "Deployment" then
        s.blocking[#s.blocking + 1] = {
            kind = "deployment",
            note = "the battle waits for start_battle (or auto_fight)",
        }
    elseif phase == "VictoryCountdown" then
        s.blocking[#s.blocking + 1] = {
            kind = "victory_countdown",
            note = "someone won; end_battle moves to the results popup",
        }
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Battle dispatch (Phase 9). Its own closure so its upvalues never count
-- against execute_command or execute_command_2 (Lua 5.1 caps every closure at
-- 60 upvalues and execute_command already hit the cap once - rule: new
-- commands NEVER go into execute_command).
-- ---------------------------------------------------------------------------
local function execute_command_battle(cmd, params)
    if cmd == "fight_battle" then
        -- CAMPAIGN side: click Attack on the pre-battle panel. The battle
        -- context then loads (script reload, poll gap). auto=true leaves a
        -- marker the battle-side hook reads to drive the whole battle.
        if not in_campaign() then
            return { status = "error", error = "not in a campaign (in battle, use start_battle / auto_fight)" }
        end
        local root = find_panel_root("popup_pre_battle")
        if not root then
            return { status = "error", error = "popup_pre_battle is not open - order an attack first" }
        end
        local set, is_siege = get_pre_battle_set(root)
        -- The attack entry is a CONTAINER (button_attack_container, a direct
        -- child of the set) with the real button_attack inside. Clicking the
        -- container is a silent no-op (hit live 2026-08-22) - descend to the
        -- inner button with a recursive find.
        local btn = set and find_uicomponent(set, "button_attack") or nil
        if not btn then
            return { status = "error", error = "button_attack not found in the pre-battle button set" }
        end
        if params.auto then
            write_file(BATTLE_AUTO_MARKER, json.encode({
                speed = tonumber(params.speed) or 10,
                max_ticks = tonumber(params.max_ticks) or 900,
            }))
        end
        if not safe_click(btn) then
            delete_file(BATTLE_AUTO_MARKER)
            return { status = "error", error = "clicking button_attack failed" }
        end
        debug_log("fight_battle: clicked button_attack (auto=" .. tostring(params.auto and true or false) .. ")")
        return { status = "ok", result = {
            clicked = true,
            siege = is_siege,
            auto = params.auto and true or false,
            note = "battle context is loading (script reload, expect a poll gap); " ..
                   "poll get_situation until context == battle" ..
                   (params.auto and " - auto_fight then drives the battle back to campaign" or ""),
        } }

    elseif cmd == "start_battle" then
        if not in_battle() then return { status = "error", error = "not in a battle" } end
        local phase = battle_phase()
        if phase ~= "Deployment" then
            return { status = "error", error = "start_battle only applies in Deployment phase (current: " .. tostring(phase) .. ")" }
        end
        local ok, err = pcall(function() bm:end_current_battle_phase() end)
        if not ok then
            return { status = "error", error = "end_current_battle_phase failed: " .. tostring(err) }
        end
        debug_log("start_battle: deployment ended")
        return { status = "ok", result = { started = true, note = "phase moves to Deployed within a tick" } }

    elseif cmd == "set_battle_speed" then
        if not in_battle() then return { status = "error", error = "not in a battle" } end
        local speed = tonumber(params.speed)
        if not speed or speed <= 0 then
            return { status = "error", error = "speed must be a positive number (1 = normal, 10 = fast-forward)" }
        end
        local ok, err = pcall(function() bm:modify_battle_speed(speed, true) end)
        if not ok then
            return { status = "error", error = "modify_battle_speed failed: " .. tostring(err) }
        end
        battle_speed = speed
        return { status = "ok", result = { speed = speed } }

    elseif cmd == "get_battle_units" then
        if not in_battle() then return { status = "error", error = "not in a battle" } end
        local p_list, p_men = battle_army_units(battle_player_army())
        local e_list, e_men = battle_army_units(battle_enemy_army())
        return { status = "ok", result = {
            phase = battle_phase(),
            player = { men = p_men, units = p_list },
            enemy = { men = e_men, units = e_list },
        } }

    elseif cmd == "battle_order" then
        -- v1 orders through one throwaway unitcontroller. order = "attack"
        -- (attack-move onto the first enemy unit still alive, or onto
        -- target_index), "attack_unit" (direct attack on target_index), or
        -- "halt". unit_indices narrows to a subset of the player army.
        if not in_battle() then return { status = "error", error = "not in a battle" } end
        local phase = battle_phase()
        if phase ~= "Deployed" then
            return { status = "error", error = "orders only apply in Deployed phase (current: " .. tostring(phase) .. "); start_battle first" }
        end
        local order = tostring(params.order or "attack")
        local ok, detail = pcall(function()
            local army = bm:get_player_army()
            local uc = army:create_unit_controller()
            if type(params.unit_indices) == "table" and #params.unit_indices > 0 then
                local units = army:units()
                for i = 1, #params.unit_indices do
                    uc:add_units(units:item(tonumber(params.unit_indices[i])))
                end
            else
                uc:add_all_units()
            end
            if order == "halt" then
                uc:halt()
                return "halt issued"
            end
            local enemy_units = bm:get_non_player_alliance():armies():item(1):units()
            local target = nil
            if params.target_index then
                target = enemy_units:item(tonumber(params.target_index))
            else
                for i = 1, enemy_units:count() do
                    local u = enemy_units:item(i)
                    if u:number_of_men_alive() > 0 then target = u break end
                end
            end
            if not target then return "no enemy target found" end
            if order == "attack_unit" then
                uc:attack_unit(target, true, true)
                return "attack_unit issued"
            end
            -- attack-move: engage whatever is met on the way (the proven
            -- whole-army order from the live run)
            uc:attack_location(target:position(), true)
            return "attack_location issued"
        end)
        if not ok then return { status = "error", error = "battle_order failed: " .. tostring(detail) } end
        debug_log("battle_order: " .. order .. " -> " .. tostring(detail))
        return { status = "ok", result = { order = order, detail = detail } }

    elseif cmd == "end_battle" then
        -- Two-step ending (verified live): in VictoryCountdown,
        -- bm:end_battle() moves the battle to Complete and opens
        -- in_battle_results_popup; the battle then WAITS until its
        -- button_dismiss_results ("End Battle") is clicked. This command does
        -- whichever step applies - call it again if the first call reports
        -- ended=false.
        if not in_battle() then return { status = "error", error = "not in a battle" } end
        local popup = battle_results_popup()
        if popup then
            local results = read_battle_results()
            local btn = find_uicomponent(popup, "button_dismiss_results")
            if not btn then
                return { status = "error", error = "button_dismiss_results not found on the results popup" }
            end
            if not safe_click(btn) then
                return { status = "error", error = "clicking button_dismiss_results failed" }
            end
            debug_log("end_battle: results dismissed (outcome " .. tostring(results and results.outcome) .. ")")
            return { status = "ok", result = {
                ended = true,
                outcome = results and results.outcome or nil,
                note = "campaign context is loading (script reload); poll get_situation until " ..
                       "context == campaign, then handle the post_battle blocker",
            } }
        end
        local phase = battle_phase()
        if phase == "VictoryCountdown" then
            local ok, err = pcall(function() bm:end_battle() end)
            if not ok then
                return { status = "error", error = "end_battle failed: " .. tostring(err) }
            end
            debug_log("end_battle: issued (VictoryCountdown -> Complete)")
            return { status = "ok", result = {
                ended = false,
                note = "battle moves to Complete and the results popup opens within a tick; " ..
                       "call end_battle again to dismiss it",
            } }
        end
        return { status = "error", error = "end_battle applies in VictoryCountdown or with the " ..
                 "results popup open (current phase: " .. tostring(phase) .. ")" }

    elseif cmd == "auto_fight" then
        -- BATTLE side: arm the machine mid-battle (from campaign use
        -- fight_battle {auto=true} instead). Acks immediately; the run ends
        -- with the context transition, so poll get_situation until the
        -- context flips back to campaign.
        if not in_battle() then
            return { status = "error", error = "not in a battle (from campaign, use fight_battle {auto: true})" }
        end
        autofight = {
            speed = tonumber(params.speed) or 10,
            max_ticks = tonumber(params.max_ticks) or 900,
            ticks = 0,
            stage = "armed",
        }
        battle_speed = autofight.speed
        debug_log("auto_fight: armed by command (speed " .. autofight.speed .. ")")
        return { status = "ok", result = {
            armed = true,
            speed = autofight.speed,
            note = "the poll loop now drives the battle; context flips to campaign when done",
        } }

    elseif cmd == "dismiss_battle_results" then
        -- CAMPAIGN side, after a manual battle: the post-battle results panel
        -- is already up (get_situation blocking kind post_battle). Arms the
        -- autoresolve machine directly at its dismiss stage, which handles
        -- the captive choice and reports human_victory + result_title.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if not find_panel_root("popup_battle_results") then
            return { status = "error", error = "popup_battle_results is not open" }
        end
        local captives = params.captives or "kill"
        if not CAPTIVE_OPTIONS[captives] then
            return { status = "error", error = "captives must be kill, enslave or release" }
        end
        autoresolve_pending = true
        autoresolve_stage = "dismiss"
        autoresolve_ticks = 0
        autoresolve_captives = captives
        autoresolve_rigged = false
        autoresolve_title = nil
        autoresolve_clicked = nil
        debug_log("dismiss_battle_results: armed the dismiss machine (captives " .. captives .. ")")
        return nil  -- deferred: the machine writes the result

    else
        return { status = "error", error = "unknown command: " .. tostring(cmd) }
    end
end

local function build_situation()
    local situation = {
        context = "frontend",
        strings_ok = strings_ok(),
        blocking = {},
    }
    if in_battle() then
        return read_battle_situation()
    end
    if in_campaign() then
        situation.context = "campaign"
        situation.turn = sf(function() return cm:turn_number() end)
        local faction = get_local_faction()
        if faction then
            situation.faction = sf(function() return faction:name() end)
            situation.treasury = sf(function() return faction:treasury() end)
        end
        situation.is_players_turn = sf(function() return cm:is_local_players_turn() end)
        local ok, active, fought = pcall(function() return cm:is_pending_battle_active() end)
        if ok then
            situation.pending_battle = {
                active = active and true or false,
                has_been_fought = fought and true or false,
            }
        end
        situation.notification = get_text(find_uicomponent(
            "hud_campaign", "faction_buttons_docker", "end_turn_docker",
            "notification_frame", "dy_notification"))
    elseif find_uicomponent("button_campaign") then
        situation.context = "main_menu"
    end
    situation.saving = uic_visible(find_uicomponent("saving_icon"))

    local blocking = situation.blocking
    -- a. a confirmation dialog swallows every other click
    local box, dialog_text = get_visible_dialogue_box()
    if box then
        blocking[#blocking + 1] = { kind = "dialog", text = dialog_text }
    end
    -- a2. move_options: the "Declare War? / Cancel Move" style interruption a
    -- movement or attack order raises. NOT a dialogue_box (verified live
    -- 2026-08-21). Answer it with answer_move_options.
    local mo = read_move_options()
    if mo then blocking[#blocking + 1] = mo end
    -- b. dilemma / incident / other event panel
    local event = read_event_detail()
    if event then blocking[#blocking + 1] = event end
    -- c. pre-battle panel
    local pre_battle = read_pre_battle()
    if pre_battle then blocking[#blocking + 1] = pre_battle end
    -- d. post-battle panel
    local post_battle = read_post_battle()
    if post_battle then blocking[#blocking + 1] = post_battle end
    -- d2. occupation choice after a settlement was taken
    local occupation = read_settlement_captured()
    if occupation then blocking[#blocking + 1] = occupation end
    -- e. fullscreen panel — skip the roots already reported by richer entries
    -- above (events, pre/post battle), which get_open_panel also names.
    local panel_key = detect_open_panel_key()
    local panel_name = get_open_panel()
    local already_reported = {
        events = true, popup_pre_battle = true, popup_battle_results = true,
        settlement_captured = true, move_options = true,
    }
    if (panel_key or panel_name) and not already_reported[panel_name or ""] then
        blocking[#blocking + 1] = {
            kind = "panel",
            name = panel_name or (panel_key and PANELS[panel_key].root or nil),
            key = panel_key,
        }
    end
    -- f. escape menu
    if uic_visible(find_uicomponent("esc_menu")) then
        blocking[#blocking + 1] = { kind = "esc_menu" }
    end
    -- g. advisor-style popups
    if uic_visible(find_uicomponent("advice_interface")) then
        blocking[#blocking + 1] = { kind = "advisor" }
    end
    -- Visibility, not existence: mission_review lingers hidden after a mission
    -- is issued (verified live — it reported a ghost mission on every call).
    if uic_visible(find_uicomponent("mission_review")) then
        blocking[#blocking + 1] = { kind = "mission" }
    end
    if uic_visible(find_uicomponent("passing_advisor_menu")) then
        blocking[#blocking + 1] = { kind = "shenzoo_advisor" }
    end
    situation.blocking_count = #blocking
    return situation
end

-- ---------------------------------------------------------------------------
-- Soak loop helpers (the tick driver itself is handle_soak_tick, below the
-- dispatch next to the other machines)
-- ---------------------------------------------------------------------------

local function finish_soak(status_str, note)
    soak_pending = false
    if soak then
        soak.finished = true
        soak.status = status_str  -- "complete" | "aborted" | "error"
        if note then soak.notes[#soak.notes + 1] = note end
        if soak.suppress_events then
            pcall(function() CampaignUI.SuppressAllEventTypesInUI(false) end)
        end
        debug_log("soak: finished (" .. tostring(status_str) .. ") turns=" ..
                  tostring(soak.done) .. "/" .. tostring(soak.target))
    end
end

local function soak_summary()
    if not soak then return nil end
    return {
        running = soak_pending and true or false,
        finished = soak.finished and true or false,
        status = soak.status,
        turns_completed = soak.done,
        target_turns = soak.target,
        current_turn = sf(function() return cm:turn_number() end),
        events_dismissed = soak.events_dismissed,
        dilemmas_answered = soak.dilemmas_answered,
        dialogs_confirmed = soak.dialogs_confirmed,
        battles = soak.battles,
        notes = soak.notes,
        strings_ok = strings_ok(),
    }
end

-- Overflow dispatch. Lua 5.1 hard-caps every closure at 60 upvalues and the
-- main execute_command hit the cap (the whole mod then FAILS TO LOAD with
-- "function ... has more than 60 upvalues"; luaparse cannot catch this).
-- Newer commands live here with their own upvalue budget; execute_command
-- delegates any name it does not know.
local function execute_command_2(cmd, params)
    if cmd == "occupy_choice" then
        -- Decide the settlement_captured panel. choice matches the option's
        -- dy_option TEXT (case-insensitive substring, e.g. "occupy", "sack",
        -- "raze", "loot", "vassal") or a 1-based index into the options list.
        -- ONE click decides - there is no confirm step (verified live).
        local detail = read_settlement_captured()
        if not detail then
            return { status = "error", error = "settlement_captured panel is not open" }
        end
        local choice = params.choice
        if choice == nil then choice = "occupy" end
        local picked = nil
        if type(choice) == "number" then
            picked = detail.options[choice]
        else
            local want = tostring(choice):lower()
            local want_pat = escape_pattern(want)
            -- exact-first, then substring, so "occupy" prefers "Occupy" over
            -- "Loot & Occupy"
            for i = 1, #detail.options do
                local t = (detail.options[i].text or ""):lower()
                if t == want then picked = detail.options[i] break end
            end
            if not picked then
                for i = 1, #detail.options do
                    local t = (detail.options[i].text or ""):lower()
                    if t:find(want_pat) then picked = detail.options[i] break end
                end
            end
        end
        if not picked then
            local names = {}
            for i = 1, #detail.options do names[#names + 1] = tostring(detail.options[i].text) end
            return { status = "error", error = "no occupation option matches '" .. tostring(choice) ..
                     "' - available: " .. table.concat(names, ", ") }
        end
        local root = find_root_child("settlement_captured")
        local parent = root and get_child(root, "button_parent") or nil
        local opt = parent and get_child(parent, picked.id) or nil
        local btn = opt and get_child(opt, "option_button") or nil
        if not btn then
            return { status = "error", error = "option_button not found for option id " .. tostring(picked.id) }
        end
        if not safe_click(btn) then
            return { status = "error", error = "clicking the option_button failed" }
        end
        debug_log("occupy_choice: clicked '" .. tostring(picked.text) .. "' (id " .. tostring(picked.id) .. ")")
        return { status = "ok", result = {
            chosen = picked.text,
            option_id = picked.id,
            settlement = detail.settlement,
            panel_closed = read_settlement_captured() == nil,
            note = "the panel needs a frame to close; a follow-up event often opens - check get_situation",
        } }

    elseif cmd == "answer_move_options" then
        -- Answer the move_options interruption ("Declare War?" etc.). option
        -- is the 1-based index from get_situation's move_options entry (or its
        -- bar number). The Declare War option routes through the diplomacy
        -- screen's confirmation, which the deferred machine clicks and closes;
        -- cancel-style options just close the panel.
        local detail = read_move_options()
        if not detail then
            return { status = "error", error = "move_options panel is not open" }
        end
        local option = tonumber(params.option)
        if not option then return { status = "error", error = "need option (bar index, 1-based; see get_situation)" } end
        local mo = get_move_options_root()
        local panel = mo and get_child(mo, "panel") or nil
        local bar = panel and get_child(panel, "options_bar" .. option) or nil
        if not bar or not uic_visible(bar) then
            return { status = "error", error = "options_bar" .. option .. " not found or hidden" }
        end
        local label = get_text(get_child(bar, "button_txt"))
        if not safe_click(bar) then
            return { status = "error", error = "clicking options_bar" .. option .. " failed" }
        end
        debug_log("answer_move_options: clicked bar " .. option .. " ('" .. tostring(label) .. "')")
        if params.confirm_war == false then
            return { status = "ok", result = { clicked = label, option = option,
                note = "war confirmation NOT auto-handled (confirm_war=false)" } }
        end
        moveopts_pending = true
        moveopts_state = { ticks = 0, label = label, option = option }
        return nil  -- deferred; handle_moveopts_tick confirms any war dialog and writes the result

    elseif cmd == "soak_turns" then
        -- Unattended multi-turn run. Acks IMMEDIATELY; the poll loop drives
        -- turns in the background and soak_status reads progress + the final
        -- summary. Per tick it clears blockers (dialogs confirmed, incidents
        -- dismissed, dilemmas answered with a fixed choice, battles handled
        -- per battle_policy) and ends the turn; a completed AI cycle counts
        -- one turn. Never writes the result file from a tick.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if soak_pending then return { status = "error", error = "a soak is already running - soak_status / soak_abort" } end
        if quit_pending or autoresolve_pending or diplomacy_pending or research_pending or moveopts_pending then
            return { status = "error", error = "another deferred sequence is running" }
        end
        local turns = tonumber(params.turns) or 5
        if turns < 1 then turns = 1 end
        if turns > 200 then turns = 200 end
        local policy = params.battle_policy or "autoresolve"
        if policy ~= "autoresolve" and policy ~= "retreat" and policy ~= "stop" then
            return { status = "error", error = "battle_policy must be autoresolve, retreat, or stop" }
        end
        local captives = params.captives or "kill"
        if not CAPTIVE_OPTIONS[captives] then
            return { status = "error", error = "captives must be one of: kill, enslave, release" }
        end
        local dilemma_choice = tonumber(params.dilemma_choice) or 1
        if dilemma_choice < 1 or dilemma_choice > 4 then dilemma_choice = 1 end
        soak = {
            target = turns, done = 0,
            last_turn = sf(function() return cm:turn_number() end) or 0,
            end_turn_issued = false,
            ticks_this_turn = 0,
            max_ticks_per_turn = tonumber(params.max_seconds_per_turn) or 300,
            dilemma_choice = dilemma_choice,
            battle_policy = policy,
            captives = captives,
            occupation = params.occupation or "occupy",
            rig_battles = params.rig_battles and true or false,
            suppress_events = params.suppress_events and true or false,
            events_dismissed = 0, dilemmas_answered = 0, dialogs_confirmed = 0,
            battles = {}, notes = {},
            abort = false, finished = false, status = "running",
        }
        if soak.suppress_events then
            local ok_sup = pcall(function() CampaignUI.SuppressAllEventTypesInUI(true) end)
            if not ok_sup then
                soak.suppress_events = false
                soak.notes[#soak.notes + 1] = "SuppressAllEventTypesInUI unavailable - dismissing events instead"
            end
        end
        soak_pending = true
        debug_log("soak: started for " .. turns .. " turns (policy=" .. policy .. ")")
        return { status = "ok", result = {
            started = true,
            target_turns = turns,
            note = "runs in the background - poll soak_status; soak_abort stops it",
        } }

    elseif cmd == "soak_status" then
        local s = soak_summary()
        if not s then return { status = "error", error = "no soak has run in this script session" } end
        return { status = "ok", result = s }

    elseif cmd == "soak_abort" then
        if not soak_pending then return { status = "error", error = "no soak is running" } end
        soak.abort = true
        return { status = "ok", result = { aborting = true, note = "the next poll tick finalises the summary - read it with soak_status" } }

    elseif cmd == "build_building" then
        -- Instant test-setup build via cm:add_building_to_settlement (a slot
        -- must be free; the engine enforces validity). For player-flow builds
        -- use the settlement UI via click_ui instead.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local region_key = params.region
        local building_key = params.building
        if not region_key or not building_key then
            return { status = "error", error = "need region and building" }
        end
        local ok, err = pcall(function() cm:add_building_to_settlement(region_key, building_key) end)
        if not ok then
            return { status = "error", error = "add_building_to_settlement failed: " .. tostring(err) }
        end
        -- Read back: does the region now hold the building?
        local present = sf(function()
            local region = cm:get_region(region_key)
            return region and region:building_exists(building_key) or nil
        end)
        debug_log("build_building: " .. building_key .. " in " .. region_key .. " present=" .. tostring(present))
        return { status = "ok", result = {
            region = region_key, building = building_key,
            called = true, building_present = present,
            note = present == false and "call returned but the building is not present - bad key, no free slot, or wrong chain" or nil,
        } }

    elseif cmd == "transfer_region" then
        -- Instant ownership transfer (state-level occupation). The post-battle
        -- occupation-choice flow is separate UI.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local region_key = params.region
        if not region_key then return { status = "error", error = "need region" } end
        local faction_key = params.faction
        if not faction_key then
            local f = get_local_faction()
            faction_key = f and sf(function() return f:name() end) or nil
        end
        if not faction_key then return { status = "error", error = "no target faction" } end
        local ok, err = pcall(function() cm:transfer_region_to_faction(region_key, faction_key) end)
        if not ok then
            return { status = "error", error = "transfer_region_to_faction failed: " .. tostring(err) }
        end
        local owner = sf(function()
            local region = cm:get_region(region_key)
            return region and region:owning_faction():name() or nil
        end)
        debug_log("transfer_region: " .. region_key .. " -> " .. faction_key .. " owner_now=" .. tostring(owner))
        return { status = "ok", result = {
            region = region_key, requested_faction = faction_key,
            owner_now = owner, transferred = owner == faction_key,
        } }

    elseif cmd == "start_research" then
        -- No cm function exists to start research in WH3: this drives the
        -- tech panel UI (open -> click the tech_<key> node -> verify via
        -- faction:is_currently_researching -> close). Deferred to the poll
        -- loop because the panel needs frames to open.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if research_pending then return { status = "error", error = "a start_research sequence is already running" } end
        local tech_key = params.tech_key
        if not tech_key then return { status = "error", error = "need tech_key" } end
        research_state = { key = tech_key, ticks = 0, opened = false, clicked = false }
        research_pending = true
        return nil  -- deferred; handle_research_tick writes the result

    elseif cmd == "level_character" then
        -- Instant levels via cm:add_agent_experience(character_string, n, true).
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local cqi = tonumber(params.cqi)
        if not cqi then return { status = "error", error = "need cqi (numeric character cqi)" } end
        local levels = tonumber(params.levels) or 1
        local lookup = "character_cqi:" .. cqi
        local rank_before = sf(function() return cm:get_character_by_cqi(cqi):rank() end)
        local ok, err = pcall(function() cm:add_agent_experience(lookup, levels, true) end)
        if not ok then
            return { status = "error", error = "add_agent_experience failed: " .. tostring(err) }
        end
        local rank_after = sf(function() return cm:get_character_by_cqi(cqi):rank() end)
        debug_log("level_character: cqi " .. cqi .. " +" .. levels .. " levels, rank " ..
                  tostring(rank_before) .. " -> " .. tostring(rank_after))
        return { status = "ok", result = {
            cqi = cqi, levels_added = levels,
            rank_before = rank_before, rank_after = rank_after,
            -- rank() updates a model tick after the XP lands (verified live:
            -- unchanged in this read, correct one eval later)
            note = rank_after == rank_before and "rank reads lag one model tick - re-read via get_characters or eval" or nil,
        } }

    elseif cmd == "grant_skill" then
        -- cm:add_skill(character_OBJECT, key, ignore_requirements,
        -- ignore_skill_points). The documented force_add_skill does NOT exist
        -- on this build (verified 2026-08-21; cm_search runtime_only found
        -- add_skill, and lib_campaign_manager.lua:7803 gave the signature).
        -- KNOWN LIMIT: on the tested build the engine can silently refuse the
        -- add even with both flags and a valid key from the character's own
        -- tree - ALWAYS check has_skill_now in the result.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local cqi = tonumber(params.cqi)
        local skill_key = params.skill_key
        if not cqi or not skill_key then return { status = "error", error = "need cqi and skill_key" } end
        local char = sf(function() return cm:get_character_by_cqi(cqi) end)
        if not char then return { status = "error", error = "no character with cqi " .. cqi } end
        local ok, err = pcall(function() cm:add_skill(char, skill_key, true, true) end)
        if not ok then
            return { status = "error", error = "add_skill failed: " .. tostring(err) }
        end
        local has = sf(function() return cm:get_character_by_cqi(cqi):has_skill(skill_key) end)
        debug_log("grant_skill: " .. skill_key .. " -> cqi " .. cqi .. " has_skill=" .. tostring(has))
        return { status = "ok", result = {
            cqi = cqi, skill = skill_key, has_skill_now = has,
            note = has == false and "engine did not apply the skill (silent refusal or bad key) - this is a known behaviour of add_skill on this build" or nil,
        } }

    elseif cmd == "cco_query" then
        -- Raw CCO read: common.get_context_value. The context system computes
        -- everything the UI can display (character stats, unit stats, tech
        -- state), so this reads values no script interface exposes. The arg
        -- forms differ by build; try the given form(s) and report which
        -- answered.
        local expression = params.expression
        if not expression then return { status = "error", error = "need expression" } end
        if not common or not common.get_context_value then
            return { status = "error", error = "common.get_context_value not available in this context" }
        end
        local attempts = {}
        local function try(label, fn)
            local ok, v = pcall(fn)
            attempts[#attempts + 1] = { form = label, ok = ok and true or false }
            if ok and v ~= nil then
                local t = type(v)
                if t ~= "boolean" and t ~= "number" and t ~= "string" then v = tostring(v) end
                return { status = "ok", result = { value = v, value_type = t, form = label, attempts = attempts } }
            end
            return nil
        end
        local r
        if params.object_id then
            r = try("(object_id, expression)", function()
                return common.get_context_value(params.object_id, expression)
            end)
        elseif params.type then
            local data = params.data
            r = try("(type, data, expression)", function()
                return common.get_context_value(params.type, data, expression)
            end)
            if not r then
                r = try("(type..data, expression)", function()
                    return common.get_context_value(tostring(params.type) .. tostring(data or ""), expression)
                end)
            end
        else
            r = try("(expression)", function()
                return common.get_context_value(expression)
            end)
        end
        if r then return r end
        return { status = "ok", result = {
            value = nil, attempts = attempts,
            note = "no form returned a value - wrong expression, wrong construction data, or nil result",
        } }

    else
        return execute_command_battle(cmd, params)
    end
end

local function execute_command(command)
    local cmd = command.command
    local params = command.params or {}

    if cmd == "ping" then
        local healthy = strings_ok()
        local info = {
            pong = true,
            in_campaign = in_campaign(),
            has_cm = cm ~= nil,
            strings_ok = healthy,
        }
        if not healthy then
            info.note = "the in-game string subsystem is corrupted — RESTART WH3; " ..
                        "JSON decoding will fail until you do"
        end
        return { status = "ok", result = info }

    elseif cmd == "get_situation" then
        -- The vision-free replacement for a screenshot: context, what blocks
        -- the agent right now (ordered), and the campaign state around it.
        return { status = "ok", result = build_situation() }

    elseif cmd == "get_status" then
        local info = {
            in_campaign = in_campaign(),
            has_cm = cm ~= nil,
            turn = -1,
            faction_name = nil,
        }
        if in_campaign() then
            info.turn = cm:turn_number()
            local faction = get_local_faction()
            if faction then
                info.faction_name = faction:name()
            end
        end
        return { status = "ok", result = info }

    elseif cmd == "get_faction_info" then
        if not in_campaign() then
            return { status = "error", error = "not in a campaign" }
        end
        local faction = get_local_faction()
        if not faction then
            return { status = "error", error = "no local faction found" }
        end
        local ok, info = pcall(function()
            return {
                name = faction:name(),
                treasury = faction:treasury(),
                turn = cm:turn_number(),
                faction_leader = faction:faction_leader():character_subtype_key() or "unknown",
                is_dead = faction:is_dead(),
                is_human = cm:is_faction_human(faction:name()),
            }
        end)
        if ok then return { status = "ok", result = info }
        else return { status = "error", error = tostring(info) } end

    elseif cmd == "get_saved_value" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local key = params.key
        if not key then return { status = "error", error = "missing key parameter" } end
        local val = cm:get_saved_value(key)
        return { status = "ok", result = { key = key, value = val } }

    elseif cmd == "set_saved_value" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local key = params.key
        local value = params.value
        if not key then return { status = "error", error = "missing key parameter" } end
        cm:set_saved_value(key, value)
        return { status = "ok", result = { key = key, value = value } }

    elseif cmd == "apply_effect_bundle" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local bundle_key = params.bundle_key
        local faction_key = params.faction_key
        local turns = params.turns or 0
        if not bundle_key then return { status = "error", error = "missing bundle_key" } end
        if not faction_key then return { status = "error", error = "missing faction_key" } end
        cm:apply_effect_bundle(bundle_key, faction_key, turns)
        return { status = "ok", result = { bundle_key = bundle_key, faction_key = faction_key, turns = turns } }

    elseif cmd == "get_regions" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local faction = get_local_faction()
        if not faction then return { status = "error", error = "no local faction" } end
        local ok, region_list = pcall(function()
            local regions = {}
            local ri = faction:region_list()
            if ri then
                for i = 0, ri:num_items() - 1 do
                    local region = ri:item_at(i)
                    if region then
                        local name = ""
                        local ok_n, n = pcall(function() return region:name() end)
                        if ok_n then name = tostring(n) end
                        local province = ""
                        local ok_p, p = pcall(function()
                            local prov = region:province()
                            if prov then return prov:name() end
                        end)
                        if ok_p then province = tostring(p) end
                        regions[#regions + 1] = {
                            name = name,
                            province = province,
                        }
                    end
                end
            end
            return regions
        end)
        if ok then return { status = "ok", result = region_list }
        else return { status = "error", error = tostring(region_list) } end

    elseif cmd == "trigger_dilemma" then
        -- cm:trigger_dilemma_raw(faction_key STRING, key, fire_immediately,
        -- whitelist). A faction OBJECT is rejected with a script error, and the
        -- engine validates the record itself: the call can succeed while
        -- nothing is issued (legacy rows, unmet conditions, missing targets).
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local dilemma_key = params.dilemma_key
        if not dilemma_key then return { status = "error", error = "missing dilemma_key" } end
        local faction_key = params.faction or params.faction_key
        if not faction_key then
            local f = get_local_faction()
            faction_key = f and sf(function() return f:name() end) or nil
        end
        if not faction_key then return { status = "error", error = "no target faction" } end
        local fire_immediately = params.fire_immediately
        if fire_immediately == nil then fire_immediately = true end
        local whitelist = params.whitelist
        if whitelist == nil then whitelist = true end
        local ok, issued = pcall(function()
            return cm:trigger_dilemma_raw(tostring(faction_key), dilemma_key,
                                          fire_immediately and true or false,
                                          whitelist and true or false)
        end)
        if not ok then
            return { status = "error", error = "trigger_dilemma_raw failed: " .. tostring(issued) }
        end
        local result = {
            dilemma = dilemma_key,
            faction = tostring(faction_key),
            fire_immediately = fire_immediately and true or false,
            whitelist = whitelist and true or false,
            issued = issued and true or false,
        }
        if not issued then
            result.note = "engine rejected the record - conditions/targets not met or legacy row; check script_log"
        end
        debug_log("trigger_dilemma: " .. tostring(dilemma_key) .. " for " ..
                  tostring(faction_key) .. " issued=" .. tostring(issued))
        return { status = "ok", result = result }

    elseif cmd == "trigger_incident" then
        -- cm:trigger_incident(faction_key STRING, key, fire_immediately).
        -- Same record validation as dilemmas: issued=false is a rejection, not
        -- an error.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local incident_key = params.incident_key
        if not incident_key then return { status = "error", error = "missing incident_key" } end
        local faction_key = params.faction or params.faction_key
        if not faction_key then
            local f = get_local_faction()
            faction_key = f and sf(function() return f:name() end) or nil
        end
        if not faction_key then return { status = "error", error = "no target faction" } end
        local fire_immediately = params.fire_immediately
        if fire_immediately == nil then fire_immediately = true end
        local ok, issued = pcall(function()
            return cm:trigger_incident(tostring(faction_key), incident_key,
                                       fire_immediately and true or false)
        end)
        if not ok then
            return { status = "error", error = "trigger_incident failed: " .. tostring(issued) }
        end
        local result = {
            incident = incident_key,
            faction = tostring(faction_key),
            fire_immediately = fire_immediately and true or false,
            issued = issued and true or false,
        }
        if not issued then
            result.note = "engine rejected the record - conditions/targets not met or legacy row; check script_log"
        end
        debug_log("trigger_incident: " .. tostring(incident_key) .. " for " ..
                  tostring(faction_key) .. " issued=" .. tostring(issued))
        return { status = "ok", result = result }

    elseif cmd == "trigger_dilemma_with_targets" then
        -- cm:trigger_dilemma_with_targets(faction_cqi NUMBER, dilemma_key,
        -- target_faction_cqi, secondary_faction_cqi, character_cqi,
        -- military_force_cqi, region_cqi, settlement_cqi, trigger_callback).
        -- For dilemmas whose records need target game objects (e.g. Shenzoo
        -- character dilemmas). Unlike trigger_dilemma_raw this wraps the
        -- delivery in an intervention in singleplayer, so issued=true means
        -- QUEUED: poll get_situation for the event panel, it can take a
        -- moment. Faction arg is a NUMERIC cqi here, not a key string.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local dilemma_key = params.dilemma_key
        if not dilemma_key then return { status = "error", error = "missing dilemma_key" } end
        local faction_cqi = tonumber(params.faction_cqi)
        if not faction_cqi then
            local f = get_local_faction()
            faction_cqi = f and sf(function() return f:command_queue_index() end) or nil
        end
        if not faction_cqi then return { status = "error", error = "missing faction_cqi and the local faction's could not be read" } end
        local t_faction    = tonumber(params.target_faction_cqi)
        local t_secondary  = tonumber(params.secondary_faction_cqi)
        local t_character  = tonumber(params.character_cqi)
        local t_force      = tonumber(params.military_force_cqi)
        local t_region     = tonumber(params.region_cqi)
        local t_settlement = tonumber(params.settlement_cqi)
        local ok, issued = pcall(function()
            return cm:trigger_dilemma_with_targets(
                faction_cqi, dilemma_key,
                t_faction, t_secondary, t_character, t_force, t_region, t_settlement,
                function()
                    debug_log("trigger_dilemma_with_targets: intervention fired for " .. tostring(dilemma_key))
                end)
        end)
        if not ok then
            return { status = "error", error = "trigger_dilemma_with_targets failed: " .. tostring(issued) }
        end
        local result = {
            dilemma = dilemma_key,
            faction_cqi = faction_cqi,
            targets = {
                target_faction_cqi = t_faction,
                secondary_faction_cqi = t_secondary,
                character_cqi = t_character,
                military_force_cqi = t_force,
                region_cqi = t_region,
                settlement_cqi = t_settlement,
            },
            issued = issued and true or false,
        }
        if issued then
            result.note = "queued via intervention - poll get_situation for the event panel"
        else
            result.note = "engine/wrapper rejected the request - bad cqi, unmet conditions, or legacy row; check script_log"
        end
        debug_log("trigger_dilemma_with_targets: " .. tostring(dilemma_key) .. " for faction cqi " ..
                  tostring(faction_cqi) .. " issued=" .. tostring(issued))
        return { status = "ok", result = result }

    elseif cmd == "read_event" then
        local detail = read_event_detail()
        if not detail then
            return { status = "error", error = "no event panel open" }
        end
        return { status = "ok", result = detail }

    elseif cmd == "answer_dilemma" then
        -- Answering is UI-only: there is no cm: function for it. Click the
        -- choice_button INSIDE the ordinal entry of dilemma_list — every
        -- choice_button shares the same id, so a plain Find would always hit
        -- the first one.
        local choice = params.choice
        if type(choice) ~= "number" or choice < 1 or choice > #DILEMMA_ORDINALS then
            return { status = "error", error = "choice must be a number 1..4 (1-based)" }
        end
        local events = find_panel_root("events")
        if not events then return { status = "error", error = "no event panel open" } end
        local dilemma = get_open_dilemma(events)
        if not dilemma then
            return { status = "error", error = "no dilemma_active panel — the open event is not a dilemma" }
        end
        local list = get_child(dilemma, "dilemma_list")
        if not list then return { status = "error", error = "dilemma_list not found" } end
        local entry, entry_id = find_dilemma_choice(list, choice)
        if not entry then
            return { status = "error", error = "no choice entry ending in " ..
                     DILEMMA_ORDINALS[choice] .. " — this dilemma has fewer choices" }
        end
        local button = get_child(entry, "choice_button")
        if not button then
            return { status = "error", error = "choice_button not found inside " .. tostring(entry_id) }
        end
        local choice_text = get_text(get_child(button, "button_txt"))
        if not safe_click(button) then
            return { status = "error", error = "clicking choice_button failed" }
        end
        debug_log("answer_dilemma: clicked choice " .. choice .. " (" .. tostring(entry_id) .. ")")
        return { status = "ok", result = {
            answered = true,
            choice = choice,
            ordinal = DILEMMA_ORDINALS[choice],
            entry_id = entry_id,
            choice_text = choice_text,
            panel_closed = find_panel_root("events") == nil,
            note = "the engine confirms with DilemmaChoiceMadeEvent, whose choice() is 0-indexed",
        } }

    elseif cmd == "dismiss_event" then
        local events = find_panel_root("events")
        if not events then return { status = "error", error = "no event panel open" } end
        local button_set = get_child(events, "button_set")
        local holder = button_set and get_child(button_set, "accept_holder") or nil
        local btn = holder and get_child(holder, "button_accept") or get_child(events, "button_accept")
        if not btn then
            return { status = "error", error = "button_accept not found under events > button_set > accept_holder" }
        end
        local visible = uic_visible(btn)
        if not safe_click(btn) then
            return { status = "error", error = "clicking button_accept failed" }
        end
        debug_log("dismiss_event: clicked events > button_set > accept_holder > button_accept")
        return { status = "ok", result = {
            dismissed = true,
            button_visible = visible,
            panel_closed = find_panel_root("events") == nil,
            note = "dilemmas keep this button hidden — answer them with answer_dilemma instead",
        } }

    elseif cmd == "get_characters" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local faction = get_local_faction()
        if not faction then return { status = "error", error = "no local faction" } end
        local ok, chars = pcall(function()
            local list = {}
            local cl = faction:character_list()
            if cl then
                for i = 0, cl:num_items() - 1 do
                    local char = cl:item_at(i)
                    if char then
                        local function sf(fn, ...)
                            local ok, r = pcall(fn, ...)
                            if ok then return r end
                            return nil
                        end
                        list[#list + 1] = {
                            subtype = sf(function() return char:character_subtype_key() end),
                            forename = sf(function() return char:get_forename() end),
                            level = sf(function() return char:level() end),
                            is_general = sf(function() return char:is_general() end),
                            is_agent = sf(function() return char:is_agent() end),
                            cqi = sf(function() return char:cqi() end),
                        }
                    end
                end
            end
            return list
        end)
        if ok then return { status = "ok", result = chars }
        else return { status = "error", error = tostring(chars) } end

    elseif cmd == "start_campaign" then
        if in_campaign() then
            return { status = "ok", result = { already_in_campaign = true } }
        end

        -- If a previous start_campaign is still pending, do nothing
        if campaign_start_pending then
            return { status = "ok", result = { pending = true } }
        end

        local campaign_key = params.campaign_key or "wh3_main_combi"
        local faction_key = params.faction_key or "mixer_cth_shenzoo"
        local party_key = params.party_key

        local started = false
        local used_method = "none"

        -- Approach 1: Click the UI Start Campaign button
        local btn = find_uicomponent("button_start_parent", "button_start_campaign")
        if btn then
            btn:SimulateLClick()
            debug_log("start_campaign: clicked button_start_parent > button_start_campaign")
            started = true
            used_method = "ui_click"
        else
            -- Approach 2: Direct button_start_campaign (alternative path)
            local btn2 = find_uicomponent("button_start_campaign")
            if btn2 then
                btn2:SimulateLClick()
                debug_log("start_campaign: clicked button_start_campaign (top-level)")
                started = true
                used_method = "ui_click_direct"
            end
        end

        -- Approach 3: Fallback to frontend.start_campaign
        if not started then
            debug_log("UI buttons not found, trying frontend.start_campaign")
            if type(frontend) == "table" or type(frontend) == "userdata" then
                if party_key then
                    started = pcall(function()
                        frontend.start_campaign(campaign_key, faction_key, party_key)
                    end)
                    if started then used_method = "api:" .. campaign_key end
                end
                if not started then
                    started = pcall(function()
                        frontend.start_campaign(campaign_key, faction_key)
                    end)
                    if started then used_method = "api_noparty:" .. campaign_key end
                end
            end
        end

        debug_log("start_campaign result: method=" .. used_method .. " started=" .. tostring(started))

        if not started then
            debug_log("All campaign start methods failed")
            return { status = "error", error = "no campaign start method worked" }
        end

        -- Set pending state; the poll loop will check for completion.
        campaign_start_pending = true
        campaign_start_params = {
            campaign_key = campaign_key,
            faction_key = faction_key,
            party_key = party_key,
            is_new_game = true,
        }
        campaign_start_time = os.clock()

        -- Register a WorldCreated listener to detect campaign load
        core:add_listener(
            "Wh3McpCampaignStarted",
            "WorldCreated",
            true,
            function()
                debug_log("WorldCreated fired — campaign loaded")
                campaign_start_pending = false
                core:remove_listener("Wh3McpCampaignStarted")
            end,
            false
        )

        -- Return nothing yet — the poll loop will write the result when ready
        return nil

    elseif cmd == "load_campaign" then
        local filename = params.filename
        if not filename then
            return { status = "error", error = "missing filename parameter" }
        end
        local ok, err = pcall(function()
            frontend.load_campaign(filename)
        end)
        if ok then
            debug_log("load_campaign called: " .. filename)
            campaign_start_pending = true
            campaign_start_params = { filename = filename, is_new_game = false }
            campaign_start_time = os.clock()
            core:add_listener("Wh3McpCampaignStarted", "WorldCreated", true,
                function()
                    debug_log("WorldCreated fired — campaign loaded from save")
                    campaign_start_pending = false
                    core:remove_listener("Wh3McpCampaignStarted")
                end, false)
            return nil
        else
            debug_log("load_campaign failed: " .. tostring(err))
            return { status = "error", error = "load_campaign failed: " .. tostring(err) }
        end

    elseif cmd == "continue_campaign" then
        local ok, err = pcall(function()
            frontend.continue_campaign()
        end)
        if ok then
            debug_log("continue_campaign called")
            campaign_start_pending = true
            campaign_start_params = { method = "continue", is_new_game = false }
            campaign_start_time = os.clock()
            core:add_listener("Wh3McpCampaignStarted", "WorldCreated", true,
                function()
                    debug_log("WorldCreated fired — campaign continued")
                    campaign_start_pending = false
                    core:remove_listener("Wh3McpCampaignStarted")
                end, false)
            return nil
        else
            debug_log("continue_campaign failed: " .. tostring(err))
            return { status = "error", error = "continue_campaign failed: " .. tostring(err) }
        end

    elseif cmd == "log_clicks" then
        -- Register a listener that logs all UI clicks to debug log
        local duration = params.duration or 30  -- seconds to listen
        debug_log("log_clicks: listening for clicks for " .. duration .. "s")
        local start = os.clock()
        -- Register a one-shot listener for ComponentLClickUp
        core:add_listener(
            "Wh3McpClickLogger",
            "ComponentLClickUp",
            true,  -- fires on every click
            function(context)
                local comp = UIComponent(context.component)
                local name = ""
                local ok, n = pcall(function() return comp:Id() end)
                if ok then name = n or "(unnamed)" end
                -- Get the full path
                local path = name
                local parent = comp
                for _ = 1, 5 do
                    local ok2, p = pcall(function() return parent:Parent() end)
                    if ok2 and p then
                        local pname = ""
                        local ok3, pn = pcall(function() return p:Id() end)
                        if ok3 then pname = pn or "" end
                        if pname ~= "" then
                            path = pname .. " > " .. path
                        end
                        parent = p
                    else break end
                end
                debug_log("CLICK: " .. path)
            end,
            false  -- one-shot (fires once then removed)
        )
        -- Set a timer to remove the listener after duration
        local tm = core:get_tm()
        if tm then
            tm:callback(function()
                core:remove_listener("Wh3McpClickLogger")
                debug_log("log_clicks: stopped listening")
            end, duration * 1000)
        end
        return { status = "ok", result = { listening = true, duration = duration } }

    elseif cmd == "click_ui" then
        -- Click a UI component by path (for debugging)
        local path = params.path
        if not path or #path == 0 then
            return { status = "error", error = "missing path array" }
        end
        local uic = find_uicomponent(unpack(path))
        -- If child_index is specified, click that child instead
        if uic and params.child_index ~= nil then
            local idx = params.child_index
            local ok, child = pcall(function() return UIComponent(uic:Find(idx)) end)
            if ok and child then
                child:SimulateLClick()
                debug_log("click_ui: clicked child " .. idx .. " of " .. table.concat(path, " > "))
                return { status = "ok", result = { clicked = "child_" .. idx .. "_of_" .. table.concat(path, " > ") } }
            else
                debug_log("click_ui: child " .. idx .. " not found in " .. table.concat(path, " > "))
                return { status = "error", error = "child " .. idx .. " not found" }
            end
        elseif uic then
            -- Try multiple activation methods
            uic:SimulateLClick()
            pcall(function() uic:SetState("selected") end)
            pcall(function() uic:TriggerEvent("click") end)
            debug_log("click_ui: activated " .. table.concat(path, " > "))
            return { status = "ok", result = { clicked = table.concat(path, " > ") } }
        else
            debug_log("click_ui: NOT FOUND: " .. table.concat(path, " > "))
            return { status = "error", error = "component not found: " .. table.concat(path, " > ") }
        end

    elseif cmd == "dump_children" then
        -- Dump children of a specific component
        local path = params.path
        if not path or #path == 0 then
            return { status = "error", error = "missing path" }
        end
        local uic = find_uicomponent(unpack(path))
        -- If child_index is specified, use that child instead
        if uic and params.child_index ~= nil then
            local ok, child = pcall(function() return UIComponent(uic:Find(params.child_index)) end)
            if ok and child then uic = child end
        end
        if not uic then
            return { status = "error", error = "component not found" }
        end
        local ok, cc = pcall(function() return uic:ChildCount() end)
        if not ok then cc = 0 end
        debug_log("=== Children of " .. table.concat(path, " > ") .. " (" .. (cc or 0) .. " children) ===")
        if cc and cc > 0 then
            for i = 0, cc - 1 do
                local ok2, child = pcall(function() return UIComponent(uic:Find(i)) end)
                if ok2 and child then
                    local name = ""
                    local ok3, n = pcall(function() return child:Id() end)
                    if ok3 then name = n or "(unnamed)" end
                    debug_log("  [" .. i .. "] " .. name)
                end
            end
        end
        debug_log("=== End children ===")
        return { status = "ok", result = { child_count = cc } }

    elseif cmd == "list_ui" then
        -- Dump the UI component tree to the debug log, optionally a subtree only
        -- and optionally returned inline as a string.
        local start_uic = nil
        local start_path = "(root)"
        if params.path and #params.path > 0 then
            start_uic = find_uicomponent(unpack(params.path))
            start_path = table.concat(params.path, " > ")
            if not start_uic then
                return { status = "error", error = "component not found: " .. start_path }
            end
        else
            start_uic = core:get_ui_root()
        end
        if not start_uic then
            debug_log("list_ui: no UI root")
            return { status = "ok", result = { count = 0 } }
        end
        local max_depth = params.max_depth or 12
        local visible_only = params.visible_only and true or false
        local lines = collect_tree(start_uic, max_depth, visible_only)
        debug_log("=== UI Tree " .. start_path .. " (depth<=" .. max_depth ..
                  (visible_only and ", visible only" or "") .. ") ===")
        for i = 1, #lines do
            debug_log(lines[i])
        end
        debug_log("=== End UI Tree ===")
        local result = {
            dumped = true,
            path = start_path,
            lines = #lines,
            max_depth = max_depth,
            visible_only = visible_only,
        }
        if params.return_tree then
            local tree = table.concat(lines, "\n")
            if #tree > 200000 then
                tree = tree:sub(1, 200000)
                result.truncated = true
            end
            result.tree = tree
        end
        return { status = "ok", result = result }

    elseif cmd == "take_screenshot" then
        local filename = params.filename or "wh3_mcp_screenshot.tga"
        local ok, err = pcall(function()
            common.take_screenshot(filename)
        end)
        if ok then
            debug_log("Screenshot taken: " .. filename)
            return { status = "ok", result = { filename = filename } }
        else
            return { status = "error", error = "screenshot failed: " .. tostring(err) }
        end

    elseif cmd == "get_treasury" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local faction = get_local_faction()
        if not faction then return { status = "error", error = "no local faction" } end
        local ok, treasury = pcall(function() return faction:treasury() end)
        if ok then return { status = "ok", result = { treasury = treasury } }
        else return { status = "error", error = tostring(treasury) } end

    elseif cmd == "save_game" then
        -- Save the game via UI: open menu, click save, type name, confirm.
        -- Pass the name RAW: the game appends its own ".<id>.save" suffix, so
        -- adding ".save" here produced files like "name.save.11293940210.save".
        local filename = params.filename or "wh3_mcp_autosave"

        -- Step 1: Click menu button to open the escape menu
        local menu_btn = find_uicomponent("menu_bar", "button_menu")
        if not menu_btn then
            menu_btn = find_uicomponent("button_menu")
        end
        if menu_btn then
            menu_btn:SimulateLClick()
            debug_log("save_game: clicked menu button")
        end

        -- Step 2: Click the Save button in the escape menu
        local save_btn = find_uicomponent("esc_menu", "menu_left", "menu_buttons", "button_save")
        if save_btn then
            save_btn:SimulateLClick()
            debug_log("save_game: clicked save button in menu")
        end

        -- Step 3: Set the filename in the save panel
        local input_name = find_uicomponent("save_game_panel", "centre_docker", "body", "map_save_parent", "save_panel", "filename_panel", "input_name")
        if input_name then
            pcall(function() input_name:SetText(filename, "") end)
            pcall(function() input_name:SetStateText(filename, "") end)
            debug_log("save_game: set filename to " .. filename)
        else
            debug_log("save_game: input_name not found, trying alternative path")
            -- Try alternative: maybe the save panel is directly accessible
            local alt_input = find_uicomponent("input_name")
            if alt_input then
                pcall(function() alt_input:SetText(filename, "") end)
                debug_log("save_game: set filename via alt path")
            end
        end

        -- Step 4: Click the confirm save button
        local confirm_btn = find_uicomponent("save_game_panel", "footer", "button_holder", "list", "button_confirm_save")
        if confirm_btn then
            confirm_btn:SimulateLClick()
            debug_log("save_game: clicked confirm save")
            -- Step 5: An existing name raises an overwrite confirmation dialog.
            local overwrite_confirmed = false
            local dialog_text = nil
            if params.overwrite ~= false then
                local box, text = get_visible_dialogue_box()
                if box then
                    dialog_text = text
                    local clicked = click_dialog_button(box, "confirm")
                    if clicked then
                        overwrite_confirmed = true
                        debug_log("save_game: confirmed overwrite dialog via " .. clicked)
                    end
                end
            end
            -- Step 6: The esc menu stays open behind the save panel; close it so
            -- the campaign is interactive again (verified live: an end_turn sent
            -- while the menu is open stalls until the menu closes).
            local menu_closed = false
            local resume_btn = find_uicomponent("esc_menu", "main", "menu_left", "menu_buttons",
                                                "holder_resume_concede", "frame_resume", "button_resume")
            if resume_btn and uic_visible(resume_btn) then
                safe_click(resume_btn)
                menu_closed = true
                debug_log("save_game: closed esc menu via button_resume")
            end
            return { status = "ok", result = {
                filename = filename,
                method = "ui_save",
                overwrite_confirmed = overwrite_confirmed,
                dialog = dialog_text,
                menu_closed = menu_closed,
            } }
        else
            debug_log("save_game: confirm_save button not found")
            return { status = "error", error = "save button not found" }
        end

    elseif cmd == "quick_save" then
        -- cm:save() takes no filename; the engine picks one. Named saves are
        -- UI-only (see save_game).
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local ok, err = pcall(function() cm:save() end)
        if not ok then
            return { status = "error", error = "cm:save failed: " .. tostring(err) }
        end
        debug_log("quick_save: cm:save() requested")
        return { status = "ok", result = {
            save_requested = true,
            note = "unnamed engine save; verify via saves list",
        } }

    elseif cmd == "probe_cm" then
        -- Enumerate available methods on cm and core related to saving
        local results = {}
        if cm then
            for k, v in pairs(cm) do
                if type(v) == "function" and tostring(k):lower():match("save") then
                    results["cm_" .. tostring(k)] = type(v)
                end
            end
        end
        if core then
            for k, v in pairs(core) do
                if type(v) == "function" and tostring(k):lower():match("save") then
                    results["core_" .. tostring(k)] = type(v)
                end
            end
        end
        for k, v in pairs(results) do
            debug_log("probe_cm: " .. k .. " = " .. tostring(v))
        end
        if not next(results) then
            debug_log("probe_cm: no save-related methods found on cm or core")
        end
        return { status = "ok", result = results }

    elseif cmd == "list_races" then
        -- List all available races from the race selection popup
        local race_list = find_uicomponent("button_select_race", "popup_menu", "content", "listview", "list_clip", "culture_list")
        if not race_list then
            return { status = "error", error = "race list component not found (are you on campaign select screen?)" }
        end
        local ok, cc = pcall(function() return race_list:ChildCount() end)
        if not ok or not cc then
            return { status = "error", error = "could not get race list child count" }
        end
        local races = {}
        for i = 0, cc - 1 do
            local ok2, child = pcall(function() return UIComponent(race_list:Find(i)) end)
            if ok2 and child then
                local name = ""
                local ok3, n = pcall(function() return child:Id() end)
                if ok3 then name = n or "" end
                -- Skip template entries
                if name ~= "" and name ~= "template_race" then
                    -- Extract the culture key from the Cco ID (remove numeric suffix)
                    local key = name
                    local key_ok, key_name = pcall(function()
                        return name:match("CcoCultureRecord(.+)") or name
                    end)
                    if key_ok and key_name then key = key_name end
                    -- Check if this race has a race_button child (clickable)
                    local has_button = false
                    local ok4, btn = pcall(function() return UIComponent(child:Find("race_button")) end)
                    if ok4 and btn then has_button = true end
                    races[#races + 1] = {
                        index = i,
                        id = name,
                        key = key,
                        has_button = has_button,
                    }
                end
            end
        end
        return { status = "ok", result = { races = races, count = #races } }

    elseif cmd == "list_lords" then
        -- List all available lords for the currently selected race
        local lord_box = find_uicomponent("lord_select_list", "list", "list_clip", "list_box")
        if not lord_box then
            return { status = "error", error = "lord list component not found (are you on campaign select screen?)" }
        end
        local ok, cc = pcall(function() return lord_box:ChildCount() end)
        if not ok or not cc then
            return { status = "error", error = "could not get lord list child count" }
        end
        local lords = {}
        for i = 0, cc - 1 do
            local ok2, child = pcall(function() return UIComponent(lord_box:Find(i)) end)
            if ok2 and child then
                local name = ""
                local ok3, n = pcall(function() return child:Id() end)
                if ok3 then name = n or "" end
                if name ~= "" and name ~= "template_lord" then
                    local key = name
                    local key_ok, key_name = pcall(function()
                        local raw = name:match("CcoFrontendFactionLeader(.+)") or name
                        -- Strip trailing numeric suffix (e.g. "wh3_main_ksl_ursun_revivalists328186000" -> "wh3_main_ksl_ursun_revivalists")
                        return raw:gsub("%d+$", "")
                    end)
                    if key_ok and key_name then key = key_name end
                    -- Check if this lord has a lord_button child (clickable)
                    local has_button = false
                    local ok4, btn = pcall(function() return UIComponent(child:Find("lord_button")) end)
                    if ok4 and btn then has_button = true end
                    lords[#lords + 1] = {
                        index = i,
                        id = name,
                        key = key,
                        has_button = has_button,
                    }
                end
            end
        end
        return { status = "ok", result = { lords = lords, count = #lords } }

    elseif cmd == "select_race" then
        -- Select a race by culture key or index
        local culture_key = params.culture_key
        local index = params.index
        if not culture_key and index == nil then
            return { status = "error", error = "provide either culture_key or index" }
        end
        local race_list = find_uicomponent("button_select_race", "popup_menu", "content", "listview", "list_clip", "culture_list")
        if not race_list then
            return { status = "error", error = "race list not found" }
        end
        local target_child = nil
        local target_index = -1
        if culture_key then
            -- Find by culture key prefix (match CcoCultureRecord<key>*)
            local ok, cc = pcall(function() return race_list:ChildCount() end)
            if ok and cc then
                for i = 0, cc - 1 do
                    local ok2, child = pcall(function() return UIComponent(race_list:Find(i)) end)
                    if ok2 and child then
                        local name = ""
                        local ok3, n = pcall(function() return child:Id() end)
                        if ok3 then name = n or "" end
                        if name:find("CcoCultureRecord" .. culture_key) then
                            target_child = child
                            target_index = i
                            break
                        end
                    end
                end
            end
        else
            -- Find by index
            local ok, child = pcall(function() return UIComponent(race_list:Find(index)) end)
            if ok and child then
                target_child = child
                target_index = index
            end
        end
        if not target_child then
            return { status = "error", error = "race not found: " .. tostring(culture_key or index) }
        end
        -- Click the race_button inside the entry
        local ok, btn = pcall(function() return UIComponent(target_child:Find("race_button")) end)
        if ok and btn then
            btn:SimulateLClick()
            pcall(function() btn:SetState("selected") end)
            pcall(function() btn:TriggerEvent("click") end)
            debug_log("select_race: selected race " .. (culture_key or "index " .. tostring(index)) .. " at index " .. target_index)
            return { status = "ok", result = { selected = culture_key or "index_" .. tostring(index), index = target_index } }
        else
            return { status = "error", error = "race_button not found inside " .. tostring(culture_key or index) }
        end

    elseif cmd == "select_lord" then
        -- Select a lord by faction key or index
        local faction_key = params.faction_key
        local index = params.index
        if not faction_key and index == nil then
            return { status = "error", error = "provide either faction_key or index" }
        end
        local lord_box = find_uicomponent("lord_select_list", "list", "list_clip", "list_box")
        if not lord_box then
            return { status = "error", error = "lord list not found" }
        end
        local target_child = nil
        local target_index = -1
        if faction_key then
            -- Find by faction key prefix (match CcoFrontendFactionLeader<key>*)
            local ok, cc = pcall(function() return lord_box:ChildCount() end)
            if ok and cc then
                for i = 0, cc - 1 do
                    local ok2, child = pcall(function() return UIComponent(lord_box:Find(i)) end)
                    if ok2 and child then
                        local name = ""
                        local ok3, n = pcall(function() return child:Id() end)
                        if ok3 then name = n or "" end
                        if name:find("CcoFrontendFactionLeader" .. faction_key) then
                            target_child = child
                            target_index = i
                            break
                        end
                    end
                end
            end
        else
            -- Find by index
            local ok, child = pcall(function() return UIComponent(lord_box:Find(index)) end)
            if ok and child then
                target_child = child
                target_index = index
            end
        end
        if not target_child then
            return { status = "error", error = "lord not found: " .. tostring(faction_key or index) }
        end
        -- Click the lord_button inside the entry
        local ok, btn = pcall(function() return UIComponent(target_child:Find("lord_button")) end)
        if ok and btn then
            btn:SimulateLClick()
            pcall(function() btn:SetState("selected") end)
            pcall(function() btn:TriggerEvent("click") end)
            debug_log("select_lord: selected lord " .. (faction_key or "index " .. tostring(index)) .. " at index " .. target_index)
            return { status = "ok", result = { selected = faction_key or "index_" .. tostring(index), index = target_index } }
        else
            return { status = "error", error = "lord_button not found inside " .. tostring(faction_key or index) }
        end

    elseif cmd == "new_game" then
        -- Click Campaign button, then schedule New Campaign click after 2s delay
        local btn = find_uicomponent("button_campaign")
        if not btn then
            return { status = "error", error = "button_campaign not found (not on main menu?)" }
        end
        btn:SimulateLClick()
        pcall(function() btn:SetState("selected") end)
        debug_log("new_game: clicked button_campaign (scheduling new_campaign in 2s)")
        local tm = core:get_tm()
        if tm then
            tm:callback(function()
                local btn2 = find_uicomponent("button_start_campaign_new")
                if btn2 then
                    btn2:SimulateLClick()
                    debug_log("new_game: clicked button_start_campaign_new (delayed)")
                else
                    debug_log("new_game: button_start_campaign_new not found after delay")
                end
            end, 2000)
        end
        return { status = "ok", result = { action = "new_game" } }

    elseif cmd == "select_campaign" then
        -- Select a campaign type by name
        local campaign_type = params.campaign_type
        if not campaign_type then
            return { status = "error", error = "provide campaign_type: prologue, roc, or ie" }
        end
        if campaign_type == "prologue" then
            local btn = find_uicomponent("button_prologue")
            if btn then
                btn:SimulateLClick()
                debug_log("select_campaign: selected prologue")
                return { status = "ok", result = { campaign = "prologue" } }
            else
                return { status = "error", error = "button_prologue not found" }
            end
        elseif campaign_type == "ie" or campaign_type == "immortal_empires" then
            local list_parent = find_uicomponent("list_parent")
            if not list_parent then return { status = "error", error = "list_parent not found" } end
            local ok, cc = pcall(function() return list_parent:ChildCount() end)
            if ok and cc then
                for i = 0, cc - 1 do
                    local ok2, child = pcall(function() return UIComponent(list_parent:Find(i)) end)
                    if ok2 and child then
                        local name = ""
                        local ok3, n = pcall(function() return child:Id() end)
                        if ok3 then name = n or "" end
                        if name:find("CcoCampaignMapPlayableAreaRecord861366624") then
                            local ok4, entry_btn = pcall(function() return UIComponent(child:Find("button_campaign_entry")) end)
                            if ok4 and entry_btn then
                                entry_btn:SimulateLClick()
                                debug_log("select_campaign: selected IE")
                                return { status = "ok", result = { campaign = "ie" } }
                            end
                        end
                    end
                end
            end
            return { status = "error", error = "IE campaign entry not found in list_parent" }
        elseif campaign_type == "roc" or campaign_type == "realm_of_chaos" then
            local list_parent = find_uicomponent("list_parent")
            if not list_parent then return { status = "error", error = "list_parent not found" } end
            local ok, cc = pcall(function() return list_parent:ChildCount() end)
            if ok and cc then
                for i = 0, cc - 1 do
                    local ok2, child = pcall(function() return UIComponent(list_parent:Find(i)) end)
                    if ok2 and child then
                        local name = ""
                        local ok3, n = pcall(function() return child:Id() end)
                        if ok3 then name = n or "" end
                        if name:find("CcoCampaignMapPlayableAreaRecord1247591265") then
                            local ok4, entry_btn = pcall(function() return UIComponent(child:Find("button_campaign_entry")) end)
                            if ok4 and entry_btn then
                                entry_btn:SimulateLClick()
                                debug_log("select_campaign: selected RoC")
                                return { status = "ok", result = { campaign = "roc" } }
                            end
                        end
                    end
                end
            end
            return { status = "error", error = "RoC campaign entry not found in list_parent" }
        else
            return { status = "error", error = "unknown campaign_type: " .. tostring(campaign_type) }
        end

    elseif cmd == "get_screen" then
        -- Detect what screen we're on by checking for specific UI components
        local screen = "unknown"
        local details = {}
        if in_campaign() then
            screen = "campaign"
            local faction = get_local_faction()
            if faction then
                local ok, name = pcall(function() return faction:name() end)
                if ok then details.faction = name end
            end
            local ok, turn = pcall(function() return cm:turn_number() end)
            if ok then details.turn = turn end
            details.is_players_turn = sf(function() return cm:is_local_players_turn() end)
            -- esc_menu exists but goes hidden behind the quit dialog, so test
            -- visibility rather than existence.
            details.esc_menu_open = uic_visible(find_uicomponent("esc_menu"))
            -- Panel: ask the UI manager first, fall back to the verified root
            -- components that only exist while their panel is open.
            local panel_key = detect_open_panel_key()
            details.panel_open = get_open_panel() or (panel_key and PANELS[panel_key].root) or nil
            details.panel_key = panel_key
            local _, dialog_text = get_visible_dialogue_box()
            details.dialog = dialog_text
            details.saving = uic_visible(find_uicomponent("saving_icon"))
        elseif find_uicomponent("load_save_game") then
            screen = "load_game"
            -- List playthroughs
            local pt_list = find_uicomponent("load_save_game", "centre_docker", "body", "playthroughs", "playthrough_list", "list_clip", "list_box")
            if pt_list then
                local ok, cc = pcall(function() return pt_list:ChildCount() end)
                if ok and cc then
                    local playthroughs = {}
                    for i = 0, cc - 1 do
                        local ok2, pt = pcall(function() return UIComponent(pt_list:Find(i)) end)
                        if ok2 and pt then
                            local name = ""
                            local ok3, n = pcall(function() return pt:Id() end)
                            if ok3 then name = n or "" end
                            if name ~= "" then
                                -- Get campaign and faction info using GetStateText()
                                local campaign = ""
                                local faction = ""
                                local center = UIComponent(pt:Find("center"))
                                if center then
                                    local camp = UIComponent(center:Find("dy_campaign"))
                                    if camp then
                                        local ok4, txt = pcall(function() return camp:GetStateText() end)
                                        if ok4 then campaign = tostring(txt) end
                                    end
                                    local fac = UIComponent(center:Find("dy_faction"))
                                    if fac then
                                        local ok5, txt = pcall(function() return fac:GetStateText() end)
                                        if ok5 then faction = tostring(txt) end
                                    end
                                end
                                playthroughs[#playthroughs + 1] = {
                                    index = i,
                                    id = name,
                                    campaign = campaign,
                                    faction = faction,
                                }
                            end
                        end
                    end
                    details.playthroughs = playthroughs
                    details.playthrough_count = #playthroughs
                end
            end
            -- List save games in the current playthrough
            local save_list = find_uicomponent("load_save_game", "centre_docker", "body", "savegames", "listview", "list_clip", "list_box")
            if save_list then
                local ok, cc = pcall(function() return save_list:ChildCount() end)
                if ok and cc then
                    local saves = {}
                    for i = 0, cc - 1 do
                        local ok2, sg = pcall(function() return UIComponent(save_list:Find(i)) end)
                        if ok2 and sg then
                            local name = ""
                            local ok3, n = pcall(function() return sg:Id() end)
                            if ok3 then name = n or "" end
                            if name ~= "" then
                                -- Get save name and turn using GetStateText()
                                local save_name = ""
                                local turn = ""
                                local name_comp = UIComponent(sg:Find("name"))
                                if name_comp then
                                    local ok4, txt = pcall(function() return name_comp:GetStateText() end)
                                    if ok4 and txt then save_name = tostring(txt) end
                                end
                                local turn_comp = UIComponent(sg:Find("turn"))
                                if turn_comp then
                                    local ok5, txt = pcall(function() return turn_comp:GetStateText() end)
                                    if ok5 and txt then turn = tostring(txt) end
                                end
                                saves[#saves + 1] = {
                                    index = i,
                                    id = name,
                                    name = save_name,
                                    turn = turn,
                                }
                            end
                        end
                    end
                    details.saves = saves
                    details.save_count = #saves
                end
            end
        elseif find_uicomponent("campaign_select_new") then
            -- We are on the campaign select screen. Determine which sub-tab is active.
            -- Check if lord_select_list has actual lord entries (non-template)
            local lord_box = find_uicomponent("lord_select_list", "list", "list_clip", "list_box")
            local has_lords = false
            if lord_box then
                local ok, cc = pcall(function() return lord_box:ChildCount() end)
                if ok and cc and cc > 1 then
                    has_lords = true
                end
            end
            -- Check if campaign list has actual campaign entries (non-template)
            local has_campaigns = false
            local list_parent = find_uicomponent("list_parent")
            if list_parent then
                local ok, cc = pcall(function() return list_parent:ChildCount() end)
                if ok and cc and cc > 2 then
                    has_campaigns = true
                end
            end
            if has_lords then
                screen = "lord_select"
                local race_list = find_uicomponent("button_select_race", "popup_menu", "content", "listview", "list_clip", "culture_list")
                if race_list then
                    local ok, cc = pcall(function() return race_list:ChildCount() end)
                    if ok and cc and cc > 1 then
                        details.races_available = true
                    end
                end
            elseif has_campaigns then
                screen = "campaign_select"
            else
                -- Just entered campaign select, data not loaded yet
                screen = "campaign_select"
                details.loading = true
            end
        elseif find_uicomponent("button_start_campaign_new") then
            screen = "campaign_submenu"  -- campaign submenu open (New/Load)
        elseif find_uicomponent("button_campaign") then
            screen = "main_menu"
        else
            screen = "unknown"
        end
        return { status = "ok", result = { screen = screen, details = details } }

    elseif cmd == "select_playthrough" then
        -- Select a playthrough by index
        local index = params.index
        if index == nil then
            return { status = "error", error = "provide index parameter" }
        end
        local pt_box = find_uicomponent("load_save_game", "centre_docker", "body", "playthroughs", "playthrough_list", "list_clip", "list_box")
        if not pt_box then
            return { status = "error", error = "playthrough list not found (not on load_game screen?)" }
        end
        local ok, pt = pcall(function() return UIComponent(pt_box:Find(index)) end)
        if ok and pt then
            pt:SimulateLClick()
            pcall(function() pt:SetState("selected") end)
            pcall(function() pt:TriggerEvent("click") end)
            debug_log("select_playthrough: selected playthrough at index " .. index)
            return { status = "ok", result = { selected_index = index } }
        else
            return { status = "error", error = "playthrough at index " .. index .. " not found" }
        end

    elseif cmd == "select_save" then
        -- Select a save game by index or name
        local index = params.index
        local name = params.name
        if index == nil and not name then
            return { status = "error", error = "provide either index or name parameter" }
        end
        local save_box = find_uicomponent("load_save_game", "centre_docker", "body", "savegames", "listview", "list_clip", "list_box")
        if not save_box then
            return { status = "error", error = "save list not found (not on load_game screen?)" }
        end
        local target = nil
        local target_index = -1
        if name then
            -- Find by save name (text in the "name" child)
            local ok, cc = pcall(function() return save_box:ChildCount() end)
            if ok and cc then
                for i = 0, cc - 1 do
                    local ok2, sg = pcall(function() return UIComponent(save_box:Find(i)) end)
                    if ok2 and sg then
                        local ok3, name_comp = pcall(function() return UIComponent(sg:Find("name")) end)
                        if ok3 and name_comp then
                            -- GetText() does not exist on WH3 uicomponents; the
                            -- readable-text method is GetStateText().
                            local ok4, txt = pcall(function() return name_comp:GetStateText() end)
                            if ok4 and txt and type(txt) == "string" and plain_find(txt, name) then
                                target = sg
                                target_index = i
                                break
                            end
                        end
                    end
                end
            end
        else
            local ok, sg = pcall(function() return UIComponent(save_box:Find(index)) end)
            if ok and sg then
                target = sg
                target_index = index
            end
        end
        if not target then
            return { status = "error", error = "save not found: " .. tostring(name or index) }
        end
        target:SimulateLClick()
        pcall(function() target:SetState("selected") end)
        pcall(function() target:TriggerEvent("click") end)
        debug_log("select_save: selected save at index " .. target_index .. (name and (" (" .. name .. ")") or ""))
        return { status = "ok", result = { selected_index = target_index, name = name } }

    elseif cmd == "probe_text" then
        -- Probe available methods on UIComponent by enumerating metatable
        local results = {}
        local save_box = find_uicomponent("load_save_game", "centre_docker", "body", "savegames", "listview", "list_clip", "list_box")
        if save_box then
            local sg = UIComponent(save_box:Find(0))
            if sg then
                local name_comp = UIComponent(sg:Find("name"))
                if name_comp then
                    local mt = getmetatable(name_comp)
                    if mt and mt.__index then
                        for k, v in pairs(mt.__index) do
                            results["method_" .. tostring(k)] = type(v)
                        end
                    end
                    local ok1, v1 = pcall(function() return name_comp:GetStateText() end)
                    results["GetStateText"] = { ok = ok1, val = tostring(v1) }
                end
            end
        end
        for k, v in pairs(results) do
            if type(v) == "table" then
                debug_log("probe " .. k .. ": ok=" .. tostring(v.ok) .. " val='" .. tostring(v.val) .. "'")
            else
                debug_log("probe " .. k .. ": " .. tostring(v))
            end
        end
        return { status = "ok", result = results }

    elseif cmd == "confirm_load" then
        -- Click the Confirm Load button
        local btn = find_uicomponent("load_save_game", "footer", "button_holder", "list", "button_confirm_load")
        if not btn then
            return { status = "error", error = "confirm_load button not found" }
        end
        btn:SimulateLClick()
        debug_log("confirm_load: clicked")
        -- Set up pending state for campaign load detection
        campaign_start_pending = true
        campaign_start_params = { method = "confirm_load", is_new_game = false }
        campaign_start_time = os.clock()
        core:add_listener("Wh3McpCampaignStarted", "WorldCreated", true,
            function()
                debug_log("WorldCreated fired — confirm_load campaign loaded")
                campaign_start_pending = false
                core:remove_listener("Wh3McpCampaignStarted")
            end, false)
        return nil  -- deferred response

    -- -----------------------------------------------------------------------
    -- Campaign control: menu, dialogs, quitting
    -- -----------------------------------------------------------------------

    elseif cmd == "open_menu" then
        local btn = find_uicomponent("menu_bar", "buttongroup", "button_menu")
        if not btn then btn = find_uicomponent("menu_bar", "button_menu") end
        if not btn then
            return { status = "error", error = "button_menu not found" }
        end
        safe_click(btn)
        debug_log("open_menu: clicked menu_bar > buttongroup > button_menu")
        local esc = find_uicomponent("esc_menu")
        return { status = "ok", result = {
            menu_open = uic_visible(esc),
            esc_menu_exists = esc ~= nil,
        } }

    elseif cmd == "resume" or cmd == "close_menu" then
        local btn = find_uicomponent("esc_menu", "main", "menu_left", "menu_buttons",
                                     "holder_resume_concede", "frame_resume", "button_resume")
        if not btn then btn = find_uicomponent("esc_menu", "button_resume") end
        if not btn then
            return { status = "error", error = "button_resume not found (esc menu not open?)" }
        end
        safe_click(btn)
        debug_log("resume: clicked button_resume")
        local esc = find_uicomponent("esc_menu")
        return { status = "ok", result = { resumed = not uic_visible(esc) } }

    elseif cmd == "confirm_dialog" or cmd == "cancel_dialog" then
        local which = (cmd == "cancel_dialog") and "cancel" or "confirm"
        local box, text = get_visible_dialogue_box()
        if not box then
            return { status = "error", error = "no visible dialogue_box found" }
        end
        local clicked = click_dialog_button(box, which)
        if not clicked then
            return { status = "error", error = "no " .. which .. " button found in the visible dialog", result = { dialog = text } }
        end
        debug_log(cmd .. ": clicked " .. clicked .. " on dialog: " .. tostring(text))
        return { status = "ok", result = { action = which, clicked = clicked, dialog = text } }

    elseif cmd == "quit_to_menu" or cmd == "exit_to_windows" then
        if quit_pending then
            return { status = "error", error = "a quit sequence is already running" }
        end
        if not in_campaign() then
            return { status = "error", error = "not in a campaign" }
        end
        -- Opening the quit dialog auto-hides the esc menu, so open it first if
        -- it is not already on screen.
        local esc = find_uicomponent("esc_menu")
        if not uic_visible(esc) then
            local menu_btn = find_uicomponent("menu_bar", "buttongroup", "button_menu")
            if not menu_btn then menu_btn = find_uicomponent("menu_bar", "button_menu") end
            if not menu_btn then
                return { status = "error", error = "button_menu not found" }
            end
            safe_click(menu_btn)
            debug_log(cmd .. ": opened esc menu")
        end
        quit_pending = true
        quit_mode = (cmd == "exit_to_windows") and "windows" or "menu"
        quit_stage = "click_quit"
        quit_ticks = 0
        debug_log(cmd .. ": sequence started (mode " .. quit_mode .. ")")
        return nil  -- deferred; the poll loop drives the rest

    -- -----------------------------------------------------------------------
    -- Turn and HUD
    -- -----------------------------------------------------------------------

    elseif cmd == "end_turn" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local method = params.method or "api"
        local force = params.force and true or false
        local turn_before = sf(function() return cm:turn_number() end)
        local is_players_turn = sf(function() return cm:is_local_players_turn() end)
        if method == "ui" then
            local btn = find_uicomponent("hud_campaign", "faction_buttons_docker", "end_turn_docker", "button_end_turn")
            if not btn then btn = find_uicomponent("button_end_turn") end
            if not btn then
                return { status = "error", error = "button_end_turn not found" }
            end
            safe_click(btn)
            debug_log("end_turn: clicked button_end_turn (turn " .. tostring(turn_before) .. ")")
        else
            local ok, err = pcall(function() cm:end_turn(force) end)
            if not ok then
                return { status = "error", error = "cm:end_turn failed: " .. tostring(err) }
            end
            debug_log("end_turn: cm:end_turn(" .. tostring(force) .. ") called (turn " .. tostring(turn_before) .. ")")
        end
        -- Verified live: an end turn requested while the esc menu is open does
        -- not run until the menu closes. Surface that so the agent can resume.
        local esc_open = uic_visible(find_uicomponent("esc_menu"))
        return { status = "ok", result = {
            turn_before = turn_before,
            method = method,
            force = force,
            is_players_turn = is_players_turn,
            esc_menu_open = esc_open,
            note = esc_open
                and "ESC MENU IS OPEN — the end turn stalls until it closes; send resume"
                or "turn advance is asynchronous; poll get_status for the new turn number",
        } }

    elseif cmd == "get_hud" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local result = {
            turn = get_text(find_uicomponent("hud_campaign", "faction_buttons_docker", "end_turn_docker", "label_turn_count")),
            notification = get_text(find_uicomponent("hud_campaign", "faction_buttons_docker", "end_turn_docker", "notification_frame", "dy_notification")),
            radial = {},
            menu_bar = {},
            end_turn_visible = uic_visible(find_uicomponent("hud_campaign", "faction_buttons_docker", "end_turn_docker", "button_end_turn")),
            open_panel = get_open_panel(),
            panel_key = detect_open_panel_key(),
        }
        local group = find_uicomponent("hud_campaign", "faction_buttons_docker", "button_group_management")
        if group then
            local cc = sf(function() return group:ChildCount() end) or 0
            for i = 0, cc - 1 do
                local ok, child = pcall(function() return UIComponent(group:Find(i)) end)
                if ok and child then
                    local id = sf(function() return child:Id() end)
                    if id and id ~= "" then
                        result.radial[#result.radial + 1] = { id = id, visible = uic_visible(child) }
                    end
                end
            end
        end
        local bar = find_uicomponent("menu_bar", "buttongroup")
        if bar then
            local cc = sf(function() return bar:ChildCount() end) or 0
            for i = 0, cc - 1 do
                local ok, child = pcall(function() return UIComponent(bar:Find(i)) end)
                if ok and child then
                    local id = sf(function() return child:Id() end)
                    if id and id ~= "" then
                        result.menu_bar[#result.menu_bar + 1] = id
                    end
                end
            end
        end
        return { status = "ok", result = result }

    -- -----------------------------------------------------------------------
    -- Panels
    -- -----------------------------------------------------------------------

    elseif cmd == "open_panel" then
        local panel = params.panel
        if not panel then
            return { status = "error", error = "missing panel parameter (technology, diplomacy, missions, factions)" }
        end
        local def = PANELS[panel]
        if not def then
            return { status = "error", error = "unknown panel: " .. tostring(panel) }
        end
        local path = table.concat(def.open, " > ")
        local btn = find_uicomponent(unpack(def.open))
        if not btn then
            return { status = "error", error = "button not found: " .. path }
        end
        safe_click(btn)
        debug_log("open_panel: clicked " .. path)
        return { status = "ok", result = {
            panel = panel,
            clicked = path,
            expected_root = def.root,
            open_panel = get_open_panel(),
            note = "the panel needs a frame to open; poll get_screen or get_hud to confirm",
        } }

    elseif cmd == "close_panel" then
        local panel = params.panel
        if not panel then panel = detect_open_panel_key() end
        local def = panel and PANELS[panel] or nil
        if panel and not def then
            return { status = "error", error = "unknown panel: " .. tostring(panel) }
        end
        -- Route 1: the documented API. Only technology_panel's name is
        -- confirmed, so for every other panel ask the UI manager which panel is
        -- open and close that by name.
        local target = def and def.api_name or nil
        if not target then target = get_open_panel() end
        local method, closed = nil, false
        -- The API cannot toggle a panel that has no close concept; missions
        -- still gets the attempt, then falls through to the toggle click.
        if target then
            local ok = pcall(function() CampaignUI.ClosePanel(target) end)
            if ok then
                method = "CampaignUI.ClosePanel(" .. target .. ")"
                local still_open = is_panel_open(target)
                if still_open == false then
                    closed = true
                elseif still_open == nil and def then
                    closed = find_root_child(def.root) == nil
                end
                debug_log("close_panel: " .. method .. " -> closed=" .. tostring(closed))
            end
        end
        -- Route 2: the panel's own verified close button (a toggle re-click for
        -- missions, which has no close button).
        if not closed and def then
            local btn = find_uicomponent(unpack(def.close))
            if btn and safe_click(btn) then
                method = table.concat(def.close, " > ") .. (def.close_is_toggle and " (toggle)" or "")
                closed = find_root_child(def.root) == nil
                debug_log("close_panel: clicked " .. method .. " -> closed=" .. tostring(closed))
            end
        end
        if not method then
            return { status = "error", error = "no way found to close panel: " .. tostring(panel or "none open") }
        end
        return { status = "ok", result = {
            panel = panel,
            target = target,
            method = method,
            closed = closed,
            open_panel = get_open_panel(),
            note = "closed=false may just mean the panel needs a frame to disappear; re-check with get_screen",
        } }

    -- -----------------------------------------------------------------------
    -- Camera
    -- -----------------------------------------------------------------------

    elseif cmd == "get_camera" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local pos = read_camera()
        if not pos then
            return { status = "error", error = "cm:get_camera_position() unavailable" }
        end
        return { status = "ok", result = pos }

    elseif cmd == "set_camera" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local cur = read_camera()
        if not cur then
            return { status = "error", error = "cm:get_camera_position() unavailable" }
        end
        local x = params.x or cur.x
        local y = params.y or cur.y
        local d = params.d or cur.d
        local b = params.b or cur.b
        local h = params.h or cur.h
        local ok, err = pcall(function() cm:set_camera_position(x, y, d, b, h) end)
        if not ok then
            return { status = "error", error = "set_camera_position failed: " .. tostring(err) }
        end
        debug_log("set_camera: " .. x .. "," .. y .. "," .. d .. "," .. b .. "," .. h)
        return { status = "ok", result = { x = x, y = y, d = d, b = b, h = h, previous = cur } }

    elseif cmd == "pan_camera" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local cur = read_camera()
        if not cur then
            return { status = "error", error = "cm:get_camera_position() unavailable" }
        end
        local x = params.x or cur.x
        local y = params.y or cur.y
        local d = params.d or cur.d
        local b = params.b or cur.b
        local h = params.h or cur.h
        local time = params.time or 2
        local ok, err = pcall(function()
            cm:scroll_camera_from_current(false, time, { x, y, d, b, h })
        end)
        if not ok then
            return { status = "error", error = "scroll_camera_from_current failed: " .. tostring(err) }
        end
        debug_log("pan_camera: to " .. x .. "," .. y .. " over " .. time .. "s")
        return { status = "ok", result = { x = x, y = y, d = d, b = b, h = h, time = time, previous = cur } }

    elseif cmd == "zoom_to" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if params.cqi ~= nil then
            local char = sf(function() return cm:get_character_by_cqi(params.cqi) end)
            if not char then
                return { status = "error", error = "no character with cqi " .. tostring(params.cqi) }
            end
            local x = sf(function() return char:display_position_x() end)
            local y = sf(function() return char:display_position_y() end)
            if not x or not y then
                return { status = "error", error = "could not read display position for cqi " .. tostring(params.cqi) }
            end
            local ok, err = pcall(function() CampaignUI.ZoomToSmooth(x, y) end)
            if not ok then
                return { status = "error", error = "CampaignUI.ZoomToSmooth failed: " .. tostring(err) }
            end
            debug_log("zoom_to: cqi " .. tostring(params.cqi) .. " at " .. x .. "," .. y)
            return { status = "ok", result = { cqi = params.cqi, x = x, y = y, method = "CampaignUI.ZoomToSmooth" } }
        elseif params.region then
            local faction = get_local_faction()
            local faction_key = faction and sf(function() return faction:name() end)
            if not faction_key then
                return { status = "error", error = "no local faction" }
            end
            local time = params.time or 2
            local ok, err = pcall(function()
                cm:scroll_camera_to_region(faction_key, params.region, time)
            end)
            if not ok then
                return { status = "error", error = "scroll_camera_to_region failed: " .. tostring(err) }
            end
            debug_log("zoom_to: region " .. tostring(params.region))
            return { status = "ok", result = { region = params.region, faction = faction_key, time = time, method = "cm:scroll_camera_to_region" } }
        else
            return { status = "error", error = "provide either cqi or region" }
        end

    -- -----------------------------------------------------------------------
    -- Armies
    -- -----------------------------------------------------------------------

    elseif cmd == "get_armies" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local faction
        if params.faction then
            faction = sf(function() return cm:get_faction(params.faction) end)
            if not faction then
                return { status = "error", error = "faction not found: " .. tostring(params.faction) }
            end
        else
            faction = get_local_faction()
            if not faction then return { status = "error", error = "no local faction" } end
        end
        local faction_name = sf(function() return faction:name() end)
        local is_turn = sf(function() return faction:is_factions_turn() end)
        local armies = {}
        local ok, err = pcall(function()
            local list = faction:military_force_list()
            if not list then return end
            for i = 0, list:num_items() - 1 do
                local mf = list:item_at(i)
                if mf then
                    local mf_cqi = sf(function() return mf:command_queue_index() end)
                    local units = sf(function() return mf:unit_list():num_items() end)
                    local general = sf(function() return mf:general_character() end)
                    local has_general = false
                    if general then
                        local is_null = sf(function() return general:is_null_interface() end)
                        has_general = (is_null == false)
                    end
                    if has_general then
                        armies[#armies + 1] = {
                            mf_cqi = mf_cqi,
                            char_cqi = sf(function() return general:cqi() end),
                            name = char_display_name(general),
                            subtype = sf(function() return general:character_subtype_key() end),
                            logical = {
                                x = sf(function() return general:logical_position_x() end),
                                y = sf(function() return general:logical_position_y() end),
                            },
                            display = {
                                x = sf(function() return general:display_position_x() end),
                                y = sf(function() return general:display_position_y() end),
                            },
                            units = units,
                            is_home_faction_turn = is_turn,
                        }
                    else
                        armies[#armies + 1] = { mf_cqi = mf_cqi, units = units, no_general = true }
                    end
                end
            end
        end)
        if not ok then
            return { status = "error", error = "military_force_list failed: " .. tostring(err) }
        end
        return { status = "ok", result = {
            faction = faction_name,
            is_factions_turn = is_turn,
            count = #armies,
            armies = armies,
        } }

    elseif cmd == "move_army" or cmd == "teleport_army" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local cqi = params.cqi
        local x, y = params.x, params.y
        local near_settlement = params.near_settlement
        if cqi == nil then return { status = "error", error = "missing cqi parameter" } end
        if (x == nil or y == nil) and not near_settlement then
            return { status = "error", error = "need x+y, or near_settlement (region key)" }
        end
        local lookup = "character_cqi:" .. tostring(cqi)
        if cmd == "teleport_army" then
            -- Raw coords usually FAIL (most tiles are invalid; verified live:
            -- 40+ guessed tiles around a mountain settlement all refused).
            -- The engine's spawn finders return tiles that always work:
            -- near_settlement uses ..._from_settlement, snap (default true)
            -- retries failed raw coords through ..._from_position.
            local faction_key = sf(function() return get_local_faction():name() end)
            local snap = params.snap
            if snap == nil then snap = true end
            local snapped = false
            if near_settlement and faction_key then
                local ok_f, fx, fy = pcall(function()
                    return cm:find_valid_spawn_location_for_character_from_settlement(
                        faction_key, tostring(near_settlement), false, true,
                        tonumber(params.distance) or 2)
                end)
                if ok_f and fx and fx >= 0 then x, y, snapped = fx, fy, true end
                if x == nil then
                    return { status = "error", error = "no valid tile found near " .. tostring(near_settlement) }
                end
            end
            local ok, res = pcall(function() return cm:teleport_to(lookup, x, y) end)
            if not ok then
                return { status = "error", error = "teleport_to failed: " .. tostring(res) }
            end
            if not res and snap and faction_key and not snapped then
                local ok_f, fx, fy = pcall(function()
                    return cm:find_valid_spawn_location_for_character_from_position(
                        faction_key, x, y, true, tonumber(params.distance) or 3)
                end)
                if ok_f and fx and fx >= 0 then
                    local ok2, res2 = pcall(function() return cm:teleport_to(lookup, fx, fy) end)
                    if ok2 and res2 then res, x, y, snapped = res2, fx, fy, true end
                end
            end
            debug_log("teleport_army: " .. lookup .. " -> " .. tostring(x) .. "," .. tostring(y) ..
                      " ok=" .. tostring(res) .. " snapped=" .. tostring(snapped))
            return { status = "ok", result = {
                teleported = res and true or false,
                lookup = lookup, x = x, y = y, snapped = snapped,
                note = "logical coords; only valid on that faction's turn",
            } }
        end
        local queued = params.queued and true or false
        local ok, err = pcall(function()
            if queued then
                cm:move_to_queued(lookup, x, y)
            else
                cm:move_to(lookup, x, y)
            end
        end)
        if not ok then
            return { status = "error", error = "move_to failed: " .. tostring(err) }
        end
        debug_log("move_army: " .. lookup .. " -> " .. x .. "," .. y .. " queued=" .. tostring(queued))
        return { status = "ok", result = {
            ordered = true,
            lookup = lookup, x = x, y = y, queued = queued,
            note = "logical coords; open-terrain pathing; only on own turn",
        } }

    elseif cmd == "select_army" then
        -- EXPERIMENTAL. No scripted select-setter exists in the WH3 API, so this
        -- clicks the army's map plate the way a player would.
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local target_name = params.name
        if not target_name and params.cqi ~= nil then
            local char = sf(function() return cm:get_character_by_cqi(params.cqi) end)
            if not char then
                return { status = "error", error = "no character with cqi " .. tostring(params.cqi) }
            end
            target_name = char_display_name(char)
        end
        if not target_name then
            return { status = "error", error = "provide either cqi or name" }
        end
        pcall(function() CampaignUI.ClearSelection() end)
        local parent = find_uicomponent("3d_ui_parent")
        if not parent then
            return { status = "error", error = "3d_ui_parent not found" }
        end
        local found_label, label_id, matched_text = false, nil, nil
        -- Army plates are named label_<char_cqi>, so a cqi targets its plate
        -- directly without any name matching.
        if params.cqi ~= nil then
            local direct = get_child(parent, "label_" .. tostring(params.cqi))
            if direct then
                found_label = true
                label_id = "label_" .. tostring(params.cqi)
                matched_text = get_text(get_child(direct, "dy_name"))
                safe_click(direct)
                safe_click(get_child(direct, "list_parent"))
                debug_log("select_army: clicked " .. label_id .. " directly")
            end
        end
        local cc = sf(function() return parent:ChildCount() end) or 0
        for i = 0, cc - 1 do
            if found_label then break end
            local ok, label = pcall(function() return UIComponent(parent:Find(i)) end)
            if ok and label then
                local id = sf(function() return label:Id() end)
                -- Some 3d_ui children return a non-string from Id(); guard the
                -- type or the find below indexes a non-string.
                if type(id) ~= "string" then id = "" end
                -- Settlement plates share the same shape; skip them.
                if id ~= "" and not id:find("^label_settlement") then
                    local name_text = get_text(get_child(label, "dy_name"))
                    if name_text and (name_text == target_name or plain_find(name_text, target_name)) then
                        found_label = true
                        label_id = id
                        matched_text = name_text
                        safe_click(label)
                        -- The clickable region is sometimes the inner list_parent.
                        safe_click(get_child(label, "list_parent"))
                        debug_log("select_army: clicked " .. id .. " (" .. name_text .. ")")
                        break
                    end
                end
            end
        end
        return { status = "ok", result = {
            found_label = found_label,
            label_id = label_id,
            matched_text = matched_text,
            searched = target_name,
            experimental = true,
            soft_select = true,
            note = "SOFT/HOVER SELECTION ONLY. Closed question (2026-08-20): WH3 exposes " ..
                   "no scripted hard-select — CampaignUI has ClearSelection and nothing else, " ..
                   "and map plates do not forward clicks to the 3D picker. Commands that need " ..
                   "a target take a cqi instead.",
        } }

    -- -----------------------------------------------------------------------
    -- Battles (campaign side only — never load the battle map)
    -- -----------------------------------------------------------------------

    elseif cmd == "attack" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local attacker_cqi = params.attacker_cqi
        local target_cqi = params.target_cqi
        local target_settlement = params.target_settlement
        if attacker_cqi == nil then return { status = "error", error = "missing attacker_cqi" } end
        if target_cqi == nil and target_settlement == nil then
            return { status = "error", error = "need target_cqi or target_settlement (region key)" }
        end
        local lay_siege = params.lay_siege and true or false
        local attacker = "character_cqi:" .. tostring(attacker_cqi)
        -- Settlements: cm:attack with a "settlement:" lookup is ACCEPTED BUT
        -- NEVER EXECUTES (verified live 2026-08-21, multiple armies and
        -- ranges). cm:attack_region(lookup, region_key) is the working call -
        -- it engaged instantly from 6 tiles.
        local target = target_settlement and tostring(target_settlement)
            or ("character_cqi:" .. tostring(target_cqi))
        -- Long approaches drain action points and the attack then stalls
        -- SILENTLY (verified live: ap hit 0 mid-march). replenish=true refills
        -- first; the result reports the remaining percentage either way.
        if params.replenish then
            pcall(function() cm:replenish_action_points(attacker) end)
        end
        local is_players_turn = sf(function() return cm:is_local_players_turn() end)
        -- The 4th argument is ignore_shroud and defaults to true; pass it
        -- explicitly so an unseen target is still a valid order.
        local ok, err
        if target_settlement then
            ok, err = pcall(function() cm:attack_region(attacker, target) end)
        else
            ok, err = pcall(function() cm:attack(attacker, target, lay_siege, true) end)
        end
        if not ok then
            return { status = "error", error = "attack order failed: " .. tostring(err) }
        end
        debug_log("attack: " .. attacker .. " -> " .. target .. " lay_siege=" .. tostring(lay_siege))
        local ap = sf(function()
            return cm:get_character_by_cqi(tonumber(attacker_cqi)):action_points_remaining_percent()
        end)
        local result = {
            ordered = true,
            attacker = attacker,
            target = target,
            lay_siege = lay_siege,
            is_players_turn = is_players_turn,
            action_points_percent = ap,
            note = "attacker paths on model time; poll get_situation for pre_battle. " ..
                   "Re-issuing the attack RESTARTS pathing; wait instead. A distant target " ..
                   "can drain action points and stall silently - send replenish=true, and a " ..
                   "declare-war prompt surfaces as a move_options blocker in get_situation.",
        }
        if is_players_turn == false then
            result.warning = "NOT the local player's turn — the engine ignores attack orders off-turn"
        end
        return { status = "ok", result = result }

    elseif cmd == "autoresolve_battle" then
        -- Deferred: the results panel needs frames to appear, so the poll loop
        -- drives stages A-C and writes the result (see handle_autoresolve_tick).
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if autoresolve_pending then
            return { status = "error", error = "an autoresolve sequence is already running" }
        end
        local root = find_panel_root("popup_pre_battle")
        if not root then
            return { status = "error", error = "popup_pre_battle is not open — order an attack first" }
        end
        local win = params.win
        if win == nil then win = true end
        local captives = params.captives or "kill"
        if not CAPTIVE_OPTIONS[captives] then
            return { status = "error", error = "captives must be one of: kill, enslave, release" }
        end
        local rigged = false
        if win then
            -- CTD GUARD (reproduced twice, 2026-08-20): calling
            -- cm:win_next_autoresolve_battle with NO pending battle active
            -- crashes the game to desktop. Never call it unguarded.
            local ok_pb, active = pcall(function() return cm:is_pending_battle_active() end)
            if not (ok_pb and active) then
                return { status = "error", error =
                    "no pending battle active — refusing to call cm:win_next_autoresolve_battle, " ..
                    "which CRASHES THE GAME TO DESKTOP without one" }
            end
            local faction = get_local_faction()
            local faction_key = faction and sf(function() return faction:name() end) or nil
            if not faction_key then return { status = "error", error = "no local faction" } end
            local ok_win, err = pcall(function() cm:win_next_autoresolve_battle(faction_key) end)
            if not ok_win then
                return { status = "error", error = "win_next_autoresolve_battle failed: " .. tostring(err) }
            end
            rigged = true
            debug_log("autoresolve_battle: rigged a win for " .. faction_key)
        end
        local set = get_pre_battle_set(root)
        local btn = get_pre_battle_button(set, "autoresolve")
        if not btn then
            return { status = "error", error = "button_autoresolve not found in the pre-battle button set" }
        end
        if not safe_click(btn) then
            return { status = "error", error = "clicking button_autoresolve failed" }
        end
        autoresolve_pending = true
        autoresolve_stage = "await_results"
        autoresolve_ticks = 0
        autoresolve_captives = captives
        autoresolve_rigged = rigged
        autoresolve_title = nil
        autoresolve_clicked = nil
        debug_log("autoresolve_battle: clicked autoresolve (win=" .. tostring(win) ..
                  ", captives=" .. captives .. ")")
        return nil  -- deferred; the poll loop drives the rest

    elseif cmd == "retreat_battle" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local root = find_panel_root("popup_pre_battle")
        if not root then
            return { status = "error", error = "popup_pre_battle is not open" }
        end
        local set, is_siege = get_pre_battle_set(root)
        local btn = get_pre_battle_button(set, "retreat")
        if not btn then
            return { status = "error", error = "button_retreat not found in the pre-battle button set" }
        end
        if not uic_visible(btn) then
            return { status = "error", error = "button_retreat is hidden — retreat is not offered for this battle" }
        end
        if not safe_click(btn) then
            return { status = "error", error = "clicking button_retreat failed" }
        end
        debug_log("retreat_battle: clicked button_retreat")
        return { status = "ok", result = {
            retreated = true,
            siege = is_siege,
            panel_closed = find_panel_root("popup_pre_battle") == nil,
            note = "the panel needs a frame to close; re-check with get_situation",
        } }


    -- -----------------------------------------------------------------------
    -- Diplomacy
    -- -----------------------------------------------------------------------

    elseif cmd == "open_diplomacy" then
        -- Deferred: the faction list only populates a frame or two after the
        -- panel opens (see handle_diplomacy_tick).
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        if diplomacy_pending then
            return { status = "error", error = "a diplomacy sequence is already running" }
        end
        local def = PANELS.diplomacy
        local btn = find_uicomponent(unpack(def.open))
        if not btn then
            return { status = "error", error = "button not found: " .. table.concat(def.open, " > ") }
        end
        if not safe_click(btn) then
            return { status = "error", error = "clicking the diplomacy button failed" }
        end
        diplomacy_pending = true
        diplomacy_stage = "await_panel"
        diplomacy_ticks = 0
        diplomacy_faction = params.faction
        debug_log("open_diplomacy: clicked the diplomacy radial button (faction=" ..
                  tostring(params.faction) .. ")")
        return nil  -- deferred; the poll loop drives the rest

    elseif cmd == "force_diplomacy" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local action = params.action
        if not action then
            return { status = "error", error = "missing action (declare_war, make_peace, " ..
                     "alliance_military, alliance_defensive, trade_agreement, military_access)" }
        end
        local faction_b = params.faction_b
        if not faction_b then return { status = "error", error = "missing faction_b" } end
        local faction_a = params.faction_a
        if not faction_a then
            local f = get_local_faction()
            faction_a = f and sf(function() return f:name() end) or nil
        end
        if not faction_a then return { status = "error", error = "no faction_a and no local faction" } end
        local invite_a = params.invite_a_allies and true or false
        local invite_b = params.invite_b_allies and true or false
        local at_war_before = read_at_war(faction_a, faction_b)
        local ok, err
        if action == "declare_war" then
            ok, err = pcall(function() cm:force_declare_war(faction_a, faction_b, invite_a, invite_b) end)
        elseif action == "make_peace" then
            ok, err = pcall(function() cm:force_make_peace(faction_a, faction_b) end)
        elseif action == "alliance_military" then
            -- One boolean picks the alliance type; there is no separate
            -- force_military_alliance / force_defensive_alliance.
            ok, err = pcall(function() cm:force_alliance(faction_a, faction_b, true) end)
        elseif action == "alliance_defensive" then
            ok, err = pcall(function() cm:force_alliance(faction_a, faction_b, false) end)
        elseif action == "trade_agreement" then
            ok, err = pcall(function() cm:force_make_trade_agreement(faction_a, faction_b) end)
        elseif action == "military_access" then
            ok, err = pcall(function() cm:force_grant_military_access(faction_a, faction_b, false) end)
        else
            return { status = "error", error = "unknown action: " .. tostring(action) }
        end
        if not ok then
            return { status = "error", error = tostring(action) .. " failed: " .. tostring(err) }
        end
        local result = {
            action = action,
            faction_a = faction_a,
            faction_b = faction_b,
            applied = true,
        }
        if action == "declare_war" or action == "make_peace" then
            result.at_war_before = at_war_before
            result.at_war_after = read_at_war(faction_a, faction_b)
        end
        if action == "declare_war" then
            result.invite_a_allies = invite_a
            result.invite_b_allies = invite_b
        end
        if action == "trade_agreement" then
            result.note = "nothing happens when no agreement is possible (no shared border or route)"
        end
        if action == "military_access" then
            result.note = "is_hard_access is documented as unused; passed false"
        end
        debug_log("force_diplomacy: " .. action .. " " .. tostring(faction_a) ..
                  " <-> " .. tostring(faction_b))
        return { status = "ok", result = result }

    elseif cmd == "get_diplomacy" then
        if not in_campaign() then return { status = "error", error = "not in a campaign" } end
        local faction_key = params.faction
        local faction
        if faction_key then
            faction = sf(function() return cm:get_faction(faction_key) end)
            if not faction then
                return { status = "error", error = "faction not found: " .. tostring(faction_key) }
            end
        else
            faction = get_local_faction()
            if not faction then return { status = "error", error = "no local faction" } end
            faction_key = sf(function() return faction:name() end)
        end
        local result = {
            faction = faction_key,
            at_war = sf(function() return faction:at_war() end),
        }
        local unavailable = {}
        local at_war_with = collect_faction_keys(function() return faction:factions_at_war_with() end)
        if at_war_with then result.at_war_with = at_war_with
        else unavailable[#unavailable + 1] = "factions_at_war_with" end
        local allies = collect_faction_keys(function() return faction:factions_allied_with() end)
        if allies then result.allies = allies
        else unavailable[#unavailable + 1] = "factions_allied_with" end
        local traders = collect_faction_keys(function() return faction:factions_trading_with() end)
        if traders then result.trade_partners = traders
        else unavailable[#unavailable + 1] = "factions_trading_with" end
        if #unavailable > 0 then
            result.unavailable = unavailable
            result.note = "these documented FACTION_SCRIPT_INTERFACE accessors did not answer on this build"
        end
        return { status = "ok", result = result }

    elseif cmd == "eval" then
        -- Execute raw Lua. The escape hatch for anything without a dedicated
        -- command. The code runs in the mod's environment (cm, core, common,
        -- CampaignUI, find_uicomponent, UIComponent all reachable).
        local code = params.code
        if not code or code == "" then
            return { status = "error", error = "missing code parameter" }
        end
        local loader = loadstring or load
        if not loader then
            return { status = "error", error = "no loadstring/load in this Lua environment" }
        end
        local fn, cerr = loader(code, "wh3_mcp_eval")
        if not fn then
            return { status = "error", error = "compile: " .. tostring(cerr) }
        end
        -- loadstring chunks get the raw _G, which lacks core, find_uicomponent,
        -- CampaignUI etc. (CA injects those into per-script environments). Run
        -- the chunk in THIS script's environment so eval sees what the mod sees.
        if setfenv and getfenv then
            local env = getfenv(1)
            pcall(setfenv, fn, env)
        end
        local packed = { pcall(fn) }
        local ok_run = packed[1]
        if not ok_run then
            return { status = "error", error = "runtime: " .. tostring(packed[2]) }
        end
        -- Only plain values survive JSON; everything else becomes tostring().
        local function jsonable(v, depth)
            local t = type(v)
            if t == "nil" then return nil end
            if t == "boolean" or t == "number" or t == "string" then return v end
            if t == "table" then
                if depth > 6 then return "(table depth cap)" end
                local out = {}
                for k, val in pairs(v) do
                    out[tostring(k)] = jsonable(val, depth + 1)
                end
                return out
            end
            return tostring(v)
        end
        local values = {}
        local n = 0
        for i = 2, #packed do
            n = n + 1
            values[n] = jsonable(packed[i], 0)
            if values[n] == nil then values[n] = "nil" end
        end
        return { status = "ok", result = { values = values, count = n } }

    elseif cmd == "cm_search" then
        -- Search the WH3 scripting API without leaving the game loop.
        -- Two merged sources: the docs corpus (wh3_mcp_docs.tsv in the game
        -- root, built from tw_autogen stubs, deployed by the MCP server) and
        -- live introspection of the running game (exists_at_runtime flags +
        -- runtime_only rows for functions the docs miss). This is DISCOVERY;
        -- execution stays in the eval command.
        -- The TSV is stream-filtered line by line ON PURPOSE: never
        -- json.decode a megabyte in here (string-corruption failure mode).
        local query = params.query
        if not query or query == "" then
            return { status = "error", error = "missing query" }
        end
        local limit = tonumber(params.limit) or 15
        if limit < 1 then limit = 1 end
        if limit > 50 then limit = 50 end
        local ctx_filter = params.context
        if ctx_filter == "" then ctx_filter = nil end

        -- lowercase tokens, split on spaces; every token must match (AND).
        -- Tokens are pattern-escaped ONCE up front: all matching below uses
        -- pattern finds, never the plain flag (see plain_find's warning).
        local tokens = {}
        local patterns = {}
        do
            local q = query:lower()
            local start = 1
            while true do
                local pos = q:find(" ", start)
                if not pos then
                    if start <= #q then tokens[#tokens + 1] = q:sub(start) end
                    break
                end
                if pos > start then tokens[#tokens + 1] = q:sub(start, pos - 1) end
                start = pos + 1
            end
            for i = 1, #tokens do patterns[i] = escape_pattern(tokens[i]) end
        end
        if #tokens == 0 then return { status = "error", error = "query has no searchable tokens" } end

        local function matches_all_tokens(text)
            for i = 1, #patterns do
                if not text:find(patterns[i]) then return false end
            end
            return true
        end

        local function split_tab(line)
            local fields = {}
            local start = 1
            while true do
                local pos = line:find("\t", start)
                if not pos then fields[#fields + 1] = line:sub(start) break end
                fields[#fields + 1] = line:sub(start, pos - 1)
                start = pos + 1
            end
            return fields
        end

        -- pass 1: corpus scan
        local matches = {}
        local truncated = false
        local corpus_ok = false
        local file = io.open(DOCS_FILE, "r")
        if file then
            corpus_ok = true
            for line in file:lines() do
                if matches_all_tokens(line:lower()) then
                    local f = split_tab(line)
                    local ctxs, klass, name = f[1] or "", f[2] or "", f[3] or ""
                    local keep = true
                    if ctx_filter then
                        if ctx_filter == "ui" then
                            local kl = klass:lower()
                            keep = (kl == "uic" or kl == "campaignui" or kl == "campaign_ui_manager")
                        else
                            keep = plain_find(ctxs, ctx_filter) ~= nil
                        end
                    end
                    if keep then
                        local name_l = name:lower()
                        local class_l = klass:lower()
                        local score = 0
                        for i = 1, #tokens do
                            if name_l == tokens[i] then score = score + 100
                            elseif name_l:find(patterns[i]) then score = score + 10
                            elseif class_l:find(patterns[i]) then score = score + 5
                            else score = score + 1 end
                        end
                        matches[#matches + 1] = {
                            score = score, contexts = ctxs, class = klass, name = name,
                            signature = f[4] or "", returns = f[5] or "",
                            description = f[6] or "",
                        }
                        if #matches >= 400 then truncated = true break end
                    end
                end
            end
            file:close()
        end
        table.sort(matches, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            if #a.name ~= #b.name then return #a.name < #b.name end
            return a.name < b.name
        end)

        -- pass 2: live introspection. Containers we can probe by direct index
        -- (works even when methods hide behind an __index FUNCTION, as the
        -- campaign_manager -> game interface forwarding does).
        local uim = in_campaign() and sf(function() return cm:get_campaign_ui_manager() end) or nil
        local ui_root = core and sf(function() return core:get_ui_root() end) or nil
        local containers = {}
        if in_campaign() and cm then
            containers.campaign_manager = cm
            containers.episodic_scripting = cm
        end
        if CampaignUI then containers.campaignui = CampaignUI end
        if core then containers.core = core end
        if uim then containers.campaign_ui_manager = uim end
        if ui_root then containers.uic = ui_root end
        -- Battle context: probe bm for both battle_manager and raw battle
        -- rows (bm forwards battle methods; its __index RAISES on missing
        -- names, which probe's pcall absorbs). Globals only on purpose -
        -- a new local here would add an upvalue to execute_command, which
        -- already hit the 60-upvalue cap once.
        if core and core:is_battle() and bm then
            containers.battle_manager = bm
            containers.battle = bm
        end
        local function probe(container, name)
            local ok, v = pcall(function() return container[name] end)
            if not ok then return nil end
            return v ~= nil
        end

        local out = {}
        local shown = limit
        if shown > #matches then shown = #matches end
        for i = 1, shown do
            local m = matches[i]
            m.score = nil
            local c = containers[m.class:lower()]
            if c then m.exists_at_runtime = probe(c, m.name) end
            out[#out + 1] = m
        end

        -- pass 3: runtime-only discovery - function names on the live objects
        -- that match the query but are absent from the corpus results. Walks
        -- pairs() plus the __index metatable chain (table __index only).
        local runtime_only = {}
        local have = {}
        for i = 1, #matches do
            have[matches[i].class:lower() .. ":" .. matches[i].name:lower()] = true
        end
        local function scan_names(label, obj)
            local seen = {}
            local o = obj
            local depth = 0
            local label_l = label:lower()
            while type(o) == "table" and not seen[o] and depth < 5 do
                seen[o] = true
                for k, v in pairs(o) do
                    if type(k) == "string" and type(v) == "function"
                       and #runtime_only < 30 then
                        local kl = k:lower()
                        if matches_all_tokens(kl) and not have[label_l .. ":" .. kl] then
                            runtime_only[#runtime_only + 1] = { class = label, name = k, source = "runtime" }
                            have[label_l .. ":" .. kl] = true
                        end
                    end
                end
                local mt = getmetatable(o)
                o = (type(mt) == "table") and rawget(mt, "__index") or nil
                depth = depth + 1
            end
        end
        if in_campaign() and cm then pcall(scan_names, "campaign_manager", cm) end
        if CampaignUI then pcall(scan_names, "campaignui", CampaignUI) end
        if core then pcall(scan_names, "core", core) end
        if uim then pcall(scan_names, "campaign_ui_manager", uim) end
        if core and core:is_battle() and bm then pcall(scan_names, "battle_manager", bm) end

        local result = {
            query = query,
            context = ctx_filter,
            total_matches = #matches,
            results = out,
            strings_ok = strings_ok(),
        }
        if truncated then result.truncated = true end
        if #runtime_only > 0 then result.runtime_only = runtime_only end
        if not corpus_ok then
            result.corpus = "missing: wh3_mcp_docs.tsv not found in the game root - restart the MCP server (it deploys the corpus) or copy server/data/wh3_mcp_docs.tsv there manually"
        end
        return { status = "ok", result = result }

    else
        return execute_command_2(cmd, params)
    end
end

-- ---------------------------------------------------------------------------
-- Polling loop
-- ---------------------------------------------------------------------------

-- Drive one tick of a quit_to_menu / exit_to_windows sequence.
--
-- The quit dialog needs a frame to appear after the quit button is clicked, so
-- this runs across poll ticks instead of synchronously inside execute_command.
-- Going to the main menu reloads every _lib/mod script, which destroys all Lua
-- state, so the result is handed to the next script instance through
-- QUIT_MARKER (see check_context_transition). Exiting to Windows kills the
-- process outright, so its result must be written BEFORE the confirm click.
local function handle_quit_tick()
    quit_ticks = quit_ticks + 1
    if quit_ticks > QUIT_MAX_TICKS then
        debug_log("quit: timed out in stage " .. tostring(quit_stage))
        quit_pending = false
        delete_file(QUIT_MARKER)
        write_file(RESULT_FILE, json.encode({
            status = "error",
            error = "quit timed out in stage " .. tostring(quit_stage),
        }))
        quit_stage = nil
        return
    end

    if quit_stage == "click_quit" then
        local btn_id = (quit_mode == "windows") and "button_windows" or "button_quit"
        local btn = find_uicomponent("esc_menu", "main", "menu_left", "menu_buttons", "frame_quit", btn_id)
        if not btn then btn = find_uicomponent("esc_menu", btn_id) end
        if btn then
            safe_click(btn)
            debug_log("quit: clicked " .. btn_id)
            quit_stage = "await_dialog"
        else
            -- The esc menu may not be up yet; nudge it open again.
            local menu_btn = find_uicomponent("menu_bar", "buttongroup", "button_menu")
            if menu_btn then safe_click(menu_btn) end
            debug_log("quit: " .. btn_id .. " not found, re-opened esc menu")
        end
        return
    end

    if quit_stage == "await_dialog" then
        local box, text = get_visible_dialogue_box()
        if not box then return end
        if quit_mode == "windows" then
            -- Write first: the process dies the moment the tick is clicked.
            write_file(RESULT_FILE, json.encode({
                status = "ok",
                result = { exiting = true, dialog = text },
            }))
            quit_pending = false
            quit_stage = nil
            local clicked = click_dialog_button(box, "confirm")
            debug_log("quit: result written, confirmed exit to windows via " .. tostring(clicked))
        else
            write_file(QUIT_MARKER, json.encode({ command = "quit_to_menu", dialog = text }))
            local clicked = click_dialog_button(box, "confirm")
            if clicked then
                debug_log("quit: confirmed exit to main menu via " .. clicked)
                quit_stage = "await_transition"
            else
                delete_file(QUIT_MARKER)
                debug_log("quit: dialog found but no confirm button")
            end
        end
        return
    end

    if quit_stage == "await_transition" then
        -- Normally the script reloads before this fires and
        -- check_context_transition writes the result instead.
        if not in_campaign() then
            quit_pending = false
            quit_stage = nil
            delete_file(QUIT_MARKER)
            write_file(RESULT_FILE, json.encode({
                status = "ok",
                result = { quit = true, in_campaign = false },
            }))
            debug_log("quit: left the campaign in-process, result written")
        end
        return
    end
end

-- Drive one tick of an autoresolve_battle sequence.
--
-- Stages: await_results (the results panel appears) -> dismiss (captive choice
-- or a visible accept/dismiss button) -> await_close (the panel is gone, write
-- the result). Each stage has its own tick budget; the counter resets on every
-- transition so a slow autoresolve cannot starve the later stages.
local AUTORESOLVE_STAGE_TICKS = {
    await_results = 30,
    dismiss = 10,
    await_close = 10,
}

local function finish_autoresolve(result)
    autoresolve_pending = false
    autoresolve_stage = nil
    if autoresolve_on_done then
        -- A soak owns this battle: hand it the outcome, never touch the
        -- result file (the soak's own command already answered).
        local cb = autoresolve_on_done
        autoresolve_on_done = nil
        pcall(cb, result)
        return
    end
    write_file(RESULT_FILE, json.encode(result))
end

local function handle_autoresolve_tick()
    autoresolve_ticks = autoresolve_ticks + 1
    local cap = AUTORESOLVE_STAGE_TICKS[autoresolve_stage] or 10
    if autoresolve_ticks > cap then
        debug_log("autoresolve: timed out in stage " .. tostring(autoresolve_stage))
        finish_autoresolve({
            status = "error",
            error = "autoresolve timed out in stage " .. tostring(autoresolve_stage),
        })
        return
    end

    if autoresolve_stage == "await_results" then
        if find_panel_root("popup_battle_results") then
            autoresolve_stage = "dismiss"
            autoresolve_ticks = 0
            debug_log("autoresolve: battle results panel is up")
        end
        return
    end

    if autoresolve_stage == "dismiss" then
        local root = find_panel_root("popup_battle_results")
        if not root then
            -- The panel closed on its own; nothing left to click.
            autoresolve_stage = "await_close"
            autoresolve_ticks = 0
            return
        end
        local panel = get_post_battle_panel(root)
        if not autoresolve_title then
            autoresolve_title = get_post_battle_result_text(panel)
        end
        local win_set = get_child(panel, "button_set_win")
        if win_set and uic_visible(win_set) then
            -- A victory blocks on the captive choice; clicking one closes the
            -- whole panel.
            local id = CAPTIVE_OPTIONS[autoresolve_captives]
            local btn = get_child(win_set, id)
            if btn and safe_click(btn) then
                autoresolve_clicked = id
                autoresolve_stage = "await_close"
                autoresolve_ticks = 0
                debug_log("autoresolve: clicked " .. id)
            end
            return
        end
        -- No captive choice: click a VISIBLE accept/dismiss button. Hidden
        -- copies live in the same panel and clicking one looks like success.
        local btn, btn_id = find_visible_descendant(panel, { "button_accept", "button_dismiss" }, 6)
        if btn and safe_click(btn) then
            autoresolve_clicked = btn_id
            autoresolve_stage = "await_close"
            autoresolve_ticks = 0
            debug_log("autoresolve: clicked " .. tostring(btn_id))
        end
        return
    end

    if autoresolve_stage == "await_close" then
        if find_panel_root("popup_battle_results") then return end
        local human_victory = sf(function() return cm:pending_battle_cache_human_victory() end)
        debug_log("autoresolve: complete (human_victory=" .. tostring(human_victory) .. ")")
        finish_autoresolve({ status = "ok", result = {
            resolved = true,
            human_victory = human_victory,
            result_title = autoresolve_title,
            clicked = autoresolve_clicked,
            captives = autoresolve_captives,
            rigged_win = autoresolve_rigged,
        } })
        return
    end
end

-- Drive one tick of an open_diplomacy sequence: wait for diplomacy_dropdown,
-- then click the requested faction's row.
local DIPLOMACY_MAX_TICKS = 10

local function handle_diplomacy_tick()
    diplomacy_ticks = diplomacy_ticks + 1
    local root = find_panel_root("diplomacy_dropdown")
    if not root then
        if diplomacy_ticks > DIPLOMACY_MAX_TICKS then
            diplomacy_pending = false
            diplomacy_stage = nil
            write_file(RESULT_FILE, json.encode({
                status = "error",
                error = "diplomacy_dropdown did not open within " .. DIPLOMACY_MAX_TICKS .. " ticks",
            }))
            debug_log("open_diplomacy: panel never opened")
        end
        return
    end
    local clicked, row_id = false, nil
    if diplomacy_faction then
        local row, id = find_faction_row(diplomacy_faction)
        if row then
            clicked = safe_click(row)
            row_id = id
        elseif diplomacy_ticks <= DIPLOMACY_MAX_TICKS then
            return  -- the list populates a frame or two after the panel opens
        end
    end
    diplomacy_pending = false
    diplomacy_stage = nil
    local result = {
        opened = true,
        faction = diplomacy_faction,
        faction_row_clicked = clicked,
        faction_row_id = row_id,
    }
    if diplomacy_faction and not clicked then
        result.note = "no faction_row_entry matched — only factions you have MET appear in the list"
    end
    write_file(RESULT_FILE, json.encode({ status = "ok", result = result }))
    debug_log("open_diplomacy: panel open, row_clicked=" .. tostring(clicked))
end

-- Drive one tick of a start_research sequence: open the tech panel, click the
-- tech_<key> node, verify via faction:is_currently_researching, close.
local RESEARCH_MAX_TICKS = 15

local function finish_research(result)
    research_pending = false
    research_state = nil
    write_file(RESULT_FILE, json.encode(result))
end

local function handle_research_tick()
    local st = research_state
    st.ticks = st.ticks + 1
    if st.ticks > RESEARCH_MAX_TICKS then
        pcall(function() CampaignUI.ClosePanel("technology_panel") end)
        finish_research({ status = "error", error = "start_research timed out - node for '" ..
            tostring(st.key) .. "' not found (bad key, or the node is locked/hidden)" })
        return
    end
    local panel = find_panel_root("technology_panel")
    if not panel then
        if st.clicked then
            -- The panel closed after our click (some techs close it): verify.
            local researching = sf(function()
                local f = get_local_faction()
                return f and f:is_currently_researching() or nil
            end)
            finish_research({ status = "ok", result = {
                tech = st.key, node = st.clicked_id,
                is_currently_researching = researching,
            } })
            return
        end
        if not st.opened then
            local p = PANELS.technology.open
            local btn = find_uicomponent(p[1], p[2], p[3], p[4])
            if btn then safe_click(btn) end
            st.opened = true
        end
        return
    end
    if st.clicked then
        local researching = sf(function()
            local f = get_local_faction()
            return f and f:is_currently_researching() or nil
        end)
        pcall(function() CampaignUI.ClosePanel("technology_panel") end)
        finish_research({ status = "ok", result = {
            tech = st.key, node = st.clicked_id,
            is_currently_researching = researching,
            note = researching == false and "clicked but nothing is researching - node may be locked or already researched" or nil,
        } })
        return
    end
    local node, id = find_visible_descendant(panel, { st.key, "tech_" .. st.key }, 14)
    if node then
        -- The clickable is the technology_entry INSIDE the node (clicking the
        -- node container does nothing - verified live; same pattern as the
        -- choice_button inside dilemma entries).
        local entry = get_child(node, "technology_entry") or node
        if safe_click(entry) then
            st.clicked = true
            st.clicked_id = id
            debug_log("start_research: clicked " .. tostring(id))
        end
    end
end

-- Drive one tick of an answer_move_options sequence: after the bar click, a
-- Declare War option routes through the diplomacy screen's war_declared
-- subpanel (both_buttongroup > button_ok_declare). Confirm it, close the
-- diplomacy screen, and report; options that skip the confirmation (Cancel
-- Move) just close the panel.
local MOVEOPTS_MAX_TICKS = 10

local function finish_moveopts(result)
    moveopts_pending = false
    moveopts_state = nil
    write_file(RESULT_FILE, json.encode(result))
end

local function handle_moveopts_tick()
    local st = moveopts_state
    st.ticks = st.ticks + 1
    local confirm = find_uicomponent("diplomacy_dropdown", "subpanel_group", "war_declared",
                                     "diplomacy_hud_war_declared", "both_buttongroup", "button_ok_declare")
    if confirm and uic_visible(confirm) then
        safe_click(confirm)
        st.confirmed_war = true
        debug_log("answer_move_options: confirmed the war declaration")
        return -- close the diplomacy screen next tick
    end
    if st.confirmed_war and find_panel_root("diplomacy_dropdown") then
        pcall(function() CampaignUI.ClosePanel("diplomacy_dropdown") end)
        return
    end
    local done = (get_move_options_root() == nil)
                 and (not st.confirmed_war or find_panel_root("diplomacy_dropdown") == nil)
    if done or st.ticks > MOVEOPTS_MAX_TICKS then
        finish_moveopts({ status = "ok", result = {
            clicked = st.label,
            option = st.option,
            war_confirmed = st.confirmed_war and true or false,
            panel_closed = get_move_options_root() == nil,
            note = st.confirmed_war
                and "war declared and confirmed; the original move order was CONSUMED - reissue it"
                or nil,
        } })
    end
end

-- Drive one tick of a running soak. Never writes the result file (soak_turns
-- acks immediately; soak_status reads progress). Priorities per tick: battle
-- panels, confirmation dialogs, event panels, then end the turn.
local function handle_soak_tick()
    if not soak then
        soak_pending = false
        return
    end
    if soak.abort then
        finish_soak("aborted")
        return
    end
    if not in_campaign() then
        finish_soak("error", "left campaign context mid-soak")
        return
    end
    soak.ticks_this_turn = soak.ticks_this_turn + 1
    if soak.ticks_this_turn > soak.max_ticks_per_turn then
        finish_soak("error", "turn exceeded " .. soak.max_ticks_per_turn ..
                    " ticks - a blocker the loop cannot clear?")
        return
    end
    if soak.ticks_this_turn % 10 == 0 and not strings_ok() then
        finish_soak("error", "string subsystem corrupted mid-soak - restart the game")
        return
    end

    local turn = sf(function() return cm:turn_number() end) or soak.last_turn

    -- 1. Pre-battle panel (queued attack landed, or the AI attacked us).
    local pre = find_panel_root("popup_pre_battle")
    if pre then
        if soak.battle_policy == "stop" then
            finish_soak("complete", "stopped on the pre-battle panel per battle_policy")
            return
        end
        local handled = false
        if soak.battle_policy == "retreat" then
            local set = get_pre_battle_set(pre)
            local btn = get_pre_battle_button(set, "retreat")
            if btn and uic_visible(btn) and safe_click(btn) then
                soak.battles[#soak.battles + 1] = { turn = turn, action = "retreated" }
                handled = true
            end
        end
        if not handled then
            -- Autoresolve (also the fallback when retreat is not offered).
            if soak.rig_battles then
                local ok_pb, active = pcall(function() return cm:is_pending_battle_active() end)
                if ok_pb and active then
                    local f = get_local_faction()
                    local fk = f and sf(function() return f:name() end) or nil
                    -- CTD guard: only with an active pending battle (see autoresolve_battle).
                    if fk then pcall(function() cm:win_next_autoresolve_battle(fk) end) end
                end
            end
            local set = get_pre_battle_set(pre)
            local btn = get_pre_battle_button(set, "autoresolve")
            if btn and safe_click(btn) then
                autoresolve_captives = soak.captives
                autoresolve_rigged = soak.rig_battles
                autoresolve_title = nil
                autoresolve_clicked = nil
                autoresolve_stage = "await_results"
                autoresolve_ticks = 0
                local battle_turn = turn
                autoresolve_on_done = function(res)
                    local entry = { turn = battle_turn, action = "autoresolved" }
                    if res and res.result then
                        entry.human_victory = res.result.human_victory
                        entry.result_title = res.result.result_title
                    elseif res and res.error then
                        entry.error = res.error
                    end
                    soak.battles[#soak.battles + 1] = entry
                end
                autoresolve_pending = true
            end
        end
        return
    end

    -- 2. A results panel with no machine armed (e.g. a battle resolved before
    -- the soak started): run the dismiss stages of the autoresolve machine.
    if not autoresolve_pending and find_panel_root("popup_battle_results") then
        autoresolve_captives = soak.captives
        autoresolve_rigged = false
        autoresolve_title = nil
        autoresolve_clicked = nil
        autoresolve_stage = "dismiss"
        autoresolve_ticks = 0
        local battle_turn = turn
        autoresolve_on_done = function(res)
            local entry = { turn = battle_turn, action = "results_cleared" }
            if res and res.result then
                entry.human_victory = res.result.human_victory
                entry.result_title = res.result.result_title
            end
            soak.battles[#soak.battles + 1] = entry
        end
        autoresolve_pending = true
        return
    end

    -- 2b. Occupation choice after a settlement was taken: decide per the
    -- soak's occupation policy (default "occupy") so the soak never stalls
    -- on a capture.
    local occupation = read_settlement_captured()
    if occupation then
        local want = (soak.occupation or "occupy"):lower()
        local want_pat = escape_pattern(want)
        local picked = nil
        for i = 1, #occupation.options do
            local t = (occupation.options[i].text or ""):lower()
            if t == want then picked = occupation.options[i] break end
        end
        if not picked then
            for i = 1, #occupation.options do
                local t = (occupation.options[i].text or ""):lower()
                if t:find(want_pat) then picked = occupation.options[i] break end
            end
        end
        picked = picked or occupation.options[1]
        if picked then
            local root = find_root_child("settlement_captured")
            local opt = root and get_child(get_child(root, "button_parent"), picked.id) or nil
            local btn = opt and get_child(opt, "option_button") or nil
            if btn and safe_click(btn) then
                soak.notes[#soak.notes + 1] = "turn " .. tostring(turn) .. " captured " ..
                    tostring(occupation.settlement) .. ": " .. tostring(picked.text)
            end
        end
        return
    end

    -- 2c. A move_options interruption ("Declare War?"): the soak never wants
    -- side-effect wars, so cancel the move (the last visible bar).
    local mo = get_move_options_root()
    if mo then
        local panel = get_child(mo, "panel")
        local last = nil
        for i = 6, 1, -1 do
            local bar = panel and get_child(panel, "options_bar" .. i) or nil
            if bar and uic_visible(bar) then last = bar break end
        end
        if last and safe_click(last) then
            soak.notes[#soak.notes + 1] = "turn " .. tostring(turn) .. " move_options cancelled"
        end
        return
    end

    -- 3. Confirmation dialogs (end-turn warnings and the like): confirm.
    local dlg = get_visible_dialogue_box()
    if dlg then
        if click_dialog_button(dlg, "tick") then
            soak.dialogs_confirmed = soak.dialogs_confirmed + 1
        end
        return
    end

    -- 4. Event panels: answer dilemmas with the configured choice, dismiss
    -- everything else.
    local events = find_panel_root("events")
    if events then
        local detail = read_event_detail()
        if detail and detail.event_type == "dilemma" then
            local dilemma = get_open_dilemma(events)
            local list = dilemma and get_child(dilemma, "dilemma_list") or nil
            local entry = list and find_dilemma_choice(list, soak.dilemma_choice) or nil
            if not entry and list and soak.dilemma_choice ~= 1 then
                entry = find_dilemma_choice(list, 1)  -- fewer choices than configured
            end
            local btn = entry and get_child(entry, "choice_button") or nil
            if btn and safe_click(btn) then
                soak.dilemmas_answered = soak.dilemmas_answered + 1
                if #soak.notes < 30 and detail.title then
                    soak.notes[#soak.notes + 1] = "turn " .. tostring(turn) .. " dilemma: " .. tostring(detail.title)
                end
            end
        else
            local button_set = get_child(events, "button_set")
            local holder = button_set and get_child(button_set, "accept_holder") or nil
            local btn = holder and get_child(holder, "button_accept") or get_child(events, "button_accept")
            if btn and safe_click(btn) then
                soak.events_dismissed = soak.events_dismissed + 1
            end
        end
        return
    end

    -- 5. Drive the turn.
    local my_turn = sf(function() return cm:is_local_players_turn() end)
    if my_turn then
        if turn > soak.last_turn then
            soak.done = soak.done + 1
            soak.last_turn = turn
            soak.end_turn_issued = false
            soak.ticks_this_turn = 0
            debug_log("soak: turn " .. turn .. " reached (" .. soak.done .. "/" .. soak.target .. ")")
            if soak.done >= soak.target then
                finish_soak("complete")
                return
            end
        end
        -- Re-issue every 15 ticks in case the first call was swallowed by a
        -- blocker that has since been cleared.
        if not soak.end_turn_issued or soak.ticks_this_turn % 15 == 0 then
            local ok_et = pcall(function() cm:end_turn() end)
            if ok_et then soak.end_turn_issued = true end
        end
    end
end

-- Drive one tick of an auto_fight run. Phase-driven: Deployment -> set speed
-- + end deployment, Deployed -> attack-move re-issued every 20 ticks (so the
-- army re-engages as enemy units rout), VictoryCountdown -> end_battle. Never
-- writes the result file: auto_fight acks immediately and the run ends with
-- the context transition back to campaign, which kills this script instance.
local function handle_autofight_tick()
    if not autofight then return end
    autofight.ticks = autofight.ticks + 1
    local phase = battle_phase()
    if phase == "Deployment" then
        -- re-issued every 5 ticks in case the first call lands too early
        if autofight.ticks % 5 == 1 then
            pcall(function() bm:modify_battle_speed(autofight.speed, true) end)
            battle_speed = autofight.speed
            pcall(function() bm:end_current_battle_phase() end)
            autofight.stage = "starting"
            debug_log("auto_fight: end deployment issued (tick " .. autofight.ticks .. ")")
        end
    elseif phase == "Deployed" then
        if autofight.ticks - (autofight.last_order or -100) >= 20 then
            local ordered = pcall(function()
                local uc = bm:get_player_army():create_unit_controller()
                uc:add_all_units()
                local units = bm:get_non_player_alliance():armies():item(1):units()
                local target = nil
                for i = 1, units:count() do
                    local u = units:item(i)
                    if u:number_of_men_alive() > 0 then target = u break end
                end
                if target then uc:attack_location(target:position(), true) end
            end)
            autofight.last_order = autofight.ticks
            autofight.stage = "fighting"
            if ordered then debug_log("auto_fight: attack order issued (tick " .. autofight.ticks .. ")") end
        end
    elseif phase == "VictoryCountdown" then
        autofight.stage = "ending"
        pcall(function() bm:end_battle() end)
    elseif phase == "Complete" then
        -- The results popup holds the battle open until its End Battle
        -- button is clicked; clicking starts the campaign reload, which
        -- kills this script instance (and with it this machine).
        autofight.stage = "dismissing"
        local popup = battle_results_popup()
        if popup then
            local results = read_battle_results()
            local btn = find_uicomponent(popup, "button_dismiss_results")
            if btn and safe_click(btn) then
                debug_log("auto_fight: results dismissed (outcome " ..
                          tostring(results and results.outcome) .. ")")
            end
        end
    end
    if autofight and autofight.ticks > autofight.max_ticks then
        debug_log("auto_fight: gave up after " .. autofight.ticks .. " ticks (battle left running)")
        autofight = nil
    end
end

local function poll()
    -- Heartbeat every 30 ticks to confirm poll loop is alive
    heartbeat_count = heartbeat_count + 1
    if heartbeat_count % 30 == 0 then
        debug_log("heartbeat #" .. heartbeat_count .. " pending=" .. tostring(campaign_start_pending) .. " in_campaign=" .. tostring(in_campaign()))
    end

    -- Battle context: hook the phase callbacks once per script instance, and
    -- arm auto_fight if the campaign side left the marker (fight_battle
    -- {auto: true}). battle_hooked resets naturally - every context
    -- transition reloads this script.
    if not battle_hooked and in_battle() then
        battle_hooked = true
        pcall(function()
            local phases = { "Deployment", "Deployed", "VictoryCountdown", "Complete" }
            for i = 1, #phases do
                local ph = phases[i]
                bm:register_phase_change_callback(ph, function()
                    battle_phase_log[#battle_phase_log + 1] = ph
                    debug_log("battle phase -> " .. ph)
                end)
            end
        end)
        local marker = read_file(BATTLE_AUTO_MARKER)
        if marker then
            delete_file(BATTLE_AUTO_MARKER)
            local okm, cfg = pcall(json.decode, marker)
            if not okm or type(cfg) ~= "table" then cfg = {} end
            autofight = {
                speed = tonumber(cfg.speed) or 10,
                max_ticks = tonumber(cfg.max_ticks) or 900,
                ticks = 0,
                stage = "armed",
            }
            debug_log("auto_fight: armed from marker (speed " .. autofight.speed .. ")")
        end
        debug_log("battle context detected - phase callbacks hooked")
    end

    -- Drive a running auto_fight. Like the soak it never blocks command
    -- reads and never writes the result file from a tick.
    if autofight and in_battle() then
        local ok, err = pcall(handle_autofight_tick)
        if not ok then debug_log("auto_fight: tick error: " .. tostring(err)) end
    end

    -- Drive a pending quit sequence. While it runs, no new commands are read.
    if quit_pending then
        local ok, err = pcall(handle_quit_tick)
        if not ok then
            debug_log("quit: tick error: " .. tostring(err))
            quit_pending = false
            quit_stage = nil
            delete_file(QUIT_MARKER)
            write_file(RESULT_FILE, json.encode({ status = "error", error = "quit sequence error: " .. tostring(err) }))
        end
        if quit_pending then return end
    end

    -- Drive a pending autoresolve sequence. Same rule as quitting: while it
    -- runs, no new commands are read.
    if autoresolve_pending then
        local ok, err = pcall(handle_autoresolve_tick)
        if not ok then
            debug_log("autoresolve: tick error: " .. tostring(err))
            autoresolve_pending = false
            autoresolve_stage = nil
            write_file(RESULT_FILE, json.encode({
                status = "error",
                error = "autoresolve sequence error: " .. tostring(err),
            }))
        end
        if autoresolve_pending then return end
    end

    -- Drive a pending open_diplomacy sequence.
    if diplomacy_pending then
        local ok, err = pcall(handle_diplomacy_tick)
        if not ok then
            debug_log("open_diplomacy: tick error: " .. tostring(err))
            diplomacy_pending = false
            diplomacy_stage = nil
            write_file(RESULT_FILE, json.encode({
                status = "error",
                error = "diplomacy sequence error: " .. tostring(err),
            }))
        end
        if diplomacy_pending then return end
    end

    -- Drive a pending answer_move_options sequence.
    if moveopts_pending then
        local ok, err = pcall(handle_moveopts_tick)
        if not ok then
            debug_log("answer_move_options: tick error: " .. tostring(err))
            moveopts_pending = false
            moveopts_state = nil
            write_file(RESULT_FILE, json.encode({
                status = "error",
                error = "answer_move_options sequence error: " .. tostring(err),
            }))
        end
        if moveopts_pending then return end
    end

    -- Drive a pending start_research sequence.
    if research_pending then
        local ok, err = pcall(handle_research_tick)
        if not ok then
            debug_log("start_research: tick error: " .. tostring(err))
            research_pending = false
            research_state = nil
            write_file(RESULT_FILE, json.encode({
                status = "error",
                error = "start_research sequence error: " .. tostring(err),
            }))
        end
        if research_pending then return end
    end

    -- Drive a running soak. Unlike the machines above this never returns
    -- early: commands (soak_status, soak_abort, get_situation, ping) stay
    -- answerable mid-run, and the tick never writes the result file.
    if soak_pending then
        local ok, err = pcall(handle_soak_tick)
        if not ok then
            debug_log("soak: tick error: " .. tostring(err))
            finish_soak("error", "tick error: " .. tostring(err))
        end
    end

    -- Check pending campaign start
    if campaign_start_pending then
        local elapsed = os.clock() - campaign_start_time

        -- UI navigation state machine
        if ui_nav_state == 1 and elapsed > 1.5 then
            -- Step 2: Make campaign_frame visible and click "New Campaign"
            local frame = find_uicomponent("campaign_frame")
            if frame then
                pcall(function() frame:SetVisible(true) end)
                debug_log("UI nav: forced campaign_frame visible")
            end
            local btn = find_uicomponent("button_start_campaign_new")
            if btn then
                btn:SimulateLClick()
                debug_log("UI nav: clicked button_start_campaign_new, state=2")
                ui_nav_state = 2
                ui_nav_start_time = os.clock()
            else
                debug_log("UI nav: button_start_campaign_new not found")
            end
        elseif ui_nav_state == 2 and os.clock() - ui_nav_start_time > 4.0 then
            -- Step 3: Dismiss difficulty popup if present, then click Start
            local accept = find_uicomponent("accept_difficulty_changes")
            if accept then
                accept:SimulateLClick()
                debug_log("UI nav: dismissed difficulty popup")
            end
            -- Try clicking the first campaign button in list_parent
            local list_parent = find_uicomponent("list_parent")
            if list_parent then
                local ok, cc = pcall(function() return list_parent:ChildCount() end)
                if ok and cc and cc > 0 then
                    -- Log how many children for debugging
                    debug_log("UI nav: campaign list has " .. cc .. " children")
                    -- Try index 0 first, then index 1 (IE might be second)
                    for i = 0, cc - 1 do
                        local child = UIComponent(list_parent:Find(i))
                        if child then
                            child:SimulateLClick()
                            debug_log("UI nav: clicked campaign child " .. i .. ", state=3")
                            ui_nav_state = 3
                            ui_nav_start_time = os.clock()
                            break
                        end
                    end
                else
                    debug_log("UI nav: campaign list empty or error")
                end
            else
                debug_log("UI nav: list_parent not found")
            end
        elseif ui_nav_state == 3 and os.clock() - ui_nav_start_time > 3.0 then
            -- Step 4: Click a lord in the lord_select_list to select faction
            local lord_list = find_uicomponent("lord_select_list", "list")
            if lord_list then
                local cc = lord_list:ChildCount()
                if cc and cc > 0 then
                    local first_lord = UIComponent(lord_list:Find(0))
                    if first_lord then
                        first_lord:SimulateLClick()
                        debug_log("UI nav: clicked first lord in list, state=4")
                        ui_nav_state = 4
                        ui_nav_start_time = os.clock()
                    end
                else
                    debug_log("UI nav: lord list empty")
                end
            else
                debug_log("UI nav: lord_select_list not found")
            end
        elseif ui_nav_state == 4 and os.clock() - ui_nav_start_time > 3.0 then
            -- Step 5: Click Start Campaign
            local accept = find_uicomponent("accept_difficulty_changes")
            if accept then
                accept:SimulateLClick()
                debug_log("UI nav: dismissed difficulty popup at state 4")
            end
            local btn = find_uicomponent("button_start_campaign")
            if btn then
                btn:SimulateLClick()
                debug_log("UI nav: clicked start_campaign, state=5")
                ui_nav_state = 5
            else
                debug_log("UI nav: start_campaign button not found, trying frontend API")
                if type(frontend) == "table" then
                    pcall(function() frontend.start_campaign("wh3_main_combi", "mixer_cth_shenzoo", "wh3_main_cth_shenzoo") end)
                end
            end
        end

        if in_campaign() then
            -- Campaign loaded. Check for Continue button (only on new games, not load games).
            if continue_wait_start == 0 then
                continue_wait_start = os.clock()
                debug_log("Campaign detected, is_new_game=" .. tostring(campaign_start_params.is_new_game))
            end

            -- Load games skip the Continue screen entirely
            if not campaign_start_params.is_new_game then
                debug_log("Load game detected, writing success immediately")
                write_campaign_success()
            else
                -- New game: wait for Continue button or timeout
                local continue_btn = find_uicomponent("custom_loading_screen", "bottom_parent", "button_continue")
                local continue_elapsed = os.clock() - continue_wait_start

                if continue_btn then
                    continue_btn:SimulateLClick()
                    pcall(function() continue_btn:SetState("selected") end)
                    pcall(function() continue_btn:TriggerEvent("click") end)
                    debug_log("Continue button clicked, campaign ready")
                    write_campaign_success()
                elseif continue_elapsed >= CONTINUE_BUTTON_TIMEOUT then
                    debug_log("Continue button timeout after " .. CONTINUE_BUTTON_TIMEOUT .. "s, writing result")
                    write_campaign_success()
                else
                    -- Still waiting for Continue button
                    return
                end
            end
        elseif elapsed >= CAMPAIGN_START_TIMEOUT then
            campaign_start_pending = false
            ui_nav_state = 0
            continue_wait_start = 0
            core:remove_listener("Wh3McpCampaignStarted")
            delete_file(CAMPAIGN_START_MARKER)
            local result = json.encode({
                status = "error",
                error = "campaign start timeout after " .. CAMPAIGN_START_TIMEOUT .. "s"
            })
            write_file(RESULT_FILE, result)
            debug_log("Campaign start timed out")
        else
            return  -- still waiting, don't read command files
        end
    end

    local content, err = read_file(COMMAND_FILE)
    if not content then
        return
    end

    debug_log("Command file found, processing")

    -- Parse the command
    local ok, command = pcall(json.decode, content)
    if not ok or not command then
        -- Log the raw content: an empty read (write race) and a corrupted
        -- decode look identical without it.
        debug_log("Failed to parse JSON: ok=" .. tostring(ok) .. " err=" .. tostring(err) ..
                  " len=" .. tostring(#tostring(content)) ..
                  " content=[" .. tostring(content):sub(1, 200) .. "]")
        local error_result = json.encode({ status = "error", error = "failed to parse command JSON: " .. tostring(err) })
        write_file(RESULT_FILE, error_result)
        delete_file(COMMAND_FILE)
        return
    end

    debug_log("Command parsed: " .. tostring(command.command))

    -- Execute
    local ok, result = pcall(execute_command, command)
    if not ok then
        debug_log("Command execution error: " .. tostring(result))
        result = { status = "error", error = tostring(result) }
    end

    -- If result is nil, the command deferred its response (start_campaign waiting for load)
    if result == nil then
        debug_log("Command deferred (pending): " .. tostring(command.command))
        -- Quit sequences own QUIT_MARKER and write it themselves once the
        -- confirmation is accepted. Writing the campaign-start marker here would
        -- make the next script instance report a failed campaign start. The
        -- autoresolve and diplomacy sequences never leave the campaign context,
        -- so they need no marker either. Same for the move_options and
        -- research machines - a stale marker from one of those made the next
        -- boot report "campaign start failed" (hit live 2026-08-22).
        if not quit_pending and not autoresolve_pending and not diplomacy_pending
           and not moveopts_pending and not research_pending then
            -- Write marker with params so the next script instance knows what was attempted
            local marker_data = json.encode({
                command = command.command,
                params = command.params,
                is_new_game = campaign_start_params.is_new_game,
            })
            write_file(CAMPAIGN_START_MARKER, marker_data)
        end
        -- Delete command file so it's not re-read on reload
        delete_file(COMMAND_FILE)
        return
    end

    local ok2, result_json = pcall(json.encode, result)
    if not ok2 then
        debug_log("JSON encode error: " .. tostring(result_json))
        result_json = '{"status":"error","error":"json encode failed"}'
    end

    -- Write result
    local ok3 = write_file(RESULT_FILE, result_json)
    if not ok3 then
        debug_log("Failed to write result file")
    end

    -- Delete command file to signal it was processed
    delete_file(COMMAND_FILE)
    debug_log("Command processed: " .. tostring(command.command))
end

-- ---------------------------------------------------------------------------
-- Initialisation
-- ---------------------------------------------------------------------------

-- Step 1: Log that the script loaded
debug_log("Script loaded from _lib/mod")

-- Step 2: Start the poll loop
-- core:get_tm() is the game's timer manager, available at main menu AND in campaign.
-- cm:repeat_real_callback() only works during campaigns.
-- If neither is ready at load time, retry via a UICreated listener.

local function start_poll_loop()
    -- Priority 1: core timer manager (works everywhere)
    local tm = core:get_tm()
    if tm then
        tm:repeat_real_callback(poll, POLL_INTERVAL, "wh3_mcp_poll")
        debug_log("Poll loop started via core timer manager")
        return true
    end

    -- Priority 2: campaign manager (only during campaigns)
    if cm then
        local ok, err = pcall(cm.repeat_real_callback, cm, poll, POLL_INTERVAL)
        if ok then
            debug_log("Poll loop started via cm:repeat_real_callback")
            return true
        end
    end

    return false
end

-- Try starting immediately
if not start_poll_loop() then
    debug_log("Timer not ready yet, deferring via UICreated listener")
    core:add_listener(
        "Wh3McpInit",
        "UICreated",
        true,
        function()
            if start_poll_loop() then
                core:remove_listener("Wh3McpInit")
            end
        end,
        false
    )
end

-- Step 3: If we're in a campaign, check if we need to fulfill a pending campaign start
if in_campaign() then
    debug_log("Campaign detected, cm functions available")
    -- If there's a result file already, the campaign loaded before our poll loop started
    -- (e.g., this is a reload due to campaign load). Don't overwrite it.
    -- If there's a command file still present (unlikely but possible), process it.
    -- No action needed — the poll loop will handle normal operation.
end

-- Step 4: Check if this script instance is the result of a campaign load or failure.
-- When the game transitions contexts (main menu <-> campaign), all _lib/mod/ scripts
-- reload. If a start_campaign was pending in the previous instance (signaled by the
-- marker file), we need to write a result to unblock the Node.js server.
--
-- Cases:
--   A) Marker exists, in campaign → campaign loaded, write success
--   B) Marker exists, NOT in campaign → campaign failed, write error
--   C) No marker → initial game load, do nothing
--   D) Result file already exists → server already unblocked, do nothing
-- A quit_to_menu confirmed in the previous script instance leaves QUIT_MARKER
-- behind. Reaching this point means the context transition happened, so the
-- waiting server gets its result here. Returns true when the marker was handled.
local function check_quit_transition()
    local marker = io.open(QUIT_MARKER, "r")
    if not marker then return false end
    marker:close()
    delete_file(QUIT_MARKER)

    local result_file = io.open(RESULT_FILE, "r")
    if result_file then
        result_file:close()
        debug_log("Quit marker found but a result already exists")
        return true
    end

    if in_campaign() then
        debug_log("Quit marker found but still in a campaign — writing failure result")
        write_file(RESULT_FILE, json.encode({
            status = "error",
            error = "quit_to_menu: script reloaded but still in a campaign",
        }))
    else
        debug_log("Quit marker found and out of campaign — writing success result")
        write_file(RESULT_FILE, json.encode({
            status = "ok",
            result = { quit = true, in_campaign = false, method = "reload_detected" },
        }))
    end
    return true
end

local function check_context_transition()
    if check_quit_transition() then return end

    -- Check if a campaign start was attempted in the previous instance
    local marker = io.open(CAMPAIGN_START_MARKER, "r")
    if not marker then
        return  -- No pending campaign start, this is just the initial game load
    end
    local marker_content = marker:read("*a")
    marker:close()
    delete_file(CAMPAIGN_START_MARKER)

    -- Parse marker to get is_new_game flag
    local is_new_game = false
    local ok, marker_data = pcall(json.decode, marker_content)
    if ok and type(marker_data) == "table" then
        is_new_game = marker_data.is_new_game or false
        debug_log("Marker data: " .. tostring(marker_content))
    else
        -- Legacy marker (just "1")
        debug_log("Legacy marker, defaulting is_new_game=false")
    end

    -- Check if a result already exists (server may have already been satisfied)
    local result_file = io.open(RESULT_FILE, "r")
    if result_file then
        result_file:close()
        return
    end

    if in_campaign() then
        -- Campaign loaded successfully
        if is_new_game then
            -- New game: defer to poll loop for Continue button handling
            debug_log("Campaign detected at init with marker — is_new_game=true, deferring to poll loop")
            campaign_start_pending = true
            campaign_start_params = { method = "reload_detected", is_new_game = true }
            campaign_start_time = os.clock()
        else
            -- Load game: write success immediately (no Continue button)
            debug_log("Campaign detected at init with marker — is_new_game=false, writing success")
            local result = json.encode({
                status = "ok",
                result = {
                    method = "reload_detected",
                    already_in_campaign = true,
                }
            })
            write_file(RESULT_FILE, result)
        end
    else
        -- Case B: Campaign start was attempted but failed
        debug_log("Campaign marker found but not in campaign — writing failure result")
        local result = json.encode({
            status = "error",
            error = "campaign start failed during initialization"
        })
        write_file(RESULT_FILE, result)
    end
end
check_context_transition()
