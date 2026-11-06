# run_13_tuning.ps1 : 13_tuning.sh 를 두 VM 에 올리고, Leader 와 Replica 에서 차례로 실행한 뒤 기록을 저장한다
# 실행 (PowerShell 어디서든 한 줄)
#   powershell -ExecutionPolicy Bypass -File D:\data-lab\run_13_tuning.ps1
# 하는 일
#   1. VAGRANT_HOME 을 D:\data-lab\.vagrant_home 으로 지정 (기존 D:\vagrant_home 은 건드리지 않음)
#   2. data-db1 에서 pg_is_in_recovery() 로 Leader 를 찾음
#   3. 13_tuning.sh 를 두 VM 의 ~/lab-scripts 로 올림
#   4. Leader 에서 실습 1 전체, Replica 에서 읽기 전용 확인
#   5. 결과를 D:\data-lab-docs\logs\13_tuning_<VM>_<시각>.log 로 저장 (기존 파일을 덮어쓰지 않음)
# Vagrant 초기화 오류(PowerShell 버전 확인)가 나면 같은 명령을 한 번 더 실행한다.

$ErrorActionPreference = 'Continue'
$env:VAGRANT_HOME = 'D:\data-lab\.vagrant_home'
Set-Location 'D:\data-lab'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LogDir      = 'D:\data-lab-docs\logs'
$Stamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$StartMarker = '[13] 쿼리 튜닝 실습 시작'

function Invoke-Vagrant {
    param([string[]]$VArgs, [string]$Marker = '')
    $out = @()
    for ($try = 1; $try -le 2; $try++) {
        $out  = @(& vagrant @VArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        if ($code -eq 0) { return $out }
        # 스크립트가 이미 시작됐다면 다시 실행하지 않는다 (중단 메시지도 그대로 돌려준다)
        if ($Marker -and (($out -join "`n").Contains($Marker))) { return $out }
        Write-Host "  [재시도] vagrant $($VArgs -join ' ') 실패 (코드 $code, $try 번째)"
    }
    $out | ForEach-Object { Write-Host $_ }
    throw "vagrant $($VArgs -join ' ') 가 두 번 실패했다."
}

function Save-Log {
    param([string]$Vm, [string[]]$Lines)
    $path = Join-Path $LogDir ("13_tuning_{0}_{1}.log" -f $Vm, $Stamp)
    $Lines | Out-File -FilePath $path -Encoding utf8
    return $path
}

Write-Host '[run] VM 상태 확인'
Invoke-Vagrant @('status') | ForEach-Object { Write-Host "  $_" }

Write-Host '[run] Leader 찾기 (data-db1 의 pg_is_in_recovery)'
$check  = "sudo -iu postgres psql -tAc 'SELECT pg_is_in_recovery()'"
$r      = @(Invoke-Vagrant @('ssh', 'data-db1', '-c', $check))
$values = @($r | ForEach-Object { $_.Trim() })
if ($values -contains 'f') {
    $Leader = 'data-db1'; $Replica = 'data-db2'
} elseif ($values -contains 't') {
    $Leader = 'data-db2'; $Replica = 'data-db1'
} else {
    $r | ForEach-Object { Write-Host "  $_" }
    throw 'Leader 를 판단하지 못했다. patronictl list 로 상태를 확인한다.'
}
Write-Host "  Leader = $Leader, Replica = $Replica"

foreach ($vm in @($Leader, $Replica)) {
    Write-Host "[run] 13_tuning.sh 올리기: $vm"
    Invoke-Vagrant @('upload', 'scripts\13_tuning.sh', '/home/vagrant/lab-scripts/13_tuning.sh', $vm) | Out-Null
}

Write-Host "[run] Leader($Leader) 에서 실습 1 전체 실행 (1분 안팎)"
$outL  = @(Invoke-Vagrant @('ssh', $Leader, '-c', 'sudo bash ~/lab-scripts/13_tuning.sh') -Marker $StartMarker)
$fileL = Save-Log $Leader $outL
if (-not (($outL -join "`n").Contains('[13] 완료'))) {
    $outL | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
    Write-Host "[run] Leader 실행이 완료되지 않았다. 기록: $fileL"
    exit 1
}

Write-Host "[run] Replica($Replica) 에서 읽기 전용 확인"
$outR  = @(Invoke-Vagrant @('ssh', $Replica, '-c', 'sudo bash ~/lab-scripts/13_tuning.sh') -Marker $StartMarker)
$fileR = Save-Log $Replica $outR

Write-Host ''
Write-Host '[run] 쿼리별 튜닝 전후 (Leader 기록에서 발췌)'
for ($i = 0; $i -lt $outL.Count; $i++) {
    if ($outL[$i] -like '*쿼리별 튜닝 전후*') {
        $outL[$i..([Math]::Min($i + 11, $outL.Count - 1))] | ForEach-Object { Write-Host $_ }
        break
    }
}
Write-Host ''
Write-Host "[run] 기록 저장: $fileL"
Write-Host "[run] 기록 저장: $fileR"
Write-Host '[run] 완료'
