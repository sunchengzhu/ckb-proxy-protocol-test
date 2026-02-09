#!/usr/bin/env bash
set -euo pipefail

# ============================================
# 跨机测试 — 客户端 (Node A + Node C)
# 在 Ubuntu 22 客户端机器上运行
#
# 前提:
#   1. 在 .env 中设置 SERVER_IP 和 CKB_BIN
#   2. 将服务端的 .node_b_peer_id 文件复制到本目录
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
SERVER_IP="${SERVER_IP:-}"

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

# 验证 SERVER_IP
if [ -z "${SERVER_IP}" ]; then
    echo "✗ 未设置 SERVER_IP"
    echo "  在 ${ENV_FILE} 中写入: SERVER_IP=<服务端IP>"
    exit 1
fi

# 验证 peer_id
PEER_ID_FILE="${BASE_DIR}/.node_b_peer_id"
if [ ! -f "${PEER_ID_FILE}" ]; then
    echo "✗ 找不到 .node_b_peer_id"
    echo "  请从服务端复制: scp server:.../server/.node_b_peer_id ${PEER_ID_FILE}"
    exit 1
fi
NODE_B_PEER_ID=$(cat "${PEER_ID_FILE}" | tr -d '[:space:]')

echo "=========================================="
echo " 跨机测试 — 客户端初始化"
echo "=========================================="
echo ""
echo "  服务端 IP: ${SERVER_IP}"
echo "  节点 B peer_id: ${NODE_B_PEER_ID}"

DEV_BA_ARG="0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7"

# --- 初始化节点 A (TCP 客户端) ---
echo ""
echo "[1/2] 初始化节点 A (TCP 客户端) ..."
rm -rf "${BASE_DIR}/node_a"
mkdir -p "${BASE_DIR}/node_a"
cd "${BASE_DIR}/node_a"
${CKB_BIN} init -c dev --p2p-port 8116 --rpc-port 8124 --force 2>&1 | tail -3 || true
rm -rf "${BASE_DIR}/node_a/data"

# bootnode 指向服务端 HAProxy TCP 端口
sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/${SERVER_IP}/tcp/18115/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml

# --- 初始化节点 C (WS 客户端) ---
echo ""
echo "[2/2] 初始化节点 C (WS 客户端) ..."
rm -rf "${BASE_DIR}/node_c"
mkdir -p "${BASE_DIR}/node_c"
cd "${BASE_DIR}/node_c"
${CKB_BIN} init -c dev --p2p-port 8117 --rpc-port 8134 --force 2>&1 | tail -3 || true
rm -rf "${BASE_DIR}/node_c/data"

# bootnode 指向服务端 HAProxy WS 端口
sed -i "s|^bootnodes = .*|bootnodes = [\"/ip4/${SERVER_IP}/tcp/18080/ws/p2p/${NODE_B_PEER_ID}\"]|" ckb.toml

# 确保两个客户端与服务端使用相同的 genesis (需从服务端复制 dev.toml)
DEV_TOML_SRC="${BASE_DIR}/.dev.toml"
if [ -f "${DEV_TOML_SRC}" ]; then
    echo ""
    echo "  发现 .dev.toml，复制到客户端节点 ..."
    cp "${DEV_TOML_SRC}" "${BASE_DIR}/node_a/specs/dev.toml"
    cp "${DEV_TOML_SRC}" "${BASE_DIR}/node_c/specs/dev.toml"
else
    echo ""
    echo "  ⚠️  未找到 .dev.toml (从服务端复制的 specs/dev.toml)"
    echo "     如果 CKB 版本一致，默认 dev.toml 应该相同，可忽略此警告"
    echo "     如果连接失败，请从服务端复制:"
    echo "       scp server:.../server/node_b/specs/dev.toml ${DEV_TOML_SRC}"
fi

echo ""
echo "=========================================="
echo " 客户端初始化完成！"
echo "=========================================="
echo ""
echo "  节点 A (TCP): P2P=8116  RPC=8124"
echo "    bootnode: TCP -> ${SERVER_IP}:18115 (Proxy Protocol v2)"
echo ""
echo "  节点 C (WS):  P2P=8117  RPC=8134"
echo "    bootnode: WS  -> ${SERVER_IP}:18080 (X-Forwarded-For/Port)"
echo ""
echo "  下一步: bash start.sh"
