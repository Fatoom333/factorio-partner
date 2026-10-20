# Сравнение пилотов: одно поручение пилоту на стенде, модель выбирается параметром (docs/TESTING.md).
# Запускать на ноутбуке из PowerShell (ssh из Git Bash не видит ssh-agent с ключами).
#
#   powershell -File tools/pc/run-pilot-bench.ps1 -Model sonnet -Run 1
#   powershell -File tools/pc/run-pilot-bench.ps1 -Model haiku  -Run 1
#
# Что делает за один прогон:
# 1. run-live.ps1 -Local поднимает стенд (сервер игры без окна на копии сейва, слот -Slot) и запускает
#    сценарий pilot_bench в фазе full: он создаёт помощника, снимает начало, ждёт, пока агент выполнит
#    поручение, и сам судит результат.
# 2. Когда сценарий готов (файл ready), agents/launch.py выдаёт помощнику ключ и пишет конфигурацию MCP;
#    MCP-сервер идёт на этой машине к RCON слота через SSH-туннель run-live.
# 3. bench.pilot_agent запускает `claude -p --agent partner-pilot --model <Model>` с одним MCP-сервером
#    и поручением. Смену останавливают: время (-MaxMinutes), число ходов (-MaxTurns), конец сценария.
# 4. Сценарий судит результат, стенд останавливается и убирается; в -Root (по умолчанию %TEMP%\fp-pilot-bench)
#    остаются каталог прогона <Model>-<Run> (transcript.jsonl, results-<слот>.json, agent-run.json) и
#    manifest.json для `python -m bench.summary`.
# Не запускать, пока хозяин играет (на ПК не должно быть процесса factorio.exe) и пока занят слот.
# Код выхода: 0 — прогон выполнен и поручение доведено, 1 — выполнен, но не доведено, 2 — сбой стенда или агента.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9._-]{1,64}$')]
    [string]$Model,

    [ValidateRange(1, 99)]
    [int]$Run = 1,

    [ValidateRange(0, 9)]
    [int]$Slot = 8,

    [ValidateRange(1, 60)]
    [double]$MaxMinutes = 15,

    [ValidateRange(5, 1000)]
    [int]$MaxTurns = 120,

    [string]$Root,

    [string]$Python,

    [string]$Claude = 'claude',

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}\.zip$')]
    [string]$Save = 'Vulkan-Start-test.zip',

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$SshHost = 'pc',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,

    # Расход лимита (get_usage, 5-часовое окно, %) до и после — в сводку.
    [double]$UsageBefore = [double]::NaN,
    [double]$UsageAfter = [double]::NaN
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $Here '..\..')).Path
if (-not $Python) { $Python = Join-Path $env:TEMP 'fp-venv\Scripts\python.exe' }
if (-not $Root) { $Root = Join-Path $env:TEMP 'fp-pilot-bench' }
$Label = "$Model-$Run"
$OutDir = Join-Path $Root $Label
$BenchDir = Join-Path $OutDir 'bench'
$HomeDir = Join-Path $OutDir 'home'
$AgentCwd = Join-Path $OutDir 'agent-cwd'
$Port = 27100 + $Slot

function Q([string]$s) { return '"' + $s + '"' }

if (-not (Test-Path -LiteralPath $Python)) { throw "нет Python стенда: $Python (venv — docs/TESTING.md)" }

# На ПК не должна идти игра: проверка по SSH (только чтение).
$probe = "if (Get-Process factorio -ErrorAction SilentlyContinue) { 'GAME_RUNNING' } else { 'GAME_FREE' }"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$ErrorActionPreference = 'Continue'
$probeOut = (& ssh -o BatchMode=yes -o ConnectTimeout=20 $SshHost "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>$null) -join "`n"
$ErrorActionPreference = 'Stop'
if ($probeOut -notmatch 'GAME_FREE') {
    throw "на ПК идёт игра или ПК недоступен (ответ: $probeOut) — прогон не начат"
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $BenchDir, $HomeDir, (Join-Path $AgentCwd '.claude\agents') | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot '.claude\agents\partner-pilot.md') -Destination (Join-Path $AgentCwd '.claude\agents') -Force

$env:FP_BENCH_DIR = $BenchDir
$env:FP_BENCH_PHASE = 'full'
$env:FP_BENCH_HELPER = 'h1'
$env:FP_BENCH_WAIT_S = [string][int]($MaxMinutes * 60 + 90)
$timeoutSec = [int]($MaxMinutes * 60 + 600)

$liveLog = Join-Path $OutDir 'run-live.log'
$liveArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Q (Join-Path $Here 'run-live.ps1')),
    '-Slot', $Slot, '-Scenario', 'pilot_bench', '-Local', '-OutDir', (Q $OutDir), '-Python', (Q $Python),
    '-Save', $Save, '-SshHost', $SshHost, '-TimeoutSec', $timeoutSec) -join ' '
Write-Host "прогон $Label (слот $Slot): поднимаю стенд"
$live = Start-Process -FilePath 'powershell' -ArgumentList $liveArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $liveLog -RedirectStandardError (Join-Path $OutDir 'run-live.err')

$status = 2
$agentInfo = $null
try {
    # Ждём, пока сценарий создаст помощника и снимет начало (ready) и появится пароль RCON слота.
    $ready = Join-Path $BenchDir 'ready'
    $pw = Join-Path $OutDir 'local\rcon.pw'
    $deadline = (Get-Date).AddSeconds(600)
    while (-not ((Test-Path -LiteralPath $ready) -and (Test-Path -LiteralPath $pw))) {
        if ($live.HasExited) { throw "стенд завершился до готовности (см. $liveLog)" }
        if ((Get-Date) -gt $deadline) { throw 'стенд не стал готов за 10 минут' }
        Start-Sleep -Seconds 5
    }
    Write-Host 'стенд готов, выдаю ключ помощнику'

    # Ключ и конфигурация MCP: пароль RCON не копируется, в конфигурацию идёт только путь к файлу.
    $env:FP_HOME = $HomeDir
    $env:FP_RCON_HOST = '127.0.0.1'
    $env:FP_RCON_PORT = [string]$Port
    $env:FP_RCON_PASSWORD_FILE = $pw
    & $Python (Join-Path $RepoRoot 'agents\launch.py') --helpers 1 --body character --helper h1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'agents/launch.py не отработал' }

    $agentArgs = @('-m', 'bench.pilot_agent', 'run', '--model', $Model, '--cwd', $AgentCwd,
        '--mcp-config', (Join-Path $HomeDir 'launch\mcp.json'), '--session', (Join-Path $HomeDir 'launch\session.json'),
        '--helper', 'h1', '--out', $OutDir, '--max-minutes', $MaxMinutes, '--max-turns', $MaxTurns,
        '--watch-pid', $live.Id, '--claude', $Claude)
    if ($Effort) { $agentArgs += @('--effort', $Effort) }
    Write-Host "запускаю пилота ($Model), не дольше $MaxMinutes мин и $MaxTurns ходов"
    Push-Location (Join-Path $Here '.')
    try {
        & $Python @agentArgs | Out-Host
        $agentCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($agentCode -ne 0) { throw 'запуск агента не удался' }
    $agentInfo = Get-Content -LiteralPath (Join-Path $OutDir 'agent-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host "ошибка прогона: $($_.Exception.Message)"
}
finally {
    # Смена кончилась (или сбой): сказать сценарию, что пора судить, и дождаться уборки стенда.
    if (-not $live.HasExited) {
        New-Item -ItemType File -Force -Path (Join-Path $BenchDir 'stop') | Out-Null
        if (-not $live.WaitForExit(600000)) {
            Write-Host 'run-live не завершился за 10 минут — прерываю (слот на ПК проверить вручную)'
            Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$resultFile = Join-Path $OutDir "results-$Slot.json"
if ($agentInfo -and (Test-Path -LiteralPath $resultFile)) {
    $recordArgs = @('-m', 'bench.pilot_agent', 'record', '--manifest', (Join-Path $Root 'manifest.json'),
        '--label', $Label, '--model', $Model, '--transcript', "$Label/transcript.jsonl",
        '--result', "$Label/results-$Slot.json", '--until', $agentInfo.ended_at)
    if (-not [double]::IsNaN($UsageBefore)) { $recordArgs += @('--usage-before', $UsageBefore) }
    if (-not [double]::IsNaN($UsageAfter)) { $recordArgs += @('--usage-after', $UsageAfter) }
    Push-Location $Here
    try { & $Python @recordArgs | Out-Host } finally { Pop-Location }
    $res = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ("итог: {0}, агент остановлен: {1}, каталог: {2}" -f $res.verdict, $agentInfo.reason, $OutDir)
    $status = if ($res.verdict -eq 'done') { 0 } else { 1 }
}
else {
    Write-Host "прогон не дал результата (см. $liveLog и $(Join-Path $OutDir 'run-live.err'))"
}
exit $status
