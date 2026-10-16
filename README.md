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
4. 创建 Windows 定时任务（默认每 15 分钟）
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
- **执行间隔：** 每 15 分钟
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

**修改执行间隔：**

```powershell
# 改为每 30 分钟
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
Set-ScheduledTask -TaskName "RcloneBisync-ServerA-ServerB" -Trigger $trigger
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

### 1. 同步失败：exit code 7

**原因：**
- 网络中断
- 触发了 `--max-delete` 保护（单次要删除超过 25% 的文件）
- bisync 状态文件损坏

**解决方法：**

```powershell
# 查看详细错误
Get-Content .\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log

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

### 4. 想要实时同步（而不是每 15 分钟）

**方案：**
- 方案 1：修改定时任务间隔为 1 分钟
- 方案 2：使用 Syncthing（需要在两台服务器和本机都安装）

```powershell
# 修改为每 1 分钟
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
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

---

## 文件说明

### 核心文件

| 文件 | 说明 |
|------|------|
| [deploy.ps1](deploy.ps1) | 一键部署脚本，完成所有初始化配置 |
| [sync.ps1](sync.ps1) | 主同步脚本，由定时任务每 15 分钟执行一次 |
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
| 冲突策略默认 `newer` | 依赖两端时间准确；更稳妥可改 `keep-both` |

---

**版本：** 1.1  
**最后更新：** 2026-10-16
