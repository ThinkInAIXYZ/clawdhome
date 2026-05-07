# ClawdHome

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://clawdhome.app)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/github/license/ThinkInAIXYZ/clawdhome)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ThinkInAIXYZ/clawdhome)](https://github.com/ThinkInAIXYZ/clawdhome/releases)

[English](README.md) | 中文

> macOS 上的多 Agent 安全管控台 —— 让一台 Mac 安全地养一支 AI Agent 团队。

ClawdHome 让你在一台 Mac 上同时运行多个独立的 AI Agent 实例（支持 OpenClaw 和 Hermes Agent 双引擎），每个实例拥有独立的 macOS 用户账号、运行时、数据和权限边界。一个统一的 SwiftUI 控制面板配合特权 XPC helper daemon，覆盖 Agent 的初始化、监控、备份、模型配置和 IM 渠道接入，从启动到运维不需要手写脚本。

官网：[clawdhome.app](https://clawdhome.app)  
下载：[GitHub Releases](https://github.com/ThinkInAIXYZ/clawdhome/releases)  
更新记录：[中文](CHANGELOG.zh.md) | [English](CHANGELOG.en.md)

## 社区群

<table>
  <tr>
    <td align="center">
      <img src="docs/assets/readme/feishu-group.png" alt="飞书群二维码" width="220" />
      <br />
      飞书群
    </td>
    <td align="center">
      <img src="docs/assets/readme/wechat-group.png" alt="微信群二维码" width="220" />
      <br />
      微信群
    </td>
  </tr>
</table>

## 界面预览

<table>
  <tr>
    <td><img src="docs/assets/readme/github-dashboard.png" alt="Dashboard" /></td>
    <td><img src="docs/assets/readme/github-claw-pool.png" alt="Claw Pool" /></td>
  </tr>
  <tr>
    <td><img src="docs/assets/readme/github-role-center.png" alt="Role Center" /></td>
    <td><img src="docs/assets/readme/github-role-awaken.png" alt="Role Awaken" /></td>
  </tr>
</table>

## 为什么是 ClawdHome

市场上多 Agent 管理方案要么太轻（Chrome 多 Profile 共享同一个系统账号，密钥和 Cookie 互相能读），要么太重（虚拟机 / Docker 跑不动 macOS 桌面应用）。ClawdHome 占据的是一个当前明显缺位的象限：**强隔离 + 低运维**。

- **真隔离，不是应用层假装**：每只 Shrimp 是独立 macOS 用户，进程、文件、Keychain、网络走系统内核强制边界。一个 Agent 被攻陷，其他 Agent 的密钥和 Cookie 物理读不到。
- **更安全的特权模型**：UI 永远不直接执行特权操作；所有系统级动作经过显式 XPC helper（LaunchDaemon），调用链可审计、可限权。
- **双引擎并存**：同一台 Mac 可以同时运行 OpenClaw 和 Hermes Agent，每套引擎独立配置，共享 API Key 管理和备份系统。
- **运维入口统一**：初始化向导、网关生命周期、文件管理、诊断、配置热加载、备份恢复和 Cron 任务都在一个面板里处理，不用写脚本，不用配 launchd。
- **本地为先，合规友好**：所有核心功能离线可用，数据不强制出境，适合有数据主权要求的场景。

## 核心亮点

- **双引擎多 Agent**：同一面板管理 OpenClaw + Hermes Agent，单 Shrimp 内支持多 Agent，每个 Agent 独立身份、模型和 IM 绑定。
- **角色市场 / Skills 商店**：一键从角色市场召唤预设 Agent 团队，通过 Skills 商店扩展能力，无需从零配置。
- **13+ IM 渠道开箱即用**：微信、飞书、Telegram、Slack、企微、钉钉、WhatsApp、邮箱等，扫码或填表单即可配对，渠道目录统一维护。
- **运维一体面板**：健康监控、watchdog 自动恢复、维护终端、集成诊断中心（环境/权限/配置/安全/Gateway/网络六大模块）。
- **分层备份与恢复**：支持单 Shrimp 或全局备份，可恢复到任意时间点。
- **模型与 Provider 集中管理**：集中存储 API Key（Keychain 隔离），一键应用模型方案，支持自定义 Provider 和本地模型服务。
- **中英文双语本地化**：基于 `Stable.xcstrings`，界面语言随系统切换。

## 适合谁

**AI 工作室 / 独立创业者**：在一台 Mac 上同时服务多个客户，每个客户的 Agent 物理隔离，互不污染。watchdog 24×7 守护，备份有据可查，客户要演示直接打开面板。

**企业 IT / 合规团队**：本地全闭环部署，数据不出境，Gateway 日志和配置变更可追溯，适合金融、医疗、法律等对数据主权和审计有要求的场景。

**独立开发者 / 技术博主**：克隆现有 Shrimp 创建实验沙盒，测完直接删，不污染主环境。直播演示时用独立 Shrimp，不会暴露自己的 API Key。

## 架构概览

```text
ClawdHome.app（SwiftUI 管理界面）
  -> XPC -> ClawdHomeHelper（特权 LaunchDaemon）
      -> 按用户隔离的 OpenClaw / Hermes Agent 实例
```

- `ClawdHome.app` 是面向操作者的控制平面，负责状态展示、初始化和日常运维。
- `ClawdHomeHelper` 是特权边界，负责用户管理、进程控制、文件操作、安装和系统级自动化。
- 每只 Shrimp 作为独立 macOS 用户运行，拥有独立的 Agent 运行时与数据目录。

## 安全模型

- 特权操作集中在 helper 边界内，UI 层不执行任何系统级命令。
- 敏感动作通过显式 XPC 方法完成，而不是任意 shell 调用。
- 关键生命周期流程内置归属和权限修复逻辑。
- 运行时资源按 Shrimp 隔离，一个实例出问题不扩散到其他实例。

## 快速开始

### 环境要求

- macOS 14+
- Xcode 15+
- 可选：[XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 从源码启动

```bash
open ClawdHome.xcodeproj
```

如果你希望先重新生成工程：

```bash
xcodegen generate
open ClawdHome.xcodeproj
```

### 本地开发安装 Helper

```bash
make install-helper
```

等价直接命令：

```bash
sudo bash scripts/install-helper-dev.sh install
```

## 常用命令

| 目的 | 命令 |
| --- | --- |
| 构建 App（Debug） | `make build` |
| 只构建 Helper | `make build-helper` |
| 构建 Release 归档 | `make build-release` |
| 生成本地未签名安装包 | `make pkg` |
| 生成本地验收用已签名安装包 | `make pkg-signed` |
| 生成已签名且已公证安装包 | `make notarize-pkg` |
| 执行完整发布流程 | `make release NOTARIZE=true` |
| 直接运行导出的 Release App | `make run-release` |
| 安装最新生成的 pkg | `make install-pkg` |
| 卸载开发模式 Helper | `make uninstall-helper` |
| 实时查看 Helper 日志 | `make log-helper` |
| 实时查看 App 日志 | `make log-app` |
| 执行本地化检查 | `make i18n-check` |
| 清理构建产物 | `make clean` |

## 故障排查

### macOS 下 `npm install -g` 失败

先检查 Xcode Command Line Tools 是否可用：

```bash
xcode-select -p
```

如果命令失败，先安装：

```bash
xcode-select --install
```

如果遇到 Xcode license 错误，请使用管理员账号接受许可：

```bash
sudo xcodebuild -license
# 或非交互方式：
sudo xcodebuild -license accept
```

### 日志在哪里看

- Helper 日志：`/tmp/clawdhome-helper.log`
- App 日志流：`make log-app`

## 仓库结构

```text
ClawdHome/          SwiftUI 应用、视图、模型、服务
ClawdHomeHelper/    特权 helper daemon 与运维操作
Shared/             App 与 Helper 共享协议和数据模型
Resources/          LaunchDaemon plist 与打包资源
scripts/            构建、安装、打包、发布与 i18n 工具
docs/               项目文档与 README 配图资源
release-notes/      发布说明草稿
```

## 本地化

- 语言：中文、英文
- 字符串体系：`Stable.xcstrings`
- 检查命令：`make i18n-check`
- 说明文档：[docs/i18n.md](docs/i18n.md)

## 路线图

- [ ] 接入基于 exec 的外部密钥管理方案
- [ ] 更细粒度的网络访问控制管理
- [ ] 简化更多模型 provider 与 IM 渠道的配置流程
- [ ] 强化本地小模型工作流与 Agent 集成
- [ ] 增强救援与诊断能力
- [ ] 优化 gateway 探测与历史健康追踪
- [ ] 完善更生产级的签名与公证分发流程

## 参与贡献

- 较大或结构性改动请先提 issue 讨论。
- PR 尽量保持小而聚焦，便于评审。
- 行为变更请附带验证证据。
- 不要提交本地或私有环境产物。
- 遵循现有 Swift 风格和项目目录约定。
- 当前仓库尚未配置自动化单元测试，因此 PR 中的手动验证说明尤其重要。

## Star History

<a href="https://www.star-history.com/?repos=ThinkInAIXYZ%2Fclawdhome&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/image?repos=ThinkInAIXYZ/clawdhome&type=date&legend=top-left" />
 </picture>
</a>

## 许可证

项目使用 Apache License 2.0，详见 [LICENSE](LICENSE)。
