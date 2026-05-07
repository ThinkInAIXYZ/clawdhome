# ClawdHome LLM Wiki Integration Architecture

本文档记录 ClawdHome 当前如何接入 LLM Wiki，重点面向后续重构：哪些模块负责什么、关键流程怎么走、哪些隐式耦合需要保留或拆开。

## 1. 当前目标

LLM Wiki 在 ClawdHome 里的定位不是一个独立桌面应用，而是 ClawdHome 内嵌的“笔记/知识库工作区”：

- 管理员在 ClawdHome 里打开“笔记”页面，看到内嵌的 LLM Wiki 前端。
- 所有虾的正式知识笔记统一进入一个共享 LLM Wiki 项目。
- 每只虾有自己的私有笔记目录，但通过共享项目里的软链被统一收录。
- 虾侧通过 workspace skill 访问同一个本地知识库接口，执行保存笔记、搜索知识库、读取文档等动作。
- ClawdHome App 负责启动和管理 LLM Wiki runtime。
- Privileged Helper 负责创建共享目录、修复权限、建立软链、安装 skill。

这套接入的核心思路是：

```text
ClawdHome App
  ├─ 内嵌 LLM Wiki 前端 WebView
  ├─ 管理 LLM Wiki runtime
  ├─ 提供 JS Bridge / Host Commands
  ├─ 读取和写入 app-state / 模型配置
  └─ 通过 Helper 修复共享项目和虾侧 skill

Privileged Helper
  ├─ 创建 /Users/Shared/ClawdHome/llmwiki/project
  ├─ 创建 /Users/Shared/ClawdHome/vaults/<user>/llmwiki-notes
  ├─ 建立 raw/sources/shrimps/<user> -> notes 软链
  ├─ 安装 ~/.openclaw/workspace/skills/clawdhome-llmwiki
  └─ 修复 Unix socket / runtime 目录权限

Embedded Runtime
  ├─ serve: 启动 TCP control server + Unix socket KB API + heartbeat socket
  └─ invoke: 执行部分 LLM Wiki 命令并通过 JSON stdin/stdout 返回

Shrimp Workspace Skill
  └─ Node 脚本通过 Unix socket 查询/写入知识库
```

## 2. 关键路径和固定命名

所有固定路径集中在 `Shared/LLMWikiModels.swift` 的 `LLMWikiPaths`：

| 名称 | 路径/值 | 用途 |
| --- | --- | --- |
| `sharedRoot` | `/Users/Shared/ClawdHome` | ClawdHome 共享根目录 |
| `sharedGroup` | `clawdhome-all` | 全局共享组 |
| `projectRoot` | `/Users/Shared/ClawdHome/llmwiki/project` | 单例 LLM Wiki 项目 |
| `runtimeRoot` | `/Users/Shared/ClawdHome/llmwiki/run` | runtime socket 和 metadata 目录 |
| `socketPath` | `/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-api.sock` | 主知识库 Unix socket |
| `heartbeatSocketPath` | `/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-heartbeat.sock` | 健康检查 Unix socket |
| `metadataPath` | `/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-api.json` | runtime 写出的 socket metadata |
| `shrimpsSourcesRoot` | `<projectRoot>/raw/sources/shrimps` | 所有虾笔记软链目录 |
| `notesPath(username)` | `/Users/Shared/ClawdHome/vaults/<username>/llmwiki-notes` | 每只虾真实笔记目录 |
| `notesEntryPath(username)` | `/Users/<username>/clawdhome_shared/private/llmwiki-notes` | 虾用户视角的笔记入口 |
| `projectSymlinkPath(username)` | `<projectRoot>/raw/sources/shrimps/<username>` | 共享项目中的虾笔记软链 |
| `workspaceSkillPath(username)` | `/Users/<username>/.openclaw/workspace/skills/clawdhome-llmwiki` | 虾侧 skill 安装位置 |
| `appStatePath(admin)` | `/Users/<admin>/Library/Application Support/ai.clawdhome.mac/EmbeddedLLMWiki/app-state.json` | ClawdHome 管理的 LLM Wiki app-state |

这些路径是当前实现的事实协议。重构时如果改路径，需要同步 App、Helper、runtime、skill 脚本和文档。

## 3. UI 入口

入口在 `ClawdHome/ContentView.swift`：

- 左侧导航 `NavDestination.notes` 显示为“笔记”。
- `NotesWorkspaceView` 内部有两个 tab：
  - `笔记`：显示 `WikiHostView`，即内嵌 LLM Wiki 前端。
  - `笔记状态`：显示 `NotesCenterView`，用于状态检查、配置、修复、启动 runtime。
- `WikiHostView` 内的 `openWikiSupport` 回调会切到 `笔记状态` tab。

当前页面结构：

```text
ContentView
  -> NotesWorkspaceView
       -> tab: 笔记
            -> WikiHostView
       -> tab: 笔记状态
            -> NotesCenterView
```

## 4. App 内嵌前端加载方式

内嵌前端由 `ClawdHome/Views/WikiHostView.swift` 管理。

### 4.1 自定义 Scheme

当前不用 `file://` 直接加载前端，而是两个自定义 scheme：

- `clawdhome-wiki://app/index.html`
  - 由 `WikiBundleSchemeHandler` 处理。
  - 只允许读取 app bundle 中的 `wiki/` 目录资源。
  - 会 canonicalize bundle root 和目标文件路径，防止越界读取。

- `clawdhome-file://local?path=<encoded path>`
  - 由 `WikiFileSchemeHandler` 处理。
  - 用于前端展示本地文件资源。
  - 读取前调用 `LocalWikiHostFS.validateReadableFilePath` 做范围校验。

### 4.2 WebView 缓存

`WikiHostWebViewCache` 缓存一个 `WKWebView` 和一个 `WikiHostCoordinator`：

- App 启动后会在 `ClawdHomeApp` 中预热 WebView。
- `WikiHostView` 打开时复用缓存，减少白屏和重复初始化。
- 配置变更时通过 `.llmWikiConfigDidChange` 通知重新加载。

### 4.3 `prepareWiki()` 启动前置检查

`WikiHostView.prepareWiki()` 是打开 Wiki 的关键入口，顺序如下：

1. 检查 app bundle 内是否存在 `wiki/index.html`。
2. 检查共享项目基础目录：
   - `projectRoot`
   - `projectRoot/wiki`
   - `projectRoot/raw/sources`
   - `shrimpsSourcesRoot`
3. 如果共享项目不完整，并且 Helper 已连接，调用 `helperClient.repairLlmWikiProject()`。
4. 如果修复后仍缺目录，显示 blocked 状态。
5. 加载 `LLMWikiAppStateStore`。
6. 通过 `LLMWikiStoreService.ensureProjectBinding()` 把共享项目写入 app-state 的 `lastProject` / `recentProjects`。
7. 调用 `LLMWikiRuntimeManager.ensureRunning()` 启动或接管 runtime。
8. 预加载 WebView。
9. 加载 `clawdhome-wiki://app/index.html`。

## 5. JS Bridge 协议

`WikiHostView` 在 `WKUserScript` 里注入 `window.ClawdHomeWiki`。

前端看到的 host 接口定义在 `EmbeddedLLMWiki/frontend/src/platform/host.ts`：

```ts
interface ClawdHomeWikiHost {
  invoke<T>(command: string, payload?: unknown): Promise<T>
  openDialog(options: HostDialogOptions): Promise<string | string[] | null>
  storeLoad(name: string): Promise<void>
  storeGet<T>(key: string): Promise<T | null>
  storeSet(key: string, value: unknown): Promise<void>
  convertFileSrc(path: string): string
  openWikiSupport(): Promise<void>
}
```

注入脚本还提供 `window.__CLAWDHOME_WIKI_BOOTSTRAP__`：

```json
{
  "projectPath": "/Users/Shared/ClawdHome/llmwiki/project",
  "projectName": "ClawdHome Wiki",
  "appStatePath": ".../EmbeddedLLMWiki/app-state.json",
  "locale": "<current locale>"
}
```

Bridge 消息由 `WikiHostCoordinator.userContentController` 接收，主要类型：

| type | 行为 |
| --- | --- |
| `invoke` | 转给 `LLMWikiHostCommandDispatcher.invoke(command,payload)` |
| `openDialog` | 打开 macOS 文件选择器，并授权选择到的外部路径 |
| `storeLoad` | 加载本地 app-state store |
| `storeGet` | 读取 app-state key |
| `storeSet` | 写入 app-state key |
| `openWikiSupport` | 切到“笔记状态” |

Bridge request 使用 `id` 匹配异步 Promise，Swift 侧完成后执行 `window.ClawdHomeWiki.__resolve(id, value)` 或 `__reject(id, error)`。

## 6. Host Command 分发

`ClawdHome/Services/LLMWikiHostCommandDispatcher.swift` 是前端命令进入宿主能力的分发层。

当前分为四类：

### 6.1 文件系统命令

由 `LocalWikiHostFS` 处理：

- `read_file`
- `write_file`
- `list_directory`
- `copy_file`
- `copy_directory`
- `preprocess_file`
- `delete_file`
- `find_related_wiki_pages`
- `create_directory`
- `list_source_documents`
- `create_project`
- `open_project`

### 6.2 Runtime / ingest 命令

由 `LLMWikiRuntimeManager` 处理：

- `clip_server_status`
- `take_pending_ingest_requests`
- 其他未知命令 fallback 到 `runtimeManager.invoke(command,payload)`

### 6.3 模型调用命令

`chat_completion` 由 `HostLLMBridge` 处理。

它不让前端直接掌握 ClawdHome 的模型池，而是由 Swift host 解析配置后发起请求。目前支持：

- `openai`
- `anthropic`
- `google`
- `ollama`
- `minimax`
- `custom`

### 6.4 全局模型配置桥接

由 `GlobalLLMConfigBridge` 和 `LLMWikiStoreService` 处理：

- `list_global_llm_options`
- `get_global_llm_selection`
- `save_global_llm_option`

它把 ClawdHome 全局模型池里的 provider/template 映射成 LLM Wiki 可理解的 LLM config，并保存到 LLM Wiki app-state。

## 7. 文件系统安全边界

这是重构时最容易出问题的地方。

当前 `LocalWikiHostFS` 的规则：

- 读取允许：
  - 共享项目根：`LLMWikiPaths.projectRoot`
  - 所有已注册的虾笔记真实目录：`/Users/Shared/ClawdHome/vaults/<username>/llmwiki-notes`
  - 用户通过 `openDialog` 明确选中过的外部路径
- 写入/删除/创建项目只允许：
  - 共享项目根
  - 已注册的虾笔记真实目录
- 路径会先通过 `standardizedFileURL`、`resolvingSymlinksInPath()`、最近存在祖先解析等逻辑 canonicalize。
- 管理的虾笔记根通过扫描 `shrimpsSourcesRoot` 下的软链得到，并且目标必须：
  - 以 `/Users/Shared/ClawdHome/vaults/` 开头
  - 以 `/llmwiki-notes` 结尾

这一层是防止 WebView / 前端依赖被攻破后任意读写管理员文件的主要保护。重构时不要把 `invoke` 直接透传到无边界的文件 API。

## 8. App State 和模型配置

`LLMWikiStoreService` 管理 LLM Wiki app-state。

关键行为：

- store 默认路径来自 `LLMWikiPaths.appStatePath(for: NSUserName())`。
- 兼容旧 bundle id：`com.llmwiki.app/app-state.json`。
- `ensureProjectBinding(projectPath:)` 写入：
  - `lastProject`
  - `recentProjects`
- `saveLLMConfig` 写入 `llmConfig`。
- `saveEmbeddingConfig` 写入 `embeddingConfig`。
- `LLMWikiLLMConfigSelectionStore` 额外用 `UserDefaults` 保存当前选择来自：
  - ClawdHome 全局模型池
  - 手动配置

模型池映射逻辑包括：

| ClawdHome provider | LLM Wiki provider | endpoint |
| --- | --- | --- |
| `openai` | `openai` | OpenAI 默认 |
| `anthropic` | `anthropic` | Anthropic 默认 |
| `google` | `google` | Gemini 默认 |
| `minimax` | `minimax` | MiniMax 默认 |
| `moonshot` | `custom` | `https://api.moonshot.cn/v1` |
| `openrouter` | `custom` | `https://openrouter.ai/api/v1` |
| `qiniu` | `custom` | `https://api.qnaigc.com/v1` |
| `zai` | `custom` | `https://open.bigmodel.cn/api/paas/v4` |
| `kimi-coding` | `anthropic` compatible | `https://api.kimi.com/coding` |
| `custom` | `custom` 或 `anthropic` compatible | 使用自定义 base URL |
| `ollama` | `ollama` | `http://localhost:11434` |

配置保存后，如果 runtime 正在运行，会重启 runtime 并发 `.llmWikiConfigDidChange` 通知刷新 WebView。

## 9. Runtime 管理

`ClawdHome/Services/LLMWikiRuntimeManager.swift` 负责管理 app bundle 内的 `llm-wiki-runtime`。

### 9.1 可执行文件位置

runtime 从 app bundle 里查找：

```text
EmbeddedLLMWiki/llm-wiki-runtime
```

源码对应 `EmbeddedLLMWiki/runtime`，构建脚本：

- `scripts/build-embedded-llmwiki-runtime.sh`
- `scripts/build-embedded-llmwiki-frontend.sh`

### 9.2 `ensureRunning()` 行为

`ensureRunning()` 的逻辑：

1. 如果已有当前 App 跟踪的 process 正在运行，继续。
2. 如果 Unix heartbeat socket 可达，认为已有 runtime 可接管。
3. 如果没有 process 且 socket 不健康，清理 stale socket。
4. 以 `serve` 参数启动 runtime。
5. 等待 heartbeat `/health` healthy，最多 40 次，每次 250ms。
6. 调用 `bindSharedProject()` 把 `projectRoot` 绑定到 runtime。

### 9.3 Runtime 环境变量

App 启动 runtime 时注入：

```text
LLM_WIKI_KB_SOCKET_PATH=/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-api.sock
LLM_WIKI_KB_HEARTBEAT_SOCKET_PATH=/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-heartbeat.sock
LLM_WIKI_KB_RUNTIME_GROUP=clawdhome-all
```

这些变量决定 runtime 的 Unix socket 路径和权限组。

### 9.4 两种 runtime 模式

`EmbeddedLLMWiki/runtime/src/main.rs` 支持：

- `serve`
  - 启动长期服务。
  - 内部启动 TCP control server、主知识库 Unix socket、heartbeat Unix socket。

- `invoke <command>`
  - 从 stdin 读取 JSON payload。
  - 执行命令后向 stdout 输出 JSON。
  - 主要作为命令兼容层，部分命令已经在 Swift host 中实现。

## 10. Runtime HTTP / Unix Socket API

`EmbeddedLLMWiki/runtime/src/clip_server.rs` 当前启动三类服务：

### 10.1 TCP control server

监听：

```text
http://127.0.0.1:19827
```

主要 endpoints：

- `GET /status`
- `GET /project`
- `POST /project`
- `GET /projects`
- `POST /projects`
- `GET /clips/pending`
- `POST /pending-ingest/take`
- `POST /clip`

在 Unix 平台上，知识库查询类 API 通过 TCP 会返回 disabled/forbidden，避免把知识库能力暴露在 TCP 上。

### 10.2 主知识库 Unix socket

路径：

```text
/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-api.sock
```

主要 endpoints：

- `GET /status`
- `GET /project`
- `POST /project`
- `POST /pending-ingest/take`
- `POST /knowledge-base/query`
- `POST /vector_stores/search`
- `POST /knowledge-base/document`
- `POST /knowledge-base/ingest`

ClawdHome App 的 `KnowledgeBaseSocketClient` 和虾侧 skill 都走这个 socket。

### 10.3 Heartbeat Unix socket

路径：

```text
/Users/Shared/ClawdHome/llmwiki/run/knowledge-base-heartbeat.sock
```

主要 endpoint：

- `GET /health`

App 用它判断 runtime 是否 ready。

## 11. Helper 负责的系统级工作

LLM Wiki 的目录、权限、软链、skill 需要 privileged helper，因为普通 App 进程不能可靠修改所有用户目录和共享组。

相关入口：

- `Shared/HelperProtocol.swift`
- `ClawdHome/Services/HelperClient.swift`
- `ClawdHomeHelper/HelperImpl+LlmWiki.swift`
- `ClawdHomeHelper/Operations/LlmWikiManager.swift`

Helper 暴露的操作：

| 操作 | 作用 |
| --- | --- |
| `setupLlmWikiNotes(username)` | 初始化某个用户的笔记目录和权限 |
| `repairLlmWikiProject()` | 修复共享项目骨架，并为所有已管理用户安装映射和 skill |
| `repairLlmWikiMapping(username)` | 修复某个用户的 notes 软链 |
| `repairLlmWikiRuntimePermissions()` | 修复 runtime 目录、socket、metadata 权限 |
| `repairBundledLlmWikiSkill(username)` | 重装某个用户的 workspace skill |
| `auditLlmWikiState()` | 返回全局状态 |
| `auditLlmWikiUserState(username)` | 返回指定用户状态 |

### 11.1 共享项目骨架

`ensureProjectSkeleton()` 创建：

```text
/Users/Shared/ClawdHome/llmwiki/project/
  .llm-wiki/
    chats/
    conversations.json
    ingest-cache.json
    ingest-queue.json
    review.json
  wiki/
    entities/
    concepts/
    sources/
    queries/
    comparisons/
    synthesis/
    index.md
    log.md
    overview.md
  raw/
    assets/
    sources/
      shrimps/
  schema.md
  purpose.md
```

目录一般使用 group sticky 模式 `2775`，文件使用 `664`，owner 是 console admin 或可解析到的主 admin，group 是 `clawdhome-all`。

### 11.2 每虾笔记目录

`setupLlmWikiNotes(username)` 做：

1. 调用 `VaultManager.setupVault(username:)` 确保 vault 基础目录存在。
2. 创建 per-shrimp group：`clawdhome-<username>`。
3. 把 admin 和该用户加入这个组。
4. 创建 `/Users/Shared/ClawdHome/vaults/<username>/llmwiki-notes`。
5. 设置 owner 为该用户，group 为 per-shrimp group。
6. 设置目录 mode `2770`。
7. 给该用户和 admin 添加目录写 ACL。

### 11.3 项目软链

`repairMapping(username)` 建立：

```text
/Users/Shared/ClawdHome/llmwiki/project/raw/sources/shrimps/<username>
  -> /Users/Shared/ClawdHome/vaults/<username>/llmwiki-notes
```

因此 LLM Wiki 共享项目看到的是 `raw/sources/shrimps/<username>`，实际文件落在每个用户的私有 vault 下。

## 12. 虾侧 Workspace Skill

Helper 在每个用户下安装：

```text
/Users/<username>/.openclaw/workspace/skills/clawdhome-llmwiki/
  SKILL.md
  scripts/
    search_knowledge_base.mjs
    get_knowledge_document.mjs
    save_note_to_kb.mjs
  references/
    note_writing_guide.md
```

同时会合并写入：

```text
/Users/<username>/.openclaw/workspace/TOOLS.md
```

写入的 guidance 告诉模型：

- 正式笔记优先写入 `~/clawdhome_shared/private/llmwiki-notes/`。
- 需要保存知识时使用 `save_note_to_kb`。
- 查询历史知识时使用 `search_knowledge_base`。
- 查看文档全文/相关内容时使用 `get_knowledge_document`。

### 12.1 保存笔记流程

虾侧执行：

```bash
cat <<'EOF' | node scripts/save_note_to_kb.mjs --title "标题" --type note
正文
EOF
```

脚本行为：

1. 读取 stdin 或 `--content`。
2. 生成 frontmatter。
3. 写入：
   ```text
   ~/clawdhome_shared/private/llmwiki-notes/<timestamp>--<slug>.md
   ```
4. 计算 project source path：
   ```text
   /Users/Shared/ClawdHome/llmwiki/project/raw/sources/shrimps/<username>/<filename>
   ```
5. 如果需要，复制文件到 project source path。
6. 通过 Unix socket 调用：
   ```text
   POST /knowledge-base/ingest
   ```
7. 返回保存路径、文件名、ingest trigger 结果。

### 12.2 搜索流程

虾侧执行：

```bash
node scripts/search_knowledge_base.mjs "查询词" 5
```

脚本通过主 Unix socket 调用：

```text
POST /vector_stores/search
```

payload 中固定带：

```json
{
  "projectPath": "/Users/Shared/ClawdHome/llmwiki/project",
  "query": "查询词",
  "max_num_results": 5
}
```

### 12.3 读取文档流程

虾侧执行：

```bash
node scripts/get_knowledge_document.mjs "<fileIdOrPath>"
```

脚本通过主 Unix socket 调用：

```text
POST /knowledge-base/document
```

## 13. 前端知识库查询流程

前端代码在 `EmbeddedLLMWiki/frontend/src/lib/knowledge-base.ts`。

`queryKnowledgeBase(projectPath, request, options)`：

1. 规范化 query。
2. 注入 retrieval mode / embedding config。
3. 调用：
   ```ts
   invoke("knowledge_base_query", { projectPath, request })
   ```
4. Swift dispatcher 未特殊处理该命令，fallback 到 `runtimeManager.invoke(...)`。
5. Rust runtime 的 `invoke("knowledge_base_query")` 调用 `commands::knowledge_base::knowledge_base_query`。

`getKnowledgeBaseDocument(projectPath, request)` 类似，调用：

```ts
invoke("knowledge_base_document", { projectPath, request })
```

## 14. “笔记状态”页

`ClawdHome/Views/NotesCenterView.swift` 和 `LLMWikiNotesCenterStore` 负责状态页。

状态页核心能力：

- 检查 runtime 是否安装、是否运行。
- 检查 shared project 是否完整。
- 检查 app-state 是否存在、当前绑定项目是否正确。
- 检查主 socket、heartbeat socket、metadata。
- 检查每个用户的 notes 目录、项目软链、workspace skill。
- 允许修复全局项目。
- 允许修复某个用户。
- 允许启动或重启 runtime。
- 允许绑定共享项目。
- 允许保存 LLM / embedding 配置。

`LLMWikiNotesCenterStore.refresh()` 的顺序：

1. `runtimeManager.isInstalled()`
2. `runtimeManager.clipServerStatus()`
3. `storeService.load()`
4. `helperClient.auditLlmWikiState()`
5. `kbClient.status()`
6. `kbClient.health()`
7. 遍历所有 `ManagedUser`，调用 `helperClient.auditLlmWikiUserState(username:)`
8. 如果用户已连接 gateway，则检查 skill store；否则 fallback 到文件存在性。

## 15. 端到端关键流程

### 15.1 首次打开“笔记”

```text
用户点击“笔记”
  -> ContentView 显示 NotesWorkspaceView
  -> 默认 tab = 笔记
  -> WikiHostView.task 执行 prepareWiki()
  -> 检查 bundle wiki/index.html
  -> 检查 shared project
  -> 如缺失，通过 Helper repairLlmWikiProject()
  -> 加载 app-state
  -> 绑定 projectRoot
  -> ensureRunning runtime
  -> 加载 clawdhome-wiki://app/index.html
  -> 前端通过 window.ClawdHomeWiki 调用 host 能力
```

### 15.2 修复某个用户的 LLM Wiki 能力

```text
用户在“笔记状态”点击修复用户
  -> NotesCenterView
  -> LLMWikiNotesCenterStore.repairUser(username)
  -> helperClient.setupLlmWikiNotes(username)
  -> helperClient.repairLlmWikiMapping(username)
  -> helperClient.repairBundledLlmWikiSkill(username)
  -> refresh 状态
```

### 15.3 虾保存笔记并进入知识库

```text
虾模型触发保存知识意图
  -> 使用 clawdhome-llmwiki skill
  -> save_note_to_kb.mjs 写入 ~/clawdhome_shared/private/llmwiki-notes
  -> 文件实际位于 /Users/Shared/ClawdHome/vaults/<user>/llmwiki-notes
  -> shared project 通过 raw/sources/shrimps/<user> 软链看到该文件
  -> 脚本 POST /knowledge-base/ingest
  -> runtime 记录 pending ingest / 触发知识库处理
```

### 15.4 虾查询知识库

```text
虾模型触发查询知识库意图
  -> 使用 clawdhome-llmwiki skill
  -> search_knowledge_base.mjs
  -> HTTP over Unix socket
  -> /vector_stores/search
  -> runtime 返回搜索结果
  -> 模型把结果总结给用户
```

### 15.5 前端执行文件操作

```text
LLM Wiki 前端调用 invoke("read_file", { path })
  -> window.ClawdHomeWiki.invoke
  -> WKScriptMessageHandler
  -> LLMWikiHostCommandDispatcher
  -> LocalWikiHostFS.validateReadablePath
  -> 读取文件并返回
```

写入/删除流程类似，但只允许进入项目根或已注册的虾笔记根。

### 15.6 保存模型配置

```text
用户在“笔记状态”保存配置
  -> LLMWikiNotesCenterStore.saveConfigs()
  -> LLMWikiStoreService.saveLLMConfig/saveEmbeddingConfig
  -> 如果 runtime running，则 restart runtime
  -> post .llmWikiConfigDidChange
  -> WikiHostView reload
```

## 16. 当前实现的主要耦合点

重构时建议重点处理这些耦合：

### 16.1 路径协议耦合

`LLMWikiPaths` 被 App、Helper、runtime 环境变量、skill 脚本、前端 bootstrap 间接共享。

风险：

- 任何路径改动都可能导致 UI、skill、runtime、权限修复其中一处断掉。

建议：

- 保留一个跨 target 的 `LLMWikiEnvironment` 或 `LLMWikiPathManifest`。
- Helper 和 App 都从同一个 schema 生成/读取。
- skill 脚本不要硬编码路径，改为读取一个安装时生成的 manifest。

### 16.2 App 同时承担 UI、host bridge、runtime supervisor

`WikiHostView` 目前做了：

- WebView 构造。
- JS bridge 注入。
- 页面加载状态。
- runtime 准备。
- shared project 修复触发。
- app-state 绑定。

建议拆分：

- `LLMWikiWebViewHost`
- `LLMWikiBridgeController`
- `LLMWikiBootstrapper`
- `LLMWikiRuntimeSupervisor`
- `LLMWikiProjectBindingService`

### 16.3 Swift host 和 Rust runtime 命令重复

部分文件系统命令在 Swift host 实现，Rust `invoke` 里也有命令分支。

当前实际行为：

- Swift dispatcher 明确处理的命令不会进 Rust runtime。
- 未识别命令 fallback 到 Rust runtime `invoke`。

风险：

- 两边安全边界可能不一致。
- 前端命令新增时容易走到未预期的 fallback。

建议：

- 明确命令所有权表。
- 对 fallback 做 allowlist，而不是所有未知命令都传给 runtime。
- Runtime 文件系统命令如果不再使用，应移除或限制在同样的 project scope 内。

### 16.4 TCP control server 与 Unix socket KB API 并存

Runtime 同时有：

- `127.0.0.1:19827` TCP control server
- 主 Unix socket KB API
- heartbeat Unix socket

当前 Unix 平台上，知识库查询类 TCP API 被禁用，但 `/project`、`/status` 等仍走 TCP。

建议：

- 重构时明确 TCP 只做本机控制面，知识库数据面只走 Unix socket。
- 如果可能，把 `/project` 绑定也迁移到 Unix socket，减少双通道状态同步。

### 16.5 Skill 安装内容由 Swift 字符串生成

`LlmWikiManager.skillSpec()` 当前用大段 Swift multiline string 生成 `SKILL.md` 和 Node 脚本。

风险：

- 可维护性差。
- 语法错误不容易被测试覆盖。
- 文案和脚本逻辑与源码分离困难。

建议：

- 把 skill 模板放入资源目录。
- 安装时只做变量替换。
- 给生成后的脚本加独立单元测试或 smoke test。

## 17. 重构时必须保留的行为

以下行为是当前产品能力依赖点，重构不能无意破坏：

- “笔记”tab 能直接打开内嵌 LLM Wiki。
- “笔记状态”tab 能修复项目、用户、runtime、skill。
- 打开 Wiki 前会自动修复共享项目骨架。
- Runtime 健康检查走 heartbeat socket。
- 知识库查询走 Unix socket，不暴露到局域网。
- `clawdhome-file` 读取必须做路径范围校验。
- WebView `invoke` 不允许任意读写管理员全盘文件。
- 每只虾的正式笔记入口仍是 `~/clawdhome_shared/private/llmwiki-notes/`。
- 共享项目仍能通过 `raw/sources/shrimps/<username>` 看到每只虾笔记。
- 虾侧 `clawdhome-llmwiki` skill 仍能保存、搜索、读取文档。
- 全局模型池可映射到 LLM Wiki 配置。
- 保存配置后运行中的 runtime 会重启或刷新配置。

## 18. 建议的重构目标分层

建议重构后形成这些边界：

```text
LLMWikiCore
  ├─ PathManifest
  ├─ ProjectManifest
  ├─ SocketManifest
  └─ CommandSchema

LLMWikiHostApp
  ├─ Notes UI
  ├─ WebView Host
  ├─ Bridge Controller
  ├─ Runtime Supervisor
  ├─ App State Store
  └─ Model Config Bridge

LLMWikiHelper
  ├─ Directory Provisioner
  ├─ Permission Repair
  ├─ User Mapping Repair
  ├─ Skill Installer
  └─ Audit Provider

LLMWikiRuntime
  ├─ Unix Socket KB API
  ├─ Heartbeat API
  ├─ Project Binding
  ├─ Ingest Queue
  └─ Query/Document APIs

LLMWikiSkill
  ├─ Manifest
  ├─ Save Note
  ├─ Search KB
  └─ Get Document
```

拆分后的依赖方向应该是：

```text
UI -> App Services -> Shared Manifest
Helper -> Shared Manifest
Runtime -> Runtime Manifest / env
Skill -> Installed Manifest / socket path
Frontend -> Host Bridge Contract
```

不要让前端直接知道 Helper，不要让 Helper 知道 WebView，不要让 Skill 硬编码过多 App 内部路径。

## 19. 推荐新增的测试清单

当前这块更需要端到端和权限测试：

### 19.1 App 侧

- 打开“笔记”时，如果 shared project 缺失，会调用 helper repair。
- `WikiHostView.prepareWiki()` 成功后 runtime healthy。
- `.llmWikiConfigDidChange` 会 reload WebView。
- `LocalWikiHostFS` 拒绝 `/etc/passwd`、`~/Library` 等越界路径。
- `LocalWikiHostFS` 允许 project root 和已注册 notes root。

### 19.2 Helper 侧

- `repairProject()` 幂等。
- `repairMapping(username)` 幂等，且修复错误软链。
- `installBundledSkill(username)` 幂等，且不会破坏已有 `TOOLS.md` 其它内容。
- `auditGlobalState()` 能正确报告目录/权限/socket metadata。
- `auditUserState(username)` 能正确报告 notes、symlink、skill。

### 19.3 Runtime 侧

- `serve` 能创建主 socket、heartbeat socket、metadata。
- heartbeat `/health` ready。
- TCP 知识库查询类 endpoint 在 macOS/Unix 返回禁用。
- Unix socket `/vector_stores/search`、`/knowledge-base/document`、`/knowledge-base/ingest` 可用。

### 19.4 Skill 侧

- `save_note_to_kb.mjs` 能写入用户 notes 目录。
- 保存后能通过 project symlink 看到文件。
- `search_knowledge_base.mjs` 能连上 socket。
- `get_knowledge_document.mjs` 能用 file id 或 path 获取文档。

## 20. 一图流

```text
                         ┌────────────────────────────┐
                         │        ClawdHome App        │
                         │                            │
                         │  NotesWorkspaceView         │
                         │   ├─ WikiHostView           │
                         │   └─ NotesCenterView        │
                         │                            │
                         │  WikiHostCoordinator        │
                         │   └─ ClawdHomeWiki Bridge   │
                         │                            │
                         │  LLMWikiRuntimeManager      │
                         │  LLMWikiStoreService        │
                         │  LLMWikiHostDispatcher      │
                         └─────────────┬──────────────┘
                                       │ XPC
                                       ▼
                         ┌────────────────────────────┐
                         │    Privileged Helper        │
                         │                            │
                         │  LlmWikiManager             │
                         │   ├─ project skeleton       │
                         │   ├─ notes permissions      │
                         │   ├─ shrimp symlinks        │
                         │   ├─ runtime permissions    │
                         │   └─ workspace skill        │
                         └─────────────┬──────────────┘
                                       │ filesystem
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ /Users/Shared/ClawdHome/llmwiki/project                                     │
│   ├─ wiki/                                                                  │
│   └─ raw/sources/shrimps/<username> -> /Users/Shared/.../llmwiki-notes      │
└─────────────────────────────────────────────────────────────────────────────┘
                                       ▲
                                       │ Unix socket
                                       ▼
                         ┌────────────────────────────┐
                         │   llm-wiki-runtime serve   │
                         │                            │
                         │  127.0.0.1:19827 control   │
                         │  knowledge-base-api.sock    │
                         │  heartbeat.sock             │
                         └─────────────┬──────────────┘
                                       ▲
                                       │ Unix socket
                                       │
                         ┌─────────────┴──────────────┐
                         │       Shrimp Workspace      │
                         │                            │
                         │ clawdhome-llmwiki skill     │
                         │  ├─ save_note_to_kb.mjs     │
                         │  ├─ search_knowledge...mjs  │
                         │  └─ get_knowledge...mjs     │
                         └────────────────────────────┘
```
