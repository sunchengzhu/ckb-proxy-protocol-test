#!/usr/bin/env bash
set -euo pipefail

# ============================================
# 跨机测试 — 服务端 (Node B + HAProxy)
# 在 Ubuntu 22 服务端机器上运行
# ============================================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${BASE_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi
CKB_BIN="${CKB_BIN:-ckb}"

# 验证 CKB 二进制
if [[ "${CKB_BIN}" == /* ]]; then
    if [ ! -x "${CKB_BIN}" ]; then
        echo "✗ 找不到可执行的 CKB_BIN: ${CKB_BIN}"
        echo "  在 ${ENV_FILE} 中写入: CKB_BIN=/path/to/ckb"
        exit 1
    fi
else
    if ! command -v "${CKB_BIN}" >/dev/null 2>&1; then
        echo "✗ 找不到 CKB_BIN: ${CKB_BIN}"
        echo "  在 ${ENV_FILE} 中写入: CKB_BIN=/path/to/ckb"
        exit 1
    fi
fi

# 检查 HAProxy 是否已安装
if ! command -v haproxy >/dev/null 2>&1; then
    echo "✗ 未安装 HAProxy，请先安装:"
    echo "  sudo apt update && sudo apt install -y haproxy"
    exit 1
fi

echo "=========================================="
echo " 跨机测试 — 服务端初始化"
echo "=========================================="

DEV_BA_ARG="0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7"

echo ""
echo "[1/2] 初始化节点 B (服务端) ..."
rm -rf "${BASE_DIR}/node_b"
mkdir -p "${BASE_DIR}/node_b"
cd "${BASE_DIR}/node_b"
${CKB_BIN} init -c dev --ba-arg "${DEV_BA_ARG}" --force 2>&1 | tail -3 || true

# 加快出块速度
sed -i 's/value = 5000/value = 500/' ckb-miner.toml

# 让 RPC 监听所有接口（跨机需要远程访问）
sed -i 's/listen_address = "127.0.0.1:8114"/listen_address = "0.0.0.0:8114"/' ckb.toml

# 生成 secret_key
mkdir -p "${BASE_DIR}/node_b/data/network"
${CKB_BIN} peer-id gen --secret-path "${BASE_DIR}/node_b/data/network/secret_key"

NODE_B_PEER_ID=$(${CKB_BIN} peer-id from-secret --secret-path "${BASE_DIR}/node_b/data/network/secret_key" 2>&1 | sed 's/^peer_id: //')
echo "  节点 B peer_id: ${NODE_B_PEER_ID}"
echo "${NODE_B_PEER_ID}" > "${BASE_DIR}/.node_b_peer_id"

# [2/2] 生成 HAProxy 配置
echo ""
echo "[2/2] 生成 HAProxy 配置 ..."

cat > "${BASE_DIR}/haproxy.cfg" <<'HAPROXY_EOF'
global
    log stdout format raw local0 info
    maxconn 4096

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 10s
    timeout client  300s
    timeout server  300s

# TCP 代理 - PROXY Protocol v2
frontend tcp_proxy
    bind *:8230
    default_backend tcp_backend

backend tcp_backend
    server ckb 127.0.0.1:8115 send-proxy-v2

# WebSocket 代理 - X-Forwarded-For + X-Forwarded-Port
frontend ws_proxy
    bind *:8231
    mode http
    default_backend ws_backend

backend ws_backend
    mode http
    option forwardfor
    http-request set-header X-Forwarded-Port %[src_port]
    server ckb 127.0.0.1:8115
HAPROXY_EOF

echo "  haproxy.cfg 已生成: ${BASE_DIR}/haproxy.cfg"

echo ""
echo "=========================================="
echo " 服务端初始化完成！"
echo "=========================================="
echo ""
echo "  节点 B: P2P=8115  RPC=0.0.0.0:8114"
echo "  peer_id: ${NODE_B_PEER_ID}"
echo "  HAProxy: TCP=8230 (proxy-v2)  WS=8231 (X-Fwd-For/Port)"
echo ""
echo "  ⚠️  请将 peer_id 传递给客户端机器:"
echo "     echo '${NODE_B_PEER_ID}' > .node_b_peer_id"
echo ""
echo "  下一步: bash start.sh"
