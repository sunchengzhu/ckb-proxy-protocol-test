#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " 停止 CKB Proxy Protocol 测试环境"
echo "=========================================="

# 停止节点 A
if [ -f "${BASE_DIR}/.node_a_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_a_pid")
    echo "  停止节点 A (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_a_pid"
fi

# 停止节点 C
if [ -f "${BASE_DIR}/.node_c_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_c_pid")
    echo "  停止节点 C (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_c_pid"
fi

# 停止节点 D
if [ -f "${BASE_DIR}/.node_d_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_d_pid")
    echo "  停止节点 D (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_d_pid"
fi

# 停止节点 E
if [ -f "${BASE_DIR}/.node_e_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_e_pid")
    echo "  停止节点 E (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_e_pid"
fi

# 停止节点 B
if [ -f "${BASE_DIR}/.node_b_pid" ]; then
    PID=$(cat "${BASE_DIR}/.node_b_pid")
    echo "  停止节点 B (PID: ${PID}) ..."
    kill "${PID}" 2>/dev/null || true
    rm -f "${BASE_DIR}/.node_b_pid"
fi

# 兜底: 查杀所有残留的 ckb run 进程
REMAINING=$(pgrep -f "ckb run" 2>/dev/null || true)
if [ -n "${REMAINING}" ]; then
    echo "  发现残留 ckb 进程，正在清理 ..."
    pkill -f "ckb run" 2>/dev/null || true
fi

# 停止 HAProxy
echo "  停止 HAProxy ..."
docker rm -f haproxy-ckb-test 2>/dev/null || true

# 清理 macOS 临时 HAProxy 配置
rm -f "${BASE_DIR}/.haproxy.darwin.cfg"

echo ""
echo "  全部停止 ✓"
echo ""
echo "  如需清理数据: rm -rf node_a node_b node_c node_d node_e node_a.log node_b.log node_c.log node_d.log node_e.log miner.log .node_* .haproxy.darwin.cfg"