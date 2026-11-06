# run_all_labs.ps1 : 실습 2 ~ 10 을 코드로 처음부터 끝까지 실행하고 기록을 남긴다
#
# 실행 (PowerShell 어디서든 한 줄)
#   powershell -ExecutionPolicy Bypass -File D:\data-lab\run_all_labs.ps1
#   시작할 때 한 번만 확인을 묻는다. 묻지 않게 하려면 -Yes, 중간부터 하려면 -From 6 처럼 실습 번호를 준다.
#
# 순서 (실습마다 시작 상태를 스스로 맞춘다)
#   실습 2  백업과 복구           지금 상태 그대로 (비정상이면 full 로 되돌림)
#   실습 3  수동 페일오버         data-db1, data-db2 를 baseline 으로 되돌림 (data-mgmt 는 꺼 둠)
#   실습 4  자동 페일오버 기본     세 VM 을 full 로 되돌림
#   실습 5  운영                 실습 4 상태 그대로
#   실습 6  장애 훈련 1 Primary 강제 종료   full 로 되돌림
#   실습 7  장애 훈련 2 망 분리             full 로 되돌림
#   실습 8  장애 훈련 3 etcd 정족수          full 로 되돌림
#   실습 9  장애 훈련 4 백업 실패와 경보     full 로 되돌림 (경보를 기다리느라 약 12분)
#   실습 10 장애 훈련 5 PITR                실습 9 상태 그대로
#   끝      세 VM 을 full 로 되돌려 깨끗한 상태로 둔다
#
# 기록: D:\data-lab-docs\logs\labs_<시각>\ 에 실습별 로그와 summary.md
# 실습 하나가 실패해도 다음 실습으로 넘어간다 (다음 실습이 스냅샷으로 시작 상태를 다시 맞추기 때문).
# 스냅샷 되돌리기 자체가 실패하면 그 자리에서 멈춘다.

param([switch]$Yes, [int]$From = 2)

$ErrorActionPreference = 'Continue'
$env:VAGRANT_HOME = 'D:\data-lab\.vagrant_home'
Set-Location 'D:\data-lab'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# 창을 마우스로 클릭하면 생기는 '선택 모드'가 실행을 멈추지 않도록 빠른 편집 모드를 끈다 (이 창에서만)
try {
    Add-Type -Namespace LabCon -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);'
    $hIn = [LabCon.K]::GetStdHandle(-10); $mode = [uint32]0
    if ([LabCon.K]::GetConsoleMode($hIn, [ref]$mode)) { [void][LabCon.K]::SetConsoleMode($hIn, (($mode -band (-bnot 0x40)) -bor 0x80)) }
} catch { }

$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogRoot = "D:\data-lab-docs\logs\labs_$Stamp"
$S       = '/home/vagrant/lab-scripts'
$AllVms  = @('data-mgmt', 'data-db1', 'data-db2')
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
$Script:RunnerLog = Join-Path $LogRoot '00_runner.log'
$Script:CurLog    = $Script:RunnerLog
$Script:LabOk     = $true
$Script:Results   = New-Object System.Collections.ArrayList
$Watch = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- 기록
function W {   # 현재 실습 로그에 줄을 쓴다
    param($Lines)
    if ($null -ne $Lines) { Add-Content -Path $Script:CurLog -Value $Lines -Encoding UTF8 }
}
function Say {   # 화면과 진행 로그, 현재 실습 로그에 쓴다
    param([string]$Msg)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line
    Add-Content -Path $Script:RunnerLog -Value $line -Encoding UTF8
    if ($Script:CurLog -ne $Script:RunnerLog) { W $line }
}

# ---------------------------------------------------------------- 외부 명령 호출 (시간 제한)
# 모든 vagrant, VBoxManage 호출에 시간 제한을 둔다. 넘기면 그 프로세스와 자식 프로세스를 끝내고 실패로 기록한다.
$TmpDir = Join-Path $env:TEMP "lab-run_$Stamp"
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
$VagrantExe = (Get-Command vagrant -ErrorAction SilentlyContinue).Source
if (-not $VagrantExe) { Write-Host 'vagrant 를 찾지 못했다'; exit 1 }
function Invoke-Proc {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 900)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fo = Join-Path $TmpDir "o_$tag.txt"; $fe = Join-Path $TmpDir "e_$tag.txt"
    $argStr = ($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $p = Start-Process -FilePath $Exe -ArgumentList $argStr -NoNewWindow -PassThru -RedirectStandardOutput $fo -RedirectStandardError $fe
    $null = $p.Handle
    $done = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $done) {
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    $code = if ($done) { $p.ExitCode } else { -1 }
    $out = @()
    if (Test-Path $fo) { $out += @(Get-Content $fo -Encoding UTF8) }
    if (Test-Path $fe) { $out += @(Get-Content $fe -Encoding UTF8) }
    Remove-Item $fo, $fe -ErrorAction SilentlyContinue
    if (-not $done) { $out += "[시간 초과] ${TimeoutSec}초가 지나 강제로 끝냈다: $Exe $argStr" }
    return @{ ok = ($done -and $code -eq 0); out = $out; code = $code; timeout = (-not $done) }
}

# Vagrant 초기화 오류(PowerShell 버전 확인)는 다시 시도한다. VM 안 스크립트의 실패와 시간 초과는 다시 하지 않는다.
function Invoke-V {
    param([string[]]$VArgs, [int]$Tries = 3, [int]$TimeoutSec = 900)
    $r = $null
    for ($t = 1; $t -le $Tries; $t++) {
        $r = Invoke-Proc $VagrantExe $VArgs $TimeoutSec
        $early = (($r.out -join "`n") -match 'failed to initialize at a very early stage|AccessViolationException')
        if ($r.ok -and -not $early) { return $r }
        if ($r.timeout) { break }
        if (-not $early -and $VArgs[0] -eq 'ssh') { break }
        Start-Sleep -Seconds 3
    }
    $r.ok = $false
    return $r
}

# VM 안에서 실습 스크립트를 실행한다. 출력은 실습 로그에, 실패하면 마지막 줄을 화면에도 보여 준다.
function VM {
    param([string]$Vm, [string]$File, [string[]]$A = @())
    $cmd = "sudo bash $S/$File " + ($A -join ' ')
    W ''
    W ('### {0}  {1} : {2}' -f (Get-Date -Format 'HH:mm:ss'), $Vm, $cmd)
    $r  = Invoke-V @('ssh', $Vm, '-c', $cmd) 3 1500
    if ($r.out.Count -eq 0) { W "(출력 없음, 종료 코드 $($r.code))" } else { W $r.out }
    $ok = $r.ok -and (($r.out -join "`n") -match '\[완료\]')
    if ($ok) {
        Write-Host ('    ok  {0} {1} {2}' -f $Vm, $File, ($A -join ' '))
    } else {
        $Script:LabOk = $false
        Say ('    실패 {0} {1} {2}' -f $Vm, $File, ($A -join ' '))
        $r.out | Select-Object -Last 6 | ForEach-Object { Write-Host "        $_" }
    }
    return $ok
}

function Wait-Ssh {   # VM 에 ssh 가 될 때까지 (재부팅 중일 수 있음)
    param([string]$Vm, [int]$MaxSec = 240)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxSec) {
        $r = Invoke-V @('ssh', $Vm, '-c', 'true') 1
        if ($r.ok) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---------------------------------------------------------------- 스크립트 올리기, 시계
$Tgz = Join-Path $env:TEMP "lab-scripts_$Stamp.tgz"
$UseTar = $false
if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
    & tar.exe -czf $Tgz -C 'D:\data-lab\scripts' . 2>$null
    $UseTar = (Test-Path $Tgz)
}
function Sync-Scripts {
    param([string]$Vm)
    if ($UseTar) {
        $r1 = Invoke-V @('upload', $Tgz, '/home/vagrant/lab-scripts.tgz', $Vm)
        $r2 = Invoke-V @('ssh', $Vm, '-c', 'mkdir -p ~/lab-scripts && tar -xzf ~/lab-scripts.tgz -C ~/lab-scripts && rm -f ~/lab-scripts.tgz')
        if ($r1.ok -and $r2.ok) { return $true }
    }
    $okAll = $true
    foreach ($f in (Get-ChildItem 'D:\data-lab\scripts' -Filter '*.sh' | Where-Object { $_.Name -match '^(lab_|1[3-9]_|2[0-2]_)' })) {
        $r = Invoke-V @('upload', $f.FullName, "/home/vagrant/lab-scripts/$($f.Name)", $Vm)
        if (-not $r.ok) { $okAll = $false }
    }
    return $okAll
}
function Sync-Time {
    param([string]$Vm)
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 2   # ssh 접속에 걸리는 시간을 조금 더한다
    return (VM $Vm 'lab_ctl.sh' @('timesync', "$epoch"))
}
function Prepare-Vm {
    param([string]$Vm)
    if (-not (Sync-Scripts $Vm)) { throw "스크립트 올리기 실패: $Vm" }
    Sync-Time $Vm | Out-Null
}

# ---------------------------------------------------------------- 스냅샷 되돌리기
# 스냅샷은 VM 이 켜진 채로 찍혀서 메모리 상태와 그때의 SSH 포트(2222 등)를 함께 갖고 있다.
# 그 상태로 이어서 켜면 포트 충돌, 시계 어긋남이 생기므로, 디스크만 스냅샷 시점으로 되돌리고 메모리 상태는 버린 뒤
# vagrant up 으로 새로 부팅한다 (전원이 꺼졌다 켜진 것과 같다. 포트는 Vagrant 가 빈 곳으로 고친다).
$VBox = Join-Path $(if ($env:VBOX_MSI_INSTALL_PATH) { $env:VBOX_MSI_INSTALL_PATH } else { 'C:\Program Files\Oracle\VirtualBox\' }) 'VBoxManage.exe'
function VBox {
    param([string[]]$A, [int]$TimeoutSec = 300)
    $r = Invoke-Proc $VBox $A $TimeoutSec
    W ("  VBoxManage {0} -> 코드 {1}" -f ($A -join ' '), $r.code)
    W $r.out
    return $r
}
function Vm-Id {
    param([string]$Vm)
    return (Get-Content "D:\data-lab\.vagrant\machines\$Vm\virtualbox\id" -Raw).Trim()
}
function Restore-Disk {   # VM 이 꺼진 상태에서 디스크를 스냅샷으로 되돌리고 저장된 실행 상태를 버린다
    param([string]$Vm, [string]$Snap)
    $id = Vm-Id $Vm
    VBox @('controlvm', $id, 'poweroff') 120 | Out-Null       # 이미 꺼져 있으면 오류가 나도 괜찮다
    Start-Sleep -Seconds 2
    $r = VBox @('snapshot', $id, 'restore', $Snap) 600
    if (-not $r.ok) { throw "스냅샷 되돌리기 실패: $Vm $Snap" }
    VBox @('discardstate', $id) 120 | Out-Null                # 저장된 상태가 없으면 오류가 나도 괜찮다
    Say "  $Vm 디스크를 $Snap 시점으로 되돌림"
}
function Boot-Vm {
    param([string]$Vm)
    $r = Invoke-V @('up', $Vm, '--no-provision') 2 900
    W $r.out
    if (-not $r.ok) { throw "부팅 실패: $Vm" }
    Say "  $Vm 부팅 완료"
}
function Halt-Vms {
    param([string[]]$Vms)
    $r = Invoke-V (@('halt', '-f') + $Vms) 2 300
    W $r.out
    Start-Sleep -Seconds 5
}

# ---------------------------------------------------------------- 시작 상태 맞추기
function Ensure-Db1Leader {
    $r = Invoke-V @('ssh', 'data-db1', '-c', "sudo bash $S/lab_ctl.sh leader")
    if (($r.out -join "`n") -match 'LEADER=data-db2') {
        Say '  Leader 가 data-db2 라서 data-db1 로 계획 전환한다'
        VM 'data-db2' '16_patroni_basics.sh' @('switchover', 'data-db2', 'data-db1') | Out-Null
    }
}

function Restore-Full {
    Say 'full 스냅샷으로 세 VM 되돌리기 (세 대를 모두 끈 뒤 디스크를 되돌리고 새로 부팅한다)'
    Halt-Vms @()
    foreach ($vm in $AllVms) { Restore-Disk $vm 'full' }
    foreach ($vm in $AllVms) { Boot-Vm $vm }
    foreach ($vm in $AllVms) { Prepare-Vm $vm }
    $saved = $Script:LabOk
    if (-not (VM 'data-db1' 'lab_ctl.sh' @('full-ready'))) { throw 'full 상태 준비 실패 (etcd, Patroni)' }
    $Script:LabOk = $saved
    Ensure-Db1Leader
    Say '  full 상태 준비 완료'
}

function Restore-Baseline {
    Say 'baseline 스냅샷으로 data-db1, data-db2 되돌리기 (data-mgmt 는 실습 3 동안 꺼 둔다. 다음 실습에서 full 로 되돌린다)'
    Halt-Vms @()
    foreach ($vm in @('data-db1', 'data-db2')) { Restore-Disk $vm 'baseline' }
    foreach ($vm in @('data-db1', 'data-db2')) { Boot-Vm $vm }
    foreach ($vm in @('data-db1', 'data-db2')) { Prepare-Vm $vm }
    if (-not (VM 'data-db1' 'lab_ctl.sh' @('baseline-ready'))) { throw 'baseline 상태 준비 실패' }
    Say '  baseline 상태 준비 완료'
}

function Ensure-Continue {   # 지금 상태가 full 정상이면 그대로, 아니면 full 로 되돌린다
    foreach ($vm in $AllVms) { Sync-Scripts $vm | Out-Null }
    $r = Invoke-V @('ssh', 'data-db1', '-c', "sudo bash $S/lab_ctl.sh wait-healthy 60")
    W $r.out
    if ($r.ok -and (($r.out -join "`n") -match '\[완료\]')) {
        Ensure-Db1Leader
        Say '  지금 상태가 정상이라 그대로 이어서 한다'
    } else {
        Say '  지금 상태가 full 정상 상태가 아니라 되돌린다'
        Restore-Full
    }
}

# ---------------------------------------------------------------- 실습 틀
function Start-Lab {
    param([string]$Name, [string]$Title)
    $Script:CurLog = Join-Path $LogRoot "$Name.log"
    $Script:LabOk  = $true
    $Script:LabSw  = [Diagnostics.Stopwatch]::StartNew()
    W "# $Title"
    W ('# 시작 {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ''
    Say "==== $Title ===="
}
function End-Lab {
    param([string]$Name, [string]$Title)
    $sec = [int]$Script:LabSw.Elapsed.TotalSeconds
    $state = if ($Script:LabOk) { '성공' } else { '실패 있음' }
    Say ("==== {0} : {1} ({2}분 {3}초) ====" -f $Title, $state, [int][Math]::Floor($sec / 60), ($sec % 60))
    [void]$Script:Results.Add([pscustomobject]@{ Lab = $Title; State = $state; Sec = $sec; Log = "$Name.log" })
    $Script:CurLog = $Script:RunnerLog
}
function Pause-Sec {
    param([int]$Sec, [string]$Why)
    Say "  ${Sec}초 기다림: $Why"
    Start-Sleep -Seconds $Sec
}

# ---------------------------------------------------------------- 실습들
function Lab2 {
    Start-Lab 'lab02_backup_restore' '실습 2 백업과 복구'
    Ensure-Continue
    VM 'data-db1' '14_backup_restore.sh' @('run') | Out-Null
    End-Lab 'lab02_backup_restore' '실습 2 백업과 복구'
}

function Lab3 {
    Start-Lab 'lab03_manual_failover' '실습 3 수동 페일오버 (pg_promote, pg_rewind)'
    Restore-Baseline
    VM 'data-db1' '15_manual_failover.sh' @('prepare') | Out-Null
    VM 'data-db2' '15_manual_failover.sh' @('cut')     | Out-Null
    VM 'data-db1' '15_manual_failover.sh' @('crash')   | Out-Null
    VM 'data-db2' '15_manual_failover.sh' @('promote') | Out-Null
    Say '  복제 비밀번호 파일을 data-db1 에 올린다 (VM 안에서 .pgpass 로 옮긴 뒤 바로 지운다, 내용은 출력하지 않는다)'
    $r = Invoke-V @('upload', 'D:\data-lab\.secrets\repl_pw', '/home/vagrant/lab-repl_pw', 'data-db1')
    if (-not $r.ok) { Say '    비밀번호 파일 올리기 실패'; $Script:LabOk = $false }
    VM 'data-db1' '15_manual_failover.sh' @('rewind')  | Out-Null
    VM 'data-db2' '15_manual_failover.sh' @('verify')  | Out-Null
    End-Lab 'lab03_manual_failover' '실습 3 수동 페일오버 (pg_promote, pg_rewind)'
}

function Lab4And5 {
    Start-Lab 'lab04_patroni_basics' '실습 4 자동 페일오버 기본 (Patroni, switchover, PgBouncer)'
    Restore-Full
    VM 'data-db1' '16_patroni_basics.sh' @('info')                              | Out-Null
    VM 'data-db2' '16_patroni_basics.sh' @('route')                             | Out-Null
    VM 'data-db1' '16_patroni_basics.sh' @('switchover', 'data-db1', 'data-db2') | Out-Null
    VM 'data-db1' '16_patroni_basics.sh' @('route')                             | Out-Null
    VM 'data-db2' '16_patroni_basics.sh' @('switchover', 'data-db2', 'data-db1') | Out-Null
    VM 'data-db1' 'lab_ctl.sh' @('wait-healthy', '120')                          | Out-Null
    End-Lab 'lab04_patroni_basics' '실습 4 자동 페일오버 기본 (Patroni, switchover, PgBouncer)'

    Start-Lab 'lab05_ops' '실습 5 운영 (잠금, VACUUM, 모니터링)'
    Ensure-Continue
    VM 'data-db1'  '17_ops.sh' @('locks')  | Out-Null
    VM 'data-db1'  '17_ops.sh' @('vacuum') | Out-Null
    VM 'data-db1'  '17_ops.sh' @('sqlmon') | Out-Null
    VM 'data-mgmt' '17_ops.sh' @('prom')   | Out-Null
    End-Lab 'lab05_ops' '실습 5 운영 (잠금, VACUUM, 모니터링)'
}

function Lab6 {
    $t = '실습 6 장애 훈련 1 Primary 강제 종료'
    Start-Lab 'lab06_drill_primary_down' $t
    Restore-Full
    VM 'data-db1' 'lab_ctl.sh' @('drill-setup')                      | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-start', 'r6', '170', 'writer') | Out-Null
    Pause-Sec 15 '평소 상태 기록'
    Say '  data-db1 강제 전원 끄기 (vagrant halt -f data-db1)'
    $r = Invoke-V @('halt', '-f', 'data-db1') 2 300; W $r.out
    Pause-Sec 75 '자동 전환과 쓰기 재개 관찰'
    Say '  옛 Primary(data-db1) 다시 켜기'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-V @('up', 'data-db1', '--no-provision') 2 900; W $r.out
    Say ('  vagrant up data-db1 : {0:N0}초' -f $sw.Elapsed.TotalSeconds)
    Sync-Time 'data-db1' | Out-Null
    VM 'data-db2' '18_drill_primary_down.sh' @('rejoin')     | Out-Null
    Say ('  data-db1 을 켜기 시작해서 Replica 로 다시 붙기까지 (호스트 기준) {0:N0}초' -f $sw.Elapsed.TotalSeconds)
    VM 'data-db1' '18_drill_primary_down.sh' @('rejoin-log') | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-report', 'r6', '120') | Out-Null
    End-Lab 'lab06_drill_primary_down' $t
}

function Lab7 {
    $t = '실습 7 장애 훈련 2 망 분리'
    Start-Lab 'lab07_drill_network_split' $t
    Restore-Full
    VM 'data-db1' 'lab_ctl.sh' @('drill-setup')                                  | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-start', 'r7', '220', 'writer')             | Out-Null
    VM 'data-db1' '19_drill_network_split.sh' @('start', 'r7', '15', '90', '220') | Out-Null
    Pause-Sec 225 '15초 뒤 data-db1 망을 끊고, 90초 뒤 다시 잇는다'
    if (-not (Wait-Ssh 'data-db1')) { Say '    data-db1 에 ssh 가 되지 않는다'; $Script:LabOk = $false }
    VM 'data-db1' '19_drill_network_split.sh' @('cleanup', 'r7') | Out-Null
    VM 'data-db1' 'lab_ctl.sh' @('watch-report', 'r7', '30')     | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('wait-healthy', '240')          | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-report', 'r7', '30')     | Out-Null
    End-Lab 'lab07_drill_network_split' $t
}

function Lab8 {
    $t = '실습 8 장애 훈련 3 etcd 1대, 2대 중지'
    Start-Lab 'lab08_drill_etcd_quorum' $t
    Restore-Full
    VM 'data-db1' 'lab_ctl.sh' @('drill-setup')                      | Out-Null
    VM 'data-db1' 'lab_ctl.sh' @('watch-start', 'r8', '300')           | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-start', 'r8', '300', 'writer') | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Pause-Sec 20 '평소 상태 기록'
    VM 'data-mgmt' '20_drill_etcd_quorum.sh' @('stop')   | Out-Null
    VM 'data-db1'  '20_drill_etcd_quorum.sh' @('health') | Out-Null
    Pause-Sec 25 'etcd 1대 중지 상태 관찰 (정족수 2/3 유지)'
    VM 'data-db2'  '20_drill_etcd_quorum.sh' @('stop')   | Out-Null
    VM 'data-db1'  '20_drill_etcd_quorum.sh' @('health') | Out-Null
    Pause-Sec 60 'etcd 2대 중지 상태 관찰 (정족수 잃음, Leader 강등)'
    VM 'data-db1'  '20_drill_etcd_quorum.sh' @('health') | Out-Null
    VM 'data-db2'  '20_drill_etcd_quorum.sh' @('start')  | Out-Null
    VM 'data-mgmt' '20_drill_etcd_quorum.sh' @('start')  | Out-Null
    Pause-Sec 20 '정족수 회복'
    VM 'data-db1'  '20_drill_etcd_quorum.sh' @('health') | Out-Null
    VM 'data-db1'  'lab_ctl.sh' @('wait-healthy', '240')  | Out-Null
    $left = 300 - [int]$sw.Elapsed.TotalSeconds + 5
    if ($left -gt 0) { Pause-Sec $left '상태 기록이 끝날 때까지' }
    VM 'data-db1' 'lab_ctl.sh' @('watch-report', 'r8', '60') | Out-Null
    VM 'data-db2' 'lab_ctl.sh' @('watch-report', 'r8', '60') | Out-Null
    End-Lab 'lab08_drill_etcd_quorum' $t
}

function Lab9And10 {
    $t = '실습 9 장애 훈련 4 백업 실패와 경보'
    Start-Lab 'lab09_drill_backup_fail' $t
    Restore-Full
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('alert')       | Out-Null
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('minio-stop')  | Out-Null
    VM 'data-db1'  '21_drill_backup_fail.sh' @('backup-fail') | Out-Null
    VM 'data-db1'  '21_drill_backup_fail.sh' @('metric')      | Out-Null
    VM 'data-db2'  '21_drill_backup_fail.sh' @('metric')      | Out-Null
    Say '  경보가 firing 될 때까지 기다린다 (규칙의 for: 10m 때문에 약 11분)'
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('alert-wait', 'firing', '900') | Out-Null
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('minio-start') | Out-Null
    VM 'data-db1'  '21_drill_backup_fail.sh' @('backup-ok')   | Out-Null
    VM 'data-db1'  '21_drill_backup_fail.sh' @('metric')      | Out-Null
    VM 'data-db2'  '21_drill_backup_fail.sh' @('metric')      | Out-Null
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('alert-wait', 'inactive', '300') | Out-Null
    VM 'data-mgmt' '21_drill_backup_fail.sh' @('alert')       | Out-Null
    End-Lab 'lab09_drill_backup_fail' $t

    $t = '실습 10 장애 훈련 5 PITR'
    Start-Lab 'lab10_drill_pitr' $t
    Ensure-Continue
    VM 'data-db1' '22_drill_pitr.sh' @('run') | Out-Null
    End-Lab 'lab10_drill_pitr' $t
}

# ---------------------------------------------------------------- 시작 확인 (한 번만)
Write-Host ''
Write-Host '실습 2 ~ 10 을 코드로 끝까지 실행한다. 예상 시간은 약 70 ~ 90분이고, 중간에 묻지 않는다.'
Write-Host '아래 작업이 들어 있다 (실습 VM 3대만 대상, 다른 VM 과 호스트 파일은 건드리지 않음):'
Write-Host '  - 스냅샷 되돌리기: data-db1, data-db2 를 baseline 으로 1번, 세 VM 을 full 로 6번'
Write-Host '    (지금 VM 안의 상태와 실습 1 튜닝 인덱스는 사라진다. 튜닝 기록은 이미 호스트에 있다)'
Write-Host '  - VM 강제 끄기 (vagrant halt -f), data-db1 강제 전원 끄기, PostgreSQL kill -9'
Write-Host '  - pg_rewind 로 baseline 의 data-db1 데이터 디렉터리 되감기'
Write-Host '  - data-db1 망 분리(nftables), etcd 중지, MinIO 중지 (모두 실습 안에서 되돌림)'
Write-Host '  - 실습용 표 DROP (lab_failover, lab_lock, lab_vac, lab_pitr), 새 DB lab_restore_* 와 복구 시험 폴더 생성'
Write-Host '  - 복제 비밀번호 파일을 baseline 의 data-db1 에 올려 .pgpass 로 옮기고 지움 (내용은 출력하지 않음)'
Write-Host '  - 마지막에 세 VM 을 full 로 되돌려 깨끗한 상태로 둔다'
Write-Host "  기록: $LogRoot"
Write-Host '  PC 가 절전 모드로 들어가지 않게 하고, 이 창을 닫지 않는다.'
if (-not $Yes) {
    $ans = Read-Host '진행하려면 yes 를 입력한다'
    if ($ans -ne 'yes') { Write-Host '취소했다.'; exit 0 }
}
Say ("시작 (실습 {0}부터)" -f $From)

# ---------------------------------------------------------------- 실행
try {
    if ($From -le 2)  { Lab2 }
    if ($From -le 3)  { Lab3 }
    if ($From -le 5)  { Lab4And5 }
    if ($From -le 6)  { Lab6 }
    if ($From -le 7)  { Lab7 }
    if ($From -le 8)  { Lab8 }
    if ($From -le 10) { Lab9And10 }
    $Script:CurLog = Join-Path $LogRoot 'lab99_final.log'
    Say '마지막 정리: 세 VM 을 full 로 되돌린다'
    Restore-Full
    $Script:CurLog = $Script:RunnerLog
} catch {
    $Script:CurLog = $Script:RunnerLog
    Say "멈춤: $($_.Exception.Message)"
    [void]$Script:Results.Add([pscustomobject]@{ Lab = '중단'; State = $_.Exception.Message; Sec = 0; Log = '00_runner.log' })
}

# ---------------------------------------------------------------- 요약
$total = [int]$Watch.Elapsed.TotalSeconds
$sum = @('# 실습 2 ~ 10 자동 실행 요약', '', ('- 실행: {0}, 전체 {1}분 {2}초' -f $Stamp, [int][Math]::Floor($total / 60), ($total % 60)), '', '| 실습 | 결과 | 걸린 시간 | 로그 |', '|---|---|---|---|')
foreach ($x in $Script:Results) {
    $sum += ('| {0} | {1} | {2}분 {3}초 | {4} |' -f $x.Lab, $x.State, [int][Math]::Floor($x.Sec / 60), ($x.Sec % 60), $x.Log)
}
$sum | Out-File -FilePath (Join-Path $LogRoot 'summary.md') -Encoding utf8
Write-Host ''
$sum | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "기록 폴더: $LogRoot"
if (Test-Path $Tgz) { Remove-Item $Tgz -Force }
Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
