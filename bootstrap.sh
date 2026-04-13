#!/bin/bash

########################################
# CC-Bridge 容器自启动脚本
# 只需传一个端口，自动安装并上线
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/ziren28/ccb/main/bootstrap.sh | bash -s -- 5001
#   curl -fsSL https://raw.githubusercontent.com/ziren28/ccb/main/bootstrap.sh | bash -s -- 5001 5022
#
# 参数1: CCB 远程端口 (必填)
# 参数2: SSH 远程端口 (可选)
########################################

REMOTE_PORT="$1"
SSH_PORT="$2"

[ -z "$REMOTE_PORT" ] && { echo "用法: bash bootstrap.sh <端口> [SSH端口]"; exit 1; }

# ===== 内置配置 =====
SERVER_IP="154.17.9.75"
FRP_TOKEN="ccb_frp_token_2026"
PG_PASS="ccb_pg_2026"
REDIS_PASS="ccb_redis_2026"
ADMIN_PASS="admin"
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFFnOxdTeiK4H+uwEQ/jLLT19eseJxVFBdUnoyK1y/Fs ed25519 256-20260410"
FRP_VERSION="0.61.1"
CCB_PORT=5674

# 从端口推算组号: 5001->1, 5002->2, ...
GROUP=$((REMOTE_PORT - 5000))
DB_NAME="ccb_g${GROUP}"
REDIS_DB=$((GROUP - 1))
NODE_NAME="ccb-${REMOTE_PORT}-$$"

ARCH=$(uname -m)
case "$ARCH" in x86_64) A="amd64";; aarch64) A="arm64";; *) echo "不支持: $ARCH"; exit 1;; esac

mkdir -p /opt/ccb/data

# 安装依赖
apt-get update -qq && apt-get install -y -qq curl ca-certificates 2>/dev/null || yum install -y curl ca-certificates 2>/dev/null

# 下载 CC-Bridge
[ -f /opt/ccb/claude-code-gateway ] || {
    curl -fsSL "https://github.com/MamoWorks/cc-bridge/releases/download/v1.6.0/claude-code-gateway-linux-${A}.tar.gz" -o /tmp/ccb.tar.gz
    tar xzf /tmp/ccb.tar.gz -C /opt/ccb/
    mv "/opt/ccb/claude-code-gateway-linux-${A}" /opt/ccb/claude-code-gateway
    chmod +x /opt/ccb/claude-code-gateway
    rm -f /tmp/ccb.tar.gz
}

# 下载 frpc
[ -f /opt/ccb/frpc ] || {
    P="frp_${FRP_VERSION}_linux_${A}"
    curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${P}.tar.gz" -o /tmp/frp.tar.gz
    tar xzf /tmp/frp.tar.gz -C /tmp/
    cp "/tmp/${P}/frpc" /opt/ccb/frpc && chmod +x /opt/ccb/frpc
    rm -rf /tmp/frp.tar.gz "/tmp/${P}"
}

# 写配置
cat > /opt/ccb/.env << EOF
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
EOF

cat > /opt/ccb/frpc.toml << EOF
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
EOF

# SSH (可选)
if [ -n "$SSH_PORT" ]; then
    command -v sshd &>/dev/null || { apt-get install -y -qq openssh-server 2>/dev/null || yum install -y openssh-server 2>/dev/null; }
    ssh-keygen -A 2>/dev/null
    mkdir -p /root/.ssh /run/sshd
    echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/;s/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    /usr/sbin/sshd

    cat > /opt/ccb/frpc-ssh.toml << EOF
serverAddr = "${SERVER_IP}"
serverPort = 7000
auth.method = "token"
auth.token = "${FRP_TOKEN}"

[[proxies]]
name = "ssh-${NODE_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${SSH_PORT}
EOF
    /opt/ccb/frpc -c /opt/ccb/frpc-ssh.toml >> /opt/ccb/data/frpc-ssh.log 2>&1 &
fi

# 启动 frpc
/opt/ccb/frpc -c /opt/ccb/frpc.toml >> /opt/ccb/data/frpc.log 2>&1 &

# 启动 CC-Bridge (前台)
set -a; source /opt/ccb/.env; set +a
exec /opt/ccb/claude-code-gateway
