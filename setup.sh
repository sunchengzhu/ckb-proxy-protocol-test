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

echo "[1/2] 初始化节点 B (服务端) ..."
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
echo "[2/2] 初始化节点 A (客户端) ..."
rm -rf "${BASE_DIR}/node_a"
mkdir -p "${BASE_DIR}/node_a"
cd "${BASE_DIR}/node_a"
${CKB_BIN} init -c dev --p2p-port 8116 --rpc-port 8124 --force 2>&1 | tail -3 || true

# 确保节点 A 使用与节点 B 相同的链规格（同一 genesis）
# 必须先拷贝 dev.toml 再删 data，因为 ckb init 已基于自己的随机 dev.toml 生成了 db
cp "${BASE_DIR}/node_b/specs/dev.toml" "${BASE_DIR}/node_a/specs/dev.toml"
rm -rf "${BASE_DIR}/node_a/data"

# 修改 node_a 的 bootnodes，两个地址：一个走 TCP 代理，一个走 WS 代理
cd "${BASE_DIR}/node_a"

# 用 sed 替换 bootnodes 行
# TCP 代理端口: 18115
# WS 代理端口: 18080
# 替换 bootnodes 为指向代理的地址
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18115/p2p/${NODE_B_PEER_ID}\", \"/ip4/127.0.0.1/tcp/18080/ws/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
else
    sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/127.0.0.1/tcp/18115/p2p/${NODE_B_PEER_ID}\", \"/ip4/127.0.0.1/tcp/18080/ws/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml
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
echo "  节点 A (客户端): ${BASE_DIR}/node_a"
echo "    - P2P 监听: 8116"
echo "    - RPC 端口: 8124"
echo "    - bootnodes:"
echo "      TCP -> 127.0.0.1:18115 (HAProxy) -> 127.0.0.1:8115"
echo "      WS  -> 127.0.0.1:18080 (HAProxy) -> 127.0.0.1:8115"
echo ""
echo "  下一步: bash start.sh"