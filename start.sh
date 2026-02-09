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
echo " 启动 CKB Proxy Protocol 测试环境"
echo "=========================================="

# --- 0. 清理残留进程 ---
echo ""
echo "[0] 清理残留进程 ..."

# 先用 PID 文件尝试关闭
for pidfile in "${BASE_DIR}/.node_a_pid" "${BASE_DIR}/.node_b_pid" "${BASE_DIR}/.node_c_pid"; do
    if [ -f "${pidfile}" ]; then
        OLD_PID=$(cat "${pidfile}")
        kill "${OLD_PID}" 2>/dev/null || true
        rm -f "${pidfile}"
    fi
done

# 兜底: 查杀所有 ckb run 进程（仅限当前用户）
pkill -f "ckb run" 2>/dev/null || true
sleep 1

docker rm -f haproxy-ckb-test 2>/dev/null || true

# --- 1. 启动 HAProxy ---
echo ""
echo "[1/4] 启动 HAProxy ..."

# macOS 不支持 --network host，需要端口映射并指向宿主机
if [[ "$OSTYPE" == "darwin"* ]]; then
    HAPROXY_CFG="${BASE_DIR}/.haproxy.darwin.cfg"
    cp "${BASE_DIR}/haproxy.cfg" "${HAPROXY_CFG}"
    # 将后端地址改为宿主机
    sed -i '' "s|server ckb 127.0.0.1:8115|server ckb host.docker.internal:8115|g" "${HAPROXY_CFG}"
    # 确保文件以换行符结尾（HAProxy 要求）
    [ -n "$(tail -c1 "${HAPROXY_CFG}")" ] && echo >> "${HAPROXY_CFG}"

    docker run --rm -d \
        --name haproxy-ckb-test \
        -p 18115:18115 \
        -p 18080:18080 \
        -v "${HAPROXY_CFG}:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        haproxy:alpine
else
    docker run --rm -d \
        --name haproxy-ckb-test \
        --network host \
        -v "${BASE_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        haproxy:alpine
fi

echo "  HAProxy 已启动"
echo "    TCP 代理:  127.0.0.1:18115 -> 127.0.0.1:8115"
echo "    WS  代理:  127.0.0.1:18080 -> 127.0.0.1:8115"

# --- 2. 启动节点 B ---
echo ""
echo "[2/4] 启动节点 B (服务端) ..."
cd "${BASE_DIR}/node_b"
${CKB_BIN} run > "${BASE_DIR}/node_b.log" 2>&1 &
NODE_B_PID=$!
echo "${NODE_B_PID}" > "${BASE_DIR}/.node_b_pid"
echo "  节点 B PID: ${NODE_B_PID}"

# 等待节点 B 的 RPC 就绪
echo "  等待节点 B RPC 就绪 ..."
for i in $(seq 1 30); do
    if curl -s -X POST http://127.0.0.1:8114 \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' \
        > /dev/null 2>&1; then
        echo "  节点 B RPC 就绪 ✓"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ 节点 B RPC 超时！查看 node_b.log"
        exit 1
    fi
    sleep 1
done

# 用 miner 出几个块，让节点退出 IBD 状态
echo "  启动 ckb-miner 出块 ..."
cd "${BASE_DIR}/node_b"
${CKB_BIN} miner -C "${BASE_DIR}/node_b" -l 5 > "${BASE_DIR}/miner.log" 2>&1
CURRENT_TIP=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')
echo "  已出块，节点 B 当前 tip: ${CURRENT_TIP}"

# --- 3. 启动节点 A ---
echo ""
echo "[3/4] 启动节点 A (TCP 客户端) ..."
cd "${BASE_DIR}/node_a"
${CKB_BIN} run > "${BASE_DIR}/node_a.log" 2>&1 &
NODE_A_PID=$!
echo "${NODE_A_PID}" > "${BASE_DIR}/.node_a_pid"
echo "  节点 A PID: ${NODE_A_PID}"

echo "  等待节点 A RPC 就绪 ..."
for i in $(seq 1 30); do
    if curl -s -X POST http://127.0.0.1:8124 \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' \
        > /dev/null 2>&1; then
        echo "  节点 A RPC 就绪 ✓"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ 节点 A RPC 超时！查看 node_a.log"
        exit 1
    fi
    sleep 1
done

# --- 4. 启动节点 C (WS 客户端) ---
echo ""
echo "[4/4] 启动节点 C (WS 客户端) ..."
cd "${BASE_DIR}/node_c"
${CKB_BIN} run > "${BASE_DIR}/node_c.log" 2>&1 &
NODE_C_PID=$!
echo "${NODE_C_PID}" > "${BASE_DIR}/.node_c_pid"
echo "  节点 C PID: ${NODE_C_PID}"

echo "  等待节点 C RPC 就绪 ..."
for i in $(seq 1 30); do
    if curl -s -X POST http://127.0.0.1:8134 \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}' \
        > /dev/null 2>&1; then
        echo "  节点 C RPC 就绪 ✓"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ 节点 C RPC 超时！查看 node_c.log"
        exit 1
    fi
    sleep 1
done

echo ""
echo "=========================================="
echo " 所有组件已启动！"
echo "=========================================="
echo ""
echo "  等待 15 秒让节点建立连接..."
sleep 15
echo ""
echo "  现在可以运行检查: bash check.sh"