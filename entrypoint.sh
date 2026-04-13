#!/bin/bash

########################################
# CC-Bridge 容器入口脚本
# 容器销毁重建后自动恢复服务
#
# 挂载 /opt/ccb 为持久卷，首次运行自动安装，
# 后续重建容器直接启动服务。
#
# 环境变量:
#   CCB_GROUP       - 节点组号 (必填, 1~10)
#   CCB_NODE        - 节点号 (必填, 1~5)
#   CCB_SERVER_IP   - 主服务器 IP (必填)
#   CCB_FRP_TOKEN   - frp token (默认 ccb_frp_token_2026)
#   CCB_PG_PASS     - PostgreSQL 密码 (默认 ccb_pg_2026)
#   CCB_REDIS_PASS  - Redis 密码 (默认 ccb_redis_2026)
#   CCB_ADMIN_PASS  - 管理密码 (默认 admin)
#   CCB_SSH_PORT    - SSH 反代端口 (可选，不设则不装 SSH)
#   CCB_SSH_PUBKEY  - SSH 公钥 (可选)
########################################

set -e

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'
ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_NC} $1"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $1"; }
info() { echo -e "${COLOR_YELLOW}[INFO]${COLOR_NC} $1"; }

# 默认值
CCB_FRP_TOKEN="${CCB_FRP_TOKEN:-ccb_frp_token_2026}"
CCB_PG_PASS="${CCB_PG_PASS:-ccb_pg_2026}"
CCB_REDIS_PASS="${CCB_REDIS_PASS:-ccb_redis_2026}"
CCB_ADMIN_PASS="${CCB_ADMIN_PASS:-admin}"
CCB_SSH_PUBKEY="${CCB_SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFFnOxdTeiK4H+uwEQ/jLLT19eseJxVFBdUnoyK1y/Fs ed25519 256-20260410}"

# 参数校验
if [ -z "$CCB_GROUP" ] || [ -z "$CCB_NODE" ] || [ -z "$CCB_SERVER_IP" ]; then
    fail "缺少环境变量: CCB_GROUP, CCB_NODE, CCB_SERVER_IP"
    echo "用法: docker run -e CCB_GROUP=1 -e CCB_NODE=1 -e CCB_SERVER_IP=154.17.9.75 ..."
    exit 1
fi

REMOTE_PORT=$((5000 + CCB_GROUP))
DB_NAME="ccb_g${CCB_GROUP}"
REDIS_DB=$((CCB_GROUP - 1))
NODE_NAME="ccb-g${CCB_GROUP}-n${CCB_NODE}"
CCB_PORT=5674
FRP_VERSION="0.61.1"

echo ""
echo "========================================="
echo "  CC-Bridge 容器自动部署"
echo "========================================="
echo "  节点: $NODE_NAME  端口: $REMOTE_PORT"
echo "  服务器: $CCB_SERVER_IP"
echo "========================================="
echo ""

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  CCB_ARCH="amd64" ;;
    aarch64) CCB_ARCH="arm64" ;;
    *)       fail "不支持的架构: $ARCH"; exit 1 ;;
esac

mkdir -p /opt/ccb/data

# ---------- 1. 安装 CC-Bridge (首次) ----------
if [ ! -f /opt/ccb/claude-code-gateway ]; then
    info "首次安装: 下载 CC-Bridge..."
    CCB_DL_URL="https://github.com/MamoWorks/cc-bridge/releases/download/v1.6.0/claude-code-gateway-linux-${CCB_ARCH}.tar.gz"
    curl -fsSL "$CCB_DL_URL" -o /tmp/ccb.tar.gz
    tar xzf /tmp/ccb.tar.gz -C /opt/ccb/
    mv /opt/ccb/claude-code-gateway-linux-${CCB_ARCH} /opt/ccb/claude-code-gateway
    chmod +x /opt/ccb/claude-code-gateway
    rm -f /tmp/ccb.tar.gz
    ok "CC-Bridge 已下载"
else
    ok "CC-Bridge 已存在 (持久卷)"
fi

# ---------- 2. 安装 frpc (首次) ----------
if [ ! -f /opt/ccb/frpc ]; then
    info "首次安装: 下载 frpc..."
    FRP_PKG="frp_${FRP_VERSION}_linux_${CCB_ARCH}"
    curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PKG}.tar.gz" -o /tmp/frp.tar.gz
    tar xzf /tmp/frp.tar.gz -C /tmp/
    cp "/tmp/${FRP_PKG}/frpc" /opt/ccb/frpc
    chmod +x /opt/ccb/frpc
    rm -rf /tmp/frp.tar.gz "/tmp/${FRP_PKG}"
    ok "frpc 已下载"
else
    ok "frpc 已存在 (持久卷)"
fi

# ---------- 3. 写入配置 (每次更新) ----------
cat > /opt/ccb/.env << ENVEOF
DATABASE_DRIVER=postgres
DATABASE_HOST=${CCB_SERVER_IP}
DATABASE_PORT=5432
DATABASE_USER=postgres
DATABASE_PASSWORD=${CCB_PG_PASS}
DATABASE_DBNAME=${DB_NAME}
REDIS_HOST=${CCB_SERVER_IP}
REDIS_PORT=6379
REDIS_PASSWORD=${CCB_REDIS_PASS}
REDIS_DB=${REDIS_DB}
ADMIN_PASSWORD=${CCB_ADMIN_PASS}
SERVER_HOST=0.0.0.0
SERVER_PORT=${CCB_PORT}
ENVEOF

cat > /opt/ccb/frpc.toml << FRPCEOF
serverAddr = "${CCB_SERVER_IP}"
serverPort = 7000
auth.method = "token"
auth.token = "${CCB_FRP_TOKEN}"

[[proxies]]
name = "${NODE_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${CCB_PORT}
remotePort = ${REMOTE_PORT}
FRPCEOF

ok "配置已写入"

# ---------- 4. SSH (可选) ----------
if [ -n "$CCB_SSH_PORT" ]; then
    info "配置 SSH..."
    # 安装 openssh
    if ! command -v sshd &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq openssh-server 2>/dev/null || \
        yum install -y openssh-server 2>/dev/null
    fi
    ssh-keygen -A 2>/dev/null
    mkdir -p /root/.ssh /run/sshd
    chmod 700 /root/.ssh
    echo "$CCB_SSH_PUBKEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

    /usr/sbin/sshd
    ok "sshd 已启动"

    # frpc-ssh
    SSH_PROXY_NAME="ssh-${NODE_NAME}"
    cat > /opt/ccb/frpc-ssh.toml << SSHEOF
serverAddr = "${CCB_SERVER_IP}"
serverPort = 7000
auth.method = "token"
auth.token = "${CCB_FRP_TOKEN}"

[[proxies]]
name = "${SSH_PROXY_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${CCB_SSH_PORT}
SSHEOF

    /opt/ccb/frpc -c /opt/ccb/frpc-ssh.toml >> /opt/ccb/data/frpc-ssh.log 2>&1 &
    ok "SSH 反代已启动 → :${CCB_SSH_PORT}"
fi

# ---------- 5. 启动服务 (前台) ----------
info "启动 CC-Bridge + frpc..."

# frpc 后台
/opt/ccb/frpc -c /opt/ccb/frpc.toml >> /opt/ccb/data/frpc.log 2>&1 &
FRPC_PID=$!

# gateway 前台 (容器主进程)
set -a
source /opt/ccb/.env
set +a

echo ""
ok "所有服务已启动"
echo "========================================="
echo "  节点: $NODE_NAME"
echo "  远程: http://${CCB_SERVER_IP}:${REMOTE_PORT}"
echo "  密码: $CCB_ADMIN_PASS"
[ -n "$CCB_SSH_PORT" ] && echo "  SSH:  ssh -p ${CCB_SSH_PORT} root@${CCB_SERVER_IP}"
echo "========================================="
echo ""

# 捕获信号优雅退出
trap "kill $FRPC_PID 2>/dev/null; exit 0" SIGTERM SIGINT

# CC-Bridge 前台运行 (容器主进程，退出则容器停止)
exec /opt/ccb/claude-code-gateway
