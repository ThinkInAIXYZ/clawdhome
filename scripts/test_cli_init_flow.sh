#!/bin/bash
# scripts/test_cli_init_flow.sh
# ClawdHome CLI 初始化流程回归脚本（真实跑通 init run）
#
# 用法：
#   ./scripts/test_cli_init_flow.sh [CLI_PATH]
#
# 可选环境变量：
#   ADMIN_PW=<管理员密码>                # 提供后自动清理测试用户
#   ADMIN_USER=<管理员用户名>            # 默认当前用户
#   TEST_USER=<固定测试用户名>           # 默认自动生成 ciinit<timestamp>

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-$ROOT_DIR/build/Debug/ClawdHomeCLI}"
TMP_DIR="$(mktemp -d /tmp/clawdhome-init-test.XXXXXX)"
TEST_USER="${TEST_USER:-ciinit$(date +%m%d%H%M%S)}"
TEST_FULL_NAME="CLI Init Flow Test"
TEST_PASSWORD="Test1234!"
TEST_CONFIG="$TMP_DIR/init-config.json"

PASS=0
FAIL=0
SKIP=0
FAILURES=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cleanup_tmp() {
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

pass() {
  echo -e "  ${GREEN}✓${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "  ${RED}✗${NC} $1"
  FAILURES+=("$1")
  FAIL=$((FAIL + 1))
}

skip() {
  echo -e "  ${YELLOW}○${NC} $1"
  SKIP=$((SKIP + 1))
}

section() {
  echo ""
  echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

assert_cmd_ok() {
  local desc="$1"; shift
  if "$@" >/tmp/clawdhome-init-test.out 2>&1; then
    pass "$desc"
  else
    fail "$desc"
    echo "    命令: $*"
    sed -n '1,8p' /tmp/clawdhome-init-test.out | sed 's/^/    /'
  fi
}

assert_cmd_fail_contains() {
  local desc="$1"
  local expected="$2"
  shift 2
  if "$@" >/tmp/clawdhome-init-test.out 2>&1; then
    fail "${desc}（应失败但成功）"
    return
  fi
  if grep -q "$expected" /tmp/clawdhome-init-test.out; then
    pass "$desc"
  else
    fail "${desc}（未匹配错误文案: $expected）"
    sed -n '1,8p' /tmp/clawdhome-init-test.out | sed 's/^/    /'
  fi
}

assert_json_expr() {
  local desc="$1"
  local json="$2"
  local expr="$3"
  if python3 - "$json" "$expr" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
expr = sys.argv[2]
ok = eval(expr, {"payload": payload})
sys.exit(0 if ok else 1)
PY
  then
    pass "$desc"
  else
    fail "$desc"
  fi
}

cat >"$TEST_CONFIG" <<'JSON'
{
  "config": {
    "agents": [
      {
        "id": "main",
        "displayName": "CLI E2E Main",
        "isDefault": true,
        "modelFallbacks": []
      }
    ],
    "imAccounts": [],
    "bindings": [],
    "providers": []
  },
  "personas": [
    {
      "agentDefId": "main",
      "dna": {
        "name": "CLI Persona",
        "fileSoul": "CLI soul test",
        "fileIdentity": "CLI identity test",
        "fileUser": "CLI user test"
      }
    }
  ]
}
JSON

echo -e "${CYAN}ClawdHome CLI 初始化流程测试${NC}"
echo "CLI: $CLI"
echo "TEST_USER: $TEST_USER"
echo ""

if [ ! -x "$CLI" ]; then
  echo -e "${RED}错误: CLI 不存在或不可执行: $CLI${NC}"
  exit 1
fi

section "1. 前置检查"
assert_cmd_ok "Helper 连接可用（version）" "$CLI" version

section "2. 执行初始化"
if "$CLI" init run "$TEST_USER" \
  --full-name "$TEST_FULL_NAME" \
  --password "$TEST_PASSWORD" \
  --config "$TEST_CONFIG" \
  --start-gateway >/tmp/clawdhome-init-run.out 2>&1; then
  pass "init run 执行成功"
else
  if grep -q "启动 gateway 失败" /tmp/clawdhome-init-run.out; then
    echo "  首次启动 gateway 失败，尝试 init resume --start-gateway ..."
    if "$CLI" init resume "$TEST_USER" --config "$TEST_CONFIG" --start-gateway \
      >/tmp/clawdhome-init-resume.out 2>&1; then
      pass "init run 首次失败，resume 后成功"
    else
      fail "init run 失败，且 resume 失败"
      sed -n '1,16p' /tmp/clawdhome-init-run.out | sed 's/^/    /'
      sed -n '1,16p' /tmp/clawdhome-init-resume.out | sed 's/^/    /'
    fi
  else
    fail "init run 执行失败"
    sed -n '1,16p' /tmp/clawdhome-init-run.out | sed 's/^/    /'
  fi
fi

section "3. 状态断言"
STATUS_JSON="$("$CLI" init status "$TEST_USER" --json)"
assert_json_expr "init status.exists=true" "$STATUS_JSON" 'payload.get("exists") is True'
assert_json_expr "init status.active=false" "$STATUS_JSON" 'payload.get("active") is False'
assert_json_expr "phase 全部 done" "$STATUS_JSON" 'all(v == "done" for v in payload.get("phases", {}).values())'
assert_json_expr "completedAt 已写入" "$STATUS_JSON" 'bool(payload.get("completedAt"))'

section "4. 运行状态断言"
INSPECT_JSON="$("$CLI" inspect "$TEST_USER" --json)"
assert_json_expr "inspect.status=running" "$INSPECT_JSON" 'payload.get("status") == "running"'
assert_json_expr "inspect.version 非空" "$INSPECT_JSON" 'bool(payload.get("version"))'
assert_json_expr "inspect.url 非空" "$INSPECT_JSON" 'bool(payload.get("url"))'

section "5. resume 行为断言"
assert_cmd_fail_contains "completed 后 resume 应失败" "初始化已完成" \
  "$CLI" init resume "$TEST_USER" --config "$TEST_CONFIG"

section "6. 清理（可选）"
if [ -n "${ADMIN_PW:-}" ]; then
  ADMIN_USER="${ADMIN_USER:-$(whoami)}"
  assert_cmd_ok "stop 测试实例" "$CLI" stop "$TEST_USER"
  if "$CLI" rm "$TEST_USER" --admin-user "$ADMIN_USER" --admin-password "$ADMIN_PW" \
    >/tmp/clawdhome-init-rm.out 2>&1; then
    pass "rm 测试实例"
  else
    echo "  CLI rm 失败，尝试 sudo sysadminctl 回退清理..."
    if printf '%s\n' "$ADMIN_PW" | sudo -S /usr/sbin/sysadminctl -deleteUser "$TEST_USER" \
      >/tmp/clawdhome-init-rm-fallback.out 2>&1; then
      if id "$TEST_USER" >/tmp/clawdhome-init-rm-id.out 2>&1; then
        fail "rm 测试实例（fallback 后用户仍存在）"
      else
        pass "rm 测试实例（fallback: sysadminctl）"
      fi
    else
      fail "rm 测试实例"
      sed -n '1,8p' /tmp/clawdhome-init-rm.out | sed 's/^/    /'
      sed -n '1,8p' /tmp/clawdhome-init-rm-fallback.out | sed 's/^/    /'
    fi
  fi
else
  skip "未设置 ADMIN_PW，跳过自动清理（测试用户保留：${TEST_USER}）"
  echo "  可手动清理：$CLI rm $TEST_USER --admin-user \"\$(whoami)\" --admin-password '<PASSWORD>'"
fi

echo ""
echo -e "${CYAN}━━━ 结果 ━━━${NC}"
echo -e "  ${GREEN}通过: $PASS${NC}  ${RED}失败: $FAIL${NC}  ${YELLOW}跳过: $SKIP${NC}"
if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  echo -e "${RED}失败项:${NC}"
  for item in "${FAILURES[@]}"; do
    echo -e "  ${RED}✗${NC} $item"
  done
fi

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}初始化流程测试通过${NC}"
  exit 0
fi

echo -e "${RED}初始化流程测试失败${NC}"
exit 1
