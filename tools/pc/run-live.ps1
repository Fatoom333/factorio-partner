# Живой тест factorio-partner на ПК (поток E, docs/TESTING.md §3). Запускать на ноутбуке из PowerShell
# (не из Git Bash: ssh из Bash не видит ssh-agent Windows (ключи из менеджера паролей)).
#
#   powershell -File tools/pc/run-live.ps1 -Slot 1 -Scenario e_rcon_maxlen
#
# 1. Собирает zip модов (по умолчанию — что просит сценарий в MODS, иначе factorio-partner) и пакет стенда.
# 2. По SSH (`pc`) кладёт пакет в D:\Temp\fp-live-<N>, разворачивает сервер без окна на копии сейва
#    (жёсткие ссылки на моды, auto_pause:false, всё на 127.0.0.1, RCON 27100+N, игра 34200+N,
#    пароль генерируется на ПК в файл).
# 3. Запускает сценарий через live_client.py (только конверты /partner).
# 4. /quit, забирает results-<N>.json и журналы в -OutDir, удаляет папку слота (если не -Keep).
# Код выхода: 0 — сценарий ok, 1 — сценарий не ok, 2 — сбой стенда.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 9)]
    [int]$Slot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9_]{1,64}$')]
    [string]$Scenario,

    # Какие наши моды включить: factorio-partner, partner-test. Пусто — из MODS сценария.
    [ValidateSet('factorio-partner', 'partner-test')]
    [string[]]$Mods,

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}\.zip$')]
    [string]$Save = 'Vulkan-Start-test.zip',

    [ValidateRange(10, 7200)]
    [int]$TimeoutSec = 600,

    [ValidateRange(10, 7200)]
    [int]$ReadyTimeoutSec = 240,

    # Куда сложить results-<N>.json и журналы. По умолчанию — %TEMP%\fp-live\<N>-<время>.
    [string]$OutDir,

    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$SshHost = 'pc',

    # Python на ноутбуке для сборки пакета.
    [string]$Python = 'python',

    # Не удалять папку слота на ПК (для разбора). Сервер всё равно останавливается.
    [switch]$Keep
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Remote = "D:\Temp\fp-live-$Slot"          # только цифра слота, путь фиксированный
$RemoteFwd = "D:/Temp/fp-live-$Slot"
$PayloadRemote = "D:/Temp/fp-live-$Slot.payload.zip"
if (-not $OutDir) {
    $OutDir = Join-Path $env:TEMP ("fp-live\{0}-{1}" -f $Slot, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Work = Join-Path $OutDir 'build'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Invoke-Pc([string]$Script) {
    # Многострочный PowerShell на ПК: только через -EncodedCommand (PS 5.1 съедает кавычки в аргументах ssh).
    $full = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$ErrorActionPreference='Stop';`n" + $Script
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    if ($enc.Length -gt 7000) { throw 'встроенный скрипт для ПК слишком длинный' }
    $ErrorActionPreference = 'Continue'   # PS 5.1: stderr нативной программы при Stop превращается в исключение
    # stderr не глушим: там причина сбоя на ПК.
    & ssh -o BatchMode=yes $SshHost "powershell -NoProfile -NonInteractive -EncodedCommand $enc" | Out-Host
    return $LASTEXITCODE
}

function Invoke-Stand([string]$Action) {
    # stand.ps1 из пакета; путь без пробелов, аргументы — только слово действия.
    # stderr не глушим (throw из stand.ps1); причину stand.ps1 к тому же дублирует в stdout.
    $ErrorActionPreference = 'Continue'
    & ssh -o BatchMode=yes $SshHost "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Remote\stand\stand.ps1 -Action $Action" | Out-Host
    return $LASTEXITCODE
}

# Остановить серверы этого слота (только factorio.exe из папки слота) и удалить папку слота.
# Ничего, кроме D:\Temp\fp-live-<N> и его payload-zip, не трогает.
$CleanScript = @"
`$d = '$Remote'
if (`$d -notmatch '^D:\\Temp\\fp-live-[0-9]`$') { throw 'плохой путь слота' }
Get-CimInstance Win32_Process -Filter "Name='factorio.exe'" |
    Where-Object { `$_.CommandLine -and `$_.CommandLine.Contains(`$d + '\') } |
    ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
if (Test-Path -LiteralPath `$d) { Remove-Item -LiteralPath `$d -Recurse -Force }
"@

$UnpackScript = $CleanScript + @"
`$z = '$($PayloadRemote.Replace('/', '\'))'
New-Item -ItemType Directory -Force -Path `$d | Out-Null
Expand-Archive -LiteralPath `$z -DestinationPath `$d -Force
Remove-Item -LiteralPath `$z -Force
Write-Host "слот $Slot`: пакет распакован в `$d"
"@

$status = 2
$deployed = $false
try {
    # 1. Сборка.
    if ($Mods -and $Mods.Count -gt 0) {
        $ModList = ($Mods -join ',')
    }
    else {
        $ModList = [string](& $Python (Join-Path $Here 'pack.py') scenario-mods --name $Scenario --plain)
        if ($LASTEXITCODE -ne 0) { throw "сценарий $Scenario не найден" }
        $ModList = $ModList.Trim()
    }
    $payload = Join-Path $Work "fp-live-$Slot.payload.zip"
    & $Python (Join-Path $Here 'pack.py') payload --slot $Slot --scenario $Scenario --out $payload `
        --mods $ModList --save $Save --timeout-sec $TimeoutSec --ready-timeout-sec $ReadyTimeoutSec | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'сборка пакета не удалась' }
    Write-Host "слот $Slot`: моды $ModList; сценарий $Scenario"

    # 2. Доставка и развёртывание.
    $ErrorActionPreference = 'Continue'
    & scp -q -o BatchMode=yes $payload "${SshHost}:$PayloadRemote"
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw 'scp пакета на ПК не удался (ПК включён? агент ключей доступен?)' }
    if ((Invoke-Pc $UnpackScript) -ne 0) { throw 'распаковка на ПК не удалась' }
    $deployed = $true
    if ((Invoke-Stand 'deploy') -ne 0) { throw 'сервер не поднялся' }

    # 3. Сценарий.
    $code = Invoke-Stand 'run'
    $status = if ($code -eq 0) { 0 } elseif ($code -eq 1) { 1 } else { 2 }
}
catch {
    Write-Host "ошибка стенда: $($_.Exception.Message)"
    $status = 2
}
finally {
    if ($deployed) {
        # 4. Остановка, сбор, уборка.
        if ((Invoke-Stand 'stop') -ne 0) { Write-Host 'остановка вернула ошибку — уборка всё равно' }
        foreach ($f in @("results-$Slot.json", "live-$Slot.log", "factorio-$Slot.log")) {
            $ErrorActionPreference = 'Continue'
            & scp -q -o BatchMode=yes "${SshHost}:$RemoteFwd/out/$f" "$OutDir" 2>$null
        }
        if (-not $Keep) {
            if ((Invoke-Pc $CleanScript) -ne 0) { Write-Host "не удалось удалить $Remote на ПК" }
        }
        else {
            Write-Host "папка слота оставлена: $Remote (-Keep)"
        }
    }
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

$results = Join-Path $OutDir "results-$Slot.json"
if (Test-Path -LiteralPath $results) {
    Write-Host "результат: $results"
    Get-Content -LiteralPath $results -Raw -Encoding UTF8 | Write-Host
    $ok = (Get-Content -LiteralPath $results -Raw -Encoding UTF8 | ConvertFrom-Json).ok
    if ($status -ne 2) { $status = if ($ok) { 0 } else { 1 } }
}
else {
    Write-Host "results-$Slot.json не получен"
    $status = 2
}
exit $status
