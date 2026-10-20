# Сквозной час трёх ролей на стенде: голос, пилот и стратег ведут одного помощника без игрока (docs/TESTING.md).
# Запускать из PowerShell на машине, где залогинен claude (не из Git Bash: ssh оттуда не видит ssh-agent).
#
#   powershell -File tools/pc/run-roles-hour.ps1 -PilotModel sonnet -Run 1
#   powershell -File tools/pc/run-roles-hour.ps1 -PilotModel haiku  -Run 1 -MaxMinutes 20
#
# Что делает за один прогон (по образцу run-pilot-bench.ps1):
# 1. run-live.ps1 -Local поднимает стенд (сервер игры без окна на копии сейва, слот -Slot) и запускает
#    сценарий roles_hour в фазе full: он создаёт помощника, кладёт в заметки прогона правило сейва
#    "AUTO: <цель>" (самостоятельный режим стратега), снимает начало и ждёт, а потом судит результат.
# 2. Когда сценарий готов (файл ready), agents/launch.py --roles выдаёт ключи трёх ролей и пишет конфигурацию
#    MCP; каждый MCP-сервер идёт к RCON слота через SSH-туннель run-live. FP_NOTES_DIR и FP_SAVE_NAME прогона
#    launch.py передаёт в конфигурацию MCP: пакеты и правила лежат в каталоге прогона, а не в save-notes репозитория.
# 3. Три `claude -p --agent partner-<роль>` запускаются одновременно, каждый одной сменой, с первым сообщением
#    роли из файла сессии (через файл на стандартном вводе: ключ роли не попадает в список процессов).
#    Смены кончаются по времени (-MaxMinutes), по концу сценария или по файлу stop. Перезапуск смен с
#    выжимкой делает agents/workflows/partner-roles.js (запускается из сессии Claude Code, не отсюда): здесь
#    замеряется один непрерывный час ролей.
# 4. Сценарий судит результат; обвязка считает по журналам смен ходы и вызовы каждой роли, ошибки и минуты
#    (bench.transcript_stats) и пишет roles-hour-report.json в каталог прогона (по умолчанию
#    %TEMP%\fp-roles-hour\<Модель пилота>-<Run>): число пакетов verified/unmet, занятость тела (busy_share),
#    метрики ролей, расход лимита. Слова хозяина в этом прогоне не подаются: они помечены в отчёте как
#    "проверяется хозяином в игре".
# Не запускать, пока хозяин играет (на ПК не должно быть процесса factorio.exe) и пока занят слот.
# -SshHost: имя, по которому эта машина достаёт ПК (на самом ПК — имя, ведущее на него же, например localhost).
# Код выхода: 0 - цель достигнута, 1 - прогон выполнен, но не достигнута, 2 - сбой стенда или агентов.

[CmdletBinding()]
param(
    [ValidateSet('sonnet', 'haiku')]
    [string]$PilotModel = 'sonnet',

    [ValidateRange(1, 99)]
    [int]$Run = 1,

    [ValidateRange(0, 9)]
    [int]$Slot = 8,

    [ValidateRange(1, 100)]
    [double]$MaxMinutes = 60,

    [string]$Root,

    [string]$Python,

    [string]$Claude = 'claude',

    # Копия сейва для стенда (имя zip в папке сохранений ПК). Пусто — ключ `save` из tools/pc/pc.local.json.
    [ValidatePattern('^([A-Za-z0-9._-]{1,64}\.zip)?$')]
    [string]$Save = '',

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$SshHost = 'pc',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,

    # Расход лимита (get_usage, 5-часовое окно, %) до и после — в отчёт.
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
if (-not $Root) { $Root = Join-Path $env:TEMP 'fp-roles-hour' }
$Label = "$PilotModel-$Run"
$OutDir = Join-Path $Root $Label
$BenchDir = Join-Path $OutDir 'bench'
$HomeDir = Join-Path $OutDir 'home'
$NotesDir = Join-Path $OutDir 'notes'
$AgentCwd = Join-Path $OutDir 'agent-cwd'
$SaveName = 'roles-hour'
$Port = 27100 + $Slot
$Roles = @('voice', 'pilot', 'strategist')

function Q([string]$s) { return '"' + $s + '"' }

function Find-Transcript([string]$SessionId) {
    $projects = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $projects)) { return $null }
    foreach ($d in Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue) {
        $p = Join-Path $d.FullName "$SessionId.jsonl"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Stop-Tree($proc) {
    if ($proc -and -not $proc.HasExited) {
        & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        $null = $proc.WaitForExit(15000)
    }
}

if (-not (Test-Path -LiteralPath $Python)) { throw "нет Python стенда: $Python (venv - docs/TESTING.md)" }
if (-not $Save) {
    $PcConfig = Join-Path $Here 'pc.local.json'
    $PcCfg = $null
    if (Test-Path -LiteralPath $PcConfig) { $PcCfg = Get-Content -LiteralPath $PcConfig -Raw -Encoding UTF8 | ConvertFrom-Json }
    if ($PcCfg -and $PcCfg.PSObject.Properties['save'] -and $PcCfg.save) { $Save = [string]$PcCfg.save }
    else { throw 'не задан сейв стенда: параметр -Save или ключ save в tools/pc/pc.local.json' }
}
if ($Save -notmatch '^[A-Za-z0-9._-]{1,64}\.zip$') { throw "имя сейва стенда не подходит: $Save" }

# На ПК не должна идти игра: проверка по SSH (только чтение).
$probe = "if (Get-Process factorio -ErrorAction SilentlyContinue) { 'GAME_RUNNING' } else { 'GAME_FREE' }"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$ErrorActionPreference = 'Continue'
$probeOut = (& ssh -o BatchMode=yes -o ConnectTimeout=20 $SshHost "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>$null) -join "`n"
$ErrorActionPreference = 'Stop'
if ($probeOut -notmatch 'GAME_FREE') {
    throw "на ПК идёт игра или ПК недоступен (ответ: $probeOut) - прогон не начат"
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $BenchDir, $HomeDir, $NotesDir, (Join-Path $AgentCwd '.claude\agents') | Out-Null
foreach ($r in $Roles) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot ".claude\agents\partner-$r.md") -Destination (Join-Path $AgentCwd '.claude\agents') -Force
}

$env:FP_BENCH_DIR = $BenchDir
$env:FP_BENCH_PHASE = 'full'
$env:FP_BENCH_HELPER = 'h1'
$env:FP_BENCH_WAIT_S = [string][int]($MaxMinutes * 60 + 90)
$env:FP_NOTES_DIR = $NotesDir
$env:FP_SAVE_NAME = $SaveName
$timeoutSec = [int]($MaxMinutes * 60 + 600)

$liveLog = Join-Path $OutDir 'run-live.log'
$liveArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Q (Join-Path $Here 'run-live.ps1')),
    '-Slot', $Slot, '-Scenario', 'roles_hour', '-Local', '-OutDir', (Q $OutDir), '-Python', (Q $Python),
    '-Save', $Save, '-SshHost', $SshHost, '-TimeoutSec', $timeoutSec) -join ' '
Write-Host "прогон $Label (слот $Slot): поднимаю стенд"
$live = Start-Process -FilePath 'powershell' -ArgumentList $liveArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $liveLog -RedirectStandardError (Join-Path $OutDir 'run-live.err')

$status = 2
$agents = @{}          # роль -> @{ proc; sid; model; agent; prompt }
$startedAt = $null
$endedAt = $null
$endReason = 'agents_exit'
try {
    # Ждём, пока сценарий создаст помощника, запишет правило сейва и снимет начало (ready) и появится пароль RCON.
    $ready = Join-Path $BenchDir 'ready'
    $pw = Join-Path $OutDir 'local\rcon.pw'
    $deadline = (Get-Date).AddSeconds(600)
    while (-not ((Test-Path -LiteralPath $ready) -and (Test-Path -LiteralPath $pw))) {
        if ($live.HasExited) { throw "стенд завершился до готовности (см. $liveLog)" }
        if ((Get-Date) -gt $deadline) { throw 'стенд не стал готов за 10 минут' }
        Start-Sleep -Seconds 5
    }
    Write-Host 'стенд готов, выдаю ключи трём ролям'

    # Ключи и конфигурация MCP: пароль RCON не копируется, в конфигурацию идёт только путь к файлу.
    $env:FP_HOME = $HomeDir
    $env:FP_RCON_HOST = '127.0.0.1'
    $env:FP_RCON_PORT = [string]$Port
    $env:FP_RCON_PASSWORD_FILE = $pw
    & $Python (Join-Path $RepoRoot 'agents\launch.py') --helpers 1 --body character --helper h1 --roles --pilot-model $PilotModel | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'agents/launch.py не отработал' }

    $session = Get-Content -LiteralPath (Join-Path $HomeDir 'launch\session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $h1 = $session.helpers | Where-Object { $_.id -eq 'h1' } | Select-Object -First 1
    if (-not $h1) { throw 'в файле сессии нет помощника h1' }

    $utf8 = New-Object Text.UTF8Encoding($false)
    foreach ($r in $Roles) {
        $role = $h1.roles.PSObject.Properties[$r].Value
        # пакеты и правила прогона - в каталоге прогона: FP_NOTES_DIR и FP_SAVE_NAME launch.py сам кладёт
        # в env конфигурации MCP
        $promptFile = Join-Path $OutDir "prompt-$r.txt"
        [IO.File]::WriteAllText($promptFile, [string]$role.prompt, $utf8)
        $sid = [guid]::NewGuid().ToString()
        $agents[$r] = @{ sid = $sid; model = [string]$role.model; agent = [string]$role.agent; prompt = $promptFile; proc = $null }
    }

    $startedAt = (Get-Date).ToUniversalTime()
    Write-Host "запускаю три роли одновременно (пилот: $PilotModel), не дольше $MaxMinutes мин"
    foreach ($r in $Roles) {
        $a = $agents[$r]
        $role = $h1.roles.PSObject.Properties[$r].Value
        $claudeArgs = @('-p', '--agent', (Q $a.agent), '--model', (Q $a.model),
            '--mcp-config', (Q $role.mcp_config), '--strict-mcp-config',
            '--allowedTools', (Q 'mcp__partner__*'), '--permission-mode', 'dontAsk',
            '--session-id', $a.sid, '--setting-sources', 'project', '--disable-slash-commands',
            '--output-format', 'text')
        if ($Effort) { $claudeArgs += @('--effort', $Effort) }
        $a.proc = Start-Process -FilePath $Claude -ArgumentList ($claudeArgs -join ' ') -WorkingDirectory $AgentCwd `
            -PassThru -NoNewWindow -RedirectStandardInput $a.prompt `
            -RedirectStandardOutput (Join-Path $OutDir "agent-$r-stdout.txt") `
            -RedirectStandardError (Join-Path $OutDir "agent-$r-stderr.txt")
    }

    $t0 = Get-Date
    $stopFile = Join-Path $BenchDir 'stop'
    while ($true) {
        Start-Sleep -Seconds 3
        if ($live.HasExited) { $endReason = 'scenario_ended'; break }
        if (Test-Path -LiteralPath $stopFile) { $endReason = 'stop_file'; break }
        if (((Get-Date) - $t0).TotalMinutes -ge $MaxMinutes) { $endReason = 'timeout'; break }
        $alive = @($Roles | Where-Object { -not $agents[$_].proc.HasExited })
        if ($alive.Count -eq 0) { $endReason = 'agents_exit'; break }
    }
}
catch {
    Write-Host "ошибка прогона: $($_.Exception.Message)"
    $endReason = 'error'
}
finally {
    $endedAt = (Get-Date).ToUniversalTime()
    foreach ($r in $Roles) {
        if ($agents.ContainsKey($r)) {
            Stop-Tree $agents[$r].proc
            # первое сообщение роли несёт её ключ: после смены файл не нужен
            Remove-Item -LiteralPath $agents[$r].prompt -Force -ErrorAction SilentlyContinue
        }
    }
    # Смены кончились (или сбой): сказать сценарию, что пора судить, и дождаться уборки стенда.
    if (-not $live.HasExited) {
        New-Item -ItemType File -Force -Path (Join-Path $BenchDir 'stop') | Out-Null
        if (-not $live.WaitForExit(600000)) {
            Write-Host 'run-live не завершился за 10 минут - прерываю (слот на ПК проверить вручную)'
            Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$resultFile = Join-Path $OutDir "results-$Slot.json"
if ($agents.Count -gt 0 -and (Test-Path -LiteralPath $resultFile)) {
    $res = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $until = $endedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $roleReports = [ordered]@{}
    $totals = @{ model_turns = 0; tool_calls = 0; tool_errors = 0; soft_errors = 0 }
    Push-Location $Here
    try {
        foreach ($r in $Roles) {
            $a = $agents[$r]
            $src = Find-Transcript $a.sid
            $entry = [ordered]@{ agent = $a.agent; model = $a.model; transcript = $null }
            if ($src) {
                $dst = Join-Path $OutDir "transcript-$r.jsonl"
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $entry.transcript = "transcript-$r.jsonl"
                $json = (& $Python -m bench.transcript_stats $dst --json --until $until) -join "`n"
                if ($LASTEXITCODE -eq 0) {
                    $st = $json | ConvertFrom-Json
                    $entry.model_turns = $st.model_turns
                    $entry.tool_calls = $st.tool_calls
                    $entry.tool_errors = $st.tool_errors
                    $entry.soft_errors = $st.soft_errors
                    $entry.active_min = [math]::Round($st.active_s / 60, 1)
                    $entry.duration_min = [math]::Round($st.duration_s / 60, 1)
                    $entry.by_short = $st.by_short
                    $entry.tokens = $st.tokens
                    foreach ($k in $totals.Keys.Clone()) { $totals[$k] += [int]$st.$k }
                }
                else { $entry.error = 'transcript_stats не разобрал журнал' }
            }
            else { $entry.error = 'журнал смены не найден' }
            $roleReports[$r] = $entry
        }
    }
    finally { Pop-Location }

    # Голос в этом прогоне должен молчать: игрока нет, говорить ему не с кем.
    $voice = $roleReports['voice']
    $voiceSays = 0
    if ($voice.Contains('by_short') -and $voice.by_short.PSObject.Properties['partner_say']) {
        $voiceSays = [int]$voice.by_short.partner_say
    }
    $usage = $null
    if (-not [double]::IsNaN($UsageBefore) -and -not [double]::IsNaN($UsageAfter)) {
        $usage = [ordered]@{ five_hour_before = $UsageBefore; five_hour_after = $UsageAfter; spent = [math]::Round($UsageAfter - $UsageBefore, 2) }
    }
    $report = [ordered]@{
        label        = $Label
        pilot_model  = $PilotModel
        verdict      = $res.verdict
        ok           = $res.ok
        ended_by     = $res.ended_by
        agents_ended = $endReason
        started_at   = $startedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ended_at     = $endedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        wall_min     = [math]::Round(($endedAt - $startedAt).TotalMinutes, 1)
        packages     = $res.packages
        body         = $res.body
        module_errors = $res.module_errors
        chests_new   = $res.chests_new
        roles        = $roleReports
        totals       = $totals
        voice_say_calls = $voiceSays
        usage        = $usage
        owner_words  = $res.owner_words
    }
    $reportFile = Join-Path $OutDir 'roles-hour-report.json'
    [IO.File]::WriteAllText($reportFile, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $p = $res.packages
    $busyMean = if ($res.body.PSObject.Properties['busy_share_mean']) { $res.body.busy_share_mean } else { 'нет данных' }
    Write-Host ("итог: {0}; пакеты: verified {1}, unmet {2}, failed {3} из {4}; busy_share (среднее) {5}; ходов {6}, вызовов {7}, ошибок {8}; голос говорил {9} раз" -f `
            $res.verdict, $p.verified, $p.unmet, $p.failed, $p.total, $busyMean, $totals.model_turns, $totals.tool_calls, `
        ($totals.tool_errors + $totals.soft_errors), $voiceSays)
    Write-Host "слова хозяина, вопросы голосу и поручения: проверяется хозяином в игре; отчёт: $reportFile"
    $status = if ($res.verdict -eq 'done') { 0 } else { 1 }
}
else {
    Write-Host "прогон не дал результата (см. $liveLog и $(Join-Path $OutDir 'run-live.err'))"
}
exit $status
