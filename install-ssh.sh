#!/bin/bash
set -e

########################################
# 一键安装 SSH + frpc 反代
# 用法:
#   bash install-ssh.sh --port 5022 \
#     --server-ip 35.212.182.237 \
#     --frp-token ccb_frp_token_2026 \
#     --name ssh-node1
#
# --port: 主服务器上暴露的远程 SSH 端口
# --name: frpc 代理名称 (需唯一)
########################################

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'
ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_NC} $1"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $1"; }
info() { echo -e "${COLOR_YELLOW}[INFO]${COLOR_NC} $1"; }

# ========== 参数 ==========
REMOTE_PORT=""
SERVER_IP="35.212.182.237"
FRP_TOKEN="ccb_frp_token_2026"
PROXY_NAME=""
LOCAL_SSH_PORT=22
FRP_VERSION="0.61.1"
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFFnOxdTeiK4H+uwEQ/jLLT19eseJxVFBdUnoyK1y/Fs ed25519 256-20260410"

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)       REMOTE_PORT="$2"; shift 2 ;;
        --server-ip)  SERVER_IP="$2"; shift 2 ;;
        --server)     SERVER_IP="$2"; shift 2 ;;
        --frp-token)  FRP_TOKEN="$2"; shift 2 ;;
        --name)       PROXY_NAME="$2"; shift 2 ;;
        --local-port) LOCAL_SSH_PORT="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if [ -z "$REMOTE_PORT" ]; then
    fail "缺少 --port (主服务器暴露的 SSH 端口)"
    echo "用法: bash install-ssh.sh --port 5022 --name ssh-node1"
    exit 1
fi

[ -z "$PROXY_NAME" ] && PROXY_NAME="ssh-${REMOTE_PORT}"

if [ "$(id -u)" -ne 0 ]; then
    fail "请用 root 运行"; exit 1
fi

echo ""
echo "========================================="
echo "  SSH + frpc 反代安装"
echo "========================================="
echo "  主服务器:     $SERVER_IP"
echo "  远程SSH端口:  $REMOTE_PORT"
echo "  本地SSH端口:  $LOCAL_SSH_PORT"
echo "  代理名称:     $PROXY_NAME"
echo "========================================="
echo ""

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    *)       fail "不支持的架构: $ARCH"; exit 1 ;;
esac

# ---------- 1. 安装 SSH ----------
info "安装 OpenSSH Server..."
if command -v sshd &>/dev/null; then
    ok "sshd 已安装"
else
    if [ -f /etc/debian_version ]; then
        apt-get update -qq
        apt-get install -y -qq openssh-server
    elif [ -f /etc/redhat-release ]; then
        yum install -y openssh-server
    else
        fail "不支持的系统"; exit 1
    fi
    ok "openssh-server 已安装"
fi

# ---------- 2. 配置 SSH ----------
info "配置 SSH..."

# 生成 host key（容器可能没有）
ssh-keygen -A 2>/dev/null
ok "Host keys 已生成"

# 配置 sshd
SSHD_CONF="/etc/ssh/sshd_config"
# 允许公钥认证
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONF"
# 禁用密码登录
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
# 监听端口
sed -i "s/^#*Port .*/Port $LOCAL_SSH_PORT/" "$SSHD_CONF"
# 允许 root 登录
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONF"
ok "sshd_config 已配置 (仅公钥, 端口 $LOCAL_SSH_PORT)"

# ---------- 3. 添加公钥 ----------
info "添加公钥..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
    ok "公钥已存在"
else
    echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    ok "公钥已添加"
fi

# ---------- 4. 启动 SSH ----------
info "启动 SSH..."
HAS_SYSTEMD=false
if pidof systemd &>/dev/null && systemctl --version &>/dev/null; then
    HAS_SYSTEMD=true
fi

if $HAS_SYSTEMD; then
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    ok "sshd 已通过 systemd 启动"
else
    # 容器环境：直接启动
    mkdir -p /run/sshd
    pkill sshd 2>/dev/null || true
    /usr/sbin/sshd -p "$LOCAL_SSH_PORT"
    ok "sshd 已直接启动 (端口 $LOCAL_SSH_PORT)"
fi

# ---------- 5. 安装 frpc ----------
info "安装 frpc..."
mkdir -p /opt/ccb/data

if [ -f /opt/ccb/frpc ]; then
    ok "frpc 已存在"
else
    FRP_PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PKG}.tar.gz"
    curl -fsSL "$FRP_URL" -o /tmp/frp.tar.gz
    tar xzf /tmp/frp.tar.gz -C /tmp/
    cp "/tmp/${FRP_PKG}/frpc" /opt/ccb/frpc
    chmod +x /opt/ccb/frpc
    rm -rf /tmp/frp.tar.gz "/tmp/${FRP_PKG}"
    ok "frpc 已下载"
fi

# ---------- 6. frpc 配置 ----------
info "写入 frpc-ssh 配置..."
cat > /opt/ccb/frpc-ssh.toml << FRPCEOF
serverAddr = "${SERVER_IP}"
serverPort = 7000
auth.method = "token"
auth.token = "${FRP_TOKEN}"

[[proxies]]
name = "${PROXY_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_SSH_PORT}
remotePort = ${REMOTE_PORT}
FRPCEOF
ok "frpc-ssh.toml 已写入"

# ---------- 7. 启动 frpc ----------
info "启动 frpc..."

# 停掉旧的 ssh 隧道
pkill -f "frpc.*frpc-ssh" 2>/dev/null || true
sleep 1

if $HAS_SYSTEMD; then
    cat > /etc/systemd/system/ccb-frpc-ssh.service << SVCEOF
[Unit]
Description=frpc SSH tunnel
After=network.target

[Service]
Type=simple
ExecStart=/opt/ccb/frpc -c /opt/ccb/frpc-ssh.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable ccb-frpc-ssh
    systemctl restart ccb-frpc-ssh
    ok "frpc-ssh systemd 服务已启动"
else
    nohup /opt/ccb/frpc -c /opt/ccb/frpc-ssh.toml >> /opt/ccb/data/frpc-ssh.log 2>&1 &
    sleep 2
    ok "frpc-ssh 已后台启动"
fi

# ---------- 8. 验证 ----------
echo ""
echo "========================================="
echo "         验证"
echo "========================================="

PASS=0
TOTAL=2

if pgrep -f "sshd" &>/dev/null; then
    ok "sshd 进程正常"
    PASS=$((PASS + 1))
else
    fail "sshd 未运行"
fi

if pgrep -f "frpc.*frpc-ssh" &>/dev/null; then
    ok "frpc-ssh 进程正常"
    PASS=$((PASS + 1))
else
    fail "frpc-ssh 未运行"
fi

echo ""
echo "========================================="
echo "  验证结果: ${PASS}/${TOTAL} 通过"
echo "========================================="
echo ""
echo "  连接命令:"
echo "    ssh -p ${REMOTE_PORT} root@${SERVER_IP}"
echo ""
echo "  管理命令:"
if $HAS_SYSTEMD; then
echo "    systemctl status ccb-frpc-ssh"
echo "    systemctl restart ccb-frpc-ssh"
else
echo "    tail -f /opt/ccb/data/frpc-ssh.log"
echo "    pkill -f 'frpc.*frpc-ssh'   # 停止隧道"
fi
echo "========================================="
