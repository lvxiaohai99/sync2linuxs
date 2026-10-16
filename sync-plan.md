# 双服务器目录双向同步方案

## 1. 背景与约束

| 项目 | 说明 |
|---|---|
| 服务器 A | 我的服务器，Tailscale IP：`100.109.141.36` |
| 服务器 B | 内网服务器，IP：`10.255.10.38` |
| 本机 | Windows 11，可同时访问 A（走 Tailscale）和 B（走内网） |
| 约束 1 | A、B 之间**不能直连**，必须经本机中转 |
| 约束 2 | **双向同步**：两端目录都可能被修改 |
| 约束 3 | **定时同步**，不要求实时 |

## 2. 方案选型

| 方案 | 原理 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **rclone bisync（推荐）** | 本机运行 rclone，以 SFTP 分别挂载 A、B，bisync 做双向同步 | 本机不落盘存数据；原生 Windows 支持；定时任务简单；冲突/删除有明确策略 | 需保持两端时间基本同步；bisync 运行时目录不能被其他任务同时写 | ✅ 采用 |
| Unison + SSH ProxyJump | 在 A 上跑 Unison，经本机做 SSH 跳板直连 B | 本机只转发 TCP；Unison 双向同步很成熟 | 需在本机开 OpenSSH Server；配置较绕 | 备选 |
| Syncthing 三节点 | A、B、本机各装 Syncthing，本机作为中间节点 | 可升级为准实时；图形界面友好 | 本机需**完整存一份数据**；常驻进程多 | 未来要实时时再考虑 |

**推荐架构：**

```
服务器 A (100.109.141.36)                服务器 B (10.255.10.38)
        │  SFTP/SSH (Tailscale)      SFTP/SSH (内网)  │
        └──────────────┐  ┌──────────────────────────┘
                       ▼  ▼
                  本机 Windows 11
              rclone bisync + 计划任务
              （数据流经过，不本地存储）
```

## 3. 前置条件检查（动手前先验证）

在 PowerShell / Git Bash 中依次确认：

```bash
# 1. 能 SSH 到 A（Tailscale 需已连接）
ssh userA@100.109.141.36 "echo ok"

# 2. 能 SSH 到 B
ssh userB@10.255.10.38 "echo ok"

# 3. 两台服务器时间基本一致（差几秒以内，bisync 依赖 mtime 判断新旧）
ssh userA@100.109.141.36 "date"; ssh userB@10.255.10.38 "date"; date
```

如时间偏差大，两台服务器都配置 NTP 校时。

## 4. 实施步骤

### 4.1 安装 rclone

```powershell
winget install Rclone.Rclone
# 验证
rclone version
```

### 4.2 配置 SSH 免密登录

为两台服务器各生成/复用密钥，并将公钥写入对方的 `~/.ssh/authorized_keys`：

```bash
ssh-keygen -t ed25519          # 如已有密钥可跳过
ssh-copy-id userA@100.109.141.36   # 或用 ssh + 手工追加公钥
ssh-copy-id userB@10.255.10.38
```

### 4.3 配置 rclone 两个 SFTP remote

运行 `rclone config` 交互式添加，或直接编辑 `rclone.conf`（路径用 `rclone config file` 查看）：

```ini
[serverA]
type = sftp
host = 100.109.141.36
user = userA
key_file = C:\Users\<你的用户名>\.ssh\id_ed25519
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum

[serverB]
type = sftp
host = 10.255.10.38
user = userB
key_file = C:\Users\<你的用户名>\.ssh\id_ed25519
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum
```

验证：

```bash
rclone lsd serverA:/home/userA/syncdir
rclone lsd serverB:/home/userB/syncdir
```

### 4.4 首次同步（--resync，只需跑一次）

> ⚠️ 首次 resync 以 **A（path1）为基准**：两边同名但内容不同的文件，以 A 端为准。
> 如果 B 端已有不可替代的数据，先手工把 B 独有的文件拷到 A，或先做一次 `--dry-run` 检查。

```bash
# 先干跑，看清要发生什么
rclone bisync serverA:/home/userA/syncdir serverB:/home/userB/syncdir --resync --dry-run --verbose

# 确认无误后正式执行
rclone bisync serverA:/home/userA/syncdir serverB:/home/userB/syncdir --resync --verbose
```

### 4.5 日常同步脚本

新建 `D:\code_sync\sync.ps1`：

```powershell
$ErrorActionPreference = "Stop"
$logDir = "D:\code_sync\logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("bisync-" + (Get-Date -Format "yyyyMMdd") + ".log")

# --check-access  确认两端可写，避免单边故障时误删
# --resilient     网络抖动后自动恢复
# --recover       上次中断后自动修复状态
# --max-delete 25 单次删除超过 25% 即中止（防误删保险丝）
# --conflict-loser num --conflict-suffix .conflict  冲突文件保留为 .conflictN 而不是直接覆盖
rclone bisync serverA:/home/userA/syncdir serverB:/home/userB/syncdir `
  --verbose --log-file $log `
  --check-access --resilient --recover `
  --max-delete 25 `
  --conflict-loser num --conflict-suffix .conflict `
  --create-empty-src-dirs

if ($LASTEXITCODE -ne 0) {
    # 可在此接邮件/微信通知
    Write-Error "bisync failed, exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
```

手工验证一次：

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

### 4.6 配置 Windows 计划任务（每 15 分钟）

以管理员 PowerShell 执行：

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName "RcloneBisync-A-B" -Action $action `
  -Trigger $trigger -Settings $settings -RunLevel Highest
```

要点：
- `-ExecutionTimeLimit 30分钟`：保证上一次没跑完时不会重叠执行（bisync 要求同一对目录同一时间只有一个实例）。
- `-StartWhenAvailable`：电脑关机错过的时间点，开机后补跑一次。
- 同步目录大、首次传输慢时，可把间隔调成 30 分钟或 1 小时。

## 5. 冲突与删除语义（使用前必读）

| 场景 | bisync 行为 |
|---|---|
| 只有一端修改 | 正常同步到另一端 |
| 两端**都改了同一文件** | 较新的一边胜出，输的一边保留为 `xxx.conflict1`（由 `--conflict-loser num` 决定），不丢数据 |
| 一端删除，另一端未动 | 删除会传播到另一端（这是"同步"而非"备份"） |
| 一端删除，另一端修改了同文件 | 修改版保留，视为更新 |
| 单次运行要删除超过 25% 的文件 | 中止并报错（`--max-delete` 保险丝），防止挂载异常导致清空对端 |

其他注意事项：
- bisync 运行期间不要对两端目录做大改动；改动请等本次同步完成。
- 日志在 `D:\code_sync\logs\`，定期清理。
- rclone 的 bisync 状态缓存在 `%LOCALAPPDATA%\rclone\bisync\`，**不要删**，删了就得重新 `--resync`。
- 两端服务器务必时间同步（NTP），否则"谁更新"判断会出错。

## 6. 验证清单

- [ ] `ssh userA@100.109.141.36` / `ssh userB@10.255.10.38` 免密成功
- [ ] `rclone lsd` 两端都能列出目录
- [ ] `--resync --dry-run` 输出符合预期
- [ ] 正式 `--resync` 完成
- [ ] 在 A 新建文件 → 手工跑 sync.ps1 → B 出现
- [ ] 在 B 修改文件 → 手工跑 sync.ps1 → A 更新
- [ ] 两端同时改同一文件 → 产生 `.conflict1` 且数据未丢
- [ ] 计划任务创建成功，到点自动执行，日志有记录

## 7. 快速部署

### 一键部署

以**管理员身份**运行 PowerShell：

```powershell
cd D:\code_sync
.\deploy.ps1
```

部署脚本自动完成：
- ✅ 检查所有依赖（SSH、网络、目录）
- ✅ 配置 rclone SFTP 连接
- ✅ 执行首次同步（--resync）
- ✅ 创建 Windows 定时任务

### 手动部署

如需手动部署，按照第 4 节步骤操作。

## 8. 使用与维护

### 日志管理

**日志位置：** `D:\code_sync\logs\`

```powershell
# 查看今天的同步日志
cat D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log

# 实时监控
Get-Content D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 20

# 清理 30 天前的日志
Get-ChildItem D:\code_sync\logs\*.log | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
    Remove-Item
```

### 定时任务管理

**任务名称：** `RcloneBisync-ServerA-ServerB`

```powershell
# 查看任务状态
Get-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"

# 立即执行一次
Start-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"

# 禁用/启用
Disable-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
Enable-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"

# 修改间隔为 30 分钟
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger $trigger

# 打开图形界面
taskschd.msc
```

### 冲突处理

修改 [sync.ps1:16](sync.ps1#L16)：

```powershell
$ConflictMode = 'keep-both'  # keep-both | newer | a-wins | b-wins
```

- **keep-both**：两端都保留，败方改名为 `.conflict1`（推荐）
- **newer**：保留修改时间更新的版本
- **a-wins**：服务器 A 覆盖 B
- **b-wins**：服务器 B 覆盖 A

### 常见问题

**1. 同步失败 (exit code 7)**

```powershell
# 查看详细日志
cat D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log

# 如果状态损坏，重新初始化
.\test-resync.ps1
```

**2. 服务器 A 不可达**

脚本已自动处理：不可达时跳过，下次自动恢复。检查 Tailscale：

```powershell
tailscale status
```

**3. 手动触发同步**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1
```

## 9. 文件清单

| 文件 | 说明 |
|------|------|
| [deploy.ps1](deploy.ps1) | 一键部署脚本 |
| [sync.ps1](sync.ps1) | 主同步脚本（定时任务执行） |
| [test-resync.ps1](test-resync.ps1) | 重新初始化测试脚本 |
| [README.md](README.md) | 完整使用文档 |
| [sync-plan.md](sync-plan.md) | 本技术方案 |
| `bin\rclone.exe` | rclone v1.75.1 |
| `logs\` | 日志目录 |
| `C:\Users\lvhaitao\AppData\Roaming\rclone\rclone.conf` | rclone 配置 |
| `C:\Users\lvhaitao\AppData\Local\rclone\bisync\` | bisync 状态（勿删） |

## 10. 后续可选项

- **告警**：sync.ps1 失败分支接入邮件 / Server酱 / 企业微信 webhook。
- **实时化**：若以后要求秒级同步，迁移到 Syncthing 三节点方案（本机需留出存储空间），或 A 上 inotify + 触发式 bisync。
- **多目录**：把 sync.ps1 参数化，多个目录对串行执行（仍保证同一目录对不并发）。
