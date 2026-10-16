# 同步测试指南

本文档指导你测试双向同步功能，验证各种场景。

## 测试前准备

确保两台服务器的 `~/sync` 目录都已经有文件。

### 查看当前状态

```bash
# 查看服务器 A 的文件
ssh lht@100.109.141.36 "ls -lah ~/sync"

# 查看服务器 B 的文件  
ssh lvhaitao@10.255.10.38 "ls -lah ~/sync"
```

## 测试场景

### 场景 1: 单边新增文件

**操作：**

```bash
# 在服务器 A 创建新文件
ssh lht@100.109.141.36 "echo 'test from A' > ~/sync/test-from-A.txt"
```

**触发同步：**

```powershell
# 手动触发同步
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

**验证：**

```bash
# 检查文件是否同步到服务器 B
ssh lvhaitao@10.255.10.38 "cat ~/sync/test-from-A.txt"
# 应该输出: test from A
```

### 场景 2: 单边修改文件

**操作：**

```bash
# 修改服务器 B 的文件
ssh lvhaitao@10.255.10.38 "echo 'modified from B' >> ~/sync/test-from-A.txt"
```

**触发同步并验证：**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

```bash
# 检查服务器 A 是否收到修改
ssh lht@100.109.141.36 "cat ~/sync/test-from-A.txt"
# 应该包含: modified from B
```

### 场景 3: 双边同时修改（冲突）

**操作：**

```bash
# 在服务器 A 修改
ssh lht@100.109.141.36 "echo 'version A' > ~/sync/conflict-test.txt"

# 在服务器 B 修改同一文件
ssh lvhaitao@10.255.10.38 "echo 'version B' > ~/sync/conflict-test.txt"
```

**触发同步：**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

**验证（默认 keep-both 策略）：**

```bash
# 服务器 A: 保留原版本
ssh lht@100.109.141.36 "cat ~/sync/conflict-test.txt"
# 应该输出: version A

# 服务器 B: 原版本被改名为 .conflict1
ssh lvhaitao@10.255.10.38 "ls ~/sync/conflict-test.txt*"
# 应该看到: conflict-test.txt 和 conflict-test.txt.conflict1

ssh lvhaitao@10.255.10.38 "cat ~/sync/conflict-test.txt"
# 输出: version A (从服务器 A 同步过来)

ssh lvhaitao@10.255.10.38 "cat ~/sync/conflict-test.txt.conflict1"
# 输出: version B (原来服务器 B 的版本)
```

### 场景 4: 单边删除文件

**操作：**

```bash
# 在服务器 A 删除文件
ssh lht@100.109.141.36 "rm ~/sync/test-from-A.txt"
```

**触发同步并验证：**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

```bash
# 检查服务器 B 的文件是否也被删除
ssh lvhaitao@10.255.10.38 "ls ~/sync/test-from-A.txt"
# 应该提示: No such file or directory
```

### 场景 5: 大量删除（触发保护机制）

**操作：**

```bash
# 在服务器 A 创建 10 个文件
for i in {1..10}; do
    ssh lht@100.109.141.36 "echo 'file $i' > ~/sync/file$i.txt"
done

# 先同步一次，让两边状态一致
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1

# 然后删除 4 个文件（超过 25% 的 40%）
for i in {1..4}; do
    ssh lht@100.109.141.36 "rm ~/sync/file$i.txt"
done
```

**触发同步：**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

**预期结果：**

同步会被中止，日志显示：

```
同步中止：rclone 退出码 7（可能触发 --max-delete 保护或网络中断）
```

**解决方法：**

临时提高删除阈值：

```powershell
# 编辑 sync.ps1，修改第 21 行
# $MaxDeletePct = 100  # 临时改为 100

# 执行同步
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1

# 同步完成后，记得改回 25
# $MaxDeletePct = 25
```

### 场景 6: 网络不可达（服务器 A）

**操作：**

```powershell
# 断开 Tailscale
tailscale down

# 尝试同步
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

**预期结果：**

脚本检测到服务器 A 不可达，自动跳过本次同步：

```
服务器A (100.109.141.36) 当前不可达，本次跳过，等待网络恢复
```

**恢复：**

```powershell
# 重新连接 Tailscale
tailscale up

# 再次同步，应该成功
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

## 查看同步日志

### 实时监控

```powershell
# 监控当前同步日志（类似 tail -f）
Get-Content D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 20
```

### 查看完整日志

```powershell
# 查看今天的完整日志
cat D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log
```

### 只看关键信息

```powershell
# 筛选关键信息（成功、失败、冲突）
Select-String -Path "D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log" `
    -Pattern "successful|failed|conflict|中止|完成" | Format-Table Line
```

## 处理大量删除的情况

如果你确实需要删除超过 25% 的文件：

### 方法一：临时提高阈值

1. 编辑 [D:\code_sync\sync.ps1](D:\code_sync\sync.ps1#L21)

```powershell
$MaxDeletePct = 100  # 临时改为 100
```

2. 执行同步

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

3. 改回默认值

```powershell
$MaxDeletePct = 25  # 改回 25
```

### 方法二：使用单向同步

如果要完全以某一端为准：

```powershell
# 以服务器 A 为准，覆盖服务器 B（先预览）
D:\code_sync\bin\rclone.exe sync serverA:sync serverB:sync --verbose --dry-run

# 确认无误后正式执行
D:\code_sync\bin\rclone.exe sync serverA:sync serverB:sync --verbose

# 重新初始化 bisync 状态
.\test-resync.ps1
```

## 自动化测试脚本

创建一个快速测试脚本：

```powershell
# test-sync-quick.ps1
Write-Host "=== 快速同步测试 ===" -ForegroundColor Cyan

# 在服务器 A 创建测试文件
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
ssh lht@100.109.141.36 "echo 'Test at $timestamp' > ~/sync/test-$timestamp.txt"
Write-Host "✓ 在服务器 A 创建测试文件: test-$timestamp.txt" -ForegroundColor Green

# 等待 2 秒
Start-Sleep -Seconds 2

# 执行同步
Write-Host "`n执行同步..." -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1

# 验证同步结果
Write-Host "`n验证同步结果..." -ForegroundColor Yellow
$result = ssh lvhaitao@10.255.10.38 "cat ~/sync/test-$timestamp.txt" 2>&1
if ($result -match "Test at $timestamp") {
    Write-Host "✓ 同步成功！文件已出现在服务器 B" -ForegroundColor Green
    Write-Host "  内容: $result"
} else {
    Write-Host "✗ 同步失败或文件未找到" -ForegroundColor Red
    Write-Host "  输出: $result"
}
```

## 常见问题排查

### 1. 同步不生效

```powershell
# 检查定时任务状态
Get-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"

# 查看最后执行时间
Get-ScheduledTaskInfo -TaskName "RcloneBisync-ServerA-ServerB"

# 手动执行一次
Start-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
```

### 2. 状态文件损坏

```powershell
# 重新初始化
.\test-resync.ps1
```

### 3. 查看 rclone 详细错误

```powershell
# 查看完整的 rclone 日志（包含所有调试信息）
cat D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log | Select-String "ERROR|WARN"
```

## 定时任务测试

### 修改间隔为 1 分钟（快速测试）

```powershell
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger $trigger

Write-Host "定时任务已改为每 1 分钟执行一次" -ForegroundColor Green
Write-Host "测试完成后记得改回 15 分钟！" -ForegroundColor Yellow
```

### 改回 15 分钟

```powershell
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger $trigger

Write-Host "定时任务已改回每 15 分钟" -ForegroundColor Green
```

## 清理测试文件

```bash
# 清理服务器 A 的测试文件
ssh lht@100.109.141.36 "rm ~/sync/test-* ~/sync/file*.txt 2>/dev/null"

# 清理服务器 B 的测试文件
ssh lvhaitao@10.255.10.38 "rm ~/sync/test-* ~/sync/file*.txt ~/sync/*.conflict* 2>/dev/null"

# 同步一次，让两边状态一致
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```
