# 项目脚本验证记录

测试日期：2026-11-16。环境：Windows、Windows PowerShell 5.1.26100.9818、Java 25.0.1、Horizon `nightly-2026-11-13-9f42064`、Minecraft 26.3。测试使用已安装的 Horizon；不涉及重新安装 Horizon。

## 已执行并通过

1. **语法与输入检查**：两个 PowerShell 脚本均通过系统 PowerShell 解析器。准备脚本的离线函数检查覆盖有效下载描述、目录穿越及异常 URL；`VerifyOnly` 遇到缺失缓存报错且不创建缓存目录。
2. **全部缓存校验**：把原始下载文件复制到项目规定的缓存布局，实际执行 `Prepare-Horizon.ps1 -VerifyOnly`，退出码为 0，输出 `Verified 5267 cached resources for Minecraft 26.3; no network or preparation performed.`。这次实际逐文件计算 SHA-1，覆盖 114 个库、5,149 个资源对象、客户端、服务端、版本元数据和资源索引。
3. **真实下载补全与完整准备**：暂时移出缓存中的版本元数据、资源索引、一个库和一个资源对象，然后运行正常准备模式。这四个文件从官方源重新下载并通过校验；库和资源对象进入同一 curl 并行批次。已有的其他文件复用缓存。准备脚本随后执行 `--prepare --complete` 和 `--check`，退出码为 0，输出 `Prepared and checked Minecraft 26.3 resources ... (5267 cached inputs).`。
4. **图形启动测试**：实际执行 `Start-Horizon.ps1 -SmokeFrames 30`，退出码为 0。报告为 `frames: 30`、`error: null`、`chunks: 0`、`player: null`。因此这是客户端窗口与菜单渲染测试，未把这次 30 帧测试表述为进入世界。加载日志确认音频输出与 Vulkan 渲染器成功初始化。

准备日志同时确认全景图 7 个、字体 5 个、内置包 2 个、语言 145 个、音效 4,962 个（约 377.3 MB）已准备。

## 测试发现与修复

Windows PowerShell 5.1 会把 `java -version` 的标准错误流包装成 ErrorRecord，尽管 Java 实际退出码为 0。准备脚本在读取版本输出时临时允许正常的 stderr，仍独立检查 Java 退出码及 25 的版本号，随后恢复错误处理设置。修复后的实际运行已通过。

## 验证范围

- 本项目测试复用了已有的完整下载缓存，未再从空缓存下载全部 5,267 个文件；实际下载覆盖上述四个文件和并行批次。
- 这次下载均成功，因此重试分支与断网恢复尚未通过实际故障注入测试。
- 完整准备复用了 Horizon 已导入的固定版本游戏文件；首次全新安装的导出过程见原始手动记录，不将其算成本轮脚本的全新安装测试。
- 原始手动流程中已观察到世界游玩及 MCP 游戏内聊天，记录于 [WALKTHROUGH.md](WALKTHROUGH.md)。项目脚本的图形测试范围以上述报告为准。
- 未测试其他 Horizon 版本、Minecraft 版本、操作系统、PowerShell 7 或在线服务器身份验证。
