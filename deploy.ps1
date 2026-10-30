#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    双服务器目录同步方案 - 一键部署脚本

.DESCRIPTION
    自动完成所有配置步骤：
    1. 检查依赖条件（SSH 连接、同步目录、网络）
    2. 配置 rclone SFTP 连接
    3. 执行首次同步（--resync）
    4. 创建 Windows 定时任务

.NOTES
    需要管理员权限运行
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ==================== 用户配置区 ====================
# 修改以下配置以适应你的环境

# 服务器 A 配置（Tailscale 服务器）
$ServerA = @{
    Host     = '100.109.141.36'
    User     = 'lht'
    KeyFile  = 'C:/Users/lvhaitao/.ssh/id_ed25519_nano'
    SyncDir  = 'sync'  # 相对于用户 home 目录
}

# 服务器 B 配置（内网服务器）
$ServerB = @{
    Host     = '10.255.10.38'
    User     = 'lvhaitao'
    KeyFile  = 'C:/Users/lvhaitao/.ssh/id_rsa_38'
    SyncDir  = 'sync'  # 相对于用户 home 目录
}

# 本机配置（默认使用脚本所在目录，换机器克隆后无需改路径）
$ProjectDir  = $PSScriptRoot
$RcloneExe   = Join-Path $ProjectDir 'bin\rclone.exe'
$SyncScript  = Join-Path $ProjectDir 'sync.ps1'
$LogDir      = Join-Path $ProjectDir 'logs'

# 定时任务配置（每天两次，不再按分钟轮询）
$TaskName     = 'RcloneBisync-ServerA-ServerB'
$TaskTimes    = @('09:20', '18:00')  # 本地时间

# ====================================================

$deployLog = Join-Path $LogDir ("deploy-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
New-Item -ItemType Directory -Force $LogDir | Out-Null

function Write-Log([string]$msg, [string]$level = 'INFO') {
    $colors = @{
        'INFO'  = 'White'
        'OK'    = 'Green'
        'WARN'  = 'Yellow'
        'ERROR' = 'Red'
        'STEP'  = 'Cyan'
    }
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Add-Content -Path $deployLog -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor $colors[$level]
}

function Test-SSHConnection($host, $user, $keyFile) {
    try {
        $result = & ssh -i $keyFile -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
                       "$user@$host" "echo OK" 2>&1
        return $result -match 'OK'
    } catch {
        return $false
    }
}

function Test-RemoteDirectory($host, $user, $keyFile, $dir) {
    try {
        $result = & ssh -i $keyFile -o ConnectTimeout=10 -o StrictHostKeyChecking=no `
                       "$user@$host" "test -d ~/$dir && echo EXISTS" 2>&1
        return $result -match 'EXISTS'
    } catch {
        return $false
    }
}

try {
    Write-Host "`n" + ("="*70) -ForegroundColor Cyan
    Write-Host " 双服务器目录同步方案 - 一键部署" -ForegroundColor Cyan
    Write-Host ("="*70) + "`n" -ForegroundColor Cyan

    Write-Log "部署开始" 'STEP'

    # ==================== 步骤 1: 检查依赖条件 ====================
    Write-Log "`n[步骤 1/5] 检查依赖条件" 'STEP'

    # 1.1 检查 rclone
    Write-Log "  检查 rclone..." 'INFO'
    if (-not (Test-Path $RcloneExe)) {
        throw "rclone.exe 不存在: $RcloneExe"
    }
    $rcloneVer = & $RcloneExe version --version 2>&1 | Select-Object -First 1
    Write-Log "  ✓ rclone: $rcloneVer" 'OK'

    # 1.2 检查同步脚本
    Write-Log "  检查同步脚本..." 'INFO'
    if (-not (Test-Path $SyncScript)) {
        throw "同步脚本不存在: $SyncScript"
    }
    Write-Log "  ✓ 同步脚本: $SyncScript" 'OK'

    # 1.3 检查 SSH 密钥
    Write-Log "  检查 SSH 密钥..." 'INFO'
    foreach ($server in @($ServerA, $ServerB)) {
        $keyPath = $server.KeyFile -replace '/', '\'
        if (-not (Test-Path $keyPath)) {
            throw "SSH 密钥不存在: $keyPath"
        }
    }
    Write-Log "  ✓ SSH 密钥文件存在" 'OK'

    # 1.4 检查网络连通性
    Write-Log "  检查网络连通性..." 'INFO'

    Write-Log "    测试服务器 A ($($ServerA.Host))..." 'INFO'
    $testA = Test-NetConnection -ComputerName $ServerA.Host -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $testA) {
        throw "无法连接到服务器 A ($($ServerA.Host):22)。请确保 Tailscale 已连接。"
    }
    Write-Log "    ✓ 服务器 A 可达" 'OK'

    Write-Log "    测试服务器 B ($($ServerB.Host))..." 'INFO'
    $testB = Test-NetConnection -ComputerName $ServerB.Host -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $testB) {
        throw "无法连接到服务器 B ($($ServerB.Host):22)。"
    }
    Write-Log "    ✓ 服务器 B 可达" 'OK'

    # 1.5 检查 SSH 免密登录
    Write-Log "  检查 SSH 免密登录..." 'INFO'

    Write-Log "    测试服务器 A SSH..." 'INFO'
    if (-not (Test-SSHConnection $ServerA.Host $ServerA.User $ServerA.KeyFile)) {
        throw "SSH 登录服务器 A 失败。请检查密钥配置。"
    }
    Write-Log "    ✓ 服务器 A SSH 登录成功" 'OK'

    Write-Log "    测试服务器 B SSH..." 'INFO'
    if (-not (Test-SSHConnection $ServerB.Host $ServerB.User $ServerB.KeyFile)) {
        throw "SSH 登录服务器 B 失败。请检查密钥配置。"
    }
    Write-Log "    ✓ 服务器 B SSH 登录成功" 'OK'

    # 1.6 检查同步目录
    Write-Log "  检查同步目录..." 'INFO'

    Write-Log "    检查服务器 A: ~/$($ServerA.SyncDir)" 'INFO'
    if (-not (Test-RemoteDirectory $ServerA.Host $ServerA.User $ServerA.KeyFile $ServerA.SyncDir)) {
        Write-Log "    目录不存在，正在创建..." 'WARN'
        & ssh -i $ServerA.KeyFile -o StrictHostKeyChecking=no "$($ServerA.User)@$($ServerA.Host)" "mkdir -p ~/$($ServerA.SyncDir)" 2>&1 | Out-Null
        Write-Log "    ✓ 已创建目录" 'OK'
    } else {
        Write-Log "    ✓ 目录存在" 'OK'
    }

    Write-Log "    检查服务器 B: ~/$($ServerB.SyncDir)" 'INFO'
    if (-not (Test-RemoteDirectory $ServerB.Host $ServerB.User $ServerB.KeyFile $ServerB.SyncDir)) {
        Write-Log "    目录不存在，正在创建..." 'WARN'
        & ssh -i $ServerB.KeyFile -o StrictHostKeyChecking=no "$($ServerB.User)@$($ServerB.Host)" "mkdir -p ~/$($ServerB.SyncDir)" 2>&1 | Out-Null
        Write-Log "    ✓ 已创建目录" 'OK'
    } else {
        Write-Log "    ✓ 目录存在" 'OK'
    }

    Write-Log "`n依赖检查全部通过 ✓" 'OK'

    # ==================== 步骤 2: 配置 rclone ====================
    Write-Log "`n[步骤 2/5] 配置 rclone" 'STEP'

    $rcloneConfDir = Join-Path $env:APPDATA 'rclone'
    $rcloneConf = Join-Path $rcloneConfDir 'rclone.conf'

    New-Item -ItemType Directory -Force $rcloneConfDir | Out-Null

    $confContent = @"
[serverA]
type = sftp
host = $($ServerA.Host)
user = $($ServerA.User)
key_file = $($ServerA.KeyFile)
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum

[serverB]
type = sftp
host = $($ServerB.Host)
user = $($ServerB.User)
key_file = $($ServerB.KeyFile)
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum
"@

    Set-Content -Path $rcloneConf -Value $confContent -Encoding UTF8
    Write-Log "  ✓ rclone 配置已写入: $rcloneConf" 'OK'

    # 验证配置
    Write-Log "  验证 rclone 配置..." 'INFO'
    $lsA = & $RcloneExe lsd serverA: 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rclone 无法连接到服务器 A: $lsA"
    }
    Write-Log "  ✓ 服务器 A 连接正常" 'OK'

    $lsB = & $RcloneExe lsd serverB: 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rclone 无法连接到服务器 B: $lsB"
    }
    Write-Log "  ✓ 服务器 B 连接正常" 'OK'

    # ==================== 步骤 3: 执行首次同步 ====================
    Write-Log "`n[步骤 3/5] 执行首次同步（--resync）" 'STEP'
    Write-Log "  这将建立同步基准状态，以服务器 A 为准..." 'INFO'

    # 清空 bisync 状态（确保首次运行）
    $bisyncState = Join-Path $env:LOCALAPPDATA 'rclone\bisync'
    if (Test-Path $bisyncState) {
        Write-Log "  清空旧的 bisync 状态..." 'INFO'
        Remove-Item "$bisyncState\*" -Force -ErrorAction SilentlyContinue
    }

    $resyncLog = Join-Path $LogDir ("resync-deploy-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Write-Log "  执行 rclone bisync --resync..." 'INFO'
    Write-Log "  日志: $resyncLog" 'INFO'

    & $RcloneExe bisync "serverA:$($ServerA.SyncDir)" "serverB:$($ServerB.SyncDir)" `
        --resync --verbose --log-file $resyncLog 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Log "  ✓ 首次同步成功完成" 'OK'

        # 显示状态文件
        if (Test-Path $bisyncState) {
            $stateFiles = Get-ChildItem $bisyncState -Filter '*.lst' -ErrorAction SilentlyContinue
            if ($stateFiles) {
                Write-Log "  生成的状态文件:" 'INFO'
                $stateFiles | ForEach-Object {
                    Write-Log "    - $($_.Name)" 'INFO'
                }
            }
        }
    } else {
        Write-Log "  ✗ 首次同步失败（退出码: $LASTEXITCODE）" 'ERROR'
        Write-Log "  查看详细日志: $resyncLog" 'ERROR'
        throw "首次同步失败"
    }

    # ==================== 步骤 4: 创建定时任务 ====================
    Write-Log "`n[步骤 4/5] 创建 Windows 定时任务" 'STEP'

    # 检查任务是否已存在
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Log "  任务已存在，先删除..." 'WARN'
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`""

    # 每天固定时刻触发（多触发器时，第二个起需显式 Enabled=$true，否则 PowerShell 会默认为禁用）
    $triggers = foreach ($t in $TaskTimes) {
        $tr = New-ScheduledTaskTrigger -Daily -At $t
        $tr.Enabled = $true
        $tr
    }

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -Principal $principal `
        -Description "双向同步服务器 A ($($ServerA.Host)) 和服务器 B ($($ServerB.Host)) 的 sync 目录；每天 $($TaskTimes -join '、')" | Out-Null

    Write-Log "  ✓ 定时任务已创建: $TaskName" 'OK'
    Write-Log "  执行时间: 每天 $($TaskTimes -join '、')" 'INFO'
    Write-Log "  执行脚本: $SyncScript" 'INFO'

    # ==================== 步骤 5: 验证部署 ====================
    Write-Log "`n[步骤 5/5] 验证部署" 'STEP'

    # 测试运行一次同步
    Write-Log "  执行测试同步..." 'INFO'
    $testSyncLog = Join-Path $LogDir ("bisync-" + (Get-Date -Format 'yyyyMMdd') + '.log')
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SyncScript

    if ($LASTEXITCODE -eq 0) {
        Write-Log "  ✓ 测试同步成功" 'OK'
    } else {
        Write-Log "  ⚠ 测试同步失败（退出码: $LASTEXITCODE）" 'WARN'
        Write-Log "  但这可能是正常的（例如没有文件变化）" 'WARN'
    }

    # 验证定时任务
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    Write-Log "  ✓ 定时任务状态: $($task.State)" 'OK'
    Write-Log "  下次运行时间: $($taskInfo.NextRunTime)" 'INFO'

    # ==================== 部署完成 ====================
    Write-Host "`n" + ("="*70) -ForegroundColor Green
    Write-Host " 🎉 部署成功完成！" -ForegroundColor Green
    Write-Host ("="*70) + "`n" -ForegroundColor Green

    Write-Log "`n部署成功完成" 'OK'

    # 显示摘要
    Write-Host "📦 部署摘要:" -ForegroundColor Cyan
    Write-Host "  • 服务器 A: $($ServerA.User)@$($ServerA.Host):~/$($ServerA.SyncDir)"
    Write-Host "  • 服务器 B: $($ServerB.User)@$($ServerB.Host):~/$($ServerB.SyncDir)"
    Write-Host "  • 同步间隔: 每 $TaskInterval 分钟"
    Write-Host "  • 日志目录: $LogDir"
    Write-Host "  • 定时任务: $TaskName"
    Write-Host ""
    Write-Host "📝 后续操作:" -ForegroundColor Cyan
    Write-Host "  1. 在两台服务器的 sync 目录中添加测试文件"
    Write-Host "  2. 等待 $TaskInterval 分钟，或手动触发任务:"
    Write-Host "     Start-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  3. 查看同步日志:"
    Write-Host "     cat $testSyncLog"
    Write-Host "  4. 查看详细使用说明:"
    Write-Host "     Get-Content `"$ProjectDir\README.md`""
    Write-Host ""
    Write-Host "🔧 管理命令:" -ForegroundColor Cyan
    Write-Host "  • 查看任务状态: Get-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  • 禁用任务: Disable-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  • 启用任务: Enable-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  • 删除任务: Unregister-ScheduledTask -TaskName '$TaskName'"
    Write-Host "  • 手动同步: powershell -File '$SyncScript'"
    Write-Host ""
    Write-Host "📖 完整文档: $ProjectDir\README.md`n" -ForegroundColor Yellow

    Write-Log "部署日志已保存: $deployLog" 'INFO'

} catch {
    Write-Log "`n✗ 部署失败: $_" 'ERROR'
    Write-Log "详细日志: $deployLog" 'ERROR'
    Write-Host "`n部署失败，请查看日志: $deployLog" -ForegroundColor Red
    exit 1
}
