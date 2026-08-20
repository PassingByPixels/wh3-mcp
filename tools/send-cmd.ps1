# send-cmd.ps1 - write a command JSON for the wh3_mcp mod and wait for the result.
# Usage: .\send-cmd.ps1 -Json '{"command":"ping","params":{}}' [-TimeoutSec 30]
# ASCII only (PS 5.1 reads BOM-less UTF-8 as CP1252).
param(
    [Parameter(Mandatory = $true)][string]$Json,
    [int]$TimeoutSec = 30
)

$wh3 = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III"
$cmdFile = Join-Path $wh3 "wh3_mcp_command.json"
$resFile = Join-Path $wh3 "wh3_mcp_result.json"

Remove-Item $resFile -ErrorAction SilentlyContinue
Set-Content -Path $cmdFile -Value $Json -NoNewline -Encoding Ascii

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resFile) {
        Start-Sleep -Milliseconds 300
        $r = Get-Content $resFile -Raw -ErrorAction SilentlyContinue
        if ($r) {
            Remove-Item $resFile -ErrorAction SilentlyContinue
            Write-Output $r
            return
        }
    }
    Start-Sleep -Milliseconds 500
}
Write-Output ('{"status":"timeout","error":"no result within ' + $TimeoutSec + 's"}')
