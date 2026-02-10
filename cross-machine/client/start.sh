#!/usr/bin/env bash
set -euo pipefail

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

if [ -z "${SERVER_IP}" ]; then
    echo "✗ 未设置 SERVER_IP，请在 ${ENV_FILE} 中配置"
    exit 1
fi

echo "=========================================="
echo " 跨机测试 — 启动客户端"
echo "=========================================="

# [0] 清理残留进程
echo ""
echo "[0/3] 清理残留进程 ..."
for PID_FILE in "${BASE_DIR}/.node_a_pid" "${BASE_DIR}/.node_c_pid" "${BASE_DIR}/.node_d_pid"; do
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(cat "${PID_FILE}")
        kill "${OLD_PID}" 2>/dev/null || true
        rm -f "${PID_FILE}"
    fi
done
pkill -f "ckb run" 2>/dev/null || true

# [1/2] 启动节点 A (TCP)
echo ""
echo "[1/3] 启动节点 A (TCP/PP v2 客户端) ..."
cd "${BASE_DIR}/node_a"
${CKB_BIN} run -C "${BASE_DIR}/node_a" > "${BASE_DIR}/node_a.log" 2>&1 &
NODE_A_PID=$!
echo "${NODE_A_PID}" > "${BASE_DIR}/.node_a_pid"
echo "  节点 A PID: ${NODE_A_PID}"

# 等待 RPC 就绪
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8124 -X POST -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' >/dev/null 2>&1; then
        echo "  ✓ 节点 A RPC 就绪"
        break
    fi
    [ "$i" -eq 30 ] && echo "  ✗ 节点 A RPC 超时" && exit 1
    sleep 1
done

# [2/2] 启动节点 C (WS)
echo ""
echo "[2/3] 启动节点 C (WS 客户端) ..."
cd "${BASE_DIR}/node_c"
${CKB_BIN} run -C "${BASE_DIR}/node_c" > "${BASE_DIR}/node_c.log" 2>&1 &
NODE_C_PID=$!
echo "${NODE_C_PID}" > "${BASE_DIR}/.node_c_pid"
echo "  节点 C PID: ${NODE_C_PID}"

# 等待 RPC 就绪
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8134 -X POST -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' >/dev/null 2>&1; then
        echo "  ✓ 节点 C RPC 就绪"
        break
    fi
    [ "$i" -eq 30 ] && echo "  ✗ 节点 C RPC 超时" && exit 1
    sleep 1
done

# [3/3] 启动节点 D (TCP/PP v1)
echo ""
echo "[3/3] 启动节点 D (TCP/PP v1 客户端) ..."
cd "${BASE_DIR}/node_d"
${CKB_BIN} run -C "${BASE_DIR}/node_d" > "${BASE_DIR}/node_d.log" 2>&1 &
NODE_D_PID=$!
echo "${NODE_D_PID}" > "${BASE_DIR}/.node_d_pid"
echo "  节点 D PID: ${NODE_D_PID}"

# 等待 RPC 就绪
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8144 -X POST -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' >/dev/null 2>&1; then
        echo "  ✓ 节点 D RPC 就绪"
        break
    fi
    [ "$i" -eq 30 ] && echo "  ✗ 节点 D RPC 超时" && exit 1
    sleep 1
done

echo ""
echo "=========================================="
echo " 客户端已启动！"
echo "=========================================="
echo ""
echo "  节点 A (TCP/PP v2): PID=${NODE_A_PID}  RPC=127.0.0.1:8124"
echo "  节点 D (TCP/PP v1): PID=${NODE_D_PID}  RPC=127.0.0.1:8144"
echo "  节点 C (WS):        PID=${NODE_C_PID}  RPC=127.0.0.1:8134"
echo "  服务端: ${SERVER_IP}"
echo ""
echo "  等待 10 秒让节点建立连接 ..."
sleep 10
echo "  下一步: bash ../check.sh"
