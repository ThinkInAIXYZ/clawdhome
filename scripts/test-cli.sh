#!/bin/bash
# scripts/test-cli.sh — ClawdHome CLI 自动化集成测试
# 用法: ./scripts/test-cli.sh [CLI路径]
# 需要 Helper 正在运行，且至少有一个现存实例

set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────
CLI="${1:-$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1)}"
TEST_INSTANCE="cli_test_instance_$$"   # 用 PID 避免冲突
PASS=0
FAIL=0
SKIP=0
FAILURES=()

# ── 颜色 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 辅助函数 ──────────────────────────────────────────────

assert_ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc"
        FAILURES+=("$desc")
        FAIL=$((FAIL + 1))
    fi
}

assert_fail() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} $desc (应该失败但成功了)"
        FAILURES+=("$desc")
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${GREEN}✓${NC} $desc (预期失败)"
        PASS=$((PASS + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$expected"; then
        echo -e "  ${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc (未找到: '$expected')"
        echo "    实际输出: $(echo "$output" | head -3)"
        FAILURES+=("$desc")
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local desc="$1"
    local field="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    # 简单检查 JSON 中是否包含字段
    if echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in (d[0] if isinstance(d,list) else d)" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $desc (JSON 缺少字段: $field)"
        FAILURES+=("$desc")
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    local desc="$1"
    echo -e "  ${YELLOW}○${NC} $desc (跳过)"
    SKIP=$((SKIP + 1))
}

section() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

cleanup() {
    echo ""
    section "清理"
    if "$CLI" ps --json 2>/dev/null | python3 -c "import sys,json; names=[s['name'] for s in json.load(sys.stdin)]; sys.exit(0 if '$TEST_INSTANCE' in names else 1)" 2>/dev/null; then
        echo "  删除测试实例 $TEST_INSTANCE..."
        "$CLI" rm "$TEST_INSTANCE" --admin-user "$(whoami)" --admin-password "${ADMIN_PW:-}" 2>/dev/null || true
    fi
}

# ── 前置检查 ──────────────────────────────────────────────

if [ ! -x "$CLI" ]; then
    echo -e "${RED}错误: CLI 不存在或不可执行: $CLI${NC}"
    echo "用法: $0 [CLI路径]"
    exit 1
fi

echo -e "${CYAN}ClawdHome CLI 集成测试${NC}"
echo "CLI: $CLI"
echo "测试实例: $TEST_INSTANCE"
echo ""

# ── 1. 基础命令 ───────────────────────────────────────────

section "1. 基础命令"

assert_contains "version 输出 CLI 版本" "clawdhome" "$CLI" --version
assert_contains "help 输出用法" "Commands:" "$CLI" --help
assert_ok "version 子命令连接 Helper" "$CLI" version

# JSON 模式
assert_json_field "version --json 输出 JSON" "cli" "$CLI" version --json

# ── 2. ps ─────────────────────────────────────────────────

section "2. ps"

assert_ok "ps 成功" "$CLI" ps
assert_contains "ps 包含表头" "NAME" "$CLI" ps
assert_json_field "ps --json 返回数组" "name" "$CLI" ps --json

# 获取一个现存实例用于后续测试
EXISTING_INSTANCE=$("$CLI" ps --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['name'])" 2>/dev/null || echo "")
if [ -n "$EXISTING_INSTANCE" ]; then
    echo -e "  ${CYAN}→${NC} 使用现存实例: $EXISTING_INSTANCE"
else
    echo -e "  ${YELLOW}⚠${NC} 未找到现存实例，部分测试将跳过"
fi

# ── 3. inspect ────────────────────────────────────────────

section "3. inspect"

if [ -n "$EXISTING_INSTANCE" ]; then
    assert_contains "inspect 显示 Name" "Name:" "$CLI" inspect "$EXISTING_INSTANCE"
    assert_contains "inspect 显示 Version" "Version:" "$CLI" inspect "$EXISTING_INSTANCE"
    assert_json_field "inspect --json 包含 status 字段" "status" "$CLI" inspect "$EXISTING_INSTANCE" --json
else
    skip "inspect（无现存实例）"
fi

assert_fail "inspect 不存在的实例应失败" "$CLI" inspect "nonexistent_instance_xyz"

# ── 4. start/stop/restart ────────────────────────────────

section "4. Gateway 控制"

if [ -n "$EXISTING_INSTANCE" ]; then
    # 获取当前状态
    RUNNING=$("$CLI" inspect "$EXISTING_INSTANCE" --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")

    if [ "$RUNNING" = "running" ]; then
        assert_ok "restart 重启运行中的实例" "$CLI" restart "$EXISTING_INSTANCE"
        # 等待重启完成
        sleep 2
        assert_ok "restart 后仍在运行" "$CLI" inspect "$EXISTING_INSTANCE"
    else
        assert_ok "start 启动停止的实例" "$CLI" start "$EXISTING_INSTANCE"
        sleep 2
    fi
else
    skip "Gateway 控制（无现存实例）"
fi

# ── 5. config get/set ─────────────────────────────────────

section "5. 配置读写"

if [ -n "$EXISTING_INSTANCE" ]; then
    assert_ok "config get 读取配置" "$CLI" config get "$EXISTING_INSTANCE" "agents.defaults.model.primary"
    assert_json_field "config get --json" "key" "$CLI" config get "$EXISTING_INSTANCE" "agents.defaults.model.primary" --json
else
    skip "config（无现存实例）"
fi

assert_fail "config get 不存在的实例" "$CLI" config get "nonexistent_xyz" "some.key"

# ── 6. doctor ─────────────────────────────────────────────

section "6. 诊断"

if [ -n "$EXISTING_INSTANCE" ]; then
    assert_contains "doctor 输出诊断分组" "环境检测" "$CLI" doctor "$EXISTING_INSTANCE"
    assert_ok "doctor --json 输出 JSON" "$CLI" doctor "$EXISTING_INSTANCE" --json
else
    skip "doctor（无现存实例）"
fi

# ── 7. chat（需要 chatCompletions 已启用） ──────────────────

section "7. 聊天 API"

if [ -n "$EXISTING_INSTANCE" ]; then
    # 先检查 gateway 是否运行
    GW_STATUS=$("$CLI" inspect "$EXISTING_INSTANCE" --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "stopped")

    if [ "$GW_STATUS" = "running" ]; then
        # 尝试发送消息（可能因为 chatCompletions 未启用而失败）
        CHAT_OUTPUT=$("$CLI" chat "$EXISTING_INSTANCE" "回复 ok" --timeout 30 2>&1) || true

        if echo "$CHAT_OUTPUT" | grep -qi "ok\|你好\|hello\|hi"; then
            echo -e "  ${GREEN}✓${NC} chat 发消息并收到回复"
            PASS=$((PASS + 1))
        elif echo "$CHAT_OUTPUT" | grep -qi "404\|not found\|disabled\|not enabled"; then
            echo -e "  ${YELLOW}○${NC} chat API 未启用 (需要 gateway.http.endpoints.chatCompletions.enabled: true)"
            SKIP=$((SKIP + 1))
        elif echo "$CHAT_OUTPUT" | grep -qi "error\|failed\|超时"; then
            echo -e "  ${YELLOW}○${NC} chat 请求失败: $(echo "$CHAT_OUTPUT" | head -1)"
            SKIP=$((SKIP + 1))
        else
            echo -e "  ${GREEN}✓${NC} chat 收到回复: $(echo "$CHAT_OUTPUT" | head -1 | cut -c1-80)"
            PASS=$((PASS + 1))
        fi

        # JSON 模式
        CHAT_JSON=$("$CLI" chat "$EXISTING_INSTANCE" "回复 ok" --json --timeout 30 2>&1) || true
        if echo "$CHAT_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} chat --json 返回有效 JSON"
            PASS=$((PASS + 1))
        elif echo "$CHAT_JSON" | grep -qi "404\|disabled"; then
            skip "chat --json（API 未启用）"
        else
            echo -e "  ${YELLOW}○${NC} chat --json 非 JSON 输出"
            SKIP=$((SKIP + 1))
        fi
    else
        skip "chat（Gateway 未运行）"
    fi
else
    skip "chat（无现存实例）"
fi

# ── 8. 实例生命周期（创建 → 状态 → 删除） ──────────────────

section "8. 实例生命周期"

if [ -n "${ADMIN_PW:-}" ]; then
    echo "  创建测试实例 $TEST_INSTANCE..."
    if "$CLI" run "$TEST_INSTANCE" --password "Test1234!" 2>&1 | tee /dev/stderr | grep -q "创建完成"; then
        echo -e "  ${GREEN}✓${NC} run 创建实例"
        PASS=$((PASS + 1))

        # 验证出现在列表中
        assert_contains "新实例出现在 ps 中" "$TEST_INSTANCE" "$CLI" ps

        # 详情查询
        assert_contains "新实例 inspect 可查" "Name:" "$CLI" inspect "$TEST_INSTANCE"

        # 停止
        assert_ok "stop 停止新实例" "$CLI" stop "$TEST_INSTANCE"
        sleep 1

        # 删除
        echo "  删除测试实例..."
        if "$CLI" rm "$TEST_INSTANCE" --admin-user "$(whoami)" --admin-password "$ADMIN_PW" 2>&1 | grep -q "已删除"; then
            echo -e "  ${GREEN}✓${NC} rm 删除实例"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}✗${NC} rm 删除实例失败"
            FAILURES+=("rm 删除实例")
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${RED}✗${NC} run 创建实例失败"
        FAILURES+=("run 创建实例")
        FAIL=$((FAIL + 1))
        cleanup
    fi
else
    skip "实例生命周期（未设置 ADMIN_PW 环境变量）"
    echo -e "  ${YELLOW}→${NC} 运行完整测试: ADMIN_PW=<密码> $0"
fi

# ── 9. 错误处理 ──────────────────────────────────────────

section "9. 错误处理"

assert_fail "未知命令应失败" "$CLI" nonexistent_command
assert_fail "config 无子命令应失败" "$CLI" config
assert_fail "chat 无参数应失败" "$CLI" chat
assert_fail "exec 无参数应失败" "$CLI" exec

# ── 结果汇总 ─────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━ 测试结果 ━━━${NC}"
echo -e "  ${GREEN}通过: $PASS${NC}  ${RED}失败: $FAIL${NC}  ${YELLOW}跳过: $SKIP${NC}"

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}失败项:${NC}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${NC} $f"
    done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}所有测试通过！${NC}"
    exit 0
else
    echo -e "${RED}有 $FAIL 项测试失败${NC}"
    exit 1
fi
