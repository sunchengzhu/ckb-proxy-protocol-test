#!/usr/bin/env bash
set -uo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " 跨机测试 — 停止客户端"
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

# 兜底清理
pkill -f "ckb run" 2>/dev/null || true

echo ""
echo "  ✓ 客户端已停止"
echo "  如需清理数据: rm -rf node_a node_c node_d node_e node_a.log node_c.log node_d.log node_e.log .node_* .dev.toml"
