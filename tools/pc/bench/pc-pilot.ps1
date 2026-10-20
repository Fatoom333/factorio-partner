# Смена пилота на ПК (вызывается из run-pilot-bench.ps1 -AgentOn pc по SSH; руками не нужна).
# Консольный claude залогинен на ПК, а не на ноутбуке: на ПК ставятся ключ помощника и MCP-сервер
# (RCON слота — 127.0.0.1 на этой же машине), запускается bench.pilot_agent. Стенд поднимает ноутбук.
#   pc-pilot.ps1 -Stage <каталог с bench\, task.txt, pilot-bench.local.json> -Label sonnet-1 -Model sonnet -Slot 8
# Остановка смены снаружи — файл <Out>\stop. Итоги (agent-run.json, transcript.jsonl, agent-stdout.txt) — в <Out>.
# Код ПК (сервер, launch.py, правила пилота) должен совпадать с коммитом, из которого собран стенд
# (-ExpectCommit): иначе смена не начинается. -Sync подтягивает папку проекта до origin/main только
# перемоткой (fast-forward) и только без локальных правок; свои коммиты ПК не откатываются никогда.
# В agent-run.json дописываются pc_commit и stand_commit.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9._-]{1,64}$')][string]$Label,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9._-]{1,64}$')][string]$Model,
    [ValidateRange(0, 9)][int]$Slot = 8,
    [double]$MaxMinutes = 15,
    [int]$MaxTurns = 120,
    [string]$Effort,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectCommit,
    [switch]$Sync
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$Stage = (Resolve-Path -LiteralPath $Stage).Path
$cfg = Get-Content -LiteralPath (Join-Path $Stage 'pilot-bench.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$repo = $cfg.repo
if (-not $repo -or -not (Test-Path -LiteralPath $repo)) { throw 'в pilot-bench.local.json нет ключа repo (папка проекта на ПК) или её нет' }
$py = Join-Path $repo '.venv\Scripts\python.exe'
$claude = if ($cfg.PSObject.Properties['claude'] -and $cfg.claude) { $cfg.claude } else { Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (Get-CimInstance Win32_Process -Filter "Name='factorio.exe'" | Where-Object { -not $_.CommandLine -or $_.CommandLine -notmatch 'fp-live-' }) {
    throw 'на ПК идёт игра хозяина — смена не начата'
}
if ($Sync) {
    $dirty = git -C $repo status --short
    if ($dirty) { Write-Host 'в папке проекта на ПК есть изменения — git не трогаю'; $dirty }
    else {
        git -C $repo fetch -q --prune origin
        if ($LASTEXITCODE -ne 0) { throw 'git fetch на ПК не прошёл' }
        git -C $repo merge-base --is-ancestor HEAD origin/main
        if ($LASTEXITCODE -ne 0) { throw 'на ПК есть коммиты, которых нет в origin/main — папку проекта не трогаю, смена не начата' }
        git -C $repo merge -q --ff-only origin/main
        if ($LASTEXITCODE -ne 0) { throw 'перемотка до origin/main на ПК не прошла' }
    }
}
$pcCommit = ((git -C $repo rev-parse HEAD) -join '').Trim()
Write-Host ("код на ПК: " + (git -C $repo log --oneline -1))
if ($pcCommit -ne $ExpectCommit) {
    throw "код на ПК ($pcCommit) не тот, из которого собран стенд ($ExpectCommit) — смена не начата (отправь коммит и запусти с -Sync)"
}
$pcDirty = git -C $repo status --porcelain -- server agents .claude/agents
if ($pcDirty) { $pcDirty; throw 'в коде на ПК есть незакоммиченные правки (server, agents, правила) — смена не начата' }

$out = Join-Path $HOME ("fp-pilot-run\" + $Label)
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
$home1 = Join-Path $out 'home'
$cwd = Join-Path $out 'agent-cwd'
New-Item -ItemType Directory -Force -Path $home1, (Join-Path $cwd '.claude\agents') | Out-Null
Copy-Item -LiteralPath (Join-Path $repo '.claude\agents\partner-pilot.md') -Destination (Join-Path $cwd '.claude\agents') -Force

$pw = "D:\Temp\fp-live-$Slot\rcon.pw"
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path -LiteralPath $pw)) {
    if ((Get-Date) -gt $deadline) { throw "нет файла пароля слота $Slot ($pw)" }
    Start-Sleep -Seconds 2
}
$env:FP_HOME = $home1
$env:FP_RCON_HOST = '127.0.0.1'
$env:FP_RCON_PORT = [string](27100 + $Slot)
$env:FP_RCON_PASSWORD_FILE = $pw
& $py -X utf8 (Join-Path $repo 'agents\launch.py') --helpers 1 --body character --helper h1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'agents/launch.py не отработал' }

$runArgs = @('-X', 'utf8', '-m', 'bench.pilot_agent', 'run', '--model', $Model, '--cwd', $cwd,
    '--mcp-config', (Join-Path $home1 'launch\mcp.json'), '--session', (Join-Path $home1 'launch\session.json'),
    '--helper', 'h1', '--out', $out, '--max-minutes', $MaxMinutes, '--max-turns', $MaxTurns,
    '--stop-file', (Join-Path $out 'stop'), '--task-file', (Join-Path $Stage 'task.txt'), '--claude', $claude)
if ($Effort) { $runArgs += @('--effort', $Effort) }
Write-Host "пилот ($Model) пошёл"
Set-Location -LiteralPath $Stage
& $py @runArgs | Out-Host
$code = $LASTEXITCODE
$runFile = Join-Path $out 'agent-run.json'
if (Test-Path -LiteralPath $runFile) {
    $run = Get-Content -LiteralPath $runFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $run | Add-Member -NotePropertyName pc_commit -NotePropertyValue $pcCommit -Force
    $run | Add-Member -NotePropertyName stand_commit -NotePropertyValue $ExpectCommit -Force
    [IO.File]::WriteAllText($runFile, ($run | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
}
Write-Host "PILOT_DONE $code"
exit $code
