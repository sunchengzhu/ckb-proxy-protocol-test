#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " 跨机测试 — 停止服务端"
echo "=========================================="

# 停止矿工
if [ -f "${BASE_DIR}/.miner_pid" ]; then
    PID=$(cat "${BASE_DIR}/.miner_pid")
    echo "  停止矿工 (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.miner_pid"
fi

# 停止节点 B
if [ -f "${BASE_DIR}/.node_b_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_b_pid")
    echo "  停止节点 B (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_b_pid"
fi

# 停止 HAProxy
if [ -f "${BASE_DIR}/.haproxy_pid" ]; then
    PID=$(cat "${BASE_DIR}/.haproxy_pid")
    echo "  停止 HAProxy (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.haproxy_pid"
fi

# 兜底清理
pkill -f "ckb run" 2>/dev/null || true
pkill -f "ckb miner" 2>/dev/null || true

echo ""
echo "  ✓ 服务端已停止"
echo "  如需清理数据: rm -rf node_b node_b.log miner.log .node_* .haproxy_pid haproxy.cfg"
