#!/usr/bin/env bash
# test_team_assembly.sh — 自动化测试「召唤团队」主流程
#
# 用法:
#   ./scripts/test_team_assembly.sh [USERNAME]
#
# 测试策略：
#   1. 创建或重置一个测试团队账号
#   2. 写入 pending_team_agents.json
#   3. 触发初始化向导（通过 osascript 打开窗口）
#   4. tail -f 日志文件，等待关键事件，输出结果
#
# 日志来源:
#   - /tmp/clawdhome-app-YYYYMMDD.log  (AppLogger 文件 sink，需 App 重启后生效)
#   - /tmp/clawdhome-init-{username}.log (向导进度日志)
#   - /tmp/clawdhome-helper-dev.log (Helper 日志)

set -euo pipefail

# --- 配置 ---
TEST_USER="${1:-test_team_auto}"
WORKSPACE_DIR="/Users/${TEST_USER}/.openclaw/workspace"
APP_LOG="/tmp/clawdhome-app-$(date +%Y%m%d).log"
INIT_LOG="/tmp/clawdhome-init-${TEST_USER}.log"
TIMEOUT_SECONDS=300
CHECK_INTERVAL=2

# ANSI 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
ok()  { echo -e "${GREEN}[PASS]${NC} $*"; }
err() { echo -e "${RED}[FAIL]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }

# --- 测试 Agents JSON (投资团队 4 名成员) ---
PENDING_AGENTS_JSON='[
  {
    "id": "invest_001",
    "emoji": "📊",
    "name": "深度投资分析师",
    "soul": "在疯狂的市场中，理性是唯一的护城河。",
    "skills": ["量化分析", "估值建模", "风险评估"],
    "category": "投资",
    "suggestedAgentID": "invest_agent",
    "fileSoul": "在疯狂的市场中，理性是唯一的护城河。",
    "fileIdentity": "角色名：深度投资分析师\n语气：冷静、客观、逻辑严密",
    "fileUser": "# 关于你\n你的风险承受能力："
  },
  {
    "id": "invest_002",
    "emoji": "💰",
    "name": "数字化CFO",
    "soul": "钱不是终点，现金流才是生命线。",
    "skills": ["现金流管理", "财务规划", "预算控制"],
    "category": "投资",
    "suggestedAgentID": "cfo_agent",
    "fileSoul": "钱不是终点，现金流才是生命线。",
    "fileIdentity": "角色名：数字化CFO\n语气：严谨、直接",
    "fileUser": "# 关于你\n你的业务类型："
  }
]'

# --- 检查 App 是否运行 ---
check_app_running() {
    if pgrep -f "ClawdHome.app" > /dev/null 2>&1; then
        ok "ClawdHome App 正在运行"
        return 0
    else
        err "ClawdHome App 未运行，请先启动 App"
        exit 1
    fi
}

# --- 检查 App Log 文件 sink ---
check_app_log() {
    if [[ -f "$APP_LOG" ]]; then
        ok "App 日志文件存在: $APP_LOG"
    else
        warn "App 日志文件不存在: $APP_LOG"
        warn "提示：AppLogger 文件 sink 需要在本次编译后重启 App 才会生效"
        warn "重启 App 后再运行此测试"
        echo ""
        warn "可用的替代监控方式："
        warn "  log stream --predicate 'subsystem == \"ai.clawdhome.mac\"' --level info"
        # 不退出，继续测试（降级为只看 init log）
        APP_LOG=""
    fi
}

# --- 检查测试账号是否存在 ---
check_user() {
    if dscl . -read "/Users/${TEST_USER}" > /dev/null 2>&1; then
        log "测试账号 ${TEST_USER} 已存在"
        return 0
    else
        err "测试账号 ${TEST_USER} 不存在"
        log "请先通过 ClawdHome UI 创建该账号，或指定已存在的账号"
        log "用法: $0 <username>"
        exit 1
    fi
}

# --- 写入 pending_team_agents.json ---
inject_pending_agents() {
    log "注入 pending_team_agents.json 到 ${WORKSPACE_DIR}..."

    # 确保目录存在
    if [[ ! -d "$WORKSPACE_DIR" ]]; then
        err "workspace 目录不存在: $WORKSPACE_DIR"
        err "请先通过 ClawdHome 初始化该账号的基础环境"
        exit 1
    fi

    # 备份旧文件
    local pending_path="${WORKSPACE_DIR}/pending_team_agents.json"
    if [[ -f "$pending_path" ]]; then
        cp "$pending_path" "${pending_path}.bak"
        log "已备份旧文件: ${pending_path}.bak"
    fi

    echo "$PENDING_AGENTS_JSON" > "$pending_path"
    ok "已写入 ${pending_path}"
    cat "$pending_path"
}

# --- 清理旧日志 ---
reset_logs() {
    if [[ -f "$INIT_LOG" ]]; then
        log "清理旧 init log: $INIT_LOG"
        > "$INIT_LOG"
    fi
}

# --- 触发初始化向导 ---
trigger_wizard() {
    log "通过 osascript 触发初始化向导 (username: ${TEST_USER})..."

    osascript <<-APPLESCRIPT
        tell application "ClawdHome"
            activate
        end tell

        -- 等待 App 激活
        delay 1

        -- 通过 URL scheme 打开向导
        open location "clawdhome://open-wizard?username=${TEST_USER}"
APPLESCRIPT

    if [[ $? -eq 0 ]]; then
        ok "已触发向导打开命令"
    else
        warn "osascript 执行失败，请手动打开初始化向导"
        warn "或通过 ClawdHome UI 点击对应账号的初始化按钮"
    fi
}

# --- 监控日志，等待关键事件 ---
monitor_logs() {
    log "开始监控日志... (超时: ${TIMEOUT_SECONDS}s)"
    echo ""

    local start_time=$SECONDS
    local last_init_size=0
    local last_app_size=0

    # 事件追踪
    local gateway_started=false
    local gateway_connected=false
    local team_activation_started=false
    local team_success_count=0
    local team_fail_count=0
    local wizard_finished=false

    echo "=== 实时日志监控 ==="

    while true; do
        local elapsed=$(( SECONDS - start_time ))

        if [[ $elapsed -ge $TIMEOUT_SECONDS ]]; then
            err "超时 (${TIMEOUT_SECONDS}s)，测试未完成"
            break
        fi

        # 读取 init log 新内容
        if [[ -f "$INIT_LOG" ]]; then
            local current_size
            current_size=$(wc -c < "$INIT_LOG")
            if [[ $current_size -gt $last_init_size ]]; then
                local new_lines
                new_lines=$(tail -c +$((last_init_size + 1)) "$INIT_LOG")
                while IFS= read -r line; do
                    if [[ -n "$line" ]]; then
                        echo -e "  ${YELLOW}[init]${NC} $line"

                        # 检测关键事件
                        if echo "$line" | grep -q "\[bg\].*Gateway.*成功\|Gateway pre-started"; then
                            gateway_started=true
                        fi
                        if echo "$line" | grep -q "\[team\] 开始激活\|injectRole.*team"; then
                            team_activation_started=true
                        fi
                        if echo "$line" | grep -q "\[team\] ✅"; then
                            ((team_success_count++))
                        fi
                        if echo "$line" | grep -q "\[team\] ❌"; then
                            ((team_fail_count++))
                        fi
                        if echo "$line" | grep -q "\[team\] 全员就位完成\|finish.*done"; then
                            wizard_finished=true
                        fi
                    fi
                done <<< "$new_lines"
                last_init_size=$current_size
            fi
        fi

        # 读取 App 文件日志新内容（如果可用）
        if [[ -n "$APP_LOG" && -f "$APP_LOG" ]]; then
            local current_app_size
            current_app_size=$(wc -c < "$APP_LOG")
            if [[ $current_app_size -gt $last_app_size ]]; then
                local new_app_lines
                new_app_lines=$(tail -c +$((last_app_size + 1)) "$APP_LOG")
                while IFS= read -r line; do
                    if [[ -n "$line" ]]; then
                        # 只显示相关的 team/gateway/wizard 日志
                        if echo "$line" | grep -qi "team\|gateway\|wizard\|agent\|connect"; then
                            echo -e "  ${BLUE}[app]${NC}  $line"

                            if echo "$line" | grep -qi "connectedUsernames\|GatewayHub.*connect.*success\|WebSocket.*connected"; then
                                gateway_connected=true
                            fi
                        fi
                    fi
                done <<< "$new_app_lines"
                last_app_size=$current_app_size
            fi
        fi

        sleep $CHECK_INTERVAL
    done

    echo ""
    echo "=== 测试结果 ==="

    if $gateway_started; then
        ok "Gateway 启动: ✓"
    else
        err "Gateway 启动: 未检测到"
    fi

    if $gateway_connected; then
        ok "Gateway WebSocket 连接: ✓"
    elif [[ -n "$APP_LOG" ]]; then
        warn "Gateway WebSocket 连接: 未在 App 日志中检测到"
    else
        warn "Gateway WebSocket 连接: 无法检测（App 文件日志不可用）"
    fi

    if $team_activation_started; then
        ok "团队激活流程: 已启动"
    else
        warn "团队激活流程: 未检测到启动"
    fi

    if [[ $team_success_count -gt 0 ]]; then
        ok "成功激活 Agent: ${team_success_count} 个"
    fi

    if [[ $team_fail_count -gt 0 ]]; then
        err "激活失败 Agent: ${team_fail_count} 个"
    fi

    if $wizard_finished; then
        ok "向导完成: ✓"
    else
        warn "向导完成: 未检测到"
    fi

    if [[ $team_fail_count -eq 0 && $team_success_count -gt 0 && $wizard_finished ]]; then
        echo ""
        ok "=== 测试通过 ==="
        return 0
    else
        echo ""
        err "=== 测试未通过，请检查上方日志 ==="
        return 1
    fi
}

# --- 显示使用说明 ---
print_usage() {
    echo ""
    echo "使用说明："
    echo "  1. 确保 ClawdHome App 已运行（本次编译后需重启以激活文件日志）"
    echo "  2. 确保测试账号已存在（通过 UI 创建或选择现有账号）"
    echo "  3. 运行: $0 [username]"
    echo ""
    echo "监控日志文件："
    echo "  App 日志:  $APP_LOG"
    echo "  Init 日志: $INIT_LOG"
    echo "  Helper 日志: /tmp/clawdhome-helper-dev.log"
    echo ""
    echo "手动 tail 监控（另开终端）："
    echo "  tail -f $APP_LOG | grep -i 'team\\|gateway\\|agent'"
    echo "  tail -f $INIT_LOG"
}

# --- 主流程 ---
main() {
    echo "========================================"
    echo "  ClawdHome 召唤团队 自动化测试"
    echo "  测试账号: ${TEST_USER}"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""

    check_app_running
    check_app_log
    check_user
    inject_pending_agents
    reset_logs

    echo ""
    log "准备工作完成，即将触发向导..."
    log "请在 ClawdHome UI 中手动打开 ${TEST_USER} 的初始化向导"
    log "（osascript URL scheme 触发可能不稳定，建议手动操作）"
    echo ""

    # 尝试自动触发（可能失败）
    # trigger_wizard

    log "等待向导启动... 按 Ctrl+C 中断"
    echo ""

    monitor_logs

    print_usage
}

main "$@"
