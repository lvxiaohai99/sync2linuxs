#Requires -Version 5.1
<#
.SYNOPSIS
    服务器A (100.109.141.36) 与 服务器B (10.255.10.38) 的 ~/sync 目录双向同步。
    本机作为中转（rclone bisync over SFTP），兼容任一服务器离线：网络恢复后自动补同步。

.NOTES
    冲突策略 $ConflictMode 可选值：
      keep-both : 两端都改同一文件时，两边都保留，败方存为 xxx.conflictN（推荐，不丢数据）
      newer     : 修改时间较新的一端覆盖较旧的一端
      a-wins    : 一律以服务器A为准覆盖B
      b-wins    : 一律以服务器B为准覆盖A
#>

# ===================== 配置区 =====================
$ProjectRoot    = $PSScriptRoot
$ConflictMode   = 'newer'          # keep-both | newer | a-wins | b-wins
$RcloneExe      = Join-Path $ProjectRoot 'bin\rclone.exe'
$PathA          = 'serverA:sync'       # 服务器A 的 ~/sync
$PathB          = 'serverB:sync'       # 服务器B 的 ~/sync
$LogDir         = Join-Path $ProjectRoot 'logs'
$MaxDeletePct   = 25                   # 单次删除超过此比例即中止（防误删保险丝）
$ConnectTimeout = 10                   # 连通性探测超时（秒）
# ==================================================

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$logFile = Join-Path $LogDir ("bisync-" + (Get-Date -Format 'yyyyMMdd') + '.log')

function Write-Log([string]$msg, [string]$level = 'INFO') {
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# --- 防重叠：同一时刻只允许一个同步实例 ---
$lockFile = Join-Path $LogDir 'bisync.lock'
try {
    $lock = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log "另一个同步实例正在运行，本次跳过" 'WARN'
    exit 0
}

try {
    Write-Log "========== 同步开始 (冲突策略: $ConflictMode) =========="

    # --- 连通性预检：任一端不可达则本次跳过，等下个周期 ---
    foreach ($ep in @(@('A','100.109.141.36'), @('B','10.255.10.38'))) {
        $ok = Test-NetConnection -ComputerName $ep[1] -Port 22 -InformationLevel Quiet `
              -WarningAction SilentlyContinue
        if (-not $ok) {
            Write-Log "服务器$($ep[0]) ($($ep[1])) 当前不可达，本次跳过，等待网络恢复" 'WARN'
            exit 0
        }
        Write-Log "服务器$($ep[0]) ($($ep[1])) 可达"
    }

    # --- 读取 .syncignore 文件 ---
    $syncIgnoreFile = Join-Path $PSScriptRoot '.syncignore'
    $excludeArgs = @()
    if (Test-Path $syncIgnoreFile) {
        Write-Log "读取排除规则: $syncIgnoreFile"
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
        Write-Log "已加载 $excludeCount 条排除规则"
    } else {
        Write-Log "未找到 .syncignore 文件，不使用排除规则" 'WARN'
    }

    # --- 冲突策略映射为 rclone 参数 ---
    $conflictArgs = switch ($ConflictMode) {
        'keep-both' { @('--conflict-resolve', 'none', '--conflict-loser', 'num', '--conflict-suffix', '.conflict') }
        'newer'     { @('--conflict-resolve', 'newer') }
        'a-wins'    { @('--conflict-resolve', 'path1') }
        'b-wins'    { @('--conflict-resolve', 'path2') }
        default     { throw "未知的 ConflictMode: $ConflictMode" }
    }

    # --- 首次运行检测：bisync 无历史状态时需要先 --resync ---
    $stateDir = Join-Path $env:LOCALAPPDATA 'rclone\bisync'
    $needResync = -not (Get-ChildItem $stateDir -Filter '*.path1.lst' -ErrorAction SilentlyContinue)
    $resyncArgs = if ($needResync) {
        Write-Log "检测到首次运行，执行 --resync（以服务器A为基准）" 'WARN'
        @('--resync')
    } else { @() }

    # --- 执行 bisync ---
    $rcloneArgs = @(
        'bisync', $PathA, $PathB,
        '--verbose', '--log-file', $logFile,
        '--check-access', '--resilient', '--recover',
        '--max-delete', $MaxDeletePct,
        '--create-empty-src-dirs',
        '--contimeout', '15s', '--timeout', '5m', '--retries', '2', '--low-level-retries', '3',
        '--links'  # 跳过符号链接，避免循环
    ) + $excludeArgs + $conflictArgs + $resyncArgs

    Write-Log "执行: rclone $($rcloneArgs -join ' ')"
    & $RcloneExe @rcloneArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-Log "同步完成 ✔"
    } elseif ($code -eq 2 -or $code -eq 7) {
        Write-Log "同步中止：rclone 退出码 $code（可能触发 --max-delete 保护或网络中断），未做破坏性操作，下周期重试" 'WARN'
    } else {
        Write-Log "同步失败：rclone 退出码 $code，详见日志，下周期自动重试" 'ERROR'
    }
    exit $code
}
catch {
    Write-Log "脚本异常: $_" 'ERROR'
    exit 1
}
finally {
    if ($lock) { $lock.Close() }
}
