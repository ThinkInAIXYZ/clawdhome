#!/usr/bin/env bash
# capture-helper-incident.sh
# 现场取证：在「App 仍在、Helper 似乎失联/卡住」时快速采集证据。
#
# 用法：
#   bash scripts/capture-helper-incident.sh
#   sudo bash scripts/capture-helper-incident.sh   # 推荐：可采集 root helper 线程栈 sample

set -euo pipefail

REL_LABEL="ai.clawdhome.mac.helper"
DEV_LABEL="ai.clawdhome.mac.helper.dev"
OUT_DIR="/tmp/clawdhome-incident-$(date +%Y%m%d-%H%M%S)"
APP_LOG="/tmp/clawdhome-app.log"
HLP_REL_LOG="/tmp/clawdhome-helper.log"
HLP_DEV_LOG="/tmp/clawdhome-helper-dev.log"

mkdir -p "$OUT_DIR"

run_capture() {
    local name="$1"
    shift
    {
        echo "### CMD: $*"
        "$@"
    } >"$OUT_DIR/$name" 2>&1 || true
}

echo "== ClawdHome Incident Capture =="
echo "output: $OUT_DIR"

run_capture "00_time.txt" date -u
run_capture "01_sw_vers.txt" sw_vers
run_capture "02_uname.txt" uname -a
run_capture "03_uptime.txt" uptime
run_capture "04_ps_clawdhome.txt" ps aux
run_capture "05_launchctl_rel.txt" launchctl print "system/$REL_LABEL"
run_capture "06_launchctl_dev.txt" launchctl print "system/$DEV_LABEL"
run_capture "07_plist_rel.txt" plutil -p "/Library/LaunchDaemons/$REL_LABEL.plist"
run_capture "08_plist_dev.txt" plutil -p "/Library/LaunchDaemons/$DEV_LABEL.plist"
run_capture "09_lsof_ports.txt" lsof -nP -iTCP -sTCP:LISTEN
run_capture "10_codesign_app.txt" codesign -dv --verbose=2 /Applications/ClawdHome.app
run_capture "11_codesign_helper_rel.txt" codesign -dv --verbose=2 "/Library/PrivilegedHelperTools/$REL_LABEL"
run_capture "12_codesign_helper_dev.txt" codesign -dv --verbose=2 "/Library/PrivilegedHelperTools/$DEV_LABEL"

cp -f "$APP_LOG" "$OUT_DIR/app.log" 2>/dev/null || true
cp -f "$HLP_REL_LOG" "$OUT_DIR/helper-release.log" 2>/dev/null || true
cp -f "$HLP_DEV_LOG" "$OUT_DIR/helper-dev.log" 2>/dev/null || true

run_capture "13_logshow_subsystem_20m.txt" log show --last 20m --style compact --predicate 'subsystem == "ai.clawdhome.mac"'
run_capture "14_logshow_helper_20m.txt" log show --last 20m --style compact --predicate 'process == "ai.clawdhome.mac.helper" OR process == "ai.clawdhome.mac.helper.dev" OR process == "ClawdHome"'

REL_PID="$(launchctl print "system/$REL_LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}' || true)"
DEV_PID="$(launchctl print "system/$DEV_LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}' || true)"

if [[ -n "${REL_PID:-}" ]]; then
    run_capture "20_ps_rel_pid.txt" ps -p "$REL_PID" -o pid,ppid,user,etime,stat,command
    run_capture "21_sample_rel_8s.txt" sample "$REL_PID" 8
fi

if [[ -n "${DEV_PID:-}" ]]; then
    run_capture "22_ps_dev_pid.txt" ps -p "$DEV_PID" -o pid,ppid,user,etime,stat,command
    run_capture "23_sample_dev_8s.txt" sample "$DEV_PID" 8
fi

run_capture "30_recent_crash_reports.txt" sh -lc "ls -lt /Library/Logs/DiagnosticReports/ai.clawdhome.mac.helper*.ips 2>/dev/null | head -n 20"
run_capture "31_recent_user_crash_reports.txt" sh -lc "ls -lt \"$HOME\"/Library/Logs/DiagnosticReports/*ClawdHome*.ips 2>/dev/null | head -n 20"

tar -czf "$OUT_DIR.tgz" -C /tmp "$(basename "$OUT_DIR")" >/dev/null 2>&1 || true

echo ""
echo "✅ capture complete"
echo "dir : $OUT_DIR"
echo "tgz : $OUT_DIR.tgz"
echo ""
echo "如果 sample 文件为空或包含 'not permitted'，请用 sudo 重跑一次。"
