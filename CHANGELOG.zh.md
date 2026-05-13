# 更新记录

## [1.10.3] - 2026-05-14

# 修复

- 修复 Browser Tool / OpenCLI 安装流程对隔离用户 `npm` 的误判；当 `~/.brew/bin/npm` 符号链接缺失但 Node 仍在 `lib/nodejs` 或 `Cellar` 中可用时，不再错误提示“未找到 npm”。
- 为 OpenCLI 安装补充共享 `npm` 缓存权限自修复与失败后重试，降低 `/var/lib/clawdhome/cache/npm` 历史权限污染导致的 `EACCES` 安装失败。
- 将 `npm` 共享缓存权限异常纳入诊断中心权限检测，支持一键修复。


## [1.10.2] - 2026-05-14

# 新功能

- 权限提示卡片移至侧边栏底部显示，减少对主内容区的遮挡。
- 新增权限操作按钮自适应布局，窄宽度下可自动换行，提升可用性。
- 为权限相关文案补充中英文双语回退，降低因翻译缺失导致的混合语言显示。

# 改进与修复

- 优化权限状态摘要与按钮文案，信息更聚焦、操作路径更清晰。

<!--
参考提交（vv1.10.1..HEAD）：
  92ac5404 feat(permission-ui): move sidebar banner and improve bilingual fallbacks
  a54ef6df docs(release): polish v1.10.1 release notes
-->


## [1.10.1] - 2026-05-13

# 新功能

- feat(browser-permission): add host permission center and auto-enable opencli bridge
- feat(browser-account): reset data-only and add uninstall flow

# 改进与修复

- fix(browser-account): auto remediate OpenCLI extension disable state
- fix(browser-account): keep OpenCLI bridge loaded on every browser launch
- fix(browser-account): prevent chrome startup regression in pipe launcher
- fix(browser-account): load OpenCLI bridge via devtools pipe on Chrome stable
- fix(browser-account): repair bridge install path and force warmup when extension missing
- fix(release): 修复 publish 步骤顺序并集成 seed-platform
- Unify auto repair for Xcode toolchain in runtime installs
- Fix Hermes settings tabs and add runtime upgrade check UI

<!--
参考提交（vv1.10.0..HEAD）：
  a785cbdc fix(browser-account): auto remediate OpenCLI extension disable state
  3d03eff8 fix(browser-account): keep OpenCLI bridge loaded on every browser launch
  c3af923b feat(browser-permission): add host permission center and auto-enable opencli bridge
  625fc6b9 fix(browser-account): prevent chrome startup regression in pipe launcher
  fe42a0b3 fix(browser-account): load OpenCLI bridge via devtools pipe on Chrome stable
  ed26d27a fix(browser-account): repair bridge install path and force warmup when extension missing
  4c53b395 feat(browser-account): reset data-only and add uninstall flow
  81e7a650 fix(release): 修复 publish 步骤顺序并集成 seed-platform
  1f2561de Unify auto repair for Xcode toolchain in runtime installs
  7bf71c5e Fix Hermes settings tabs and add runtime upgrade check UI
-->


## [1.10.0] - 2026-05-10

### 新功能

- **浏览器账号桥接**：Agent 可借助你的浏览器账号直接访问外部服务，已登录的平台无需再次授权即可代你操作；OpenCLI 与 Hermes/OpenClaw 统一账号体系，登录态持久化、会话安全隔离。
- **Prompt 记忆 & 提示词库**：新增 Prompt 记忆浮层与全局提示词库，支持搜索、标签筛选与快速启动；内置一批高质量提示词模板。
- **Hermes × OpenClaw 双引擎完善**：独立安装界面、多标签终端切换、按 Profile 启停控制、批量操作与开机自启，两套引擎均可独立维护。
- **全局模型池重构**：模型池按 Provider 分组，支持实时搜索与动态拉取模型列表；支持自定义渠道、API 连通测试与拖拽调整降级优先级。
- **数据备份与恢复**：支持快照、增量备份与一键恢复。
- **内嵌多标签终端**：替代旧维护窗口，支持输出搜索、主题切换与标签克隆；输出完整保真不截断，后台自动清理。
- **安全文件共享（Vault）**：新增安全文件夹、公共文件夹与跨 Shrimp 共享空间；Agent 自动获得工具权限，权限守护按需修复。
- **文件管理升级**：支持文件与文件夹的复制、移动与多选批量删除；列排序、文本编辑窗口可自由调整大小。
- **设置面板焕新**：设置入口迁移至侧边栏，IM 绑定与 Agent 管理合并到同一 Tab，操作路径更短。
- **统一诊断中心**：环境、权限、配置、安全、Gateway、网络六项检测一键直达；支持分引擎诊断，新增健康探针、强制重启与断连提示。
- **ClawdHome CLI**：Docker 风格命令（`init` / `exec` 等）直达，消除 shrimp 子命令嵌套。
- **外观与升级体验**：新增系统 / 浅色 / 深色三态外观切换；升级动画、通知与快捷命令全面焕新。
- **Chrome 环境隔离**：ClawdHome 只管理自己专属的浏览器环境，不干扰日常使用的 Chrome。
- **多语言补完**：残留中文硬编码全面整理，英文翻译准确自然，不再出现占位文字。

### 改进与修复

- 修复 OpenCLI 冷启动失败、daemon 启动顺序错乱等问题，首次上手与重启体验更可靠
- 修复白屏、黑屏及嵌入控制界面显示异常等 WebView 相关问题
- 修复 IM 通道历史配置兼容性；配对完成后保留在配置面板，不再自动关闭
- 向导、详情页、绑定流程等多处残留中文替换为完整本地化文案
- 其他若干稳定性、兼容性与排版细节改进


## [1.9.0] - 2026-04-28

# 新功能
- 🐎 Hermes Agent 引擎支持：新增第二引擎 Hermes Agent，可与 OpenClaw 并存。支持独立安装界面、维护终端环境隔离及引擎感知诊断。
- 🦞 OpenClaw 多 Agent 管理：单个 openclaw 实例现支持创建与管理多个 Agent，每个 Agent 独立配置身份、模型与 IM 绑定。
- 角色市场支持多 Agent：单个 Agent 定义可支持多种IM绑定，一键召唤一个团队。
- 虾塘卡片全面重设计：虾塘卡片宽度自适应，实时显示 Agent（角色） 数量。
- 设置面板重构：设置项移至详情侧边栏独立Tab，IM 绑定与 Agent 管理统一呈现，操作路径更清晰。
- 自定义模型渠道：支持添加自定义 Provider 渠道，提供全局模板选择与 API 凭据连通性测试；Agent 模型配置改为下拉选择。
- 维护终端功能升级：新增输出内容搜索、主题切换、克隆标签页及限流保护。
- 文件管理升级：支持文件列表多选批量删除与列排序；文本编辑窗口支持自由拖拽调整大小。

# 改进与修复
- 优化 Gateway 开机自启稳定性，新增 bootstrap 失败自动重试机制。
- 创建或删除 Agent 后 Gateway 将自动重启，并自动定位到新建 Agent。
- 修复包含中文字符的名称在生成 Agent ID 时报错的问题。
- 修复访问共享 Vault 时的文件权限问题。
- 其他多项改进。


## [1.8.0] - 2026-04-12

### 新功能
- 安全文件夹：每只虾拥有专属安全空间，虾之间数据完全隔离，管理员通过 Finder 与虾交换文件
- 公共文件夹：所有虾共享的通用资源空间，适合存放提示词模板、参考数据等
- 频道绑定管理：可视化查询频道绑定状态，支持飞书/微信通道配置
- 频道配对优化：配对完成后留在配置面板继续调整选项，不再自动关闭窗口
- ClawdHome CLI：新增命令行工具，支持脚本化管理
- Gateway 离线配置：Gateway 未运行时配置修改自动回退到本地直写
- 升级体验：升级动画效果、卡片内升级入口、App 更新弹窗提醒

### 改进与修复
- XPC 终端输出改为 Data 传输，修复 ANSI/UTF-8 截断导致的乱码问题
- 提取 UserEnvContract 统一用户隔离环境变量，消除硬编码路径
- 版本号加载态与已加载态区分显示，避免闪烁
- Skills 安装异常但验证通过时显示恢复消息而非直接报错
- 备份列表查询增加诊断日志
- 环境验证修复，诊断中心深度检查增强，恢复进度浮窗
- 进程列表列宽优化


## [1.7.0] - 2026-04-09

### 新功能
- 分层备份与恢复系统：支持单个 Shrimp 备份和全局备份，可随时恢复到任意备份点
- 外观模式切换：支持跟随系统、浅色、深色三种模式循环切换
- 定时任务管理界面：可视化管理 Cron 定时任务，查看执行日志
- Skills 商店：浏览、安装、配置和管理 OpenClaw 技能
- 模型优先级管理：拖拽排序设置模型降级链
- 诊断中心：一站式检测环境、权限、配置、安全、Gateway、网络六大模块
- 配置热加载：修改配置后无需重启 Gateway 即可生效
- Ed25519 设备标识：增强 WebSocket 认证安全性
- Helper 健康面板：在设置页查看 Helper 运行状态，支持强制重启
- 记忆日志侧边栏：快速浏览和管理 Shrimp 记忆日志
- 初始化向导支持从自定义 Provider API 拉取模型列表

### 改进与修复
- XPC 通信全面增加超时保护，防止 Helper 无响应时界面挂起
- Watchdog 智能重试间隔，跳过未安装的用户
- Node.js 安装增加 SHA-256 完整性校验，防御 Zip Slip 路径穿越和 npm 注入
- 备份系统使用 rsync 替代双重 tar，显著提升大目录备份速度
- 备份目录迁移至用户可访问的位置
- 修复备份文件名中含连字符时用户名解析错误
- 修复 Cron/Skills API 因 scope 被清空导致的请求失败
- 修复 JSON 配置文件中斜杠被错误转义的问题
- Web UI 增加加载状态指示
- 进程列表移除冗余列，文件双击可直接编辑
- Helper 断连时显示浮动横幅提醒
- 升级过程中断连后自动恢复
- 管理员用户可查看可升级 Shrimp 数量


## [1.6.0] - 2026-04-03

### 新功能
- 新增基础环境工具链诊断与一键修复功能，快速排查和解决网关运行环境问题

### 改进与修复
- 优化应用更新检查及升级进度展示体验
- 修复 Shrimp 无法启动的问题
- 改进每只虾的基础环境隔离级别，并增加安装包缓存，加速启动多只虾


## [1.5.0] - 2026-04-02

### 新功能
- 新增 Shrimp 初始化配置向导，引导完成首次设置
- 应用更新检测移至后台守护进程，提升检测可靠性

### 改进与修复
- 优化详情窗口布局与概览页交互体验
- 完善版本升级提示文案
- 加强代理配置与权限校验的安全性
- 提升隔离环境与初始化流程的稳定性


## [1.4.0] - 2026-03-31

### 新功能
- 新增代理（Proxy）设置自动应用至托管用户
- 终端操作流程中新增身份验证辅助功能
- 角色中心新增更多预设角色，并支持中英双语

### 改进与修复
- 优化用户初始化引导流程，步骤更清晰
- 改进应用内更新及模型配置体验
- 安装包同时支持 Intel 与 Apple Silicon 双架构
- 默认启用公证签名，提升 macOS 安全信任


## [1.3.0] - 2026-03-29

### 新功能
- 新增角色市场，可快速浏览和采用预设角色配置
- 支持直接配置模型，无需依赖预设方案
- 全新引导设置体验，支持从已有 Shrimp 克隆配置
- 网关守护进程：自动监控并恢复异常退出的网关实例

### 改进与修复
- 优化新用户引导和用户管理流程的交互细节
- 改进应用内横幅通知的展示效果
- 增强用户目录权限的安全性处理
- 快速迁移功能文案优化


## [1.2.0] - 2026-03-26

### 新功能
- **微信引导入驻**：新增微信渠道的 Shrimp 初始化引导流程，帮助用户快速完成入驻配置。
- **详情页快速文件传输**：在 Shrimp 详情页中可直接上传/下载文件，无需跳转到文件管理器。
- **文件管理器终端直跳**：在维护窗口打开终端时，自动定位到当前浏览路径，省去手动 `cd` 步骤。
- **模型状态快捷命令**：新增模型运行状态的快速查看命令，方便在管理界面即时确认模型服务状态。

### 改进与修复
- **初始化向导稳定性提升**：修复了初始化流程中偶发的卡顿与异常跳转问题，向导体验更加流畅可靠。
- **Homebrew 权限自动修复**：当检测到 Homebrew 相关权限异常时，应用可自动尝试修复，减少手动排查步骤。
- **模型标签本地化**：备用模型的显示名称现已完整翻译为中文，不再出现英文原始标签。
- **日志输出优化**：改进了运行日志的输出行为，使日志内容更清晰、噪声更少。

---