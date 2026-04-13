#!/bin/bash
set -e

########################################
# CC-Bridge 外部节点一键安装脚本
# 安装: CC-Bridge + frpc，自动注册到主服务器
#
# 用法:
#   bash install-node.sh --group 1 --node 1 \
#     --server-ip 35.212.182.237 \
#     --frp-token ccb_frp_token_2026 \
#     --pg-pass ccb_pg_2026 \
#     --redis-pass ccb_redis_2026 \
#     --admin-pass admin
#
# 端口规则: 5000 + (group-1)*10 + node
#   组1节点1 → 5001, 组1节点2 → 5002
#   组2节点1 → 5011, 组2节点2 → 5012
########################################

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'
ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_NC} $1"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $1"; }
info() { echo -e "${COLOR_YELLOW}[INFO]${COLOR_NC} $1"; }

# ========== 参数解析 ==========
GROUP=""
NODE=""
SERVER_IP=""
FRP_TOKEN=""
PG_PASS=""
REDIS_PASS=""
ADMIN_PASS="admin"
CCB_PORT=5674
FRP_VERSION="0.61.1"

while [[ $# -gt 0 ]]; do
    case $1 in
        --group)      GROUP="$2"; shift 2 ;;
        --node)       NODE="$2"; shift 2 ;;
        --server-ip)  SERVER_IP="$2"; shift 2 ;;
        --server)     SERVER_IP="$2"; shift 2 ;;
        --frp-token)  FRP_TOKEN="$2"; shift 2 ;;
        --pg-pass)    PG_PASS="$2"; shift 2 ;;
        --redis-pass) REDIS_PASS="$2"; shift 2 ;;
        --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# 参数校验
MISSING=""
[ -z "$GROUP" ]     && MISSING="$MISSING --group"
[ -z "$NODE" ]      && MISSING="$MISSING --node"
[ -z "$SERVER_IP" ] && MISSING="$MISSING --server-ip"
[ -z "$FRP_TOKEN" ] && MISSING="$MISSING --frp-token"
[ -z "$PG_PASS" ]   && MISSING="$MISSING --pg-pass"
[ -z "$REDIS_PASS" ] && MISSING="$MISSING --redis-pass"
if [ -n "$MISSING" ]; then
    fail "缺少参数:$MISSING"
    echo "用法: bash install-node.sh --group 1 --node 1 --server-ip IP --frp-token TOKEN --pg-pass PW --redis-pass PW"
    exit 1
fi

if [ "$GROUP" -lt 1 ] || [ "$GROUP" -gt 10 ] 2>/dev/null; then
    fail "--group 范围 1~10"; exit 1
fi
if [ "$NODE" -lt 1 ] || [ "$NODE" -gt 5 ] 2>/dev/null; then
    fail "--node 范围 1~5"; exit 1
fi

REMOTE_PORT=$((5000 + (GROUP - 1) * 10 + NODE))
DB_NAME="ccb_g${GROUP}"
REDIS_DB=$((GROUP - 1))
NODE_NAME="ccb-g${GROUP}-n${NODE}"

echo ""
echo "========================================="
echo "  CC-Bridge 节点安装"
echo "========================================="
echo "  节点组:     $GROUP"
echo "  节点号:     $NODE"
echo "  节点名:     $NODE_NAME"
echo "  远程端口:   $REMOTE_PORT"
echo "  数据库:     $DB_NAME"
echo "  Redis DB:   $REDIS_DB"
echo "  主服务器:   $SERVER_IP"
echo "========================================="
echo ""

# ---------- 1. 检测系统 ----------
if [ "$(id -u)" -ne 0 ]; then
    fail "请用 root 运行"; exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  CCB_ARCH="amd64"; FRP_ARCH="amd64" ;;
    aarch64) CCB_ARCH="arm64"; FRP_ARCH="arm64" ;;
    *)       fail "不支持的架构: $ARCH"; exit 1 ;;
esac
ok "架构: $ARCH ($CCB_ARCH)"

# ---------- 2. 创建目录 ----------
mkdir -p /opt/ccb/data
cd /opt/ccb

# ---------- 3. 下载 CC-Bridge ----------
info "下载 CC-Bridge..."
if [ -f /opt/ccb/claude-code-gateway ]; then
    ok "CC-Bridge 已存在，跳过下载"
else
    # 获取最新 release
    CCB_RELEASE_URL="https://api.github.com/repos/MamoWorks/cc-bridge/releases/latest"
    CCB_TAG=$(curl -fsSL "$CCB_RELEASE_URL" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\(.*\)".*/\1/')
    if [ -z "$CCB_TAG" ]; then
        fail "无法获取 CC-Bridge 最新版本"
        info "尝试使用 v1.6.0..."
        CCB_TAG="v1.6.0"
    fi
    ok "CC-Bridge 版本: $CCB_TAG"

    # 下载二进制
    CCB_DL_NAME="claude-code-gateway-linux-${CCB_ARCH}"
    CCB_DL_URL="https://github.com/MamoWorks/cc-bridge/releases/download/${CCB_TAG}/${CCB_DL_NAME}"

    info "下载 $CCB_DL_URL ..."
    curl -fsSL "$CCB_DL_URL" -o /opt/ccb/claude-code-gateway || {
        # 尝试 .tar.gz 格式
        info "尝试 tar.gz 格式..."
        curl -fsSL "${CCB_DL_URL}.tar.gz" -o /tmp/ccb.tar.gz
        tar xzf /tmp/ccb.tar.gz -C /opt/ccb/
        rm -f /tmp/ccb.tar.gz
    }
    chmod +x /opt/ccb/claude-code-gateway
    ok "CC-Bridge 下载完成"
fi

# ---------- 4. 下载 frpc ----------
info "下载 frpc..."
if [ -f /opt/ccb/frpc ]; then
    ok "frpc 已存在，跳过下载"
else
    FRP_PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PKG}.tar.gz"
    cd /tmp
    curl -fsSL "$FRP_URL" -o frp.tar.gz
    tar xzf frp.tar.gz
    cp "${FRP_PKG}/frpc" /opt/ccb/frpc
    chmod +x /opt/ccb/frpc
    rm -rf frp.tar.gz "${FRP_PKG}"
    ok "frpc 下载完成"
fi

# ---------- 5. 写入 .env ----------
info "写入配置..."
cat > /opt/ccb/.env << ENVEOF
DATABASE_DRIVER=postgres
DATABASE_HOST=${SERVER_IP}
DATABASE_PORT=5432
DATABASE_USER=postgres
DATABASE_PASSWORD=${PG_PASS}
DATABASE_DBNAME=${DB_NAME}
REDIS_HOST=${SERVER_IP}
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASS}
REDIS_DB=${REDIS_DB}
ADMIN_PASSWORD=${ADMIN_PASS}
SERVER_HOST=0.0.0.0
SERVER_PORT=${CCB_PORT}
ENVEOF
ok ".env 已写入"

# ---------- 6. 写入 frpc.toml ----------
cat > /opt/ccb/frpc.toml << FRPCEOF
serverAddr = "${SERVER_IP}"
serverPort = 7000
auth.method = "token"
auth.token = "${FRP_TOKEN}"

[[proxies]]
name = "${NODE_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${CCB_PORT}
remotePort = ${REMOTE_PORT}
FRPCEOF
ok "frpc.toml 已写入"

# ---------- 7. 创建 systemd 服务 ----------
# CC-Bridge service
cat > /etc/systemd/system/ccb.service << 'SVCEOF'
[Unit]
Description=CC-Bridge (Claude Code Gateway)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/ccb
EnvironmentFile=/opt/ccb/.env
ExecStart=/opt/ccb/claude-code-gateway
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

# frpc service
cat > /etc/systemd/system/ccb-frpc.service << 'SVCEOF'
[Unit]
Description=frpc for CC-Bridge
After=network.target

[Service]
Type=simple
ExecStart=/opt/ccb/frpc -c /opt/ccb/frpc.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
ok "systemd 服务已创建"

# ---------- 8. 启动服务 ----------
info "启动服务..."
systemctl enable ccb ccb-frpc
systemctl restart ccb
sleep 2
systemctl restart ccb-frpc
sleep 2
ok "服务已启动"

# ---------- 9. 验证 ----------
echo ""
echo "========================================="
echo "         部署验证"
echo "========================================="

PASS=0
TOTAL=4

# 检查 ccb 进程
if systemctl is-active ccb &>/dev/null; then
    ok "CC-Bridge 进程正常"
    PASS=$((PASS + 1))
else
    fail "CC-Bridge 未运行"
    journalctl -u ccb --no-pager -n 5
fi

# 检查 frpc 进程
if systemctl is-active ccb-frpc &>/dev/null; then
    ok "frpc 进程正常"
    PASS=$((PASS + 1))
else
    fail "frpc 未运行"
    journalctl -u ccb-frpc --no-pager -n 5
fi

# 检查本地端口
sleep 1
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${CCB_PORT}" 2>/dev/null | grep -qE "200|302|401|404"; then
    ok "CC-Bridge 本地端口 ${CCB_PORT} 可达"
    PASS=$((PASS + 1))
else
    fail "CC-Bridge 本地端口 ${CCB_PORT} 不可达"
fi

# 检查 frpc 隧道日志
if journalctl -u ccb-frpc --no-pager -n 20 2>/dev/null | grep -qi "start proxy success\|connected"; then
    ok "frpc 隧道已连通 → 主服务器:${REMOTE_PORT}"
    PASS=$((PASS + 1))
else
    fail "frpc 隧道未确认连通 (可能延迟，请稍后检查)"
fi

echo ""
echo "========================================="
echo "  验证结果: ${PASS}/${TOTAL} 通过"
echo "========================================="
echo ""
echo "  节点名:       $NODE_NAME"
echo "  本地访问:     http://127.0.0.1:${CCB_PORT}"
echo "  远程访问:     http://${SERVER_IP}:${REMOTE_PORT}"
echo "  管理密码:     $ADMIN_PASS"
echo ""
echo "  管理命令:"
echo "    systemctl status ccb        # 查看 CC-Bridge 状态"
echo "    systemctl status ccb-frpc   # 查看 frpc 状态"
echo "    systemctl restart ccb       # 重启 CC-Bridge"
echo "    journalctl -u ccb -f        # 查看日志"
echo "========================================="
