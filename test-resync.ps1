#Requires -Version 5.1
# 测试首次 resync 的最小化脚本

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$RcloneExe = Join-Path $ProjectRoot 'bin\rclone.exe'
$PathA = 'serverA:sync'
$PathB = 'serverB:sync'
$LogDir = Join-Path $ProjectRoot 'logs'

New-Item -ItemType Directory -Force $LogDir | Out-Null
$logFile = Join-Path $LogDir ("resync-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Write-Host "========== 测试 resync =========="
Write-Host "日志文件: $logFile"

# 先检查两端连通性
Write-Host "`n检查连通性..."
foreach ($ep in @(@('A','100.109.141.36'), @('B','10.255.10.38'))) {
    $ok = Test-NetConnection -ComputerName $ep[1] -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($ok) {
        Write-Host "  服务器$($ep[0]) ($($ep[1])) ✓" -ForegroundColor Green
    } else {
        Write-Host "  服务器$($ep[0]) ($($ep[1])) ✗ 不可达" -ForegroundColor Red
        exit 1
    }
}

# 清空 bisync 状态目录（强制首次运行）
$stateDir = Join-Path $env:LOCALAPPDATA 'rclone\bisync'
if (Test-Path $stateDir) {
    Write-Host "`n清空状态目录: $stateDir"
    Remove-Item "$stateDir\*" -Force -ErrorAction SilentlyContinue
}

# 读取 .syncignore 文件
$syncIgnoreFile = Join-Path $PSScriptRoot '.syncignore'
$excludeArgs = @()
if (Test-Path $syncIgnoreFile) {
    Write-Host "`n读取排除规则: $syncIgnoreFile"
    $rules = Get-Content $syncIgnoreFile -Encoding UTF8 |
        Where-Object { $_ -match '\S' } |  # 非空行
        Where-Object { $_ -notmatch '^\s*#' }  # 非注释行

    $excludeCount = 0
    foreach ($rule in $rules) {
        $rule = $rule.Trim()
        if ($rule) {
            $excludeArgs += '--exclude'
            $excludeArgs += $rule
            $excludeCount++
        }
    }
    Write-Host "已加载 $excludeCount 条排除规则" -ForegroundColor Green
} else {
    Write-Host "`n未找到 .syncignore 文件，不使用排除规则" -ForegroundColor Yellow
}

# 执行最小化的 resync 命令
Write-Host "`n执行 rclone bisync --resync..."
$cmdArgs = @('bisync', $PathA, $PathB, '--resync', '--verbose', '--log-file', $logFile, '--links') + $excludeArgs
Write-Host "命令: $RcloneExe $($cmdArgs -join ' ')`n"

& $RcloneExe @cmdArgs

$code = $LASTEXITCODE
Write-Host "`nrclone 退出码: $code"

if ($code -eq 0) {
    Write-Host "✓ resync 成功完成" -ForegroundColor Green
    Write-Host "`n检查生成的状态文件:"
    Get-ChildItem $stateDir -Filter '*.lst' | Select-Object Name, Length, LastWriteTime | Format-Table
} else {
    Write-Host "✗ resync 失败" -ForegroundColor Red
    Write-Host "`n查看日志获取详情: $logFile"
}

exit $code
