# 同步排除规则使用指南

## 概述

[.syncignore](.syncignore) 文件类似 `.gitignore`，用于指定哪些文件和目录不需要同步。

## 规则语法

```
# 注释行以 # 开头
build/              # 排除 build 目录
*.o                 # 排除所有 .o 文件
**/build/           # 排除任意深度的 build 目录
temp*.log           # 支持通配符
```

### 通配符说明

- `*` - 匹配任意字符（不包括 `/`）
- `**` - 匹配任意目录层级
- `?` - 匹配单个字符
- `[abc]` - 匹配括号中的任意一个字符

### 示例

| 规则 | 匹配 | 不匹配 |
|------|------|--------|
| `build/` | `build/`, `src/build/` | `builds/` |
| `**/build/` | `a/build/`, `a/b/build/` | `build-test/` |
| `*.o` | `main.o`, `src/test.o` | `main.obj` |
| `temp*` | `temp.log`, `temp123` | `mytemp` |

## 已配置的默认规则

[.syncignore](.syncignore) 已经包含了常见的排除规则：

### 编译产物
- `build/`, `install/` - 构建和安装目录
- `*.o`, `*.so`, `*.dll`, `*.exe` - 二进制文件
- `cmake-build-*/` - CMake 构建目录

### IDE 配置
- `.vscode/`, `.idea/`, `.vs/` - IDE 配置目录
- `*.swp`, `*.swo` - Vim 临时文件

### 临时文件
- `tmp/`, `temp/`, `*.tmp`, `*.log` - 临时文件
- `__pycache__/`, `*.pyc` - Python 缓存

### 版本控制
- `.git/`, `.svn/` - 版本控制目录

### 特定问题 / 巨型仓（务必排除，否则整体同步会扫几百万文件）
- `jgzd_git/iot_vst/` - 板级 SDK（forrepo：buildroot/kernel/chromium/output…）
- `jgzd_git/mt/_thirdparty_measure/` - 第三方 deb/解压包
- `jgzd_git/utils/rk3576-cross-toolchain/` - 已知有符号链接循环的目录
- `**/buildroot/`、`**/prebuilts/`、`**/output/` - SDK/构建输出通用名
- `.cursor/`、`.qoder/` - 本机 AI 工作区状态

**原则：** 日常 bisync 只同步源码/文档/配置；完整 SDK、工具链、编译产物用 git 或单独拷贝。

## 使用方法

### 1. 编辑排除规则

```bash
# 用任意编辑器打开
notepad D:\code_sync\.syncignore
# 或
code D:\code_sync\.syncignore
```

添加你的自定义规则到文件末尾的"自定义规则"部分。

### 2. 验证规则

编辑后，检查会排除多少条规则：

```powershell
# 查看有效规则数量（排除注释和空行）
(Get-Content D:\code_sync\.syncignore | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }).Count
```

### 3. 重新初始化同步

**重要：** 修改 `.syncignore` 后，必须重新初始化 bisync 状态：

```powershell
.\test-resync.ps1
```

这会：
- 清空旧的 bisync 状态
- 使用新的排除规则重新扫描两端目录
- 建立新的基准状态

### 4. 测试同步

```powershell
# 执行一次同步测试
powershell -ExecutionPolicy Bypass -File D:\code_sync\sync.ps1

# 查看日志，确认规则生效
cat D:\code_sync\logs\bisync-$(Get-Date -Format 'yyyyMMdd').log
```

日志中应该看到：

```
[INFO ] 读取排除规则: D:\code_sync\.syncignore
[INFO ] 已加载 XX 条排除规则
```

## 常见场景

### 场景 1: 排除所有 build 目录

```
# 在 .syncignore 中添加
**/build/
**/Build/
**/BUILD/
```

### 场景 2: 排除特定项目的构建产物

```
# 排除特定项目
my-project/build/
my-project/install/
my-project/*.o
```

### 场景 3: 只同步源代码，不同步编译产物

```
# C/C++ 项目
*.o
*.a
*.so
build/
install/
CMakeCache.txt
CMakeFiles/

# 但保留依赖库（注释掉不需要排除的）
# !third_party/
```

**注意：** rclone 不支持 `!` 白名单语法，需要通过精确的排除规则实现。

### 场景 4: 排除大文件

```
# 排除压缩包
*.zip
*.tar
*.tar.gz
*.rar

# 排除二进制数据文件
*.bin
*.dat
*.dump
```

### 场景 5: 同步 .git 但排除其他版本控制

```
# 在 .syncignore 中注释掉 .git 行
# .git/

# 但保留排除 .svn
.svn/
```

## 调试技巧

### 查看当前会排除哪些规则

```powershell
Get-Content D:\code_sync\.syncignore | 
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
    ForEach-Object { Write-Host "排除: $_" }
```

### 测试特定文件是否会被排除

rclone 不提供内置的"测试某个文件是否匹配规则"功能，但你可以：

1. 先执行 `--dry-run` 查看会同步哪些文件：

```powershell
D:\code_sync\bin\rclone.exe sync serverA:sync serverB:sync --dry-run --verbose --exclude-from D:\code_sync\.syncignore
```

2. 搜索日志看特定文件是否出现

```powershell
Select-String -Path D:\code_sync\logs\bisync-*.log -Pattern "你的文件名"
```

### 查看同步了多少文件

查看日志中的统计信息：

```
Checks:             31596 / 31596, 100%, Listed 31598
```

这表示扫描了 31,596 个文件。修改排除规则后，这个数字应该会减少。

## 注意事项

### 1. 修改规则后必须 resync

```powershell
.\test-resync.ps1
```

否则 bisync 状态与新规则不匹配，会导致同步失败。

### 2. 规则是全局的

排除规则对两个服务器都生效。如果某个文件在服务器 A 被排除，那么即使服务器 B 有这个文件，也不会同步到服务器 A。

### 3. 已同步的文件不会自动删除

如果某个文件之前已经同步到两端，后来你添加了排除规则，该文件**不会被自动删除**，只是不再继续同步它的修改。

如需删除，手动在两端删除后再 resync。

### 4. 符号链接

脚本默认使用 `--links` 参数跳过符号链接，避免循环。如果需要同步符号链接，需要：

1. 确保没有循环引用
2. 编辑 [sync.ps1](sync.ps1) 和 [test-resync.ps1](test-resync.ps1)，删除 `--links` 参数

### 5. 路径分隔符

rclone 的排除规则统一使用 `/` 作为路径分隔符，即使在 Windows 上也是如此。

## 性能优化

合理的排除规则可以显著提升同步速度：

| 场景 | 扫描文件数 | 耗时 |
|------|-----------|------|
| 无排除规则（包含大型工具链） | 813,952 | 3分31秒 ❌ |
| 排除 build/install/工具链 | 31,596 | 15.7秒 ✅ |

**建议：**
- 排除所有不需要同步的编译产物
- 排除大型第三方库（如果不需要同步）
- 排除 IDE 配置目录

## 高级用法

### 使用多个排除文件

如果规则很多，可以创建多个排除文件：

```
.syncignore              # 主规则
.syncignore.build        # 构建相关
.syncignore.ide          # IDE 相关
```

然后修改 [sync.ps1](sync.ps1) 读取多个文件（需要手动编辑代码）。

### 按项目配置不同规则

如果同步目录中有多个项目，可以为每个项目指定规则：

```
# 项目 A
project-a/build/
project-a/install/

# 项目 B
project-b/target/
project-b/node_modules/
```

## 参考资料

- [rclone filtering 官方文档](https://rclone.org/filtering/)
- [rclone bisync 文档](https://rclone.org/bisync/)
- [本项目 README](README.md)
