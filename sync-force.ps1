#Requires -Version 5.1
<#
.SYNOPSIS
    当日常 sync.ps1 因 --max-delete 保护中止时，确认后强制执行一次大批量删除同步。

.NOTES
    - 仅在你确认「就是要删、另一端也要跟上」时使用
    - 不要改定时任务去调用本脚本；默认仍走无 --force 的 sync.ps1
#>

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  强制同步（rclone bisync --force）" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "作用：绕过 --max-delete 删除比例保护，把「大量删除」同步到另一端。"
Write-Host "风险：删错后很难自动恢复。当前冲突策略见 sync.ps1 的 `$ConflictMode。"
Write-Host ""
Write-Host "仅在以下情况继续："
Write-Host "  - 你故意在某一端做了大范围删除，且希望另一端也删除"
Write-Host "  - 你已经核对过日志里的 Safety abort / too many deletes"
Write-Host ""

$answer = Read-Host "确认强制执行？请输入 YES（其他任意内容则取消）"
if ($answer -ne 'YES') {
    Write-Host "已取消，未做任何同步。" -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "开始强制同步..." -ForegroundColor Yellow
& (Join-Path $ProjectRoot 'sync.ps1') -ForceLargeDelete
exit $LASTEXITCODE
