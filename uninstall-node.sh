#!/bin/bash

########################################
# CC-Bridge 节点卸载脚本
# 用法: bash uninstall-node.sh
########################################

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'
ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_NC} $1"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $1"; }
info() { echo -e "${COLOR_YELLOW}[INFO]${COLOR_NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "请用 root 运行"; exit 1
fi

echo ""
echo "========================================="
echo "  CC-Bridge 节点卸载"
echo "========================================="
echo ""

# ---------- 1. 停止进程 ----------
info "停止服务..."

# systemd 环境
if pidof systemd &>/dev/null && systemctl --version &>/dev/null; then
    systemctl stop ccb ccb-frpc 2>/dev/null
    systemctl disable ccb ccb-frpc 2>/dev/null
    rm -f /etc/systemd/system/ccb.service /etc/systemd/system/ccb-frpc.service
    systemctl daemon-reload
    ok "systemd 服务已移除"
fi

# 容器环境 / 残留进程
if [ -f /opt/ccb/stop.sh ]; then
    bash /opt/ccb/stop.sh 2>/dev/null
fi
pkill -f "claude-code-gateway" 2>/dev/null
pkill -f "frpc.*ccb" 2>/dev/null
pkill -f "/opt/ccb/start.sh" 2>/dev/null
ok "进程已停止"

# ---------- 2. 删除文件 ----------
info "删除文件..."
rm -rf /opt/ccb
ok "/opt/ccb 已删除"

echo ""
ok "卸载完成"
echo "========================================="
