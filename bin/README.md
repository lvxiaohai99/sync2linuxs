# rclone 工具

本目录需要放置 Windows 版 `rclone.exe`，**不纳入 Git**（体积约 80MB+）。

## 下载安装

1. 打开官方发布页：https://rclone.org/downloads/
2. 下载 **Windows - amd64** 的 zip
3. 解压后将 `rclone.exe` 放到本目录（与本 README 同级）

或在 PowerShell 中（需能访问网络）：

```powershell
cd $PSScriptRoot   # 即本 bin 目录，或手动 cd 到项目\bin
$ver = 'v1.75.1'   # 可按需改版本号
$url = "https://downloads.rclone.org/$ver/rclone-$ver-windows-amd64.zip"
$zip = Join-Path $env:TEMP 'rclone.zip'
Invoke-WebRequest -Uri $url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $env:TEMP -Force
Copy-Item (Join-Path $env:TEMP "rclone-$ver-windows-amd64\rclone.exe") -Destination .\rclone.exe -Force
.\rclone.exe version
```

下载完成后，回到项目根目录执行 `.\deploy.ps1` 即可部署。
