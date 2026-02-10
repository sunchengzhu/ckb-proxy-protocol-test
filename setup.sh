#!/usr/bin/env bash
set -euo pipefail

# ============================================
# 使用说明:
#   1. 确保 ckb 二进制在 PATH 中，或者修改下面的 CKB_BIN 变量
#   2. 运行: bash setup.sh
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

if [[ "${CKB_BIN}" == /* ]]; then
    if [ ! -x "${CKB_BIN}" ]; then
        echo "✗ 找不到可执行的 CKB_BIN: ${CKB_BIN}"
        echo "  解决方案:"
        echo "    1) export CKB_BIN=/path/to/ckb"
        echo "    2) 或在 ${ENV_FILE} 中写入: CKB_BIN=/path/to/ckb"
        exit 1
    fi
else
    if ! command -v "${CKB_BIN}" >/dev/null 2>&1; then
        echo "✗ 找不到 CKB_BIN: ${CKB_BIN}"
        echo "  解决方案:"
        echo "    1) export CKB_BIN=/path/to/ckb"
        echo "    2) 或在 ${ENV_FILE} 中写入: CKB_BIN=/path/to/ckb"
        exit 1
    fi
fi

echo "=========================================="
echo " CKB Proxy Protocol 测试环境初始化"
echo "=========================================="

# --- 初始化节点 B (服务端，监听 8115，RPC 8114) ---
echo ""
# 使用 dev chain 测试用 lock arg 初始化（需要 --ba-arg 才能启用 Miner RPC）
DEV_BA_ARG="0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7"

echo "[1/4] 初始化节点 B (服务端) ..."
rm -rf "${BASE_DIR}/node_b"
mkdir -p "${BASE_DIR}/node_b"
cd "${BASE_DIR}/node_b"
${CKB_BIN} init -c dev --ba-arg "${DEV_BA_ARG}" --force 2>&1 | tail -3 || true

# 加快出块速度（Dummy PoW 的间隔从 5000ms 改为 500ms）
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/value = 5000/value = 500/' ckb-miner.toml
else
    sed -i 's/value = 5000/value = 500/' ckb-miner.toml
fi

# - 默认监听 /ip4/0.0.0.0/tcp/8115
# - 默认 reuse_tcp_with_ws = true（同端口也监听 WS）
# - 默认 trusted_proxies 包含 127.0.0.1 和 ::1

# 生成 secret_key（ckb init 不会自动生成，需要手动生成）
mkdir -p "${BASE_DIR}/node_b/data/network"
${CKB_BIN} peer-id gen --secret-path "${BASE_DIR}/node_b/data/network/secret_key"

# 提取节点 B 的 peer_id（输出格式: "peer_id: Qm..."）
NODE_B_PEER_ID=$(${CKB_BIN} peer-id from-secret --secret-path "${BASE_DIR}/node_b/data/network/secret_key" 2>&1 | sed 's/^peer_id: //')
echo "  节点 B peer_id: ${NODE_B_PEER_ID}"

# --- 初始化节点 A-TCP (通过 TCP 代理连接) ---
echo ""
echo "[2/4] 初始化节点 A (TCP 客户端) ..."
rm -rf "${BASE_DIR}/node_a"
mkdir -p "${BASE_DIR}/node_a"
cd "${BASE_DIR}/node_a"
${CKB_BIN} init -c dev --p2p-port 8116 --rpc-port 8124 --force 2>&1 | tail -3 || true

cp "${BASE_DIR}/node_b/specs/dev.toml" "${BASE_DIR}/node_a/specs/dev.toml"
rm -rf "${BASE_DIR}/node_a/data"

# 节点 A 只走 TCP 代理 (HAProxy :18115 -> :8115, send-proxy-v2)
cd "${BASE_DIR}/node_a"
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18115/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
else
    sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18115/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
fi

# --- 初始化节点 C (WS 客户端，通过 WebSocket 代理连接) ---
echo ""
echo "[3/4] 初始化节点 C (WS 客户端) ..."
rm -rf "${BASE_DIR}/node_c"
mkdir -p "${BASE_DIR}/node_c"
cd "${BASE_DIR}/node_c"
${CKB_BIN} init -c dev --p2p-port 8117 --rpc-port 8134 --force 2>&1 | tail -3 || true

cp "${BASE_DIR}/node_b/specs/dev.toml" "${BASE_DIR}/node_c/specs/dev.toml"
rm -rf "${BASE_DIR}/node_c/data"

# 节点 C 只走 WS 代理 (HAProxy :18080 -> :8115, X-Forwarded-For)
cd "${BASE_DIR}/node_c"
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18080/ws/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
else
    sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18080/ws/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
fi

# --- 初始化节点 D (TCP 客户端，通过 Proxy Protocol v1 连接) ---
echo ""
echo "[4/4] 初始化节点 D (TCP/PP v1 客户端) ..."
rm -rf "${BASE_DIR}/node_d"
mkdir -p "${BASE_DIR}/node_d"
cd "${BASE_DIR}/node_d"
${CKB_BIN} init -c dev --p2p-port 8118 --rpc-port 8144 --force 2>&1 | tail -3 || true

cp "${BASE_DIR}/node_b/specs/dev.toml" "${BASE_DIR}/node_d/specs/dev.toml"
rm -rf "${BASE_DIR}/node_d/data"

# 节点 D 只走 TCP 代理 (HAProxy :18116 -> :8115, send-proxy v1)
cd "${BASE_DIR}/node_d"
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18116/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
else
    sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18116/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
fi

# 保存 peer_id 供后续使用
echo "${NODE_B_PEER_ID}" > "${BASE_DIR}/.node_b_peer_id"

echo ""
echo "=========================================="
echo " 初始化完成！"
echo "=========================================="
echo ""
echo "  节点 B (服务端): ${BASE_DIR}/node_b"
echo "    - P2P 监听: 8115 (TCP + WS)"
echo "    - RPC 端口: 8114"
echo "    - peer_id: ${NODE_B_PEER_ID}"
echo ""
echo "  节点 A (TCP 客户端): ${BASE_DIR}/node_a"
echo "    - P2P 监听: 8116"
echo "    - RPC 端口: 8124"
echo "    - bootnode: TCP -> 127.0.0.1:18115 (HAProxy, Proxy Protocol v2)"
echo ""
echo "  节点 C (WS 客户端): ${BASE_DIR}/node_c"
echo "    - P2P 监听: 8117"
echo "    - RPC 端口: 8134"
echo "    - bootnode: WS -> 127.0.0.1:18080 (HAProxy, X-Forwarded-For)"
echo ""
echo "  节点 D (TCP/PP v1 客户端): ${BASE_DIR}/node_d"
echo "    - P2P 监听: 8118"
echo "    - RPC 端口: 8144"
echo "    - bootnode: TCP -> 127.0.0.1:18116 (HAProxy, Proxy Protocol v1)"
echo ""
echo "  下一步: bash start.sh"