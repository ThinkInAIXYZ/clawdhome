# ASR CPU 架构判定降级设计

## 目标

避免 `clawdhome ai asr` 在 Codex 等限制读取硬件 sysctl 的环境中，将 Apple Silicon 设备误报为 Intel Mac；同时继续阻止 Intel Mac 使用依赖 MLX 的 ASR 后端。

## 范围

只修改 CLI 的 ASR 平台前置检查与对应集成测试。不改变 ASR 工具、模型缓存、应用端能力提示或 Intel 平台的产品支持范围。

## 判定顺序

1. `CLAWDHOME_CPU_ARCH_OVERRIDE` 保持为测试专用最高优先级覆盖。
2. 调用 `sysctlbyname("hw.optional.arm64")`：成功时，以其值作为硬件事实。这样 Apple Silicon 主机上的 Rosetta `x86_64` 进程仍可被识别为 Apple Silicon。
3. 仅当该 sysctl 调用失败时，调用 `uname` 读取当前进程架构：`arm64` 或 `arm64e` 视为 Apple Silicon，`x86_64` 视为 Intel。
4. sysctl 与 `uname` 都无法取得有效结果时，返回“无法确认 CPU 架构”的独立错误，不使用 Intel 不支持的文案。

## 行为边界

- 原生 `arm64` 进程在受限沙箱中会通过 CPU 前置检查；后续工具启动或模型运行仍可能受沙箱策略限制，并应保留其真实错误。
- Rosetta 进程不能只凭 `uname == x86_64` 判为 Intel；在可访问 sysctl 的正常 macOS 环境中，第二层硬件检测会先确认 Apple Silicon。
- 原生 Intel 主机的 sysctl 值为 `0`，会继续得到既有的“不支持 Intel”错误。

## 测试

- 保留现有 `CLAWDHOME_CPU_ARCH_OVERRIDE=x86_64` 的 Intel 拒绝用例。
- 为架构探测提取可注入的最小辅助函数，使测试能覆盖：sysctl 成功、sysctl 失败后 `arm64` 回退、sysctl 失败后 `x86_64` 回退，以及两种探测均失败的未知状态。
- 运行 `make test-cli`，确保现有 ASR CLI 行为不回归。

