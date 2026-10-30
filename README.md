# sync2linuxs — 双服务器目录同步

通过 Windows 本机作为中转，用 rclone bisync 实现两台无法直连的 Linux 服务器之间的双向目录同步。

**仓库：** https://github.com/lvxiaohai99/sync2linuxs

## 目录

- [系统架构](#系统架构)
- [项目结构](#项目结构)
- [依赖条件](#依赖条件)
- [快速开始](#快速开始)
- [日志管理](#日志管理)
- [定时任务管理](#定时任务管理)
- [冲突处理策略](#冲突处理策略)
- [常见问题](#常见问题)
- [文件说明](#文件说明)
- [已知问题与改进](#已知问题与改进)

---

## 系统架构

```
服务器 A (100.109.141.36)              服务器 B (10.255.10.38)
   ~/sync 目录                            ~/sync 目录
        │                                      │
        │  SFTP/SSH (Tailscale)   SFTP/SSH (内网)
        └──────────────┐    ┌──────────────────┘
                       ▼    ▼
                  本机 Windows 11
            rclone bisync + 计划任务
           （数据流经过，不本地存储）
```

**同步特性：**
- 双向同步：两端修改都会传播到对端
- 冲突保护：可按策略保留双方版本或择优覆盖
- 删除保护：单次删除超过 25% 文件时自动中止
- 网络容错：任一端不可达时跳过本次，网络恢复后继续
- 完整日志：每次同步都有详细记录
- 排除规则：通过 `.syncignore` 跳过编译产物等大文件

---

## 项目结构

```
sync2linuxs/
├── deploy.ps1          # 一键部署（需管理员）
├── sync.ps1            # 日常双向同步（定时任务调用）
├── sync-force.ps1      # 删除保护触发后，手动确认再强制同步
├── test-resync.ps1     # 清空状态并强制 --resync
├── .syncignore         # 同步排除规则（类似 .gitignore）
├── .gitignore          # Git 忽略：logs、rclone.exe 等
├── bin/
│   ├── README.md       # 如何下载 rclone.exe
│   └── rclone.exe      # 本地放置，不提交到 Git
├── logs/               # 运行日志（不提交）
├── README.md           # 本说明书
├── SYNCIGNORE.md       # 排除规则说明
├── TESTING.md          # 测试指南
└── sync-plan.md        # 技术方案设计
```

脚本路径均基于 `$PSScriptRoot`（脚本所在目录），克隆到任意盘符即可使用。

---

## 依赖条件

### 1. SSH 免密登录配置

在 `deploy.ps1` 顶部修改服务器地址、用户名和密钥路径。默认示例：

```
服务器 A：Tailscale IP + 对应私钥
服务器 B：内网 IP + 对应私钥
```

**验证方法（按你实际配置改用户和 IP）：**

```bash
ssh -i <密钥A> <用户A>@<主机A> "echo 连接成功"
ssh -i <密钥B> <用户B>@<主机B> "echo 连接成功"
```

### 2. 服务器上的同步目录

两台服务器上都需要存在 `~/sync` 目录（部署脚本也会自动创建）。

### 3. 网络要求

- 本机可 SSH 到服务器 A、服务器 B（示例里 A 走 Tailscale，B 走内网）
- 两台服务器系统时间差建议不超过 1 分钟（NTP）

### 4. rclone 工具

从仓库克隆后，按 [bin/README.md](bin/README.md) 下载 `rclone.exe` 放到 `bin\` 目录。

---

## 快速开始

### 0. 获取代码并准备 rclone

```powershell
git clone https://github.com/lvxiaohai99/sync2linuxs.git
cd sync2linuxs
# 按 bin\README.md 下载 rclone.exe 到 bin\
```

### 1. 修改配置

编辑 `deploy.ps1` 顶部的 `$ServerA` / `$ServerB`（主机、用户、密钥路径），以及 `sync.ps1` 里的冲突策略等参数。

### 2. 一键部署

以**管理员身份**打开 PowerShell，在项目根目录执行：

```powershell
.\deploy.ps1
```

部署脚本会自动完成：
1. 检查依赖（SSH、同步目录、rclone）
2. 写入 rclone SFTP 配置
3. 首次 `--resync` 建立基准
4. 创建 Windows 定时任务（默认每天 09:20、18:00）
5. 打印后续操作说明

### 3. 手动测试同步

```powershell
powershell -ExecutionPolicy Bypass -File .\sync.ps1
Get-Content .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log
```

---

## 日志管理

### 日志存放位置

```
logs/
├── bisync-yyyyMMdd.log          # 日常同步日志（按日期命名）
├── resync-test-*.log            # 测试日志
└── deploy-*.log                 # 部署日志
```

### 查看同步记录

在项目根目录执行：

```powershell
# 查看完整日志
Get-Content .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log

# 只看关键信息（成功/失败/冲突）
Select-String -Path ".\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log" -Pattern "INFO |ERROR|WARN|successful|failed|conflict"
```

**查看最近 5 次同步的状态：**

```powershell
Get-ChildItem .\logs\bisync-*.log |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 |
    ForEach-Object {
        Write-Host "`n=== $($_.Name) ===" -ForegroundColor Cyan
        Select-String -Path $_.FullName -Pattern "同步完成|同步失败|同步中止" | Select-Object -Last 1
    }
```

**监控实时同步（类似 tail -f）：**

```powershell
Get-Content .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 20
```

### 日志清理

```powershell
# 删除 30 天前的日志
Get-ChildItem .\logs\*.log |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Verbose
```

---

## 定时任务管理

### 任务信息

- **任务名称：** `RcloneBisync-ServerA-ServerB`
- **执行时间：** 每天 **09:20**、**18:00**（各一次）
- **执行脚本：** 项目根目录下的 `sync.ps1`
- **权限级别：** 最高权限（Highest）
- **超时时间：** 30 分钟

### 查看任务状态

```powershell
# 查看任务详情
Get-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" | Format-List *

# 查看最近运行记录
Get-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" | Get-ScheduledTaskInfo
```

### 管理定时任务

**启用任务：**

```powershell
Enable-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
```

**禁用任务：**

```powershell
Disable-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
```

**立即执行一次：**

```powershell
Start-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
```

**删除任务：**

```powershell
Unregister-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Confirm:$false
```

**修改执行时间：**

```powershell
# 示例：改回每天 09:20 和 18:00
$t1 = New-ScheduledTaskTrigger -Daily -At '09:20'; $t1.Enabled = $true
$t2 = New-ScheduledTaskTrigger -Daily -At '18:00'; $t2.Enabled = $true
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger @($t1, $t2)
```

### 打开任务计划程序图形界面

```powershell
taskschd.msc
```

在任务计划程序中，找到 `RcloneBisync-ServerA-ServerB` 任务：
- 位置：任务计划程序库 → 根目录
- 可以查看运行历史、修改触发器、查看详细属性

---

## 冲突处理策略

在 [sync.ps1](sync.ps1:16) 中可以配置冲突处理模式：

```powershell
$ConflictMode = 'keep-both'  # 修改这一行
```

### 可选策略

| 策略值 | 行为 | 适用场景 |
|--------|------|----------|
| **keep-both** | 两端都保留，败方文件改名为 `xxx.conflict1` | **推荐**，不丢数据，手动合并 |
| **newer** | 保留修改时间更新的版本 | 相信时间戳，服务器时间必须准确 |
| **a-wins** | 一律以服务器 A 为准覆盖 B | 服务器 A 是权威来源 |
| **b-wins** | 一律以服务器 B 为准覆盖 A | 服务器 B 是权威来源 |

### 冲突文件示例

如果两端同时修改了 `test.txt`，在 `keep-both` 模式下会产生：

```
服务器 A:
  test.txt           (服务器 A 的版本，保留)

服务器 B:
  test.txt           (服务器 A 的版本，同步过来)
  test.txt.conflict1 (服务器 B 原来的版本，自动改名)
```

手动检查冲突文件后，决定保留哪个版本，然后删除不需要的。

---

## 常见问题

### 1. 同步失败 / 中止：too many deletes（删除保护）

**原因：** 单次同步要删除的文件超过 `--max-delete`（默认 25%）。这是防误删保险丝，**不会真的删文件**。  
日常 `sync.ps1` / 定时任务**不会**自动加 `--force`；触发时终端会打印黄色提示框和下面这条命令。

**若确认就是要大删、另一端也要跟上：**

```powershell
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync-force.ps1
```

按提示输入 `YES` 后，会带 `--force` 再同步一次。

| 你的真实意图 | 做法 |
|-------------|------|
| 故意大删，另一端跟上 | 运行上面的 `sync-force.ps1`，输入 `YES` |
| 误删了，另一端还有 | **不要**跑 force；先从正确端拷回 |
| 只是改了排除规则 | 执行 `.\test-resync.ps1` |

```powershell
# 查看是否触发了删除保护
Select-String -Path .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log -Pattern "too many deletes|Safety abort"
```

### 1b. 同步失败：exit code 7

**原因：**
- 网络中断
- bisync 状态文件损坏

**解决方法：**

```powershell
# 查看详细错误
Get-Content .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log -Tail 50

# 如果是状态文件损坏，重新初始化
.\test-resync.ps1
```

### 2. 服务器 A 经常不可达

**原因：** Tailscale 连接不稳定

**解决方法：**
- 检查 Tailscale 是否在运行：`tailscale status`
- 脚本已经自动处理：不可达时跳过本次同步，等待下次

### 3. 同步后文件时间戳变了

**原因：** rclone 通过 SFTP 传输时保留修改时间，但 SSH 服务器配置可能影响

**解决方法：**
- 这是正常的，bisync 依赖修改时间判断是否需要同步
- 确保两台服务器时间同步（NTP）

### 4. 想改同步频率（默认每天两次）

**方案：**
- 方案 1：改计划任务触发时间（见上方「修改执行时间」）
- 方案 2：需要更频繁时可用短间隔重复触发；要近实时可用 Syncthing

```powershell
# 示例：临时改为每 30 分钟（测试完建议改回每天 09:20 / 18:00）
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger $trigger
```

### 5. 如何手动触发一次同步

```powershell
# 方法 1：直接运行脚本
powershell -ExecutionPolicy Bypass -File .\sync.ps1

# 方法 2：通过任务计划程序
Start-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB"
```

### 6. 同步很慢

**优化建议：**
1. 检查网络连接速度（特别是 Tailscale）
2. 同步目录中避免放置大量小文件；用 `.syncignore` 排除 `build/` 等
3. 修改 `sync.ps1` 里 rclone 的 `--timeout` / `--retries` 参数

### 7. 误删了很多文件，如何恢复

**防护机制：** 脚本已经配置了 `--max-delete 25`，单次删除超过 25% 会自动中止

**恢复方法：**
- 如果还没触发同步，立即禁用定时任务
- 从另一台服务器手动复制文件回来
- 检查 rclone 的 bisync 状态文件（可能有历史记录）

### 8. 日志里 Transferred 0 B，但 Checks/Listed 上百万、跑十几分钟

**多数情况仍正常卡在「扫目录」阶段**：还没开始传文件，所以是 `0 B`。  
但若 **Listed 达到几百万**（以前通常只有几万），就不正常了——多半扫进了不该同步的巨型树。

**2026-10-30 实例：** `jgzd_git/iot_vst/forrepo/`（含 buildroot、kernel、chromium 等）把 Path2 列表撑到约 **840MB**，同步会极慢。已在 `.syncignore` 排除该目录。

处理：改完忽略规则后执行一次 `.\test-resync.ps1`（或等脚本因无成功状态自动 `--resync`），不要让定时任务继续硬扛几百万文件。

### 9. 日志写「首次运行 / --resync」，但我已经同步很多天了

**原因：** 不是真的第一次。`sync.ps1` 靠本机状态文件判断：

`C:\Users\<你>\AppData\Local\rclone\bisync\*.path1.lst`

上次若出现 **致命错误**（例如 SFTP 重命名 `.clangd.*.partial` 失败），rclone 会把状态改成 `*.lst-err`，并要求必须 `--resync` 才能恢复。此时没有成功的 `*.path1.lst`，脚本就会自动带 `--resync`——以前文案误写成「首次运行」。

**处理：**
1. 已排除 `.clangd` / `*.partial`，减少这类失败
2. 让下一次带 `--resync` 的同步跑成功即可；成功后会重新生成 `*.path1.lst`，之后恢复日常增量同步
3. 若反复因同一文件失败，先在两端删掉残留的 `*.partial`，再跑一次同步

### 10. 同步失败：prior lock file found

**原因：** 上次 rclone bisync 被强制结束或崩溃，留下了 `.lck` 锁文件，后续同步会立刻失败。

**解决方法：**
1. 优先直接再跑一次 `.\sync.ps1`（脚本会自动识别僵死锁并清除）
2. 若仍报错，可手动删除锁文件后重试：

```powershell
Remove-Item -Force "$env:LOCALAPPDATA\rclone\bisync\serverA_sync..serverB_sync.lck"
powershell -ExecutionPolicy Bypass -File .\sync.ps1
```

注意：只有确认没有其他同步正在跑时才能删锁。

---

## 文件说明

### 核心文件

| 文件 | 说明 |
|------|------|
| [deploy.ps1](deploy.ps1) | 一键部署脚本，完成所有初始化配置 |
| [sync.ps1](sync.ps1) | 主同步脚本，由定时任务每天 09:20 / 18:00 执行 |
| [sync-force.ps1](sync-force.ps1) | 删除保护触发后，确认再强制同步一次（手动） |
| [test-resync.ps1](test-resync.ps1) | 测试脚本，清空状态重新 resync |
| [README.md](README.md) | 本文档 |
| [sync-plan.md](sync-plan.md) | 技术方案设计文档 |

### 配置文件

| 文件 | 说明 |
|------|------|
| `C:\Users\lvhaitao\AppData\Roaming\rclone\rclone.conf` | rclone 的 SFTP 连接配置 |
| `C:\Users\lvhaitao\.ssh\config` | SSH 连接配置（已有） |
| `C:\Users\lvhaitao\AppData\Local\rclone\bisync\` | rclone bisync 状态目录（不要手动删除） |

### 工具

| 文件 | 说明 |
|------|------|
| [bin\rclone.exe](bin/rclone.exe) | rclone v1.75.1 Windows 版本 |

---

## 调整同步参数

如需修改同步行为，编辑 [sync.ps1](sync.ps1) 的配置区（第 15-23 行）：

```powershell
$ConflictMode   = 'keep-both'          # 冲突策略
$RcloneExe      = Join-Path $PSScriptRoot 'bin\rclone.exe'
$PathA          = 'serverA:sync'       # 服务器A的同步路径
$PathB          = 'serverB:sync'       # 服务器B的同步路径
$LogDir         = Join-Path $PSScriptRoot 'logs'
$MaxDeletePct   = 25                   # 删除保护阈值（百分比）
$ConnectTimeout = 10                   # 网络检测超时（秒）
```

修改后无需重启定时任务，下次执行时自动生效。

---

## 支持与反馈

如遇到问题：
1. 查看日志：`.\logs\bisync-*.log`
2. 查看本文档的[常见问题](#常见问题)
3. 查看 [sync-plan.md](sync-plan.md) 了解原理

---

## 已知问题与改进

| 现状 | 说明 / 后续可改进 |
|------|-------------------|
| 服务器地址写在脚本里 | 可抽到 `config.ps1` 或环境变量，避免改代码 |
| 密钥路径本机相关 | 部署前必须按本机改 `deploy.ps1` |
| rclone 不进仓库 | 克隆后需按 `bin/README.md` 下载 |
| 仅 Windows 中转 | 依赖本机在线与任务计划；本机关机则暂停同步 |
| 冲突策略可配置 | 当前默认见 `sync.ps1` 的 `$ConflictMode`；两端时钟不准时更稳妥用 `keep-both` |
| 僵死锁已自动清理 | `sync.ps1` 会检查 `.lck` 对应 PID，进程已退出则删除锁；仍失败见 FAQ §8 |
| `.syncignore` 行内注释 | 已支持剥离规则后方的 `# 注释`，避免传给 rclone |

---

**版本：** 1.8  
**最后更新：** 2026-10-30
