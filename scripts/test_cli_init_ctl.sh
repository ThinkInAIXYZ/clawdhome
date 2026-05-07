#!/bin/bash
# scripts/test_cli_init_ctl.sh
# ClawdHome CLI 初始化测试控制台（支持全流程/分步骤）

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_ENV_FILE="$ROOT_DIR/scripts/test_cli_init.local.env"
ENV_FILE="${INIT_ENV_FILE:-$DEFAULT_ENV_FILE}"
CLI_INPUT_PATH="${2:-}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

CMD="${1:-help}"
TEST_USER="${TEST_USER:-ciinit$(date +%m%d%H%M%S)}"
TEST_FULL_NAME="${TEST_FULL_NAME:-CLI Init Flow Test}"
TEST_PASSWORD="${TEST_PASSWORD:-Test1234!}"
TEST_CONFIG_PATH="${TEST_CONFIG_PATH:-/tmp/clawdhome-init-config-${TEST_USER}.json}"
VERIFY_CHAT="${VERIFY_CHAT:-1}"
VERIFY_CHAT_MESSAGE="${VERIFY_CHAT_MESSAGE:-请简短回复：初始化验证成功}"
VERIFY_CHAT_SESSION="${VERIFY_CHAT_SESSION:-default}"
VERIFY_CHAT_TIMEOUT="${VERIFY_CHAT_TIMEOUT:-120}"
INIT_BIND_MODE="${INIT_BIND_MODE:-none}" # none|interactive
ENABLE_FEISHU_BIND="${ENABLE_FEISHU_BIND:-0}"
ENABLE_WEIXIN_BIND="${ENABLE_WEIXIN_BIND:-0}"
AUTO_CLEAN="${AUTO_CLEAN:-0}"
ADMIN_USER="${ADMIN_USER:-$(whoami)}"
ADMIN_PW="${ADMIN_PW:-}"

find_cli() {
  if [ -n "$CLI_INPUT_PATH" ] && [ -x "$CLI_INPUT_PATH" ]; then
    echo "$CLI_INPUT_PATH"
    return
  fi
  if [ -x "$ROOT_DIR/build/Debug/ClawdHomeCLI" ]; then
    echo "$ROOT_DIR/build/Debug/ClawdHomeCLI"
    return
  fi
  local dd
  dd="$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Debug/ClawdHomeCLI -maxdepth 0 2>/dev/null | head -1 || true)"
  if [ -n "$dd" ] && [ -x "$dd" ]; then
    echo "$dd"
    return
  fi
  echo ""
}

CLI="$(find_cli)"
if [ -z "$CLI" ]; then
  echo "错误: 未找到 ClawdHomeCLI，可先执行 make build-cli" >&2
  exit 1
fi

log() {
  echo "[ctl] $*"
}

require_admin_pw() {
  if [ -z "$ADMIN_PW" ]; then
    echo "错误: 本步骤需要 ADMIN_PW（请在 $ENV_FILE 设置）" >&2
    exit 1
  fi
}

ensure_config() {
  if [ -n "${TEST_CONFIG_TEMPLATE:-}" ]; then
    cp "$TEST_CONFIG_TEMPLATE" "$TEST_CONFIG_PATH"
    return
  fi

  if [ -f "$TEST_CONFIG_PATH" ]; then
    return
  fi

  cat >"$TEST_CONFIG_PATH" <<'JSON'
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
}

build_init_flags() {
  local flags=()
  flags+=("--full-name" "$TEST_FULL_NAME")
  flags+=("--password" "$TEST_PASSWORD")
  flags+=("--config" "$TEST_CONFIG_PATH")
  flags+=("--start-gateway")

  if [ "$INIT_BIND_MODE" = "interactive" ]; then
    flags+=("--interactive-binding")
  fi
  if [ "$ENABLE_FEISHU_BIND" = "1" ]; then
    flags+=("--bind-feishu")
  fi
  if [ "$ENABLE_WEIXIN_BIND" = "1" ]; then
    flags+=("--bind-weixin")
  fi
  if [ "$VERIFY_CHAT" = "1" ]; then
    flags+=("--verify-chat")
    flags+=("--verify-chat-message" "$VERIFY_CHAT_MESSAGE")
    flags+=("--verify-chat-session" "$VERIFY_CHAT_SESSION")
    flags+=("--verify-chat-timeout" "$VERIFY_CHAT_TIMEOUT")
  fi

  printf '%s\n' "${flags[@]}"
}

run_init() {
  ensure_config
  mapfile -t flags < <(build_init_flags)
  log "init run @${TEST_USER}"
  "$CLI" init run "$TEST_USER" "${flags[@]}"
}

run_resume() {
  ensure_config
  mapfile -t flags < <(build_init_flags)
  log "init resume @${TEST_USER}"
  "$CLI" init resume "$TEST_USER" "${flags[@]}"
}

run_status() {
  log "init status @${TEST_USER}"
  "$CLI" init status "$TEST_USER"
  log "inspect @${TEST_USER}"
  "$CLI" inspect "$TEST_USER"
}

run_bind_feishu() {
  ensure_config
  log "run + 飞书绑定 @${TEST_USER}"
  "$CLI" init run "$TEST_USER" --config "$TEST_CONFIG_PATH" --start-gateway --bind-feishu
}

run_bind_weixin() {
  ensure_config
  log "run + 微信绑定 @${TEST_USER}"
  "$CLI" init run "$TEST_USER" --config "$TEST_CONFIG_PATH" --start-gateway --bind-weixin
}

run_chat_verify() {
  log "chat 验证 @${TEST_USER}"
  "$CLI" chat "$TEST_USER" "$VERIFY_CHAT_MESSAGE" \
    --session "$VERIFY_CHAT_SESSION" \
    --timeout "$VERIFY_CHAT_TIMEOUT"
}

run_clean() {
  require_admin_pw
  log "stop @${TEST_USER}"
  "$CLI" stop "$TEST_USER" || true
  log "rm @${TEST_USER}"
  "$CLI" rm "$TEST_USER" --admin-user "$ADMIN_USER" --admin-password "$ADMIN_PW"
}

run_full() {
  log "CLI: $CLI"
  log "TEST_USER: $TEST_USER"
  log "CONFIG: $TEST_CONFIG_PATH"
  "$CLI" version >/dev/null
  run_init
  run_status
  if [ "$AUTO_CLEAN" = "1" ]; then
    run_clean
  else
    log "AUTO_CLEAN=0，跳过清理"
  fi
}

print_help() {
  cat <<EOF
用法:
  scripts/test_cli_init_ctl.sh <command> [CLI_PATH]

命令:
  full          跑全流程（init + status + inspect + 可选 clean）
  init          只执行 init run
  resume        只执行 init resume
  status        查看 init status + inspect
  bind-feishu   对当前 TEST_USER 执行飞书绑定
  bind-weixin   对当前 TEST_USER 执行微信绑定
  chat          执行一次 chat 验证
  clean         停止并删除测试用户
  help          显示帮助

本地配置:
  默认读取: $DEFAULT_ENV_FILE
  可通过 INIT_ENV_FILE 指定其它路径。

建议:
  cp scripts/test_cli_init.local.env.example scripts/test_cli_init.local.env
  然后按需填写 ADMIN_PW / TEST_USER / 绑定策略等。
EOF
}

case "$CMD" in
  full) run_full ;;
  init) run_init ;;
  resume) run_resume ;;
  status) run_status ;;
  bind-feishu) run_bind_feishu ;;
  bind-weixin|bind-wechat) run_bind_weixin ;;
  chat) run_chat_verify ;;
  clean) run_clean ;;
  help|-h|--help) print_help ;;
  *)
    echo "未知命令: $CMD" >&2
    print_help
    exit 1
    ;;
esac
