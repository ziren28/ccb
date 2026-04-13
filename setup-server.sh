#!/bin/bash
set -e

########################################
# CC-Bridge 主服务器一键部署脚本
# 安装: PostgreSQL + Redis + frps
# 用法: bash setup-server.sh
########################################

# ========== 配置区 ==========
PG_PASSWORD="ccb_pg_2026"
REDIS_PASSWORD="ccb_redis_2026"
FRP_TOKEN="ccb_frp_token_2026"
FRP_VERSION="0.61.1"
FRP_BIND_PORT=7000
FRP_ALLOW_PORTS="5001-5100"
# ============================

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_NC='\033[0m'

ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_NC} $1"; }
fail() { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $1"; }
info() { echo -e "${COLOR_YELLOW}[INFO]${COLOR_NC} $1"; }

# ---------- 1. 检测系统 ----------
info "检测系统环境..."
if [ "$(id -u)" -ne 0 ]; then
    fail "请用 root 运行"; exit 1
fi

if [ -f /etc/debian_version ]; then
    PKG_MGR="apt"
    export DEBIAN_FRONTEND=noninteractive
elif [ -f /etc/redhat-release ]; then
    PKG_MGR="yum"
else
    fail "不支持的系统"; exit 1
fi
ok "系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    *)       fail "不支持的架构: $ARCH"; exit 1 ;;
esac

# ---------- 2. 安装 PostgreSQL ----------
info "安装 PostgreSQL..."
if command -v psql &>/dev/null; then
    ok "PostgreSQL 已安装: $(psql --version)"
else
    if [ "$PKG_MGR" = "apt" ]; then
        apt-get update -qq
        apt-get install -y -qq postgresql postgresql-contrib
    else
        yum install -y postgresql-server postgresql-contrib
        postgresql-setup --initdb 2>/dev/null || true
    fi
    ok "PostgreSQL 安装完成"
fi

# 启动 PostgreSQL
systemctl enable postgresql
systemctl start postgresql
ok "PostgreSQL 已启动"

# 设置密码
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_PASSWORD';\"" 2>/dev/null
ok "PostgreSQL 密码已设置"

# 创建 10 个数据库
info "创建 10 个数据库..."
for i in $(seq 1 10); do
    DB_NAME="ccb_g${i}"
    su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1" 2>/dev/null \
        && info "  $DB_NAME 已存在" \
        || { su - postgres -c "psql -c \"CREATE DATABASE $DB_NAME;\"" 2>/dev/null && ok "  $DB_NAME 已创建"; }
done

# 配置远程访问
PG_CONF_DIR=$(su - postgres -c "psql -tc \"SHOW config_file;\"" | xargs dirname)
PG_HBA="$PG_CONF_DIR/pg_hba.conf"
PG_CONF="$PG_CONF_DIR/postgresql.conf"

# listen_addresses
if grep -q "^listen_addresses" "$PG_CONF"; then
    sed -i "s/^listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
else
    echo "listen_addresses = '*'" >> "$PG_CONF"
fi

# pg_hba: 允许所有 IP 用密码连接
if ! grep -q "0.0.0.0/0.*md5\|0.0.0.0/0.*scram" "$PG_HBA"; then
    echo "host    all    all    0.0.0.0/0    md5" >> "$PG_HBA"
fi

systemctl restart postgresql
ok "PostgreSQL 远程访问已配置"

# ---------- 3. 安装 Redis ----------
info "安装 Redis..."
if command -v redis-server &>/dev/null; then
    ok "Redis 已安装: $(redis-server --version | head -1)"
else
    if [ "$PKG_MGR" = "apt" ]; then
        apt-get install -y -qq redis-server
    else
        yum install -y redis
    fi
    ok "Redis 安装完成"
fi

# 配置 Redis
REDIS_CONF="/etc/redis/redis.conf"
[ -f "$REDIS_CONF" ] || REDIS_CONF="/etc/redis.conf"

if [ -f "$REDIS_CONF" ]; then
    # bind 所有接口
    sed -i 's/^bind 127.0.0.1.*/bind 0.0.0.0/' "$REDIS_CONF"
    sed -i 's/^# bind 0.0.0.0/bind 0.0.0.0/' "$REDIS_CONF"
    # 设置密码
    if grep -q "^requirepass" "$REDIS_CONF"; then
        sed -i "s/^requirepass.*/requirepass $REDIS_PASSWORD/" "$REDIS_CONF"
    else
        echo "requirepass $REDIS_PASSWORD" >> "$REDIS_CONF"
    fi
    # 关闭 protected-mode
    sed -i 's/^protected-mode yes/protected-mode no/' "$REDIS_CONF"
fi

systemctl enable redis-server 2>/dev/null || systemctl enable redis 2>/dev/null
systemctl restart redis-server 2>/dev/null || systemctl restart redis 2>/dev/null
ok "Redis 已配置并启动"

# ---------- 4. 安装 frps ----------
info "安装 frps..."
if command -v frps &>/dev/null || [ -f /usr/local/bin/frps ]; then
    ok "frps 已安装"
else
    FRP_PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PKG}.tar.gz"
    info "下载 frp v${FRP_VERSION}..."
    cd /tmp
    curl -fsSL "$FRP_URL" -o frp.tar.gz
    tar xzf frp.tar.gz
    cp "${FRP_PKG}/frps" /usr/local/bin/frps
    chmod +x /usr/local/bin/frps
    rm -rf frp.tar.gz "${FRP_PKG}"
    ok "frps 安装完成"
fi

# frps 配置
mkdir -p /etc/frp
cat > /etc/frp/frps.toml << FRPEOF
bindPort = $FRP_BIND_PORT
auth.method = "token"
auth.token = "$FRP_TOKEN"
allowPorts = [
  { start = 5001, end = 5100 }
]
FRPEOF
ok "frps 配置已写入 /etc/frp/frps.toml"

# systemd service
cat > /etc/systemd/system/frps.service << 'SVCEOF'
[Unit]
Description=frp server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable frps
systemctl restart frps
ok "frps 已启动"

# ---------- 5. 防火墙 ----------
info "配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow 5432/tcp comment "PostgreSQL"
    ufw allow 6379/tcp comment "Redis"
    ufw allow 7000/tcp comment "frps control"
    ufw allow 5001:5100/tcp comment "frp tunnels"
    ok "ufw 规则已添加"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=5432/tcp
    firewall-cmd --permanent --add-port=6379/tcp
    firewall-cmd --permanent --add-port=7000/tcp
    firewall-cmd --permanent --add-port=5001-5100/tcp
    firewall-cmd --reload
    ok "firewalld 规则已添加"
else
    info "未检测到防火墙，跳过"
fi

# ---------- 6. 验证 ----------
echo ""
echo "========================================="
echo "         部署验证"
echo "========================================="

# PostgreSQL
if su - postgres -c "psql -c 'SELECT 1'" &>/dev/null; then
    ok "PostgreSQL 运行正常"
    DB_COUNT=$(su - postgres -c "psql -tc \"SELECT count(*) FROM pg_database WHERE datname LIKE 'ccb_g%';\"" | xargs)
    ok "  数据库数量: $DB_COUNT"
else
    fail "PostgreSQL 连接失败"
fi

# Redis
if redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
    ok "Redis 运行正常"
else
    fail "Redis 连接失败"
fi

# frps
if systemctl is-active frps &>/dev/null; then
    ok "frps 运行正常 (端口 $FRP_BIND_PORT)"
else
    fail "frps 未运行"
fi

echo ""
echo "========================================="
echo "         连接信息"
echo "========================================="
SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo "  服务器 IP:       $SERVER_IP"
echo "  PostgreSQL:      $SERVER_IP:5432"
echo "  PG 密码:         $PG_PASSWORD"
echo "  Redis:           $SERVER_IP:6379"
echo "  Redis 密码:      $REDIS_PASSWORD"
echo "  frps:            $SERVER_IP:$FRP_BIND_PORT"
echo "  frp Token:       $FRP_TOKEN"
echo "  隧道端口范围:    5001-5100"
echo ""
echo "  数据库列表:      ccb_g1 ~ ccb_g10"
echo "  Redis DB:        0 ~ 9 (对应组 1~10)"
echo "========================================="
echo ""
ok "主服务器部署完成! 接下来在外部节点执行 install-node.sh"
