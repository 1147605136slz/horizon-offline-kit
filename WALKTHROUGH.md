# Horizon 26.3 离线启动实录：从缺资源到可玩的单机世界

> 记录时间：2026-11-16。平台：Windows，Horizon `nightly-2026-11-13-9f42064`，Minecraft Java Edition `26.3`。
>
> 这里的“破解”是我们当时对“绕开启动器登录、直接进入单机”的口头叫法。实际过程是准备游戏资源并调用 Horizon 自带的客户端入口；没有修改 Horizon 或 Minecraft 的二进制文件，没有制作补丁、序列号，也没有取得微软会话。下面记录实际做过和验证过的步骤。

## 结果先看

- 用 `horizon-client.exe --resources ... --name Steve` 在**没有 `--session-file`** 的情况下进入单机世界；最初的核心资源测试渲染 60 帧、退出码为 0。
- 补齐音效等资源后，`horizon-prepare.exe --check` 退出码为 0；最终再次无会话启动并渲染 30 帧，`smoke-report` 中 `error: null`、`frames: 30`。
- 用户随后在实际游戏里截到了 26.3/Horizon 的 F3 画面，并通过 Horizon 的 MCP 控制接口读取了角色状态、发送了一条游戏内聊天。后者是额外的连通性验证，与离线启动本身无关。

**边界**：这是 Horizon 的本地单机启动记录。它不证明在线服务器、微软账号服务或多人联机的账号验证也被绕过。Horizon 版本和准备器绑定 26.3，升级后要重新检查资源。

## 1. 定位启动入口与依赖

查看已安装版本目录里的 `PLAY.txt`、`research-lock.json` 及命令帮助后，找到两个关键入口：

- `horizon-prepare.exe --prepare`：从 Minecraft 26.3 客户端、服务端、版本元数据、Java 库及运行时生成 Horizon 专用资源。
- `horizon-client.exe --resources <目录>`：直接加载准备好的资源；本地单机启动没有要求 `--session-file`。这一点以实际运行结果为准。

直接运行客户端的第一次尝试报错：`Horizon's prepared game files are missing: no horizon-resources.json`。因此先解决资源准备，而不是改启动器的账号记录。

## 2. 取得固定版本的游戏文件

从 Mojang 的 26.3 版本元数据确认客户端、服务端、资源索引与 114 个 Maven 库的下载信息。此轮使用的直链是：

| 文件 | 来源 |
| --- | --- |
| 26.3 版本元数据 | `https://piston-meta.mojang.com/v1/packages/9f67e10ed013deeaad20ac3c800652765d493408/26.3.json` |
| 客户端 JAR | `https://piston-data.mojang.com/v1/objects/e877b6a07acd633fb3bb475002175cec036e7b87/client.jar` |
| 服务端 JAR | `https://piston-data.mojang.com/v1/objects/33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c/server.jar` |
| 资源索引 34.json | `https://piston-meta.mojang.com/v1/packages/e99f9973047785b5a9d52eaf72020b97545053c9/34.json` |

本机四个文件的 SHA-1 实测分别为 `9f67e10ed013deeaad20ac3c800652765d493408`、`e877b6a07acd633fb3bb475002175cec036e7b87`、`33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c`、`e99f9973047785b5a9d52eaf72020b97545053c9`，与元数据和 Horizon 的 `research-lock.json` 中接受的版本相符。运行时使用的是 Java 25。

版本元数据中的 114 个 `libraries[].downloads.artifact` 按各自的 `path` 放进同一个 Maven 目录。实际使用 Ghost Downloader 的 `ghd add <URL> -o <artifact 所在目录>` 创建任务、`ghd wait <任务 ID...>` 等待；初次缺了 `lwjgl-vulkan-3.4.3.jar`，补下后核对目录中有 114 个 JAR。先前 `horizon-prepare` 曾因缺 `lz4-java-1.10.1.jar` 中止，也按相同方式补齐。

## 3. 先准备核心资源并验证启动

以下命令按本机目录结构写成 PowerShell 模板；先将变量改为自己的实际路径。`$javaHome` 指 Java 25 **根目录**，不是 `bin\java.exe`。

```powershell
$hz       = 'C:\path\to\horizon-launcher\versions\nightly-2026-11-13-9f42064'
$client   = 'D:\path\to\client.jar'
$server   = 'D:\path\to\server.jar'
$meta     = 'D:\path\to\26.3.json'
$libs     = 'D:\path\to\libraries'   # Maven 目录结构
$assets   = 'D:\path\to\assets'      # indexes\34.json 和 objects\<前两位>\<SHA1>
$javaHome = 'C:\path\to\java-25'
$out      = Join-Path $hz '.local\horizon-client\26.3'

& "$hz\horizon-prepare.exe" --prepare `
  --client-jar $client --server-jar $server --version-json $meta `
  --libraries-dir $libs --java-home $javaHome `
  --root $hz --output $out --progress json
```

本轮核心资源准备退出码为 0，生成了 `horizon-resources.json`。将资源放进版本目录的 `.local\horizon-client\26.3` 后，直接运行 `horizon-client.exe` 的首次 smoke test 渲染了 60 帧、退出码为 0；日志提示音效尚未复制。因此核心单机已经可玩，但资源还没有补全，不能把此时的 `--check` 失败说成游戏不能启动。

## 4. 补全 34 号资源索引对应的对象

`34.json` 索引有 **5,149 个对象**，声明总字节数 **487,358,754**。每个对象的 URL 和磁盘路径由 SHA-1 推出：

```text
URL:    https://resources.download.minecraft.net/<SHA1 前两位>/<SHA1>
磁盘:   <assets>\objects\<SHA1 前两位>\<SHA1>
索引:   <assets>\indexes\34.json
```

曾试用 Ghost Downloader 批量下载这些小文件；它按单文件创建任务并额外生成带 MIME 后缀的文件名，逐组等待的吞吐量不适合 5,149 个对象。于是停止那批尝试，预先建立 256 个前缀目录，按 `34.json` 生成 curl 配置，用 `curl.exe --parallel --parallel-max 20 --retry 4` 并发下载到**不带扩展名的 SHA-1 文件名**。第一次请求退出码为 56，按缺失或大小不符的清单重试了 2 个对象。

最终按索引逐项核对：**5,149 / 5,149 个文件存在且字节数一致**，额外文件数为 0。这里的逐项核对是**大小检查**，并没有对 5,149 个对象都重新计算 SHA-1；切勿把它写成“逐个哈希验证”。

之后把 `34.json` 放在 `assets\indexes\34.json`，再执行完整准备：

```powershell
& "$hz\horizon-prepare.exe" --prepare `
  --client-jar $client --server-jar $server --version-json $meta `
  --libraries-dir $libs --assets-dir $assets --java-home $javaHome `
  --root $hz --output $out --complete --progress json

& "$hz\horizon-prepare.exe" --check --root $hz --output $out
$LASTEXITCODE  # 本次实测：0
```

准备日志显示：全景图 7 个文件、字体 5 个、内置包 2 个、语言 145 个、音效 4,962 个（约 377.3 MB）。`--check` 用于检查资源文件及版本是否齐全；根据程序帮助，它**不逐文件校验内容**。

## 5. 用单独的批处理脚本启动

批处理的核心内容如下；把版本名换成自己安装的版本，并根据需要修改名字和存档目录：

```bat
@echo off
set "V=%APPDATA%\horizon-launcher\versions\nightly-2026-11-13-9f42064"
set "RES=%V%\.local\horizon-client\26.3"
set "BASE=%USERPROFILE%\HorizonOffline"
if not exist "%BASE%\game" mkdir "%BASE%\game"
if not exist "%BASE%\home" mkdir "%BASE%\home"
start "" "%V%\horizon-client.exe" --resources "%RES%" --game-dir "%BASE%\game" --home "%BASE%\home" --name "Steve" %*
```

本机创建了桌面快捷方式，指向该批处理文件；最终通过同一资源目录单独做了 30 帧 smoke test，进程退出 0，报告含 `"error": null`、`"frames": 30`，日志里不再有“缺音效”的提示。之后用户的实际游玩截图也确认了世界、界面与渲染均可运行。

## 复盘：哪里出了错，怎么排除

| 现象 | 定位与处理 |
| --- | --- |
| 直接启动提示缺 `horizon-resources.json` | 先运行 `horizon-prepare --prepare`，把准备结果交给 `--resources`。 |
| 准备器报缺 `lz4-java` | 按版本 JSON 的 `downloads.artifact.path` 补齐 Maven 库。 |
| 114 个库初次下载还差 `lwjgl-vulkan` | 单独重试并核对库数量。 |
| 核心准备完成但 `--check` 仍失败 | 缺音效、全景图、字体、语言和内置包；补全 assets 后运行 `--complete`。 |
| 批量资源下载出现 curl 56 错误 | 从索引检查缺失/大小不符对象，仅重试失败项。 |
| Ghost Downloader 处理海量小对象太慢 | 保留其完成的库下载，资源对象改用 curl 并发并按索引核对。 |

**关键认识**：这一轮得到的是 Horizon 自带本地启动链路的可复现用法，游戏数据来自对应的 26.3 文件；“进入单机”与“获得在线账号身份”是两件不同的事。全文仅记录命令、元数据和测试结果，未上传 JAR、资源对象、账户数据或控制端口令牌。
