#!/bin/bash

########################################
# 批量生成节点安装命令
# 用法: bash gen-commands.sh [选项]
#
# 选项:
#   --groups N          节点组数 (默认 3)
#   --nodes-per-group N 每组节点数 (默认 2)
#   --server-ip IP      主服务器 IP (默认自动检测)
#   --frp-token TOKEN   frp token
#   --pg-pass PW        PostgreSQL 密码
#   --redis-pass PW     Redis 密码
#   --admin-pass PW     管理后台密码 (默认 admin)
########################################

GROUPS=3
NODES_PER_GROUP=2
SERVER_IP=""
FRP_TOKEN="ccb_frp_token_2026"
PG_PASS="ccb_pg_2026"
REDIS_PASS="ccb_redis_2026"
ADMIN_PASS="admin"

while [[ $# -gt 0 ]]; do
    case $1 in
        --groups)          GROUPS="$2"; shift 2 ;;
        --nodes-per-group) NODES_PER_GROUP="$2"; shift 2 ;;
        --server-ip)       SERVER_IP="$2"; shift 2 ;;
        --frp-token)       FRP_TOKEN="$2"; shift 2 ;;
        --pg-pass)         PG_PASS="$2"; shift 2 ;;
        --redis-pass)      REDIS_PASS="$2"; shift 2 ;;
        --admin-pass)      ADMIN_PASS="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# 自动检测 IP
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
fi

echo ""
echo "=========================================================="
echo "  CC-Bridge 节点安装命令"
echo "=========================================================="
echo "  主服务器:       $SERVER_IP"
echo "  节点组数:       $GROUPS"
echo "  每组节点数:     $NODES_PER_GROUP"
echo "  端口范围:       5001 ~ $((5000 + GROUPS * 10))"
echo "=========================================================="
echo ""

for g in $(seq 1 "$GROUPS"); do
    PORT=$((5000 + g))
    echo "==========================================="
    echo "  组 $g  (端口: ${PORT}, 数据库: ccb_g${g}, Redis DB: $((g-1)))"
    echo "  同组节点共享端口，同时只有一台在线"
    echo "==========================================="
    echo ""
    for n in $(seq 1 "$NODES_PER_GROUP"); do
        echo "--- 节点 ${g}-${n} ---"
        echo ""
        cat << CMDEOF
curl -fsSL https://raw.githubusercontent.com/ziren28/ccb/main/install-node.sh | bash -s -- \\
  --group $g --node $n \\
  --server-ip $SERVER_IP \\
  --frp-token $FRP_TOKEN \\
  --pg-pass $PG_PASS \\
  --redis-pass $REDIS_PASS \\
  --admin-pass $ADMIN_PASS
CMDEOF
        echo ""
    done
done

echo "==========================================="
echo "  端口分配表 (每组一个端口)"
echo "==========================================="
for g in $(seq 1 "$GROUPS"); do
    PORT=$((5000 + g))
    echo "  组${g}  →  :${PORT}  (${NODES_PER_GROUP} 个节点轮换)"
done
echo "==========================================="
