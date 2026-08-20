# build.ps1 ??? Package the WH3 MCP mod into a .pack file
# Uses the RPFM MCP server (must be running on :45127).
# Run this after editing pack/script/_lib/mod/wh3_mcp.lua
#
# The pack is saved to the project folder first, then copied to the WH3 data
# directory. If WH3 has the file locked (running), the copy is retried every
# 2 seconds for up to 30 seconds (exit to main menu may release the lock).

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSCommandPath
$LuaPath = Join-Path $ProjectRoot 'pack\script\_lib\mod\wh3_mcp.lua'
$BuildPath = Join-Path $ProjectRoot 'wh3_mcp_server.pack'
$DeployPath = 'C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\wh3_mcp_server.pack'
$BaseUrl = 'http://127.0.0.1:45127/mcp'

if (-not (Test-Path $LuaPath)) { Write-Error "Lua script not found: $LuaPath"; exit 1 }

# ---------------------------------------------------------------------------
# 1. RPFM session
# ---------------------------------------------------------------------------
Write-Host '=== RPFM: init session ==='
$initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wh3-mcp","version":"1.0"}}}'
$initBody | Out-File "$env:TEMP\mcp_init.json" -Encoding ascii
$headers = curl.exe -s -D - -X POST $BaseUrl -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "@$env:TEMP\mcp_init.json" 2>&1
$SessionId = ($headers -split "`n" | Where-Object { $_ -match 'mcp-session-id' } | ForEach-Object { ($_ -split ': ')[1].Trim() })
if (-not $SessionId) { Write-Error "RPFM session failed: $headers"; exit 1 }

function Rpc {
    param($Method, $ArgsJson)
    $body = @{ jsonrpc='2.0'; id=[int](Get-Random -Min 1000 -Max 9999); method='tools/call'; params=@{ name=$Method; arguments=$ArgsJson } } | ConvertTo-Json -Compress -Depth 5
    $path = "$env:TEMP\mcp_rpc_$([int](Get-Random -Min 1000 -Max 9999)).json"
    $body | Out-File $path -Encoding ascii
    $r = curl.exe -s -X POST $BaseUrl -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SessionId" -d "@$path" 2>&1
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    return ($r -match '"isError":false')
}

# ---------------------------------------------------------------------------
# 2. Set game
# ---------------------------------------------------------------------------
Write-Host '=== RPFM: set game ==='
Rpc 'set_game_selected' @{ game_name='warhammer_3'; rebuild_dependencies=$true } | Out-Null

# ---------------------------------------------------------------------------
# 3. Close stale packs, create new pack
# ---------------------------------------------------------------------------
Write-Host '=== RPFM: close + new pack ==='
Rpc 'close_all_packs' @{} | Out-Null
$npBody = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"new_pack","arguments":{}}}'
$npBody | Out-File "$env:TEMP\mcp_newpack.json" -Encoding ascii
$npResp = curl.exe -s -X POST $BaseUrl -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SessionId" -d "@$env:TEMP\mcp_newpack.json" 2>&1
if ($npResp -match '"String":"([^"]+)"') { $PackKey = $Matches[1] } elseif ($npResp -match 'new_pack\.pack') { $PackKey = 'new_pack.pack' } else { Write-Error "new_pack failed: $npResp"; exit 1 }
Write-Host "Pack key: $PackKey"

# ---------------------------------------------------------------------------
# 4. Add Lua file
# ---------------------------------------------------------------------------
Write-Host '=== RPFM: add Lua file ==='
$EscapedLuaPath = $LuaPath -replace '\\', '\\'
$addBody = @"
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_packed_files","arguments":{"pack_key":"$PackKey","source_paths":["$EscapedLuaPath"],"destination_paths":"[{\"File\":\"script/_lib/mod/wh3_mcp.lua\"}]"}}}
"@
$addBody | Out-File "$env:TEMP\mcp_add.json" -Encoding ascii
$r = curl.exe -s -X POST $BaseUrl -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SessionId" -d "@$env:TEMP\mcp_add.json" 2>&1
if ($r -match '"isError":false') { Write-Host 'File added OK' } else { Write-Error "Add file failed: $r"; exit 1 }

# ---------------------------------------------------------------------------
# 5. Save to project folder (always writable)
# ---------------------------------------------------------------------------
Write-Host '=== RPFM: save pack ==='
$EscapedBuildPath = $BuildPath -replace '\\', '\\'
$saveBody = @"
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"save_pack_as","arguments":{"pack_key":"$PackKey","path":"$EscapedBuildPath"}}}
"@
$saveBody | Out-File "$env:TEMP\mcp_save.json" -Encoding ascii
$r = curl.exe -s -X POST $BaseUrl -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SessionId" -d "@$env:TEMP\mcp_save.json" 2>&1
if ($r -match '"isError":false') {
    Write-Host "Pack saved to project: $BuildPath"
} else {
    Write-Error "Save failed: $r"; exit 1
}

# ---------------------------------------------------------------------------
# 6. Deploy to WH3 data dir (retry if locked by running game)
# ---------------------------------------------------------------------------
Write-Host '=== Deploy to WH3 data ==='
$maxRetries = 15
$retryDelay = 2  # seconds
for ($i = 0; $i -lt $maxRetries; $i++) {
    try {
        Copy-Item -Path $BuildPath -Destination $DeployPath -Force -ErrorAction Stop
        Write-Host "Deployed to: $DeployPath"
        Write-Host 'Build complete!'
        exit 0
    } catch {
        if ($i -lt $maxRetries - 1) {
            Write-Host "  (locked by WH3, retrying in ${retryDelay}s...)"
            Start-Sleep -Seconds $retryDelay
        } else {
            Write-Warning "Could not deploy (WH3 has file locked). Pack built at: $BuildPath"
            Write-Warning "Copy manually after closing WH3: Copy-Item '$BuildPath' '$DeployPath' -Force"
            Write-Host 'Build complete (not deployed)!'
            exit 0  # not a failure
        }
    }
}