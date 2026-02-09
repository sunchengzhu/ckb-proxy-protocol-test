#!/usr/bin/env bash
set -uo pipefail
# 注意: 不用 set -e，因为 grep 找不到匹配会返回非零

# ============================================
# 跨机测试 — 检查脚本
# 在客户端机器上运行，远程查询服务端 RPC
#
# 前提: client/.env 中配置了 SERVER_IP
# ============================================

# 从 client/.env 加载配置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="${SCRIPT_DIR}/client"
ENV_FILE="${CLIENT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi
SERVER_IP="${SERVER_IP:-}"

if [ -z "${SERVER_IP}" ]; then
    echo "✗ 未设置 SERVER_IP，请在 ${CLIENT_DIR}/.env 中配置"
    exit 1
fi

# 获取客户端机器的 IP（连接服务端时的源 IP）
CLIENT_IP="${CLIENT_IP:-}"
if [ -z "${CLIENT_IP}" ]; then
    # 自动检测: 通过路由表查找到达 SERVER_IP 的出口 IP
    CLIENT_IP=$(ip route get "${SERVER_IP}" 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
fi

echo "=========================================="
echo " CKB Proxy Protocol 跨机测试检查"
echo " TCP (Proxy Protocol v2) + WS (X-Forwarded-For/Port)"
echo "=========================================="
echo ""
echo "  服务端: ${SERVER_IP}"
echo "  客户端: ${CLIENT_IP:-未知}"

PASS=0
FAIL=0

# 端口常量
NODE_A_LISTEN_PORT=8116
NODE_C_LISTEN_PORT=8117
HAPROXY_TCP_PORT=8230
HAPROXY_WS_PORT=8231

# RPC 地址
NODE_B_RPC="http://${SERVER_IP}:8114"
NODE_A_RPC="http://127.0.0.1:8124"
NODE_C_RPC="http://127.0.0.1:8134"

# -------------------------------------------
# 获取节点 B 的 peers
# -------------------------------------------
PEERS_JSON=$(curl -s --connect-timeout 5 -X POST "${NODE_B_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_peers","params":[]}')

if [ -z "${PEERS_JSON}" ] || echo "${PEERS_JSON}" | jq -e '.error' >/dev/null 2>&1; then
    echo ""
    echo "  ❌ 无法连接到服务端 RPC (${NODE_B_RPC})"
    echo "     请检查: 1) 服务端已启动  2) 防火墙放行 8114 端口"
    exit 1
fi

PEER_COUNT=$(echo "${PEERS_JSON}" | jq '.result | length')

# 获取节点 A 和节点 C 的 node_id
NODE_A_INFO=$(curl -s -X POST "${NODE_A_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_A_ID=$(echo "${NODE_A_INFO}" | jq -r '.result.node_id')

NODE_C_INFO=$(curl -s -X POST "${NODE_C_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_C_ID=$(echo "${NODE_C_INFO}" | jq -r '.result.node_id')

# -------------------------------------------
# 检查 1: 节点 B 是否有 2 个 peers（TCP + WS）
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 1: 节点 B 的已连接 peers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  连接的 peer 数量: ${PEER_COUNT}（期望: 2）"

if [ "${PEER_COUNT}" -ge 2 ]; then
    echo "  ✅ PASS: 有 ${PEER_COUNT} 个 peer 连接 (TCP + WS 两条路径)"
    PASS=$((PASS + 1))
elif [ "${PEER_COUNT}" -eq 1 ]; then
    echo "  ⚠️  只有 1 个 peer 连接，可能另一个节点还没连上"
    echo "     稍等后重试: sleep 5 && bash check.sh"
    FAIL=$((FAIL + 1))
else
    echo "  ❌ FAIL: 没有 peer 连接！"
    FAIL=$((FAIL + 1))
    echo "  可能原因:"
    echo "    - 服务端 HAProxy 未运行"
    echo "    - 防火墙未放行 8230/8231 端口"
    echo "    - 客户端节点未启动"
fi

# -------------------------------------------
# 检查 2: 地址解析 — 分别识别 TCP 和 WS peer
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 2: Peer 地址解析（区分 TCP / WS 路径）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  节点 A node_id: ${NODE_A_ID}  (TCP 客户端, 走 :${HAPROXY_TCP_PORT})"
echo "  节点 C node_id: ${NODE_C_ID}  (WS  客户端, 走 :${HAPROXY_WS_PORT})"
echo ""

echo "${PEERS_JSON}" | jq -r '.result[] | "\(.node_id)|\(.addresses | map(.address) | join(","))"' 2>/dev/null \
| while IFS='|' read -r pid addrs; do
    if [ "${pid}" = "${NODE_A_ID}" ]; then
        LABEL="节点 A (TCP / Proxy Protocol v2)"
    elif [ "${pid}" = "${NODE_C_ID}" ]; then
        LABEL="节点 C (WS / X-Forwarded-For)"
    else
        LABEL="未知节点"
    fi

    echo "  ── ${LABEL} ──"
    echo "    peer_id: ${pid}"

    echo "${addrs}" | tr ',' '\n' | while read -r addr; do
        [ -z "${addr}" ] && continue
        IP=$(echo "${addr}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
        PORT=$(echo "${addr}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')
        [ -z "${IP}" ] && IP="unknown"
        [ -z "${PORT}" ] && PORT="unknown"

        echo "    地址: ${addr}"
        echo "    解析: IP=${IP}  端口=${PORT}"

        if [ "${PORT}" = "${HAPROXY_TCP_PORT}" ] || [ "${PORT}" = "${HAPROXY_WS_PORT}" ]; then
            echo "    ❌ 端口 ${PORT} 是 HAProxy 代理端口 -> 代理头未生效"
        elif [ "${PORT}" = "${NODE_A_LISTEN_PORT}" ] || [ "${PORT}" = "${NODE_C_LISTEN_PORT}" ]; then
            echo "    ⚠️  端口 ${PORT} 是节点的 P2P 监听端口（可能是 identify 上报的）"
        else
            echo "    ✅ 端口 ${PORT} 是随机源端口 -> 代理头正确传递了真实源端口"
        fi

        if [ -n "${CLIENT_IP}" ] && [ "${IP}" = "${CLIENT_IP}" ]; then
            echo "    ✅ IP ${IP} 是客户端机器的真实 IP"
        elif [ "${IP}" = "127.0.0.1" ] || [ "${IP}" = "::1" ]; then
            echo "    ❌ IP 为 127.0.0.1（代理头可能未传递真实 IP）"
        fi
    done
    echo ""
done

# -------------------------------------------
# 检查 3: 三节点同步状态
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 3: 区块同步状态（三节点）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIP_B=$(curl -s -X POST "${NODE_B_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_A=$(curl -s -X POST "${NODE_A_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_C=$(curl -s -X POST "${NODE_C_RPC}" \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

echo "  节点 B tip: ${TIP_B}"
echo "  节点 A tip: ${TIP_A}"
echo "  节点 C tip: ${TIP_C}"

if [ "${TIP_B}" = "${TIP_A}" ] && [ "${TIP_B}" = "${TIP_C}" ]; then
    echo "  ✅ PASS: 三个节点 tip 一致，同步正常"
    PASS=$((PASS + 1))
elif [ "${TIP_B}" = "${TIP_A}" ] || [ "${TIP_B}" = "${TIP_C}" ]; then
    echo "  ⚠️  部分节点 tip 不一致 (可能还在同步中)"
else
    echo "  ⚠️  三个节点 tip 都不一致 (可能还在同步中)"
fi

# -------------------------------------------
# 检查 4: TCP 路径验证 (Proxy Protocol v2)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 4: TCP 路径 — Proxy Protocol v2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TCP_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_A_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
TCP_IP=$(echo "${TCP_PEER_ADDR}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
TCP_PORT=$(echo "${TCP_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 A (TCP 客户端) 在节点 B 视角的地址:"
echo "    ${TCP_PEER_ADDR}"
echo "    IP: ${TCP_IP:-无}  端口: ${TCP_PORT:-无}"
echo ""

# 4a: IP 验证
echo "  [4a] Proxy Protocol v2 — IP 传递:"
if [ -z "${TCP_IP}" ]; then
    echo "    ❌ FAIL: 节点 B 没有看到节点 A 的连接"
    FAIL=$((FAIL + 1))
elif [ -n "${CLIENT_IP}" ] && [ "${TCP_IP}" = "${CLIENT_IP}" ]; then
    echo "    ✅ PASS: IP=${TCP_IP} 是客户端机器的真实 IP"
    echo "       -> Proxy Protocol v2 正确传递了客户端真实 IP"
    PASS=$((PASS + 1))
elif [ "${TCP_IP}" = "127.0.0.1" ]; then
    echo "    ❌ FAIL: IP=127.0.0.1（Proxy Protocol 未传递真实 IP）"
    FAIL=$((FAIL + 1))
else
    echo "    ⚠️  IP=${TCP_IP}（非客户端 IP ${CLIENT_IP:-未知}，可能是 NAT 地址）"
    PASS=$((PASS + 1))
fi

# 4b: 端口验证
echo ""
echo "  [4b] Proxy Protocol v2 — 端口传递:"
if [ -z "${TCP_PORT}" ]; then
    echo "    ❌ FAIL: 无端口信息"
    FAIL=$((FAIL + 1))
elif [ "${TCP_PORT}" = "${HAPROXY_TCP_PORT}" ]; then
    echo "    ❌ FAIL: 端口 ${TCP_PORT} 是 HAProxy TCP 代理端口"
    echo "       -> Proxy Protocol v2 未生效"
    FAIL=$((FAIL + 1))
else
    echo "    ✅ PASS: 端口 ${TCP_PORT} 是随机源端口（非 ${HAPROXY_TCP_PORT}）"
    echo "       -> Proxy Protocol v2 正确传递了客户端真实源端口"
    PASS=$((PASS + 1))
fi

# -------------------------------------------
# 检查 5: WS 路径验证 — X-Forwarded-For (IP)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 5: WS 路径 — X-Forwarded-For (IP)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WS_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_C_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
WS_IP=$(echo "${WS_PEER_ADDR}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
WS_PORT=$(echo "${WS_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 C (WS 客户端) 在节点 B 视角的地址:"
echo "    ${WS_PEER_ADDR}"
echo "    IP: ${WS_IP:-无}  端口: ${WS_PORT:-无}"
echo ""

if [ -z "${WS_IP}" ]; then
    echo "  ❌ FAIL: 节点 B 没有看到节点 C 的连接 (WS 路径)"
    FAIL=$((FAIL + 1))
elif [ -n "${CLIENT_IP}" ] && [ "${WS_IP}" = "${CLIENT_IP}" ]; then
    echo "  ✅ PASS: IP=${WS_IP} 是客户端机器的真实 IP"
    echo "     -> X-Forwarded-For 正确传递了客户端真实 IP"
    PASS=$((PASS + 1))
elif [ "${WS_IP}" = "127.0.0.1" ]; then
    echo "  ❌ FAIL: IP=127.0.0.1（X-Forwarded-For 未传递真实 IP）"
    FAIL=$((FAIL + 1))
else
    echo "  ⚠️  IP=${WS_IP}（非客户端 IP ${CLIENT_IP:-未知}，可能是 NAT 地址）"
    PASS=$((PASS + 1))
fi

# -------------------------------------------
# 检查 6: WS 路径验证 — X-Forwarded-Port (端口)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 6: WS 路径 — X-Forwarded-Port (端口)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 获取节点 C 连接服务端 HAProxy :8231 的实际源端口
NODE_C_REAL_PORT=""
NODE_C_PID_FILE="${CLIENT_DIR}/.node_c_pid"
if [ -f "${NODE_C_PID_FILE}" ]; then
    NODE_C_PID=$(cat "${NODE_C_PID_FILE}")
    # Linux: 用 ss 查找节点 C 到 SERVER_IP:8231 的连接
    NODE_C_REAL_PORT=$(ss -tnp 2>/dev/null \
        | grep "pid=${NODE_C_PID}," \
        | grep "${SERVER_IP}:${HAPROXY_WS_PORT}" \
        | head -1 \
        | sed -n "s/.*:\([0-9]*\) *${SERVER_IP}:.*/\1/p")
fi

echo "  节点 B 报告的端口 (get_peers):  ${WS_PORT:-无}"
echo "  节点 C 到 HAProxy 的实际源端口 (ss): ${NODE_C_REAL_PORT:-未获取到}"
echo ""

if [ -z "${WS_PORT}" ]; then
    echo "  ❌ FAIL: 节点 B 没有看到节点 C 的端口"
    FAIL=$((FAIL + 1))
elif [ -n "${NODE_C_REAL_PORT}" ] && [ "${WS_PORT}" = "${NODE_C_REAL_PORT}" ]; then
    echo "  ✅ PASS: 端口完全匹配！X-Forwarded-Port 正确传递了客户端真实源端口"
    echo "     节点 C 源端口 ${NODE_C_REAL_PORT} == 节点 B 看到的端口 ${WS_PORT}"
    PASS=$((PASS + 1))
elif [ -n "${NODE_C_REAL_PORT}" ] && [ "${WS_PORT}" != "${NODE_C_REAL_PORT}" ]; then
    echo "  ❌ FAIL: 端口不匹配！"
    echo "     节点 C 源端口 ${NODE_C_REAL_PORT} ≠ 节点 B 看到的端口 ${WS_PORT}"
    echo "     -> X-Forwarded-Port 未正确传递客户端源端口"
    FAIL=$((FAIL + 1))
else
    echo "  ⚠️  无法获取节点 C 的实际源端口 (ss 未找到连接)"
    echo "     退化检查: 端口 ${WS_PORT} 不是 HAProxy 监听端口 ${HAPROXY_WS_PORT}"
    if [ "${WS_PORT}" = "${HAPROXY_WS_PORT}" ]; then
        echo "  ❌ FAIL: 端口是 HAProxy WS 代理端口"
        FAIL=$((FAIL + 1))
    else
        echo "  ✅ PASS (弱验证): 端口 ${WS_PORT} 非代理端口"
        PASS=$((PASS + 1))
    fi
fi

# -------------------------------------------
# 检查 7: IP 一致性 — TCP 与 WS 两条路径的 IP 是否一致
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 7: TCP 与 WS 路径 IP 一致性"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  TCP 路径 (Proxy Protocol v2) 看到的 IP: ${TCP_IP:-无}"
echo "  WS  路径 (X-Forwarded-For)  看到的 IP: ${WS_IP:-无}"
echo ""

if [ -n "${TCP_IP}" ] && [ -n "${WS_IP}" ]; then
    if [ "${TCP_IP}" = "${WS_IP}" ]; then
        echo "  ✅ PASS: 两条路径看到的 IP 一致 (${TCP_IP})"
        echo "     -> 两种代理机制都正确传递了相同的客户端 IP"
        PASS=$((PASS + 1))
    else
        echo "  ❌ FAIL: 两条路径看到的 IP 不一致"
        echo "     TCP: ${TCP_IP}  vs  WS: ${WS_IP}"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  ⚠️  部分路径无 IP 信息，跳过一致性检查"
fi

# -------------------------------------------
# 总结
# -------------------------------------------
echo ""
echo "=========================================="
echo " 测试总结"
echo "=========================================="
echo "  通过: ${PASS}"
echo "  失败: ${FAIL}"
echo ""

if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -ge 7 ]; then
    echo "  🎉 所有检查通过！TCP + WS 两条代理路径均已验证"
elif [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
    echo "  ✅ 已通过的检查无失败，但部分检查未计分 (可能还在同步中)"
else
    echo "  ⚠️  存在失败项，请查看上方详情"
fi

echo ""
echo "  📌 跨机测试要点:"
echo "     * TCP 路径:  客户端 -> ${SERVER_IP}:${HAPROXY_TCP_PORT} (Proxy Protocol v2) -> 节点 B"
echo "     * WS  路径:  客户端 -> ${SERVER_IP}:${HAPROXY_WS_PORT} (X-Forwarded-For + X-Forwarded-Port) -> 节点 B"
echo "     * 跨机场景下 IP 验证更有意义: 节点 B 应看到客户端的真实 IP (${CLIENT_IP:-?})"
echo "     * X-Forwarded-Port: 节点 C 的源端口应与节点 B get_peers 端口精确匹配"
echo "=========================================="

exit "${FAIL}"
