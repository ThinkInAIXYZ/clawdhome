# ClawdHome 安全隔离设计

## 概述

ClawdHome 基于 macOS 原生多用户机制实现虾（Shrimp）之间的安全隔离。每个虾对应一个独立的 macOS 用户账户，利用操作系统级别的权限边界保证进程、文件、网络的隔离。

## 架构分层

```
┌─────────────────────────────────────────────────────┐
│  ClawdHome.app（管理员 UI，普通用户权限）              │
│    └── SwiftUI + XPC Client                         │
└──────────────┬──────────────────────────────────────┘
               │ NSXPCConnection (Mach service)
┌──────────────▼──────────────────────────────────────┐
│  ClawdHomeHelper（root LaunchDaemon）                │
│    ├── UserManager     — 创建/删除 macOS 用户        │
│    ├── GatewayManager  — 启停 OpenClaw 网关实例       │
│    ├── InstallManager  — Node.js/OpenClaw 安装       │
│    ├── ConfigWriter    — 配置文件读写                 │
│    └── ShellRunner     — 指定用户身份执行命令          │
└──────────────┬──────────────────────────────────────┘
               │ per-user launchctl / sudo -u
┌──────────────▼──────────────────────────────────────┐
│  Shrimp 实例（各自运行在独立 macOS 用户下）            │
│    ├── ~/.openclaw/    — 配置与数据（仅本用户可访问）   │
│    ├── ~/.npm-global/  — npm 全局安装目录              │
│    └── ~/.brew/        — Homebrew 隔离安装            │
└─────────────────────────────────────────────────────┘
```

## 隔离层次

### 1. 进程隔离

每个虾的 OpenClaw 网关以对应 macOS 用户身份运行（通过 `launchctl` 的 `UserName` 字段）。进程间无法相互 signal 或 ptrace，由 macOS 内核强制执行。

### 2. 文件系统隔离

| 路径 | 权限 | 说明 |
|------|------|------|
| `~<shrimp>/` | `700` (rwx------) | 虾的 home 目录，仅本用户可访问 |
| `~<shrimp>/.openclaw/` | `700` | 网关配置与运行时数据 |
| `/var/lib/clawdhome/` | `750` (root:wheel) | Helper 私有数据，虾不可访问 |

### 3. 凭证隔离

- 各虾的 API Key 存储在管理员用户的 Keychain 中（`ProviderKeychainStore`），虾本身无法读取原始密钥
- 密钥通过 Helper → ConfigWriter 注入到虾的配置文件中，运行时由 OpenClaw 网关读取

### 4. 网络隔离

- 每个虾的网关绑定到不同端口
- 可通过 `netpolicy` 配置限制虾的出站网络访问

## 目录布局

```
/var/lib/clawdhome/                     ← Helper 私有（root:wheel 750）
├── app-update-state.json               │ 应用更新状态
├── client-id                           │ 实例标识
├── tasks.json                          │ 后台任务状态
├── backup-config.json                  │ 备份配置
├── *-init.json                         │ 各虾的初始化进度
├── *-netpolicy.json                    │ 各虾的网络策略
├── global-netconfig.json               │ 全局网络配置
├── cache/                              │ 安装包缓存
│   ├── homebrew/                       │   Homebrew tarball
│   └── nodejs/                         │   Node.js 预编译包
└── models/                             │ 本地 AI 模型
    └── omlx/                           │   omlx 模型文件

/Users/Shared/ClawdHome/                ← 跨用户共享空间
├── public/                             │ 公共文件夹（所有虾 + 管理员）
└── vaults/                             │ 安全文件夹
    └── <shrimp-username>/              │   每虾独立（管理员 + 该虾）
```

## 权限组设计

### 专属组（per-shrimp）

- 组名：`clawdhome-<shrimp-username>`
- 成员：管理员用户 + 该虾用户
- 用途：安全文件夹 `/Users/Shared/ClawdHome/vaults/<shrimp>/` 的访问控制
- 目录权限：`0770` + setgid bit

### 共享组（全局）

- 组名：`clawdhome-all`
- 成员：管理员用户 + 所有虾用户
- 用途：公共文件夹 `/Users/Shared/ClawdHome/public/` 的访问控制
- 目录权限：`0775` + setgid bit

### 组生命周期

| 事件 | 操作 |
|------|------|
| 创建虾 | 创建 `clawdhome-<username>` 组；将虾和管理员加入；将虾加入 `clawdhome-all` |
| 删除虾 | 将虾从 `clawdhome-all` 移除；删除 `clawdhome-<username>` 组；可选清理 vault 目录 |
| 首次安装 | 创建 `clawdhome-all` 组 |

## 特权操作原则

1. **App 层绝不执行特权操作** — 所有系统级操作通过 XPC 路由到 Helper
2. **Helper 最小权限** — 仅执行协议中定义的操作，不暴露通用 shell
3. **缓存防投毒** — 安装缓存存放在 `/var/lib/clawdhome/cache/`（root only），防止虾篡改缓存包实现提权
4. **配置写入经 Helper** — 虾的配置由 Helper 的 `ConfigWriter` 写入，虾自身不能修改配置中的特权字段
