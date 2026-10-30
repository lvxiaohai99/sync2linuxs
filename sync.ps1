#Requires -Version 5.1
<#
.SYNOPSIS
    服务器A (100.109.141.36) 与 服务器B (10.255.10.38) 的 ~/sync 目录双向同步。
    本机作为中转（rclone bisync over SFTP），兼容任一服务器离线：网络恢复后自动补同步。

.PARAMETER ForceLargeDelete
    加上 rclone --force，允许超过 --max-delete 比例的大批量删除。
    日常定时任务不要带此参数；需要时请运行 sync-force.ps1（会再次确认）。

.NOTES
    冲突策略 $ConflictMode 可选值：
      keep-both : 两端都改同一文件时，两边都保留，败方存为 xxx.conflictN（推荐，不丢数据）
      newer     : 修改时间较新的一端覆盖较旧的一端
      a-wins    : 一律以服务器A为准覆盖B
      b-wins    : 一律以服务器B为准覆盖A
#>
param(
    [switch]$ForceLargeDelete
)

# ===================== 配置区 =====================
$ProjectRoot    = $PSScriptRoot
$ConflictMode   = 'b-wins'          # keep-both | newer | a-wins | b-wins
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

    # --- 清理僵死 bisync 锁：上次进程崩溃/被结束时，.lck 会卡住后续同步 ---
    $stateDir = Join-Path $env:LOCALAPPDATA 'rclone\bisync'
    if (Test-Path $stateDir) {
        Get-ChildItem $stateDir -Filter '*.lck' -ErrorAction SilentlyContinue | ForEach-Object {
            $lockPath = $_.FullName
            try {
                $info = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $lockPid = [int]$info.PID
                $alive = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                if (-not $alive) {
                    Remove-Item -Force $lockPath
                    Write-Log "已清除僵死锁文件（原 PID $lockPid 已退出）: $lockPath" 'WARN'
                } else {
                    Write-Log "检测到其他 bisync 仍在运行 (PID $lockPid)，本次跳过" 'WARN'
                    exit 0
                }
            } catch {
                # 无法解析则按僵死处理，避免永久卡死
                Remove-Item -Force $lockPath -ErrorAction SilentlyContinue
                Write-Log "已清除无法解析的锁文件: $lockPath" 'WARN'
            }
        }
    }

    # --- 读取 .syncignore 文件 ---
    $syncIgnoreFile = Join-Path $PSScriptRoot '.syncignore'
    $excludeArgs = @()
    if (Test-Path $syncIgnoreFile) {
        Write-Log "读取排除规则: $syncIgnoreFile"
        $rules = Get-Content $syncIgnoreFile -Encoding UTF8 |
            Where-Object { $_ -match '\S' } |           # 非空行
            Where-Object { $_ -notmatch '^\s*#' } |     # 非整行注释
            ForEach-Object {
                # 去掉行内注释（规则后方的 # ...），只保留规则本身
                ($_ -replace '\s+#.*$', '').Trim()
            } |
            Where-Object { $_ }

        $excludeCount = 0
        foreach ($rule in $rules) {
            $excludeArgs += '--exclude'
            $excludeArgs += $rule
            $excludeCount++
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

    # --- 是否需要 --resync ---
    # rclone 成功时留下 *.path1.lst；致命失败后会改成 *.lst-err，并要求 --resync 才能恢复。
    # 脚本以前只认 *.path1.lst，失败后会误报「首次运行」。
    $hasOkList  = [bool](Get-ChildItem $stateDir -Filter '*.path1.lst' -ErrorAction SilentlyContinue)
    $hasErrList = [bool](Get-ChildItem $stateDir -Filter '*.path1.lst-err' -ErrorAction SilentlyContinue)
    $needResync = -not $hasOkList
    $resyncArgs = if ($needResync) {
        if ($hasErrList) {
            Write-Log "上次同步致命失败（状态文件为 .lst-err），按 rclone 要求执行 --resync 恢复；这不是真正的首次运行" 'WARN'
        } else {
            Write-Log "未找到 bisync 成功状态（*.path1.lst），执行 --resync 建立基准" 'WARN'
        }
        @('--resync')
    } else { @() }

    # --- 执行 bisync ---
    $forceArgs = @()
    if ($ForceLargeDelete) {
        $forceArgs = @('--force')
        Write-Log "已启用 --force：允许超过 --max-delete $MaxDeletePct% 的大批量删除" 'WARN'
    }

    $rcloneArgs = @(
        'bisync', $PathA, $PathB,
        '--verbose', '--log-file', $logFile,
        '--check-access', '--resilient', '--recover',
        '--max-delete', $MaxDeletePct,
        '--create-empty-src-dirs',
        '--contimeout', '15s', '--timeout', '5m', '--retries', '2', '--low-level-retries', '3',
        '--links'  # 跳过符号链接，避免循环
    ) + $forceArgs + $excludeArgs + $conflictArgs + $resyncArgs

    Write-Log "执行: rclone $($rcloneArgs -join ' ')"
    & $RcloneExe @rcloneArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-Log "同步完成 ✔"
    } else {
        # 从本次日志尾部识别常见中止原因，给出更直白的说明
        $tail = @()
        if (Test-Path $logFile) {
            $tail = Get-Content $logFile -Tail 80 -ErrorAction SilentlyContinue
        }
        $tailText = $tail -join "`n"

        if ($tailText -match 'too many deletes') {
            $forceCmd = "powershell -ExecutionPolicy Bypass -File `"$ProjectRoot\sync-force.ps1`""
            Write-Log "同步已安全中止：触发 --max-delete $MaxDeletePct% 删除保护（单次要删的文件太多）。两端都未按这次计划改动。" 'WARN'
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Yellow
            Write-Host "  删除保护已触发（too many deletes）" -ForegroundColor Yellow
            Write-Host "============================================================" -ForegroundColor Yellow
            Write-Host "两端文件都还在，这次没有真的大删。"
            Write-Host ""
            Write-Host "若确认就是要大删、另一端也要跟上，请手动执行：" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  $forceCmd" -ForegroundColor Green
            Write-Host ""
            Write-Host "脚本会要求你输入 YES 后才加 --force 再同步一次。"
            Write-Host "若是误删、另一端还有正确文件：不要执行上面命令，先从正确端拷回。"
            Write-Host "若只是改了 .syncignore：执行 .\test-resync.ps1"
            Write-Host "============================================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Log "手动强制同步命令: $forceCmd" 'WARN'
        } elseif ($tailText -match 'prior lock file found') {
            Write-Log "同步失败：存在 bisync 锁文件。若无其他同步在跑，重新执行本脚本会尝试清除僵死锁。" 'ERROR'
        } elseif ($tailText -match 'is a file not a directory|\.clangd|partial file rename') {
            Write-Log "同步致命失败（退出码 $code）：多半是 .clangd 一端为文件、一端为目录，或 *.partial 重命名失败。已应在 .syncignore 排除；若仍失败，请在两端删除 jgzd_git/mt/.clangd 后再跑一次。" 'ERROR'
        } elseif ($code -eq 2 -or $code -eq 7) {
            Write-Log "同步中止：rclone 退出码 $code（可能网络中断或安全保护），未做破坏性操作，下周期重试" 'WARN'
        } else {
            Write-Log "同步失败：rclone 退出码 $code，详见日志，下周期自动重试" 'ERROR'
        }
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
