# ClawdHome XPC 通信规范

> 生成日期：2026-04-06 | 基于当前 main 分支代码分析

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                  ClawdHome.app (用户态)                    │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
│  │ SwiftUI Views│  │ ShrimpPool   │  │ GatewayHub    │   │
│  └──────┬──────┘  └──────┬───────┘  └───────────────┘   │
│         │                │                               │
│         ▼                ▼                               │
│  ┌──────────────────────────────────────────────┐       │
│  │            HelperClient (@Observable)          │       │
│  │                                                │       │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐      │       │
│  │  │ control  │ │dashboard │ │ install  │      │       │
│  │  │Connection│ │Connection│ │Connection│      │       │
│  │  └────┬─────┘ └────┬─────┘ └────┬─────┘      │       │
│  │  ┌────┴─────┐ ┌────┴─────┐ ┌────┴──────┐     │       │
│  │  │  file    │ │ process  │ │personaRead│     │       │
│  │  │Connection│ │Connection│ │Connection │     │       │
│  │  └────┬─────┘ └────┬─────┘ └────┬──────┘     │       │
│  └───────┼───────────┼───────────┼───────────────┘       │
└──────────┼───────────┼───────────┼───────────────────────┘
           │           │           │
     ══════╧═══════════╧═══════════╧══════  Mach IPC 边界
           │           │           │         (内核调度)
┌──────────┼───────────┼───────────┼───────────────────────┐
│          ▼           ▼           ▼                        │
│  ┌──────────────────────────────────────────────┐        │
│  │      NSXPCListener (Mach Service)             │        │
│  │      ai.clawdhome.mac.helper                  │        │
│  │                                                │        │
│  │  ┌─────────────┐   ┌────────────────────┐     │        │
│  │  │ Listener    │──▶│ isCallerAuthorized │     │        │
│  │  │ Delegate    │   │ ① UID ∈ admin(80)  │     │        │
│  │  └─────────────┘   │ ② CodeSign (Release)│     │        │
│  │                     └────────────────────┘     │        │
│  │  ┌───────────────────────────────────────┐     │        │
│  │  │    ClawdHomeHelperImpl (NSObject)      │     │        │
│  │  │    70 个 @objc XPC 方法               │     │        │
│  │  └──────────┬────────────────────────────┘     │        │
│  └─────────────┼────────────────────────────────┘        │
│                ▼                                          │
│  ┌──────────────────────────────────────────────┐        │
│  │ Operations                                    │        │
│  │ ┌────────────┐ ┌──────────────┐ ┌──────────┐ │        │
│  │ │UserManager │ │GatewayManager│ │ConfigWrite│ │        │
│  │ ├────────────┤ ├──────────────┤ ├──────────┤ │        │
│  │ │InstallMgr  │ │UserFileMgr   │ │ProcessMgr│ │        │
│  │ ├────────────┤ ├──────────────┤ ├──────────┤ │        │
│  │ │LocalLLMMgr │ │ShellRunner   │ │DashboardC│ │        │
│  │ └────────────┘ └──────────────┘ └──────────┘ │        │
│  └──────────────────────────────────────────────┘        │
│                                                           │
│            ClawdHomeHelper (root LaunchDaemon)             │
└───────────────────────────────────────────────────────────┘
```

---

## 2. 连接池设计

### 6 条专用连接

| 连接名称 | 变量 | 职责 | 隔离理由 |
|---------|------|------|---------|
| `control` | `controlConnection` | 用户/Gateway 管理、配置、命令执行 | 核心控制通道 |
| `dashboard` | `dashboardConnection` | 仪表盘快照、连接列表、更新状态 | 只读查询不阻塞控制 |
| `install` | `installConnection` | Node/npm/OpenClaw 安装升级 | 长时间运行（分钟级） |
| `file` | `fileConnection` | 文件 CRUD、目录浏览、解压 | I/O 密集不阻塞控制 |
| `process` | `processConnection` | 进程列表、详情、kill | 独立于文件和控制 |
| `personaRead` | `personaReadConnection` | git log/diff/restore | git 操作耗时，独立隔离 |

### 连接生命周期

```
App 启动
    │
    ▼
connect()
    ├─ invalidate 所有旧连接
    ├─ makeConnection("control")  ─→ NSXPCConnection.resume()
    ├─ makeConnection("dashboard") ─→ NSXPCConnection.resume()
    ├─ makeConnection("install")   ─→ NSXPCConnection.resume()
    ├─ makeConnection("file")      ─→ NSXPCConnection.resume()
    ├─ makeConnection("process")   ─→ NSXPCConnection.resume()
    ├─ makeConnection("personaRead") ─→ NSXPCConnection.resume()
    └─ verifyConnection()
           │
           ▼
       proxy.getGatewayStatus("__probe__")
           │
       ┌───┴───┐
    成功│       │失败
       ▼       ▼
  isConnected  isConnected
    = true      = false
```

---

## 3. XPC 协议方法清单

> Mach Service: `ai.clawdhome.mac.helper`
> Protocol: `ClawdHomeHelperProtocol` (@objc, NSObjectProtocol)

### 3.1 版本探测与生命周期

| 方法 | 签名 | 连接 | 说明 |
|------|------|------|------|
| `getVersion` | `(String) -> Void` | control | 版本号，兼作健康探针 |
| `requestRestart` | `(Bool) -> Void` | control | Helper exit(0) → launchd 自动拉起 |

### 3.2 用户管理 (7 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `createUser(username:fullName:password:)` | `(Bool, String?)` | sysadminctl 创建标准用户 |
| `deleteUser(username:keepHome:adminUser:adminPassword:)` | `(Bool, String?)` | sysadminctl 删除用户 |
| `prepareDeleteUser(username:)` | `(Bool, String?)` | 删前清理：停 gateway + 移除群组 |
| `cleanupDeletedUser(username:)` | `(Bool, String?)` | 删后清理：移除 Helper 状态文件 |
| `logoutUser(username:)` | `(Bool, String?)` | launchctl bootout 退出登录 |
| `changeUserPassword(username:newPassword:)` | `(Bool, String?)` | dscl -passwd 修改密码 |
| `resetUserEnv(username:)` | `(Bool, String?)` | 删除 ~/.npm-global + ~/.openclaw |

### 3.3 Gateway 控制 (9 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `startGateway(username:)` | `(Bool, String?)` | launchctl 启动 |
| `stopGateway(username:)` | `(Bool, String?)` | launchctl 停止 |
| `restartGateway(username:)` | `(Bool, String?)` | kickstart -k 原子重启 |
| `getGatewayStatus(username:)` | `(Bool, Int32)` | 返回 (isRunning, pid) |
| `getGatewayURL(username:)` | `(String)` | 返回 http://localhost:PORT |
| `setGatewayAutostart(enabled:)` | `(Bool, String?)` | 全局自启开关 |
| `getGatewayAutostart()` | `(Bool)` | 读取全局自启状态 |
| `setUserAutostart(username:enabled:)` | `(Bool, String?)` | 单用户自启开关 |
| `getUserAutostart(username:)` | `(Bool)` | 读取单用户自启状态 |

### 3.4 安装与环境 (10 个方法)

| 方法 | Reply 签名 | 连接 | 超时 |
|------|-----------|------|------|
| `installOpenclaw(username:version:)` | `(Bool, String?)` | install | 长时间 |
| `getOpenclawVersion(username:)` | `(String)` | control | - |
| `installNode(username:nodeDistURL:)` | `(Bool, String?)` | install | 长时间 |
| `isNodeInstalled(username:)` | `(Bool)` | control | 1.2s fallback |
| `setupNpmEnv(username:)` | `(Bool, String?)` | install | - |
| `repairHomebrewPermission(username:)` | `(Bool, String?)` | install | - |
| `setNpmRegistry(username:registry:)` | `(Bool, String?)` | control | - |
| `getNpmRegistry(username:)` | `(String)` | control | - |
| `getXcodeEnvStatus()` | `(String)` JSON | control | - |
| `installXcodeCommandLineTools()` | `(Bool, String?)` | install | - |
| `acceptXcodeLicense()` | `(Bool, String?)` | install | - |
| `cancelInit(username:)` | `(Bool)` | control | - |

### 3.5 配置管理 (4 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `setConfig(username:key:value:)` | `(Bool, String?)` | 通过 CLI 写入（可能慢） |
| `getConfig(username:key:)` | `(String)` | 通过 CLI 读取 dot-path |
| `getConfigJSON(username:)` | `(String)` | 直接读文件（毫秒级） |
| `setConfigDirect(username:path:valueJSON:)` | `(Bool, String?)` | 直接写文件 dot-path |

### 3.6 文件管理 (9 个方法，走 fileConnection)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `listDirectory(username:relativePath:showHidden:)` | `(String?, String?)` | JSON [FileEntry] |
| `readFile(username:relativePath:)` | `(Data?, String?)` | ≤10MB |
| `readFileTail(username:relativePath:maxBytes:)` | `(Data?, String?)` | 按字节截断 |
| `writeFile(username:relativePath:data:)` | `(Bool, String?)` | 覆盖写 + 修权限 |
| `deleteItem(username:relativePath:)` | `(Bool, String?)` | 删除文件/目录 |
| `createDirectory(username:relativePath:)` | `(Bool, String?)` | mkdir + chown |
| `renameItem(username:relativePath:newName:)` | `(Bool, String?)` | 同目录改名 |
| `extractArchive(username:relativePath:)` | `(Bool, String?)` | zip/tar.gz/tgz/bz2/xz |
| `searchMemory(username:query:limit:)` | `(String?, String?)` | SQLite FTS 搜索 |

### 3.7 进程管理 (4 个方法，走 processConnection)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `getProcessList(username:)` | `(String)` | JSON [ProcessEntry] |
| `getProcessListSnapshot(username:)` | `(String)` | 含端口扫描进度 |
| `getProcessDetail(pid:)` | `(String)` | JSON ProcessDetail |
| `killProcess(pid:signal:)` | `(Bool, String?)` | 15=TERM, 9=KILL |

### 3.8 仪表盘与监控 (4 个方法，走 dashboardConnection)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `getDashboardSnapshot()` | `(String)` | 缓存快照，零阻塞 |
| `getCachedAppUpdateState()` | `(String?)` | 无缓存返回 nil |
| `getConnections()` | `(String?)` | nstat 连接列表 |
| `readSystemLog(name:)` | `(Data?, String?)` | ≤2MB 审计日志 |

### 3.9 终端会话 PTY (5 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `startMaintenanceTerminalSession(username:commandJSON:)` | `(Bool, String, String?)` | 返回 sessionID |
| `pollMaintenanceTerminalSession(sessionID:fromOffset:)` | `(Bool, String, Int64, Bool, Int32, String?)` | chunk+offset+exit |
| `sendMaintenanceTerminalSessionInput(sessionID:inputBase64:)` | `(Bool, String?)` | Base64 输入 |
| `resizeMaintenanceTerminalSession(sessionID:cols:rows:)` | `(Bool, String?)` | 调整 pty 尺寸 |
| `terminateMaintenanceTerminalSession(sessionID:)` | `(Bool, String?)` | 清理会话 |

### 3.10 命令执行 (4 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `runOpenclawCommand(username:argsJSON:)` | `(Bool, String)` | 通用 openclaw CLI |
| `runModelCommand(username:argsJSON:)` | `(Bool, String)` | openclaw models 子命令 |
| `runPairingCommand(username:argsJSON:)` | `(Bool, String)` | openclaw pairing 子命令 |
| `runFeishuOnboardCommand(username:argsJSON:)` | `(Bool, String)` | 飞书 lark-tools 安装 |

### 3.11 网络策略 (6 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `getShrimpNetworkPolicy(username:)` | `(String?)` | 单虾网络策略 |
| `setShrimpNetworkPolicy(username:policyJSON:)` | `(Bool, String?)` | 设置单虾策略 |
| `getGlobalNetworkConfig()` | `(String?)` | 全局网络配置 |
| `setGlobalNetworkConfig(configJSON:)` | `(Bool, String?)` | 设置全局配置 |
| `enableNetworkPF()` | `(Bool, String?)` | 启用 PF 防火墙 |
| `disableNetworkPF()` | `(Bool, String?)` | 禁用 PF 防火墙 |

### 3.12 代理配置 (2 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `applySystemProxyEnv(username:enabled:proxyURL:noProxy:)` | `(Bool, String?)` | 注入/移除代理环境变量 |
| `applyProxySettings(username:enabled:proxyURL:noProxy:restartGatewayIfRunning:)` | `(Bool, String?)` | 一次性应用代理+可选重启 |

### 3.13 Secrets 同步 (2 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `syncSecrets(username:secretsJSON:authProfilesJSON:)` | `(Bool, String?)` | 推送密钥到虾 |
| `reloadSecrets(username:)` | `(Bool, String?)` | 通知热加载 |

### 3.14 克隆虾 (4 个方法)

| 方法 | Reply 签名 | 超时 |
|------|-----------|------|
| `scanCloneClaw(username:)` | `(String, String?)` | 20s |
| `cloneClaw(requestJSON:)` | `(Bool, String, String?)` | 240s |
| `cancelCloneClaw(targetUsername:)` | `(Bool, String?)` | - |
| `getCloneClawStatus(targetUsername:)` | `(String?)` | - |

### 3.15 本地 AI (7 个方法)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `installOmlx()` | `(Bool, String?)` | brew 安装 omlx |
| `getLocalLLMStatus()` | `(String)` | JSON LocalServiceStatus |
| `listLocalModels()` | `(String)` | JSON [LocalModelInfo] |
| `startLocalLLM()` | `(Bool, String?)` | 启动 omlx LaunchDaemon |
| `stopLocalLLM()` | `(Bool, String?)` | 停止 omlx LaunchDaemon |
| `downloadLocalModel(modelId:)` | `(Bool, String?)` | huggingface 下载 |
| `deleteLocalModel(modelId:)` | `(Bool, String?)` | 删除本地模型 |

### 3.16 角色定义 Git (4 个方法，走 personaReadConnection)

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `initPersonaGitRepo(username:)` | `(Bool, String?)` | 幂等 git init |
| `commitPersonaFile(username:filename:message:)` | `(Bool, String?)` | 单文件 commit |
| `getPersonaFileHistory(username:filename:)` | `(String?, String?)` | git log JSON |
| `getPersonaFileDiff(username:filename:commitHash:)` | `(String?, String?)` | unified diff |
| `restorePersonaFileToCommit(username:filename:commitHash:)` | `(Bool, String?)` | checkout + commit |

### 3.17 其他

| 方法 | Reply 签名 | 说明 |
|------|-----------|------|
| `runHealthCheck(username:fix:)` | `(Bool, String)` | 环境+安全审计 |
| `backupUser(username:destinationPath:)` | `(Bool, String?)` | tar.gz 备份 |
| `restoreUser(username:sourcePath:)` | `(Bool, String?)` | tar.gz 恢复 |
| `saveInitState(username:json:)` | `(Bool, String?)` | 持久化向导进度 |
| `loadInitState(username:)` | `(String)` | 读取向导进度 |
| `isScreenSharingEnabled()` | `(Bool)` | VNC 状态查询 |
| `enableScreenSharing()` | `(Bool, String?)` | 启用 VNC |
| `setHelperDebugLogging(enabled:)` | `(Bool, String?)` | DEBUG 日志开关 |
| `getHelperDebugLogging()` | `(Bool)` | 读取日志开关 |

**合计：约 70 个 XPC 方法**

---

## 4. 交互时序图

### 4.1 连接建立与验证

```
App                           Kernel                       Helper (root)
 │                              │                              │
 │ NSXPCConnection(.privileged) │                              │
 │─────────────────────────────▶│ Mach message                │
 │                              │─────────────────────────────▶│
 │                              │    shouldAcceptNewConnection │
 │                              │◀─────────────────────────────│
 │                              │      ① uid(ofPID) → sysctl  │
 │                              │      ② isAdminUID(uid)       │
 │                              │      ③ accept=true           │
 │                              │                              │
 │◀─ connection resumed ────────│                              │
 │                              │                              │
 │ getGatewayStatus("__probe__")│                              │
 │─────────────────────────────▶│─────────────────────────────▶│
 │                              │                              │── 快速返回
 │◀─ reply (false, -1) ────────│◀─────────────────────────────│
 │                              │                              │
 │ isConnected = true           │                              │
```

### 4.2 创建虾 (新用户初始化完整流程)

```
App (UI)                    HelperClient                     Helper (root)
 │                              │                              │
 │ 1. 创建 macOS 用户            │                              │
 │─────────────────────────────▶│ createUser(u, fn, pw)        │
 │                              │─────[control]───────────────▶│ sysadminctl -addUser
 │                              │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 2. 安装 Node.js               │                              │
 │─────────────────────────────▶│ installNode(u, url)          │
 │                              │─────[install]───────────────▶│ 下载 + 解压 Node
 │     (分钟级)                  │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 3. 配置 npm 环境              │                              │
 │─────────────────────────────▶│ setupNpmEnv(u)               │
 │                              │─────[install]───────────────▶│ mkdir ~/.npm-global
 │                              │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 4. 安装 OpenClaw              │                              │
 │─────────────────────────────▶│ installOpenclaw(u, ver)      │
 │                              │─────[install]───────────────▶│ npm install -g openclaw
 │     (分钟级)                  │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 5. 写入配置                   │                              │
 │─────────────────────────────▶│ setConfigDirect(u, path, val)│
 │                              │─────[control]───────────────▶│ 直接写 JSON 文件
 │                              │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 6. 同步密钥                   │                              │
 │─────────────────────────────▶│ syncSecrets(u, keys, auth)   │
 │                              │─────[control]───────────────▶│ 写入 secrets 文件
 │                              │◀─────(true, nil)─────────────│
 │                              │                              │
 │ 7. 启动 Gateway               │                              │
 │─────────────────────────────▶│ startGateway(u)              │
 │                              │─────[control]───────────────▶│ launchctl bootstrap
 │                              │◀─────(true, nil)─────────────│
```

### 4.3 终端会话 (PTY 交互)

```
App                         HelperClient                     Helper (PTY)
 │                              │                              │
 │ startMaintenanceTerminal     │                              │
 │─────────────────────────────▶│ start(u, cmdJSON)            │
 │                              │─────[control]───────────────▶│ fork + execve
 │                              │◀── (ok, sessionID, nil) ─────│ PTY 已创建
 │                              │                              │
 │  ┌──── 轮询循环 ─────┐       │                              │
 │  │ pollTerminalSession │      │                              │
 │  │────────────────────▶│ poll(sid, offset)              │
 │  │                     │─────[control]──────────────────▶│ 读取 outputBuffer
 │  │                     │◀── (ok, chunk, nextOff, ...) ──│
 │  │ 渲染 chunk 到终端   │      │                              │
 │  │                     │      │                              │
 │  │ 用户输入             │      │                              │
 │  │────────────────────▶│ sendInput(sid, base64)         │
 │  │                     │─────[control]──────────────────▶│ write(stdinPipe)
 │  │                     │◀── (ok, nil) ──────────────────│
 │  │                     │      │                              │
 │  │  exit detected      │      │                              │
 │  └─────────────────────┘      │                              │
 │                              │                              │
 │ terminateTerminalSession      │                              │
 │─────────────────────────────▶│ terminate(sid)               │
 │                              │─────[control]───────────────▶│ process.terminate()
 │                              │◀── (ok, nil) ────────────────│
```

### 4.4 Dashboard 刷新 (非阻塞路径)

```
App (Timer 2s)              HelperClient                     Helper (缓存)
 │                              │                              │
 │ getDashboardSnapshot()       │                              │
 │─────────────────────────────▶│                              │
 │                              │─────[dashboard]─────────────▶│ 读缓存 (DashboardCollector)
 │                              │◀── (JSON snapshot) ──────────│ ← 零阻塞
 │ 更新 UI                      │                              │
 │                              │                              │
 │ getProcessListSnapshot(u)    │                              │
 │─────────────────────────────▶│                              │
 │                              │─────[process]───────────────▶│ ps + lsof (异步)
 │                              │◀── (JSON) ───────────────────│
 │ 更新进程表                    │                              │
```

### 4.5 连接中断与恢复

```
App                                                          Helper
 │                                                              │
 │  ←── interruptionHandler 触发 ──                             │ 进程被暂时中断
 │  (XPC 框架自动恢复，无需操作)                                   │
 │                                                              │
 │  ←── invalidationHandler 触发 ──                             │ Helper 进程终止
 │  isConnected = false                                         │
 │                                                              │
 │  App 侧 maintainConnection() 定时器（5s）                     │
 │  ────── verifyConnection() ────────▶                         │
 │  ←── error ────────────────────────                          │ 仍不可达
 │                                                              │
 │  ... (Helper 重启后)                                          │
 │  ────── verifyConnection() ────────▶                         │
 │  ←── (true, -1) ──────────────────                           │ 恢复
 │  isConnected = true                                          │
```

---

## 5. 安全模型

### 5.1 认证流程

```
新连接请求到达
    │
    ▼
uid(ofPID:) ─── sysctl(KERN_PROC) ──→ 获取调用方 UID
    │
    ▼
isAdminUID() ─── getgrouplist() ──→ 检查 UID ∈ gid 80 (admin)
    │
    ├── 非 admin ──→ reject + 日志警告
    │
    ▼ (admin)
#if !DEBUG
    │
    ▼
验证代码签名 ──→ auditToken 匹配 ClawdHome.app 签名
    │
    ├── 签名不匹配 ──→ reject
    │
    ▼ (通过)
#endif
    │
    ▼
accept ──→ 导出 ClawdHomeHelperImpl 实例
```

### 5.2 权限边界

| 层级 | 主体 | 权限 |
|------|------|------|
| App 进程 | 当前登录用户 | 标准用户权限，无 root |
| XPC 消息 | Mach 内核 | 验证 PID → UID → admin group |
| Helper 进程 | root (LaunchDaemon) | 完全系统权限 |
| 操作范围 | 目标 Shrimp 用户 | 仅操作该用户 home 目录 |

### 5.3 日志脱敏

Helper 所有日志经过 `LogRedactor.redact()` 处理，匹配模式包括：
- `#token=xxx` → `#token=[REDACTED]`
- `?api_key=xxx` / `?password=xxx` → `?api_key=[REDACTED]`
- Bearer tokens
- API keys（sk-、key-、pat- 前缀）

---

## 6. 并发模式

### 6.1 客户端 async/await 桥接

```swift
// 模式 1：基础 callback → async 桥接
let (ok, msg) = await withCheckedContinuation { cont in
    proxy.method(args) { ok, msg in
        cont.resume(returning: (ok, msg))
    }
}

// 模式 2：带超时的 TaskGroup
try await withThrowingTaskGroup { group in
    group.addTask { /* 真实 XPC 调用 */ }
    group.addTask { try await Task.sleep(for: timeout); throw error }
    defer { group.cancelAll() }
    return try await group.next()!
}

// 模式 3：callback 丢失兜底 (isNodeInstalled)
// 1.2s 后 fallback 到本地文件检测
```

### 6.2 服务端防重复回复

```swift
// Helper 侧的 replyOnce 模式
let lock = NSLock()
var hasReplied = false
func replyOnce(_ args...) {
    lock.lock()
    defer { lock.unlock() }
    guard !hasReplied else { return }
    hasReplied = true
    reply(args...)
}
```

---

## 7. 数据序列化

### XPC 类型约束

| 类型 | ObjC 兼容 | 用途 |
|------|----------|------|
| `String` | ✅ | 文本、JSON 载体 |
| `Bool` | ✅ | 成功/失败 |
| `Int32` | ✅ | PID、信号值 |
| `Int` | ✅ | 字节限制 |
| `Int64` | ✅ | 偏移量 |
| `Data` | ✅ | 二进制文件内容 |
| `String?` | ✅ | 可选错误消息 |

### JSON 序列化策略

复杂结构一律 JSON 编码为 String 传输：
- 请求参数：`argsJSON`、`requestJSON`、`policyJSON`、`commandJSON`
- 响应数据：Dashboard snapshot、Process list、File entries
- 编码器：标准 `JSONEncoder` / `JSONDecoder`

---

## 8. 问题分析与优化建议

### 8.1 严重问题

#### ~~P0: `withCheckedContinuation` 可能永久挂起~~ ✅ 已修复

**修复内容**：添加了 `xpcCall<T>(timeout:operation:)` 通用超时包装器，**所有 XPC 方法均已获得超时保护**：
- 普通操作：默认 30s 超时
- 安装类操作（installOpenclaw、installNode、installOmlx 等）：600s（10 分钟）
- 克隆操作：240s
- 备份/恢复：120s
- 命令执行：60s
- 仅保留 `isNodeInstalled` 的手动兜底机制（兼容旧 Helper callback 丢失）

超时后抛出 `HelperError.operationFailed`，非 throwing 方法返回安全默认值。

#### P0: 协议膨胀 — 70 个扁平方法

**现状**：所有操作定义在单个 `@objc protocol` 中，无分组、无版本控制。

**影响**：
- 新增方法需 App + Helper 同时更新，版本耦合严重
- 无法做灰度：旧 Helper 不支持新方法时，App 调用直接崩溃或无响应
- 维护成本高，方法命名空间污染

**建议**：
1. 引入版本协商机制：`getVersion` 返回支持的 API 版本号，客户端按版本决定可用方法
2. 将方法按领域拆分为多个 protocol（UserManagement、GatewayControl、FileManagement 等），通过 `NSXPCInterface` 的 `setInterface:forSelector:` 分组暴露
3. 或改用 JSON-RPC over XPC：单个 `dispatch(method:params:reply:)` 入口，内部路由

### 8.2 高优先级

#### P1: 认证缺少方法级授权

**现状**：认证仅检查"调用方是否为 admin 用户"。一旦通过，可调用任何方法（包括 deleteUser、killProcess、changeUserPassword）。

**影响**：如果任何 admin 用户安装的第三方应用连接到该 Mach service，将获得完整 root 操作权限。

**建议**：
1. Release 模式下强制代码签名验证（当前已有但应确认 100% 覆盖）
2. 考虑对破坏性操作（deleteUser、killProcess、resetUserEnv）增加二次确认或 nonce 机制
3. 文件操作增加路径白名单验证（仅允许操作 `~<shrimp>/` 下的文件，防止路径遍历）

#### P1: 无连接健康度追踪

**现状**：6 条连接独立运行，但只有一个 `isConnected` 布尔值追踪整体状态。

**影响**：
- 某条连接断开（如 install 连接超时），其他连接状态不受影响但 `isConnected` 可能被错误地设为 false
- 无法定位"哪条连接有问题"
- 无重连指标

**建议**：
```swift
struct ConnectionHealth {
    var control: ConnectionState
    var dashboard: ConnectionState
    var install: ConnectionState
    // ...
}
enum ConnectionState {
    case connected
    case interrupted  // 可自动恢复
    case invalidated  // 需要重建
}
```

#### ~~P1: invalidationHandler 中 `[weak self]` 捕获但未更新状态~~ ✅ 已修复

**修复内容**：`invalidationHandler` 现在会在主线程设置 `isConnected = false`，任何一条连接被 invalidate（Helper 终止/被替换）都会立即触发 App 侧的重连流程。日志级别也从 `.info` 改为 `.error`，便于诊断。

### 8.3 中等优先级

#### ~~P2: PTY 会话缺少自动清理~~ ✅ 已修复

**修复内容**：`ClawdHomeHelperImpl` 新增 30 秒周期的 `sweepStaleSessions()` 定时器：
- 已退出进程的会话：60 秒无 poll 后自动清理
- 活跃但空闲的会话：10 分钟无 poll 后自动 terminate + 清理
- 每个 session 新增 `lastPollTime` 属性，`poll()` 调用时自动更新

#### P2: 无请求幂等性保证

**现状**：`createUser`、`installOpenclaw` 等操作无幂等性设计。

**影响**：网络抖动导致 App 侧未收到 reply 时重试，可能导致重复操作。大部分操作由 Helper 侧幂等处理（如 sysadminctl 创建已存在用户会失败），但不是所有操作都安全。

**建议**：
1. 对长时间操作引入 request ID，Helper 侧去重
2. 或对所有写操作实现幂等语义（检查前置状态后再执行）

#### P2: 错误信息结构化不足

**现状**：所有错误通过 `String?` 返回，客户端无法程序化处理不同错误类型。

**影响**：无法区分"用户已存在"和"权限不足"和"磁盘空间不足"，只能展示原始错误文本。

**建议**：
```swift
// 定义错误码枚举
struct XPCResult: Codable {
    let success: Bool
    let errorCode: String?   // "USER_EXISTS", "PERMISSION_DENIED", "DISK_FULL"
    let errorMessage: String? // 人类可读描述
    let data: String?         // JSON payload
}
```

#### P2: Dashboard 轮询模式浪费资源

**现状**：App 每 2 秒轮询 `getDashboardSnapshot`，即使数据未变化也传输完整 JSON。

**建议**：
1. 引入 ETag/版本号机制，无变化时返回空
2. 或使用 XPC 的反向通知能力：Helper 主动推送变更事件到 App

#### ~~P2: 文件操作路径验证~~ ✅ 已有保护

**现状**：`UserFileManager.resolvedPath()` 已实现完整的路径遍历防护：
1. 用户名只允许字母、数字、`_`、`-`、`.`
2. 使用 `URL.standardized` 规范化路径（解析 `..` 和符号链接）
3. 验证规范化后的绝对路径必须以 `/Users/<username>/` 为前缀
4. 不满足条件时抛出 `UserFileError.pathTraversal`

无需额外修复。

### 8.4 低优先级改进

#### P3: 连接数可优化

**现状**：6 条连接，每条独立的 NSXPCConnection。

**分析**：NSXPCConnection 底层共享 Mach port，6 条连接的实际开销不大。但 Helper 侧每条连接创建独立的 `ClawdHomeHelperImpl` 实例，意味着状态（如 maintenanceSessions）不共享。

**建议**：如果 PTY 会话需要跨连接访问（如 control 连接启动，file 连接 poll），应将 session store 提升为全局单例。

#### P3: 缺少 XPC 通信指标

**建议**：添加调用计数、延迟、错误率等指标，便于诊断性能问题：
```swift
struct XPCMetrics {
    var callCount: [String: Int]     // 按方法名统计
    var avgLatency: [String: Double] // 按方法名统计
    var errorCount: Int
    var lastError: Date?
}
```

#### P3: JSON 序列化性能

**现状**：每次 XPC 调用都创建新的 JSONEncoder/JSONDecoder。

**建议**：使用静态/缓存的编解码器实例。对大 payload（Dashboard snapshot）考虑 MessagePack 等二进制格式。

---

## 9. 超时策略汇总

| 操作类别 | 客户端超时 | 服务端超时 | 说明 |
|---------|-----------|-----------|------|
| `startGateway` | 25s | - | Gateway 启动可能慢（自定义消息） |
| `isGatewayRunningQuickly` | 3s | - | 快速状态检查 |
| `scanCloneClaw` | 20s | - | 文件系统扫描 |
| `cloneClaw` | 240s (4min) | - | 大数据拷贝 |
| `isNodeInstalled` | 1.2s fallback | - | 兼容旧 Helper callback 丢失 |
| 安装类（installOpenclaw 等） | **600s (10min)** | - | npm install / brew install / 下载 |
| 命令类（runOpenclawCommand 等） | **300s (5min)** | - | CLI 命令可能涉及网络请求 |
| `pollMaintenanceTerminalSession` | **10s** | - | 轮询应快速返回 |
| **其他所有方法** | **30s（默认）** | - | `xpcCall` 全局保护 |

> **超时设计原则**：超时是"防 callback 永远丢失"的安全网，不是操作限速器。
> 宁可宽松（让合法慢操作完成）也不要太紧（导致误杀正常请求）。

---

## 10. 修复状态与剩余优化路线图

### 已完成

| 优先级 | 改动 | 状态 |
|--------|------|------|
| P0 | 全局默认超时 wrapper（`xpcCall`） | ✅ 已修复 |
| P1 | invalidationHandler 更新 `isConnected` 状态 | ✅ 已修复 |
| P2 | PTY 会话自动超时清理（30s 扫描周期） | ✅ 已修复 |
| P2 | relativePath 路径遍历检查 | ✅ 已有保护 |

### 剩余待办

| 阶段 | 优先级 | 改动 | 预期收益 |
|------|--------|------|---------|
| Phase 1 | P0 | 协议版本协商 / 拆分 | 解耦 App-Helper 版本 |
| Phase 1 | P1 | 分连接健康度追踪（per-connection state） | 精确诊断 |
| Phase 2 | P1 | 方法级授权 + 代码签名强制验证 | 安全加固 |
| Phase 2 | P2 | 结构化错误码 | 改善错误处理 |
| Phase 3 | P2 | Dashboard 推送替代轮询 | 降低 CPU / IPC 开销 |
| Phase 3 | P2 | 请求幂等性（request ID 去重） | 防重复操作 |
| Phase 3 | P3 | XPC 调用指标采集 | 可观测性 |
| Phase 3 | P3 | JSON 编解码器缓存 | 性能微优化 |
