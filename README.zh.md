# ClawdHome

[English](README.md) | 中文

**ClawdHome 让你在一台 Mac 上安全“养虾”：隔离运行多个 OpenClaw gateway 实例，让每只虾都住进安全、可靠、边界清晰的房子。**

## 官网与下载

- [https://clawdhome.app](https://clawdhome.app)

## 适用场景

ClawdHome 面向需要在一台 Mac 上运行多个 OpenClaw gateway 的开发者与运维者，重点解决身份、数据、权限不混用的问题。它特别适合生产/测试隔离、低风险克隆演练，以及通过统一控制台完成日常运维和排障。

## 视觉概览

<table>
  <tr>
    <td><img src="docs/assets/readme/github-dashboard.png" alt="Dashboard" /></td>
    <td><img src="docs/assets/readme/github-claw-pool.png" alt="Claw Pool" /></td>
  </tr>
  <tr>
    <td><img src="docs/assets/readme/github-filemanager.png" alt="File Manager" /></td>
    <td><img src="docs/assets/readme/github-process.png" alt="Process" /></td>
  </tr>
</table>

ClawdHome 提供统一控制平面，用于监控、隔离和运维多个 OpenClaw gateway 实例，覆盖不同用户与不同角色的虾。

## ClawdHome 是什么

ClawdHome 是一个用于安全隔离和运维多个 OpenClaw gateway 实例的 macOS 管理应用，配合特权 Helper Daemon 工作。它聚焦于一件事：在同一台机器上安全地运行并管理多个彼此隔离的 OpenClaw gateway 实例。每个虾都有独立的运行上下文、数据与策略边界。

## 为什么要做它

- OpenClaw 不是一次性装好就结束，而是需要持续去“养”（学习、成长、迭代）；在这个过程中，给每只虾独立房子（账号隔离、权限边界）是基础前提。
- 养的过程需要低风险试错：可以快速克隆一只虾做实验、演练或回归验证，逐步形成稳定可维护的“数字分身”。
- 主力 MacBook 也要能安全、低损耗养虾：人用管理员账号，虾用普通账号，每只虾有独立边界。
- 虚拟机和 Docker 对这个场景偏重；基于 macOS 多用户体系更原生（系统 UI、浏览器自动化）。
- 养虾不只是聊天，还希望虾能接入智能家居，并利用 Mac 神经网络/GPU 加速能力支持更低延迟、更低成本的本地能力。
- OpenClaw 实例在真实场景中会嘎掉，因此需要统一运维能力以及备份、维护、恢复流程。

## 工作方式

```text
ClawdHome.app（管理员 UI）
  -> XPC -> ClawdHomeHelper（特权守护进程）
      -> 用户级 OpenClaw gateway 实例（按虾隔离）
```

- `ClawdHome.app` 负责可视化运维、状态查看和配置入口。
- `ClawdHomeHelper` 负责受控的系统级操作。
- 每个虾对应一个隔离的 OpenClaw gateway 运行单元。
- gateway 生命周期按实例独立管理（启动/停止/重启/健康检查）。
- 配置与数据按实例处理，并带有明确的归属与权限策略。

## 安全模型

- 特权操作集中在 helper 边界，不直接暴露到普通用户侧。
- 运行时资源按虾/实例隔离。
- 敏感操作通过显式 XPC 接口执行，而非临时命令拼接。
- 核心生命周期流程内置归属与权限修复逻辑。

## 快速开始

### 环境要求

- macOS 14+
- Xcode 15+
- 可选：[XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 构建与运行

```bash
open ClawdHome.xcodeproj
```

或先重新生成工程：

```bash
xcodegen generate
open ClawdHome.xcodeproj
```

### 安装 Helper（开发模式）

```bash
make install-helper
```

等价命令：

```bash
sudo bash scripts/install-helper-dev.sh install
```

### macOS 下 npm 安装失败排查

如果在 `npm install -g` 阶段失败，先检查 Xcode 命令行工具状态：

```bash
xcode-select -p
```

如果命令报错，先安装 Command Line Tools：

```bash
xcode-select --install
```

如果报 license 相关错误，请先接受许可：

```bash
sudo xcodebuild -license
# 或非交互：
sudo xcodebuild -license accept
```

## 关键能力

- 一台 Mac 上多虾 OpenClaw gateway 隔离运行。
- 按实例的生命周期控制与健康状态可视化。
- 受管用户操作与初始化流程管理。
- 配置编辑与诊断工具统一入口。
- 文件、会话、记忆、日志等管理能力。
- 本地 AI 运维集成（按配置启用）。

## 仓库结构

```text
ClawdHome/
  UI 应用（SwiftUI）、模型、服务、视图
ClawdHomeHelper/
  特权 helper daemon 与运维操作实现
Shared/
  App 与 Helper 共享协议和数据模型
scripts/
  构建、安装、打包、发布说明脚本
Resources/
  helper 启动配置与打包资源
```

## 开发工作流

- 构建 App（Debug）：

```bash
make build
```

- 构建 Helper（Debug）：

```bash
make build-helper
```

- 打包：

```bash
make pkg
```

- 查看 Helper 日志：

```bash
make log-helper
```

## 路线图

- [ ] 外部密钥管理（Exec 模式 secrets provider）。
- [ ] 网络访问控制精细化管理。
- [ ] 接入更多模型和 IM 通道的简化配置。
- [ ] 本地整合运行小模型，完成一些场景 Skill，接入 OpenClaw。
- [ ] 救援诊断能力。
- [ ] gateway 探测与历史健康追踪优化。
- [ ] 生产级签名/公证分发流程完善。

## 参与贡献

- 较大改动请先提 issue 讨论。
- PR 保持小而清晰，避免混合不相关修改。
- 行为变更请附验证证据。
- 避免提交本地/私有环境产物。
- 遵循现有 Swift 代码风格与目录结构。

## 许可证

项目使用 Apache License 2.0，见 [LICENSE](LICENSE)。
