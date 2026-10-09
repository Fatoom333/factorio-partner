# Стенд живых тестов factorio-partner — часть, которая работает НА ПК (поток E, docs/TESTING.md §3).
# Запускает tools/pc/run-live.ps1 по SSH из распакованного пакета D:\Temp\fp-live-<N>\stand\.
#
#   stand.ps1 -Action deploy   копия сейва, жёсткие ссылки на моды, конфиги, пароль RCON, запуск сервера без окна
#   stand.ps1 -Action run      сценарий через live_client.py -> out\results-<N>.json
#   stand.ps1 -Action stop     /quit через live_client.py, ожидание выхода, журнал в out\
#
# Настройки — stand\stand.json (собирает tools/pc/pack.py). Всё слушает только 127.0.0.1.
# Пароль RCON генерируется здесь, лежит только в <slot>\rcon.pw и в аргументах процесса сервера.
# Factorio пишет свои аргументы (и пароль) в factorio-current.log: журнал печатается и копируется
# ТОЛЬКО через Copy-RedactedLog / Show-LogTail, которые заменяют пароль на <private>.
# Никаких /c, /sc, /silent-command: команды в игру шлёт только live_client.py.
# PowerShell 5.1, без внешних модулей.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('deploy', 'run', 'stop')]
    [string]$Action
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$StandDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SlotDir = Split-Path -Parent $StandDir
if ($SlotDir -notmatch '^[A-Za-z]:\\Temp\\fp-live-[0-9]$') {
    throw "stand.ps1 должен лежать в <диск>:\Temp\fp-live-<N>\stand, а лежит в $StandDir"
}
$Cfg = Get-Content -LiteralPath (Join-Path $StandDir 'stand.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Slot = [int]$Cfg.slot
if ($SlotDir -notmatch "fp-live-$Slot`$") { throw "слот в stand.json ($Slot) не совпадает с папкой $SlotDir" }
$RconPort = 27100 + $Slot
$GamePort = 34200 + $Slot
$DataDir = Join-Path $SlotDir 'data'
$ModsDir = Join-Path $SlotDir 'mods'
$OutDir = Join-Path $SlotDir 'out'
$PwFile = Join-Path $SlotDir 'rcon.pw'
$PidFile = Join-Path $SlotDir 'server.pid'
$LogFile = Join-Path $DataDir 'factorio-current.log'
$OurMods = @('factorio-partner', 'partner-test')
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Get-ModNameFromFile([string]$FileName) {
    # <name>_<version>.zip -> name
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $m = [regex]::Match($base, '^(.+)_\d+\.\d+\.\d+$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $base
}

function Test-PortFree([int]$Port, [string]$Proto) {
    if ($Proto -eq 'tcp') {
        return -not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    }
    return -not (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Get-SlotServer {
    # Только factorio.exe, запущенный из папки этого слота (по командной строке).
    $needle = "$SlotDir\"
    Get-CimInstance Win32_Process -Filter "Name='factorio.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) }
}

function New-RconPassword {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Protect-File([string]$Path) {
    # Доступ к файлу пароля — только текущему пользователю.
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $id = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-Client([string[]]$ClientArgs) {
    $ErrorActionPreference = 'Continue'   # PS 5.1: stderr Python не должен становиться исключением
    $py = [string]$Cfg.pc_python
    if (-not (Test-Path -LiteralPath $py)) { throw "нет Python для стенда: $py" }
    # -I: изолированный режим (без PYTHON* и без импорта из текущей папки); UTF-8 клиент ставит сам.
    & $py -I (Join-Path $StandDir 'live_client.py') @ClientArgs | Out-Host
    return $LASTEXITCODE
}

function Format-Redacted([string]$Text, [string]$Secret) {
    # Factorio: Program arguments: ... "--rcon-password" "<пароль>" — значение после ключа в любом виде,
    # плюс любое вхождение самого пароля (если он известен).
    $t = [regex]::Replace($Text, '("?--rcon-password"?(?:[ \t]+|=))(?:"[^"\r\n]*"|[^\s"]+)', '$1"<private>"')
    if ($Secret -and $Secret.Length -ge 8) { $t = $t.Replace($Secret, '<private>') }
    return $t
}

function Get-RedactedLogText([string]$Path, [string]$Secret) {
    # Чтение с FileShare.ReadWrite: сервер может ещё держать журнал открытым.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $sr = New-Object IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding $false), $true)
        $text = $sr.ReadToEnd()
        $sr.Dispose()
    }
    finally { $fs.Dispose() }
    return (Format-Redacted $text $Secret)
}

function Copy-RedactedLog([string]$Src, [string]$Dst, [string]$Secret) {
    # Единственный способ вынести журнал Factorio из слота: копия без пароля RCON.
    $clean = Get-RedactedLogText $Src $Secret
    [IO.File]::WriteAllText($Dst, $clean, (New-Object System.Text.UTF8Encoding $false))
}

function Get-RconSecret {
    if (-not (Test-Path -LiteralPath $PwFile)) { return '' }
    try { return ([IO.File]::ReadAllText($PwFile)).Trim() } catch { return '' }
}

function Show-LogTail {
    if (Test-Path -LiteralPath $LogFile) {
        Write-Host '--- хвост журнала сервера (пароль RCON вычищен) ---'
        $lines = (Get-RedactedLogText $LogFile (Get-RconSecret)) -split "\r?\n"
        $lines | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    }
}

function Invoke-Deploy {
    $exe = [string]$Cfg.factorio_exe
    $fdata = [string]$Cfg.factorio_data
    $save = Join-Path (Join-Path $fdata 'saves') ([string]$Cfg.save)
    foreach ($p in @($exe, $fdata, $save)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "не найдено: $p" }
    }
    if (Get-SlotServer) { throw "в слоте $Slot уже работает сервер — сначала уборка" }
    if (-not (Test-PortFree $RconPort 'tcp')) { throw "порт RCON $RconPort занят" }
    if (-not (Test-PortFree $GamePort 'udp')) { throw "порт игры $GamePort занят" }

    New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'saves'), $ModsDir, $OutDir | Out-Null
    $saveCopy = Join-Path (Join-Path $DataDir 'saves') 'fp-live.zip'
    Copy-Item -LiteralPath $save -Destination $saveCopy

    # Моды: жёсткие ссылки на zip игрока (тот же диск D:), кроме наших — их кладём свежие.
    $srcMods = Join-Path $fdata 'mods'
    $linked = 0
    foreach ($f in Get-ChildItem -LiteralPath $srcMods -Filter '*.zip' -File) {
        if ($OurMods -contains (Get-ModNameFromFile $f.Name)) { continue }
        New-Item -ItemType HardLink -Path (Join-Path $ModsDir $f.Name) -Target $f.FullName | Out-Null
        $linked++
    }
    foreach ($m in $Cfg.mods) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $StandDir 'mods') ([string]$m.file)) -Destination $ModsDir
    }

    # mod-list.json: как у игрока, но наши моды включены ровно по списку стенда.
    $listPath = Join-Path $srcMods 'mod-list.json'
    $list = Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $wanted = @($Cfg.mods | ForEach-Object { [string]$_.name })
    $entries = New-Object System.Collections.ArrayList
    foreach ($e in $list.mods) {
        if ($OurMods -contains [string]$e.name) { continue }
        [void]$entries.Add([ordered]@{ name = [string]$e.name; enabled = [bool]$e.enabled })
        # Включённые моды-папки (не zip) копируем — ссылок на папки не делаем.
        if ($e.enabled) {
            foreach ($d in Get-ChildItem -LiteralPath $srcMods -Directory -ErrorAction SilentlyContinue) {
                if ($d.Name -eq $e.name -or $d.Name -like "$($e.name)_*") {
                    Copy-Item -LiteralPath $d.FullName -Destination $ModsDir -Recurse
                }
            }
        }
    }
    foreach ($n in $OurMods) {
        [void]$entries.Add([ordered]@{ name = $n; enabled = ($wanted -contains $n) })
    }
    Write-Utf8NoBom (Join-Path $ModsDir 'mod-list.json') (ConvertTo-Json @{ mods = $entries.ToArray() } -Depth 4)
    $settingsDat = Join-Path $srcMods 'mod-settings.dat'
    if (Test-Path -LiteralPath $settingsDat) { Copy-Item -LiteralPath $settingsDat -Destination $ModsDir }

    Write-Utf8NoBom (Join-Path $SlotDir 'config.ini') @"
[path]
read-data=__PATH__executable__/../../data
write-data=$DataDir
"@
    $server = [ordered]@{
        name = "fp-live-$Slot"
        description = 'factorio-partner live test (temporary copy)'
        visibility = [ordered]@{ public = $false; lan = $false }
        require_user_verification = $false
        max_players = 1
        auto_pause = $false
        only_admins_can_pause_the_game = $true
        autosave_interval = 10000
        autosave_slots = 1
        autosave_only_on_server = $true
        non_blocking_saving = $false
    }
    Write-Utf8NoBom (Join-Path $SlotDir 'server-settings.json') (ConvertTo-Json $server -Depth 4)

    # Сначала пустой файл и права только владельцу, потом пароль: нет окна, когда пароль
    # лежит в файле с унаследованными правами.
    if (Test-Path -LiteralPath $PwFile) { Remove-Item -LiteralPath $PwFile -Force }
    [IO.File]::Create($PwFile).Dispose()
    Protect-File $PwFile
    $pw = New-RconPassword
    Write-Utf8NoBom $PwFile $pw

    $cmd = ('"{0}" --start-server "{1}" -c "{2}" --mod-directory "{3}" --server-settings "{4}" ' +
        '--bind 127.0.0.1 --port {5} --rcon-bind 127.0.0.1:{6} --rcon-password {7}') -f `
        $exe, $saveCopy, (Join-Path $SlotDir 'config.ini'), $ModsDir, (Join-Path $SlotDir 'server-settings.json'),
        $GamePort, $RconPort, $pw
    # Через CIM: процесс не умирает вместе с SSH-сессией.
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $cmd; CurrentDirectory = $SlotDir
    }
    $cmd = $null; $pw = $null
    if ($r.ReturnValue -ne 0) { throw "сервер не запустился (Win32_Process.Create = $($r.ReturnValue))" }
    Set-Content -LiteralPath $PidFile -Value $r.ProcessId -Encoding ASCII
    Write-Host "слот $Slot`: сервер pid $($r.ProcessId), модов по ссылкам $linked, наши: $($wanted -join ', ')"

    # Ждём RCON: процесс жив и live_client авторизуется.
    $deadline = (Get-Date).AddSeconds([int]$Cfg.ready_timeout_sec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue)) {
            Show-LogTail
            throw 'сервер завершился при загрузке'
        }
        if ((Test-Path -LiteralPath $LogFile) -and
            (Select-String -LiteralPath $LogFile -Pattern 'Starting RCON interface' -SimpleMatch -Quiet)) {
            break
        }
        Start-Sleep -Seconds 2
    }
    $left = [int][Math]::Max(10, ($deadline - (Get-Date)).TotalSeconds)
    $code = Invoke-Client @('wait-ready', '--slot', "$Slot", '--dir', $SlotDir, '--timeout', "$left")
    if ($code -ne 0) { Show-LogTail; throw 'RCON не готов' }
    Write-Host "слот $Slot`: RCON 127.0.0.1:$RconPort готов"
}

function Invoke-Run {
    $code = Invoke-Client @('run', '--slot', "$Slot", '--dir', $SlotDir, '--scenario', [string]$Cfg.scenario,
        '--timeout', "$([int]$Cfg.timeout_sec)")
    Write-Host "слот $Slot`: сценарий $($Cfg.scenario) завершился с кодом $code"
    exit $code
}

function Invoke-Stop {
    $procs = @(Get-SlotServer)
    if ($procs.Count -gt 0 -and (Test-Path -LiteralPath $PwFile)) {
        [void](Invoke-Client @('quit', '--slot', "$Slot", '--dir', $SlotDir))
        foreach ($p in $procs) {
            Wait-Process -Id $p.ProcessId -Timeout 60 -ErrorAction SilentlyContinue
        }
    }
    foreach ($p in @(Get-SlotServer)) {
        Write-Host "слот $Slot`: сервер pid $($p.ProcessId) не вышел по /quit — останавливаю"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # Журналы Factorio содержат пароль RCON (строка Program arguments): в out\ — только вычищенная
    # копия, а сами журналы в слоте перезаписываем вычищенными (на случай -Keep).
    $secret = Get-RconSecret
    foreach ($name in @('factorio-current.log', 'factorio-previous.log')) {
        $src = Join-Path $DataDir $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if ($name -eq 'factorio-current.log') {
            Copy-RedactedLog $src (Join-Path $OutDir "factorio-$Slot.log") $secret
        }
        try { Copy-RedactedLog $src $src $secret }
        catch { Write-Host "слот $Slot`: не удалось вычистить $name в слоте: $($_.Exception.Message)" }
    }
    Write-Host "слот $Slot`: остановлен"
}

try {
    switch ($Action) {
        'deploy' { Invoke-Deploy }
        'run' { Invoke-Run }
        'stop' { Invoke-Stop }
    }
}
catch {
    # Причину — в stdout: на ноутбуке run-live.ps1 видит её даже если stderr ssh потерялся.
    Write-Host "слот $Slot`: ошибка стенда ($Action): $($_.Exception.Message)"
    exit 2
}
