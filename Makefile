# Makefile — ClawdHome 开发工具
# 用法：make <target>

PROJECT    := ClawdHome.xcodeproj
SCHEME_APP := ClawdHome
SCHEME_HLP := ClawdHomeHelper
INFO_PLIST := ClawdHome/Info.plist
PLIST      := /usr/libexec/PlistBuddy
BUILD_COUNTER_FILE := .build-version
INITIAL_BUILD_NUMBER := 500
BUILD_COUNTER_SCRIPT := scripts/build_counter.sh

APPLE_TEAM_ID ?= Y7P5QLKLYG
APP_SIGN_IDENTITY ?= Developer ID Application: Mengjun Xie (Y7P5QLKLYG)
PKG_SIGN_IDENTITY ?= Developer ID Installer: Mengjun Xie (Y7P5QLKLYG)
NOTARY_PROFILE ?= clawdhome-release
SIGN_APP ?= false
SIGN_PKG ?= false
NOTARIZE ?= true
BUILD_ARCHS ?= arm64

.PHONY: help bump-build build build-cli build-helper build-release install-helper uninstall-helper doctor-mode switch-release-test capture-incident pkg pkg-skip-build pkg-signed pkg-release sign-pkg notarize-pkg release release-dry-run release-notes-draft changelog version-next install-hooks clean version i18n i18n-check test-release-scripts test-all test-fresh test-init test-checkpoint test-reset test-deploy test-clean run-cli test-cli test-cli-onboard-env test-cli-onboard-help test-cli-onboard test-cli-onboard-step test-cli-onboard-clean

WEBSITE_DIR ?= ../clawdhome_website

help:
	@echo "可用目标："
	@echo "  build            Debug 构建（构建时自动递增本地 Build 号）"
	@echo "  build-cli        Debug 构建 CLI（仅 CLI，不含 App/Helper）"
	@echo "  run-cli          构建并运行 CLI（传参: make run-cli ARGS='shrimp list'）"
	@echo "  test-cli         构建并运行 CLI 集成测试"
	@echo "  test-cli-onboard-env   初始化本地测试配置文件（若不存在）"
	@echo "  test-cli-onboard-help  显示初始化测试控制台帮助（full/step）"
	@echo "  test-cli-onboard       跑 CLI 初始化全流程（支持扫码绑定/chat 验证）"
	@echo "  test-cli-onboard-step  跑单步骤（示例: make test-cli-onboard-step STEP=bind-weixin）"
	@echo "  test-cli-onboard-clean 清理测试用户（需要 ADMIN_PW）"
	@echo "  build-helper     Debug 构建 Helper"
	@echo "  build-release    Release 归档构建（构建时自动递增本地 Build 号）"
	@echo "  bump-build       预览下一次构建将使用的 Build 号"
	@echo "  version          显示当前语义化版本、当前 Build 号和当前 tag"
	@echo "  version-next     预览下一个语义化版本号"
	@echo "  changelog        预览基于 git log 自动生成的发布草稿"
	@echo "  release-notes-draft  用 claude -p 生成中英文发布说明草稿并打开"
	@echo "  install-helper   安装开发 Helper 到系统（dev label，需要 sudo）"
	@echo "  uninstall-helper 卸载开发 Helper（dev label，需要 sudo）"
	@echo "  doctor-mode      诊断当前机器处于开发/发布/混合哪种模式"
	@echo "  switch-release-test  切换到发布包验收模式（清理残留并安装 dist 最新 pkg）"
	@echo "  capture-incident 现场取证（建议 sudo），输出 /tmp/clawdhome-incident-*.tgz"
	@echo "  pkg              开发用快速打包（默认不签名）"
	@echo "  pkg-intel        打包 Intel (x86_64) 安装包"
	@echo "  pkg-universal    打包 Universal (arm64 + x86_64) 安装包"
	@echo "  pkg-skip-build   跳过构建直接打开发包"
	@echo "  pkg-signed       生成已签名未公证安装包（发布前本地验收推荐）"
	@echo "  notarize-pkg     生成已签名且已公证安装包（读取 NOTARY_PROFILE / CLAWDHOME_NOTARY_PROFILE）"
	@echo "  QUIET_XCODE=false 可显示完整 xcodebuild 输出（默认静默并写入 build/logs/）"
	@echo "  release          正式发布：更新 changelog + tag + 签名 pkg + 默认公证 + GitHub Release（可用 NOTARIZE=false 关闭）"
	@echo "  release-dry-run  预览正式发布流程（不执行）"
	@echo "  test-release-scripts  校验 release/changelog 脚本"
	@echo "  install-hooks    安装 git commit-msg / pre-commit hooks"
	@echo "  run-release      直接运行 build/export 里的 Release 包（无需安装）"
	@echo "  install-pkg      安装最新 pkg 到 /Applications（需要 sudo）"
	@echo "  log-helper       实时跟踪 Helper 日志（/tmp/clawdhome-helper.log）"
	@echo "  log-helper-dev   实时跟踪开发 Helper 日志（/tmp/clawdhome-helper-dev.log）"
	@echo "  log-app          实时跟踪 App 系统日志（os_log）"
	@echo "  i18n             运行 Stable.xcstrings 本地化检查"
	@echo "  i18n-check       本地化 CI 检查（未本地化/缺失翻译/占位符一致性）"
	@echo "  clean            清理 build/ dist/ 目录"
	@echo ""
	@echo "── 自动化测试 ──"
	@echo "  test-init        【仅需一次】创建底座并建立环境快照"
	@echo "  test-checkpoint  从底座克隆快照机"
	@echo "  test-reset       从快照秒级重置纯净环境"
	@echo "  test-deploy      启动测试实例、推包、安装并执行验证"
	@echo "  test-all         一键流程：重置 -> 部署"
	@echo "  test-fresh       【最常用】make pkg + 完整测试（自动用 dist/ 最新包）"
	@echo "  test-clean       深度清理所有测试相关虚拟机"

# ── 版本管理 ──────────────────────────────────────────────────────────────────

version:
	@V=$$($(PLIST) -c "Print CFBundleShortVersionString" $(INFO_PLIST)); \
	 B=$$(BUILD_COUNTER_FILE="$(BUILD_COUNTER_FILE)" INITIAL_BUILD_NUMBER="$(INITIAL_BUILD_NUMBER)" bash "$(BUILD_COUNTER_SCRIPT)" current); \
	 TAG=$$(bash scripts/semver.sh --current 2>/dev/null || echo "无 tag"); \
	 NEXT=$$(bash scripts/semver.sh 2>/dev/null || echo "无法计算"); \
	 echo "Info.plist 版本：$$V"; \
	 echo "当前 Build：$$B"; \
	 echo "当前 tag：$$TAG"; \
	 echo "下一发布版本：$$NEXT"

version-next:
	@bash scripts/semver.sh

changelog:
	@bash scripts/changelog.sh --stdout

test-release-scripts:
	@bash tests/release_scripts_test.sh

bump-build:
	@B=$$(BUILD_COUNTER_FILE="$(BUILD_COUNTER_FILE)" INITIAL_BUILD_NUMBER="$(INITIAL_BUILD_NUMBER)" bash "$(BUILD_COUNTER_SCRIPT)" current); \
	 NEXT=$$(BUILD_COUNTER_FILE="$(BUILD_COUNTER_FILE)" INITIAL_BUILD_NUMBER="$(INITIAL_BUILD_NUMBER)" bash "$(BUILD_COUNTER_SCRIPT)" next-preview); \
	 echo "Build 号由本地计数器自动递增（当前：$${B}，下次构建：$${NEXT}）"

# ── 构建 ──────────────────────────────────────────────────────────────────────

build: bump-build
	@BUILD_NO=$$(BUILD_COUNTER_FILE="$(BUILD_COUNTER_FILE)" INITIAL_BUILD_NUMBER="$(INITIAL_BUILD_NUMBER)" bash "$(BUILD_COUNTER_SCRIPT)" reserve); \
	MARKETING_VERSION=$$(bash scripts/semver.sh 2>/dev/null || $(PLIST) -c "Print CFBundleShortVersionString" $(INFO_PLIST)); \
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-destination "platform=macOS" \
		-configuration Debug \
		CLAWDHOME_MARKETING_VERSION_OVERRIDE="$$MARKETING_VERSION" \
		CLAWDHOME_BUILD_NUMBER_OVERRIDE="$$BUILD_NO" \
		MARKETING_VERSION="$$MARKETING_VERSION" \
		CURRENT_PROJECT_VERSION="$$BUILD_NO" \
		INFOPLIST_KEY_CFBundleShortVersionString="$$MARKETING_VERSION" \
		INFOPLIST_KEY_CFBundleVersion="$$BUILD_NO" \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; \
	xcodebuild \
		-project $(PROJECT) \
		-scheme ClawdHomeCLI \
		-destination "platform=macOS" \
		-configuration Debug \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

build-cli:
	xcodebuild \
		-project $(PROJECT) \
		-scheme ClawdHomeCLI \
		-destination "platform=macOS" \
		-configuration Debug \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# 构建后直接运行 CLI，支持传参：make run-cli ARGS="shrimp list --json"
run-cli: build-cli
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	echo "→ $$CLI $(ARGS)"; \
	"$$CLI" $(ARGS)

# 构建后运行集成测试
test-cli: build-cli
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	bash scripts/test-cli.sh "$$CLI"

# CLI 初始化测试控制台（支持 full/step）
test-cli-onboard-env:
	@if [ -f scripts/test_cli_init.local.env ]; then \
		echo "✅ scripts/test_cli_init.local.env 已存在"; \
	else \
		cp scripts/test_cli_init.local.env.example scripts/test_cli_init.local.env; \
		echo "✅ 已创建 scripts/test_cli_init.local.env（请填写 ADMIN_PW 等本地参数）"; \
	fi

test-cli-onboard-help: build-cli
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	bash scripts/test_cli_init_ctl.sh help "$$CLI"

test-cli-onboard: build-cli
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	bash scripts/test_cli_init_ctl.sh full "$$CLI"

test-cli-onboard-step: build-cli
	@[ -n "$(STEP)" ] || (echo "❌ 需要 STEP 参数，例如: make test-cli-onboard-step STEP=bind-feishu"; exit 1)
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	bash scripts/test_cli_init_ctl.sh "$(STEP)" "$$CLI"

test-cli-onboard-clean: build-cli
	@CLI=$$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1); \
	[ -n "$$CLI" ] || (echo "❌ 未找到 CLI 二进制"; exit 1); \
	bash scripts/test_cli_init_ctl.sh clean "$$CLI"

build-helper: bump-build
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME_HLP) \
		-destination "platform=macOS" \
		-configuration Debug \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

build-release: bump-build
	@BUILD_NO=$$(BUILD_COUNTER_FILE="$(BUILD_COUNTER_FILE)" INITIAL_BUILD_NUMBER="$(INITIAL_BUILD_NUMBER)" bash "$(BUILD_COUNTER_SCRIPT)" reserve); \
	MARKETING_VERSION=$$(bash scripts/semver.sh 2>/dev/null || $(PLIST) -c "Print CFBundleShortVersionString" $(INFO_PLIST)); \
	xcodebuild archive \
		-project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-archivePath build/ClawdHome.xcarchive \
		CLAWDHOME_MARKETING_VERSION_OVERRIDE="$$MARKETING_VERSION" \
		CLAWDHOME_BUILD_NUMBER_OVERRIDE="$$BUILD_NO" \
		MARKETING_VERSION="$$MARKETING_VERSION" \
		CURRENT_PROJECT_VERSION="$$BUILD_NO" \
		INFOPLIST_KEY_CFBundleShortVersionString="$$MARKETING_VERSION" \
		INFOPLIST_KEY_CFBundleVersion="$$BUILD_NO" \
		ARCHS="$(BUILD_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO && \
	echo "构建 ClawdHomeCLI..." && \
	xcodebuild \
		-project $(PROJECT) \
		-scheme ClawdHomeCLI \
		-configuration Release \
		-destination "generic/platform=macOS" \
		CLAWDHOME_MARKETING_VERSION_OVERRIDE="$$MARKETING_VERSION" \
		CLAWDHOME_BUILD_NUMBER_OVERRIDE="$$BUILD_NO" \
		ARCHS="$(BUILD_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO \
		build

# ── 安装 / 卸载 ───────────────────────────────────────────────────────────────

install-helper:
	sudo bash scripts/install-helper-dev.sh install

uninstall-helper:
	sudo bash scripts/install-helper-dev.sh uninstall

doctor-mode:
	bash scripts/doctor-helper-mode.sh

switch-release-test:
	@if [ -n "$(PKG)" ]; then \
		bash scripts/switch-release-test.sh "$(PKG)"; \
	else \
		bash scripts/switch-release-test.sh; \
	fi

capture-incident:
	bash scripts/capture-helper-incident.sh

# ── 打包 ──────────────────────────────────────────────────────────────────────

pkg: bump-build
	bash scripts/build-pkg.sh --no-sync-api-version
	@open dist/

pkg-intel: bump-build
	PKG_ARCHS=x86_64 bash scripts/build-pkg.sh --no-sync-api-version
	@open dist/

pkg-universal: bump-build
	PKG_ARCHS="arm64 x86_64" bash scripts/build-pkg.sh --no-sync-api-version
	@open dist/

pkg-skip-build:
	bash scripts/build-pkg.sh --skip-build --no-sync-api-version
	@open dist/

pkg-signed: bump-build
	SIGN_APP=true \
	SIGN_PKG=true \
	NOTARIZE=false \
	APPLE_TEAM_ID="$(APPLE_TEAM_ID)" \
	APP_SIGN_IDENTITY="$(APP_SIGN_IDENTITY)" \
	PKG_SIGN_IDENTITY="$(PKG_SIGN_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	bash scripts/build-pkg.sh --no-sync-api-version
	@open dist/

pkg-release: pkg-signed

sign-pkg: pkg-signed

notarize-pkg: bump-build
	@[ -n "$(NOTARY_PROFILE)" ] || (echo "❌ 请提供 NOTARY_PROFILE=<keychain-profile>"; exit 1)
	SIGN_APP=true \
	SIGN_PKG=true \
	NOTARIZE=true \
	APPLE_TEAM_ID="$(APPLE_TEAM_ID)" \
	APP_SIGN_IDENTITY="$(APP_SIGN_IDENTITY)" \
	PKG_SIGN_IDENTITY="$(PKG_SIGN_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	bash scripts/build-pkg.sh --no-sync-api-version
	@open dist/

release:
	SIGN_APP=true \
	SIGN_PKG=true \
	NOTARIZE=$(NOTARIZE) \
	APPLE_TEAM_ID="$(APPLE_TEAM_ID)" \
	APP_SIGN_IDENTITY="$(APP_SIGN_IDENTITY)" \
	PKG_SIGN_IDENTITY="$(PKG_SIGN_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	bash scripts/release.sh

release-dry-run:
	SIGN_APP=true \
	SIGN_PKG=true \
	NOTARIZE=$(NOTARIZE) \
	APPLE_TEAM_ID="$(APPLE_TEAM_ID)" \
	APP_SIGN_IDENTITY="$(APP_SIGN_IDENTITY)" \
	PKG_SIGN_IDENTITY="$(PKG_SIGN_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	bash scripts/release.sh --dry-run

release-notes-draft:
	bash scripts/release_notes_draft.sh

# ── 运行 ──────────────────────────────────────────────────────────────────────

# 直接运行 build/export 里的 Release app（无需安装 pkg）
run-release:
	@[ -d build/export/ClawdHome.app ] || (echo "❌ 先运行 make pkg"; exit 1)
	@open build/export/ClawdHome.app

# 安装最新 pkg 到系统（需要密码）
install-pkg:
	@PKG=$$(ls -t dist/*.pkg 2>/dev/null | head -1); \
	[ -n "$$PKG" ] || (echo "❌ 先运行 make pkg"; exit 1); \
	echo "安装 $$PKG ..."; \
	sudo installer -pkg "$$PKG" -target /

# ── 日志 ──────────────────────────────────────────────────────────────────────

log-helper:
	tail -f /tmp/clawdhome-helper.log

log-helper-dev:
	tail -f /tmp/clawdhome-helper-dev.log

log-app:
	log stream --predicate 'subsystem == "ai.clawdhome.mac"' --level debug

# ── 清理 ──────────────────────────────────────────────────────────────────────

clean:
	rm -rf build/ dist/
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_APP) clean -quiet

# ── Git Hooks ────────────────────────────────────────────────────────────────

install-hooks:
	@cp scripts/hooks/commit-msg .git/hooks/commit-msg
	@cp scripts/hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/commit-msg
	@chmod +x .git/hooks/pre-commit
	@echo "✅ git hooks 已安装（commit-msg, pre-commit）"

# ── i18n ──────────────────────────────────────────────────────────────────────

i18n:
	$(MAKE) i18n-check

i18n-check:
	scripts/i18n_check_untranslated.py
	scripts/i18n_ci_check.py
	scripts/i18n_forbid_legacy_t.py

# ==============================================================================
# 自动化测试环境模块 (带 test- 前缀)
# ==============================================================================

# --- 测试变量配置 ---
# TEST_IPSW: lume create 使用的 macOS 恢复镜像
#   latest          — 自动下载最新支持版本（推荐）
#   /path/to/*.ipsw — 本地 IPSW 文件路径
# lume 支持的版本示例（通过 'lume images' 查看完整列表）：
#   macOS Sequoia 15.x  → 下载地址见 Apple 开发者门户
#   macOS Sonoma  14.x  → 同上
#   macOS Ventura 13.x  → 同上
TEST_IPSW         ?= latest
TEST_BASE_VM      := test-base-image            # 永不直接修改的"底包"
TEST_SNAPSHOT_VM  := test-snapshot-ready        # 预配置好的快照
TEST_RUN_VM       := test-active-instance       # 真正跑测试的临时实例

# TEST_PKG_PATH: 默认自动取 dist/ 下最新的 pkg（make pkg 产物）
# 也可以手动指定：make test-deploy TEST_PKG_PATH=dist/ClawdHome-1.2.0.pkg
TEST_PKG_PATH     ?= $(shell ls -t dist/ClawdHome-*.pkg 2>/dev/null | head -1)

TEST_CPU          ?= 4
TEST_MEM          ?= 8

APP_NAME_FOR_TEST := ClawdHome
HELPER_LABEL      := ai.clawdhome.mac.helper

# --- 核心指令 ---

# 一键总入口：重置 -> 部署
test-all: test-reset test-deploy
	@echo "✅ 测试流程执行完毕。"

# 【联动构建】先 make pkg 生成最新包，再完整测试（最常用）
test-fresh: pkg test-all
	@echo "✅ 构建 + 测试流程执行完毕（包来自 dist/）。"

# 1. 【仅需执行一次】初始化底包并建立快照
test-init:
	@echo "🏗️  正在创建测试底座..."
	@lume ls | grep -q "$(TEST_BASE_VM)" || \
		lume create $(TEST_BASE_VM) --ipsw $(TEST_IPSW) --cpu $(TEST_CPU) --memory $(TEST_MEM)
	@echo "🚀 启动底座以进行预配置..."
	@lume run $(TEST_BASE_VM) --no-display > /dev/null 2>&1 &
	@until lume exec $(TEST_BASE_VM) true > /dev/null 2>&1; do sleep 3; done
	@echo "🛠️  正在注入基础测试工具（如需要）..."
	@# 示例：lume exec $(TEST_BASE_VM) "brew install some-tool"
	@lume stop $(TEST_BASE_VM)
	@echo "✅ 底座初始化完成。"
	@$(MAKE) test-checkpoint

# 2. 【建立快照】从底座克隆出一个快照机
test-checkpoint:
	@echo "📸 正在建立环境快照..."
	@lume stop $(TEST_SNAPSHOT_VM) > /dev/null 2>&1 || true
	@lume delete $(TEST_SNAPSHOT_VM) > /dev/null 2>&1 || true
	lume clone $(TEST_BASE_VM) $(TEST_SNAPSHOT_VM)
	@echo "✅ 快照点已就绪: $(TEST_SNAPSHOT_VM)"

# 3. 【秒级重置】删除旧的测试机，从快照瞬间克隆新的
test-reset:
	@echo "🔄 正在从快照重置纯净环境..."
	@lume stop $(TEST_RUN_VM) > /dev/null 2>&1 || true
	@lume delete $(TEST_RUN_VM) > /dev/null 2>&1 || true
	@lume ls | grep -q "$(TEST_SNAPSHOT_VM)" || $(MAKE) test-init
	lume clone $(TEST_SNAPSHOT_VM) $(TEST_RUN_VM)
	@echo "✅ 环境已重置为纯净状态。"

# 4. 【部署与运行】启动、传包、安装并验证
test-deploy:
	@[ -n "$(TEST_PKG_PATH)" ] || (echo "❌ dist/ 下未找到 pkg，请先运行 make pkg"; exit 1)
	@echo "🚀 启动测试实例..."
	@lume run $(TEST_RUN_VM) --no-display > /dev/null 2>&1 &
	@until lume exec $(TEST_RUN_VM) true > /dev/null 2>&1; do sleep 2; done
	@echo "📦 正在推送并安装待测包: $(TEST_PKG_PATH)"
	lume cp $(TEST_PKG_PATH) $(TEST_RUN_VM):/tmp/test.pkg
	lume exec $(TEST_RUN_VM) "sudo installer -pkg /tmp/test.pkg -target /"
	@echo "🧪 开始执行自动化验证..."
	@echo "  → 验证 app 安装..."
	@lume exec $(TEST_RUN_VM) "[ -d /Applications/$(APP_NAME_FOR_TEST).app ] && echo '  ✅ App 安装成功' || (echo '  ❌ App 未找到'; exit 1)"
	@echo "  → 验证 Helper daemon..."
	@lume exec $(TEST_RUN_VM) "launchctl print system/$(HELPER_LABEL) > /dev/null 2>&1 && echo '  ✅ Helper daemon 运行正常' || echo '  ⚠️  Helper daemon 未注册（可能需要首次启动 App）'"
	@echo "✅ 验证完成。"

# 5. 【深度清理】删除所有相关虚拟机
test-clean:
	@echo "🧹 清理所有测试相关的虚拟机..."
	@lume stop $(TEST_RUN_VM) $(TEST_SNAPSHOT_VM) $(TEST_BASE_VM) > /dev/null 2>&1 || true
	@lume delete $(TEST_RUN_VM) $(TEST_SNAPSHOT_VM) $(TEST_BASE_VM) > /dev/null 2>&1 || true
	@echo "✨ 已恢复系统洁净。"
