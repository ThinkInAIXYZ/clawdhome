# Makefile — ClawdHome 开发工具
# 用法：make <target>

PROJECT    := ClawdHome.xcodeproj
SCHEME_APP := ClawdHome
SCHEME_HLP := ClawdHomeHelper
INFO_PLIST := ClawdHome/Info.plist
PLIST      := /usr/libexec/PlistBuddy

.PHONY: help bump-build build build-helper build-release install-helper uninstall-helper pkg pkg-skip-build release release-dry-run changelog version-next install-hooks clean version i18n i18n-check

WEBSITE_DIR ?= ../clawdhome_website

help:
	@echo "可用目标："
	@echo "  build            递增 Build 号后 Debug 构建（App + Helper）"
	@echo "  build-helper     递增 Build 号后 Debug 构建 Helper"
	@echo "  build-release    递增 Build 号后 Release 归档构建"
	@echo "  bump-build       仅递增 Build 号（不构建）"
	@echo "  version          显示当前版本和 Build 号"
	@echo "  version-next     预览下一个语义化版本号"
	@echo "  changelog        预览将生成的 CHANGELOG 内容"
	@echo "  install-helper   安装 Helper 到系统（需要 sudo）"
	@echo "  uninstall-helper 卸载 Helper（需要 sudo）"
	@echo "  pkg              打包 .pkg 安装包"
	@echo "  pkg-skip-build   跳过构建直接打包"
	@echo "  release          一键发布：changelog + tag + pkg + GitHub Release"
	@echo "  release-dry-run  预览发布流程（不执行）"
	@echo "  install-hooks    安装 git commit-msg hook"
	@echo "  run-release      直接运行 build/export 里的 Release 包（无需安装）"
	@echo "  install-pkg      安装最新 pkg 到 /Applications（需要 sudo）"
	@echo "  log-helper       实时跟踪 Helper 日志（/tmp/clawdhome-helper.log）"
	@echo "  log-app          实时跟踪 App 系统日志（os_log）"
	@echo "  i18n             运行 Stable.xcstrings 本地化检查"
	@echo "  i18n-check       本地化 CI 检查（未本地化/缺失翻译/占位符一致性）"
	@echo "  clean            清理 build/ dist/ 目录"

# ── 版本管理 ──────────────────────────────────────────────────────────────────

version:
	@V=$$($(PLIST) -c "Print CFBundleShortVersionString" $(INFO_PLIST)); \
	 B=$$(git rev-list --count HEAD 2>/dev/null || echo 0); \
	 TAG=$$(bash scripts/semver.sh --current 2>/dev/null || echo "无 tag"); \
	 echo "Info.plist 版本：$$V  Git 提交数：$$B  当前 tag：$$TAG"

version-next:
	@bash scripts/semver.sh

changelog:
	@bash scripts/changelog.sh --stdout

bump-build:
	@echo "Build 号由 git 提交数自动决定，无需手动递增（当前：$$(git rev-list --count HEAD)）"

# ── 构建 ──────────────────────────────────────────────────────────────────────

build: bump-build
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-destination "platform=macOS" \
		-configuration Debug \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

build-helper: bump-build
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME_HLP) \
		-destination "platform=macOS" \
		-configuration Debug \
		build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

build-release: bump-build
	xcodebuild archive \
		-project $(PROJECT) \
		-scheme $(SCHEME_APP) \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-archivePath build/ClawdHome.xcarchive \
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=NO

# ── 安装 / 卸载 ───────────────────────────────────────────────────────────────

install-helper:
	sudo bash scripts/install-helper-dev.sh install

uninstall-helper:
	sudo bash scripts/install-helper-dev.sh uninstall

# ── 打包 ──────────────────────────────────────────────────────────────────────

pkg: bump-build
	bash scripts/build-pkg.sh
	@open dist/

pkg-skip-build:
	bash scripts/build-pkg.sh --skip-build
	@open dist/

release:
	bash scripts/release.sh

release-dry-run:
	bash scripts/release.sh --dry-run

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

log-app:
	log stream --predicate 'subsystem == "ai.clawdhome.mac"' --level debug

# ── 清理 ──────────────────────────────────────────────────────────────────────

clean:
	rm -rf build/ dist/
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_APP) clean -quiet

# ── Git Hooks ────────────────────────────────────────────────────────────────

install-hooks:
	@cp scripts/hooks/commit-msg .git/hooks/commit-msg
	@chmod +x .git/hooks/commit-msg
	@echo "✅ commit-msg hook 已安装"

# ── i18n ──────────────────────────────────────────────────────────────────────

i18n:
	$(MAKE) i18n-check

i18n-check:
	scripts/i18n_check_untranslated.py
	scripts/i18n_ci_check.py
	scripts/i18n_forbid_legacy_t.py
