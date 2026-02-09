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

echo "=========================================="
echo " 跨机测试 — 启动服务端"
echo "=========================================="

# [0] 清理残留进程
echo ""
echo "[0/3] 清理残留进程 ..."
for PID_FILE in "${BASE_DIR}/.node_b_pid" "${BASE_DIR}/.miner_pid" "${BASE_DIR}/.haproxy_pid"; do
    if [ -f "${PID_FILE}" ]; then
        OLD_PID=$(cat "${PID_FILE}")
        kill "${OLD_PID}" 2>/dev/null || true
        rm -f "${PID_FILE}"
    fi
done
pkill -f "ckb run" 2>/dev/null || true
pkill -f "ckb miner" 2>/dev/null || true

# [1/3] 启动 HAProxy
echo ""
echo "[1/3] 启动 HAProxy ..."

if [ ! -f "${BASE_DIR}/haproxy.cfg" ]; then
    echo "  ✗ 找不到 haproxy.cfg，请先运行 bash setup.sh"
    exit 1
fi

haproxy -f "${BASE_DIR}/haproxy.cfg" -D -p "${BASE_DIR}/.haproxy_pid"
sleep 1

if [ -f "${BASE_DIR}/.haproxy_pid" ] && kill -0 "$(cat "${BASE_DIR}/.haproxy_pid")" 2>/dev/null; then
    echo "  ✓ HAProxy 已启动 (PID: $(cat "${BASE_DIR}/.haproxy_pid"))"
else
    echo "  ✗ HAProxy 启动失败"
    exit 1
fi

# [2/3] 启动节点 B
echo ""
echo "[2/3] 启动节点 B ..."
cd "${BASE_DIR}/node_b"
${CKB_BIN} run -C "${BASE_DIR}/node_b" > "${BASE_DIR}/node_b.log" 2>&1 &
NODE_B_PID=$!
echo "${NODE_B_PID}" > "${BASE_DIR}/.node_b_pid"
echo "  节点 B PID: ${NODE_B_PID}"

# 等待 RPC 就绪
echo "  等待节点 B RPC 就绪 ..."
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:8114 -X POST -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' >/dev/null 2>&1; then
        echo "  ✓ 节点 B RPC 就绪"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ 节点 B RPC 超时！查看日志: tail -50 ${BASE_DIR}/node_b.log"
        exit 1
    fi
    sleep 1
done

# [3/3] 启动矿工
echo ""
echo "[3/3] 启动矿工 ..."
cd "${BASE_DIR}/node_b"
${CKB_BIN} miner -C "${BASE_DIR}/node_b" > "${BASE_DIR}/miner.log" 2>&1 &
MINER_PID=$!
echo "${MINER_PID}" > "${BASE_DIR}/.miner_pid"
echo "  矿工 PID: ${MINER_PID}"

echo ""
echo "=========================================="
echo " 服务端已启动！"
echo "=========================================="
echo ""
echo "  节点 B: RPC=0.0.0.0:8114  P2P=8115"
echo "  HAProxy: TCP=8230  WS=8231"
echo "  矿工: 已启动出块"
echo ""
echo "  等待客户端连接 ..."
echo "  停止: bash stop.sh"
