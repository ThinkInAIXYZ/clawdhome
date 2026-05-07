# ClawdHome 文件共享设计

## 概述

安全文件夹允许管理员（人）和虾（Shrimp）之间安全地交换文件，解决人机协同中的文件传递问题。通过 Finder 打开共享目录，用户可以直接利用 macOS 原生的文件管理能力（拖拽、预览、Quick Look、标签、Spotlight 搜索等）与虾交互，无需在 ClawdHome 内重新实现文件管理器。

分为两种类型：

- **安全文件夹（Vault）**：每虾独立，仅管理员和该虾可访问 — 用于向特定虾传递私密文件或接收其输出
- **公共文件夹（Public）**：所有虾和管理员共享 — 用于跨虾共享通用资源（提示词模板、参考数据等）

## 目录结构

```
/Users/Shared/ClawdHome/
├── public/                          ← 公共文件夹
│   ├── prompts/                     │   共享提示词
│   ├── datasets/                    │   共享数据集
│   └── ...                          │   用户自由组织
└── vaults/
    ├── shrimp-alice/                ← Alice 的安全文件夹
    │   └── ...
    ├── shrimp-bob/                  ← Bob 的安全文件夹
    │   └── ...
    └── ...
```

### 虾侧发现机制

每个虾的 home 目录下自动创建 `~/clawdhome_shared/` 符号链接目录，让虾（和通过虾对话的 AI）能自然发现共享文件夹：

```
~shrimp/
├── .openclaw/workspace/              ← workspace（不放符号链接）
│   ├── SOUL.md, IDENTITY.md, ...    │   persona 文件
│   ├── TOOLS.md                     │   含共享文件夹使用指引
│   ├── memory/                      │   记忆文件
│   └── .git/                        │   版本控制
└── clawdhome_shared/                 ← 目录（内含两个符号链接）
    ├── private/ → /Users/Shared/ClawdHome/vaults/<username>/  ← 自己的专属文件夹
    └── public/  → /Users/Shared/ClawdHome/public/             ← 公共文件夹
```

**跨平台兼容性**：skill 和 agent 统一通过 `~/clawdhome_shared/private/` 和 `~/clawdhome_shared/public/` 访问，底层存储路径是平台实现细节，通过符号链接抹平差异：

| 平台 | 底层专属存储路径 | 底层公共存储路径 | 虾侧访问路径（统一） |
|------|-----------------|-----------------|---------------------|
| macOS | `/Users/Shared/ClawdHome/vaults/<username>/` | `/Users/Shared/ClawdHome/public/` | `~/clawdhome_shared/private/` / `~/clawdhome_shared/public/` |
| Linux | （规划中） | （规划中） | `~/clawdhome_shared/private/` / `~/clawdhome_shared/public/` |

虾无需知道自己的用户名，也看不到其他虾的目录。

**为什么不放在 workspace 内？** workspace 目录已包含大量内容（persona 文件、git 仓库、memory、skills 等），再加入符号链接会干扰 git 仓库状态和目录结构。独立放在 home 根目录更清晰。

### TOOLS.md 注入

虾通过 workspace 中的 `TOOLS.md` 了解共享文件夹的存在和使用规范。注入逻辑会检查 TOOLS.md 内容是否已包含 `clawdhome_shared` 关键词，未包含则将共享文件夹指引**追加**到文件末尾（不覆盖已有内容）。

| 场景 | 触发点 |
|------|--------|
| 新虾（初始化向导） | Step 2 写完 persona 文件后 |
| 新虾（角色市场领养） | 写完预设 persona 后 |
| 老虾（补全） | 用户进入侧边栏"文件共享"页面时 |

TOOLS.md 告知虾：
- `~/clawdhome_shared/private/` — 所有工作产出物优先存放在此
- `~/clawdhome_shared/public/` — 读取公共资源
- 敏感数据不进公共文件夹

### 已有虾的处理

对于功能上线前已存在的虾，无需数据迁移。用户进入"文件共享"页面时，后台自动为所有虾执行：
1. 检查 TOOLS.md 是否包含共享文件夹指引 → 未包含则追加并 git commit
2. 调用 `setupVault` → 创建权限组、vault/public 目录、符号链接（幂等）

全部静默执行，不阻塞 UI。

选择 `/Users/Shared/` 的理由：
- Apple 官方设计的跨用户共享目录
- Finder 侧栏可直接导航
- 不受 SIP（System Integrity Protection）限制
- Time Machine 自动备份

## 权限模型

### 公共文件夹

```
/Users/Shared/ClawdHome/public/
  owner: root
  group: clawdhome-all
  mode:  2775 (rwxrwsr-x)
         ^^^^
         setgid — 新建文件自动继承 clawdhome-all 组
```

- `clawdhome-all` 组成员：管理员 + 所有虾
- 所有成员可读写，新文件自动属于 `clawdhome-all` 组
- 虾之间可以通过公共文件夹交换文件

### 安全文件夹

```
/Users/Shared/ClawdHome/vaults/<shrimp-username>/
  owner: <shrimp-user>
  group: clawdhome-<shrimp-username>
  mode:  2770 (rwxrws---)
         ^^^^
         setgid — 新文件自动继承专属组
```

- `clawdhome-<shrimp-username>` 组成员：管理员 + 该虾
- 仅管理员和该虾可访问，其他虾完全不可见
- 适合存放该虾专属的敏感配置、私有数据

### 访问矩阵

| 角色 | 公共文件夹 | 自己的 Vault | 其他虾的 Vault |
|------|-----------|-------------|---------------|
| 管理员 | 读写 | 读写 | 读写 |
| Shrimp A | 读写 | 读写 | 无权限 |
| Shrimp B | 读写 | 读写 | 无权限 |

## Helper 操作

### 创建虾时（`setupVault`，幂等）

```bash
# 1. 创建专属权限组（先检查是否存在）
dseditgroup -o create clawdhome-<username>
dseditgroup -o edit -a <admin-user> -t user clawdhome-<username>
dseditgroup -o edit -a <username> -t user clawdhome-<username>

# 2. 加入全局共享组
dseditgroup -o create clawdhome-all
dseditgroup -o edit -a <username> -t user clawdhome-all

# 3. 创建安全文件夹
mkdir -p /Users/Shared/ClawdHome/vaults/<username>
chown <username>:clawdhome-<username> /Users/Shared/ClawdHome/vaults/<username>
chmod 2770 /Users/Shared/ClawdHome/vaults/<username>

# 4. 确保公共文件夹存在
mkdir -p /Users/Shared/ClawdHome/public
chown root:clawdhome-all /Users/Shared/ClawdHome/public
chmod 2775 /Users/Shared/ClawdHome/public

# 5. 在虾 home 下创建符号链接目录
mkdir -p ~<username>/clawdhome_shared
ln -s /Users/Shared/ClawdHome/vaults/<username> ~<username>/clawdhome_shared/private
ln -s /Users/Shared/ClawdHome/public ~<username>/clawdhome_shared/public
```

所有 `dseditgroup` 操作通过 `groupExists()` 和 `isUser(_:memberOf:)` 预检查实现幂等，避免依赖不稳定的 stderr 错误文案。

### 删除虾时（`teardownVault`）

```bash
# 1. 从全局组移除
dseditgroup -o edit -d <username> -t user clawdhome-all

# 2. 删除专属组
dseditgroup -o delete clawdhome-<username>

# 3. 安全文件夹归档
mv vaults/<username> vaults/<username>-archived-<ISO8601-timestamp>
```

## UI 集成

### 侧边栏入口

侧边栏"日常"区提供"文件共享"入口（`folder.badge.person.crop` 图标），点击进入 `VaultFilesView`。

### 卡片网格

以卡片形式展示：
- 每只虾一张卡片（虾名_专属），显示文件数量
- 公共文件夹卡片（通用全局知识库）
- 点击卡片 → vault 不存在时自动 `setupVault` → 在 Finder 中打开

### 虾详情页入口

`UserDetailView` 概览页中也提供"安全文件夹"和"公共文件夹"按钮，行为一致。

### Finder 集成（核心交互方式）

核心设计理念是**通过 Finder 而非应用内文件管理器**来处理文件：

- 用户可以拖拽文件到虾的 vault 中，虾的网关直接读取
- 虾的输出文件可以在 Finder 中直接预览、编辑、分享
- 支持 Quick Look、标签、评论、Spotlight 搜索等全部 macOS 原生能力
- 无需在 ClawdHome 中重新构建文件浏览/编辑/预览功能

## 安全考虑

1. **setgid bit** 确保新文件自动继承正确的组，避免手动 chown
2. **umask 配合** — 虾的 gateway 进程建议设置 `umask 002`，确保组成员可写
3. **符号链接限制** — `/Users/Shared/` 默认有 sticky bit，防止用户删除他人文件
4. **目录遍历** — vault 的 `0770` 权限阻止其他虾 ls 或 cd 进入
5. **缓存与模型分离** — 安装缓存和模型文件存放在 `/var/lib/clawdhome/`（root only），不在共享空间中，防止虾篡改
6. **幂等操作** — `setupVault` 可安全重复调用，组和目录操作均通过状态预检查避免重复创建错误
