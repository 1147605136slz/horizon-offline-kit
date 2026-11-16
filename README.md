# Horizon Offline Kit · 26.3

[下载项目 ZIP](https://github.com/1147605136slz/horizon-offline-kit/archive/refs/heads/main.zip) · [使用步骤](#快速开始) · [测试记录](VALIDATION.md)

Windows 上的 Horizon 26.3 本地单机资源准备与启动脚本。把「下载依赖 → 校验文件 → 准备资源 → 启动游戏」整理成一个可复现的小项目。

适合在启动器登录页面卡住、想研究 Horizon 本地单机入口的用户。Horizon 客户端自带不传入 `--session-file` 的启动方式，本项目使用这个入口。它不生成微软账号身份，不修改认证代码，也不包含 Horizon 或 Minecraft 的游戏文件。

## 快速开始

### 1. 安装前置软件

- Windows 10/11，系统自带的 Windows PowerShell 5.1 即可。也可使用 PowerShell 7。
- 从 [Horizon 官网](https://playhorizon.dev) 安装 Horizon。已验证的版本是 `nightly-2026-11-13-9f42064`，其游戏版本为 26.3。
- 安装 Java 25，记下包含 `bin/java.exe` 的 Java 根目录。
- 系统中需要 `curl.exe`，脚本使用其并行下载功能。

下载本仓库 ZIP 并解压，或：

```powershell
git clone https://github.com/1147605136slz/horizon-offline-kit.git
cd horizon-offline-kit
```

### 2. 准备资源

在 PowerShell 中执行，替换 Java 路径；如果 Horizon 装在其他位置，也替换版本目录。

```powershell
$hz = "$env:APPDATA\horizon-launcher\versions\nightly-2026-11-13-9f42064"
$java = 'C:\path\to\java-25'

powershell -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Horizon.ps1 -HorizonRoot $hz -JavaHome $java
```

首次运行会从 Mojang 元数据指定的官方地址取得客户端、服务端、库文件与资源对象，逐文件检查大小和 SHA-1，再调用 Horizon 自带的准备器。需要联网及足够的缓存、导出和存档空间。后续运行复用校验通过的缓存，失败文件可重试。

### 3. 启动单机

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Horizon.ps1 -HorizonRoot $hz -PlayerName Steve
```

默认存档目录为当前用户的 `HorizonOffline/game`，日志放在这个目录的 `.horizon-home`。自定义存档目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Horizon.ps1 -HorizonRoot $hz -GameDir 'D:\Games\HorizonSingleplayer' -PlayerName Steve
```

脚本不会修改启动器账户数据。通过启动脚本打开的游戏与启动器中其他存档的关系由 `-GameDir` 决定。

## 参数

| 脚本 | 参数 | 用途 |
| --- | --- | --- |
| Prepare-Horizon | `-HorizonRoot` | 已安装的 Horizon 版本目录，必填 |
| Prepare-Horizon | `-JavaHome` | Java 25 根目录，必填 |
| Prepare-Horizon | `-CacheDir` | 下载缓存目录，默认项目下 `cache` |
| Prepare-Horizon | `-Parallel` | curl 并发数，默认 12 |
| Prepare-Horizon | `-VerifyOnly` | 只检查已有缓存，离线运行，不调用准备器 |
| Start-Horizon | `-HorizonRoot` | 已安装的 Horizon 版本目录，必填 |
| Start-Horizon | `-GameDir` | 存档和用户配置目录 |
| Start-Horizon | `-PlayerName` | 本地启动时传给客户端的玩家名 |
| Start-Horizon | `-SmokeFrames 30` | 运行 30 帧后退出并检查测试报告 |

```powershell
# 缓存完整性检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Horizon.ps1 -HorizonRoot $hz -JavaHome $java -VerifyOnly

# 图形启动测试，仍需可用的桌面和 GPU
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Horizon.ps1 -HorizonRoot $hz -SmokeFrames 30
```

## 原理与验证范围

Horizon 是对 Minecraft Java Edition 的 Rust 重实现。`horizon-prepare.exe` 从固定版本的游戏文件生成 `horizon-resources.json` 等资源；`horizon-client.exe --resources <目录>` 加载它们。这个版本的客户端在本地单机启动时可以省略 `--session-file`。

原始手动流程已验证：114 个 Java 库下载完成，5,149 个资源对象存在且大小匹配，完整准备和 `--check` 退出码为 0，最终图形 smoke test 渲染 30 帧且 `error: null`，实际单机游玩与 MCP 游戏内聊天也已观察到。原流程只对四个核心文件计算了 SHA-1；本项目新增的脚本对缓存中的每个下载对象都核对 SHA-1。项目脚本自己的运行验证见 [VALIDATION.md](VALIDATION.md)。

`horizon-prepare --check` 检查资源是否存在、版本是否匹配；它本身不逐文件核对内容。成功进入单机不代表取得在线账号身份，在线账号服务及服务器的身份验证仍各自独立。

本项目固定 26.3，不承诺适用于其他版本。请保持 Horizon 准备器、客户端及游戏元数据版本一致。

## 排错

| 现象 | 处理 |
| --- | --- |
| 下载 ZIP 后脚本被系统阻止 | 解压到自己的目录，并使用上方 `-ExecutionPolicy Bypass` 命令仅对本次进程运行脚本 |
| 找不到准备器、客户端或版本锁文件 | `-HorizonRoot` 应指向具体版本目录，先完成 Horizon 安装 |
| Java 版本不符 | `-JavaHome` 指向 Java 25 的根目录 |
| curl 下载或哈希检查失败 | 检查网络后重新运行；脚本保留通过校验的缓存 |
| 缺少 `horizon-resources.json` | 先完成准备步骤 |
| `--check` 发现缺项 | 重新运行准备脚本，检查 Horizon 与游戏版本是否一致 |
| 图形测试失败或窗口闪退 | 查看 `-GameDir` 下 `.horizon-home` 的报告和日志，检查显卡驱动 |

## 过程记录

完整手动操作记录：[WALKTHROUGH.md](WALKTHROUGH.md)。原文也保留在 [MyFirstRepository](https://github.com/1147605136slz/MyFirstRepository/blob/main/docs/horizon-26.3-offline.md)。

本仓库只分发脚本与说明，缓存、游戏 JAR、导出资源和存档均不加入版本控制。Minecraft 与 Horizon 的名称及游戏文件分别属于其各自权利人；本项目与其没有隶属关系。
