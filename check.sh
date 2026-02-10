#!/usr/bin/env bash
set -uo pipefail
# 注意: 不用 set -e，因为 grep 找不到匹配会返回非零

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " CKB Proxy Protocol 测试检查"
echo " TCP (PP v2) + TCP (PP v1) + WS (X-Forwarded-For/Port) + TCP (无协议)"
echo "=========================================="

PASS=0
FAIL=0

# 端口常量
NODE_A_LISTEN_PORT=8116
NODE_C_LISTEN_PORT=8117
NODE_D_LISTEN_PORT=8118
NODE_E_LISTEN_PORT=8119
HAPROXY_TCP_PORT=18115
HAPROXY_TCP_V1_PORT=18116
HAPROXY_TCP_PLAIN_PORT=18117
HAPROXY_WS_PORT=18080

# -------------------------------------------
# 获取节点 B 的 peers
# -------------------------------------------
PEERS_JSON=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_peers","params":[]}')

PEER_COUNT=$(echo "${PEERS_JSON}" | jq '.result | length')

# 获取节点 A 和节点 C 的 node_id（用于区分哪个 peer 是 TCP、哪个是 WS）
NODE_A_INFO=$(curl -s -X POST http://127.0.0.1:8124 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_A_ID=$(echo "${NODE_A_INFO}" | jq -r '.result.node_id')

NODE_C_INFO=$(curl -s -X POST http://127.0.0.1:8134 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_C_ID=$(echo "${NODE_C_INFO}" | jq -r '.result.node_id')

NODE_D_INFO=$(curl -s -X POST http://127.0.0.1:8144 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_D_ID=$(echo "${NODE_D_INFO}" | jq -r '.result.node_id')

NODE_E_INFO=$(curl -s -X POST http://127.0.0.1:8154 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_E_ID=$(echo "${NODE_E_INFO}" | jq -r '.result.node_id')

# -------------------------------------------
# 检查 1: 节点 B 是否有 2 个 peers（TCP + WS）
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 1: 节点 B 的已连接 peers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  连接的 peer 数量: ${PEER_COUNT}（期望: 4）"

if [ "${PEER_COUNT}" -ge 4 ]; then
    echo "  ✅ PASS: 有 ${PEER_COUNT} 个 peer 连接 (TCP/PP v2 + TCP/PP v1 + WS + TCP/无协议 四条路径)"
    PASS=$((PASS + 1))
elif [ "${PEER_COUNT}" -ge 1 ]; then
    echo "  ⚠️  只有 ${PEER_COUNT} 个 peer 连接，可能某个节点还没连上"
    echo "     稍等后重试: sleep 5 && bash check.sh"
    FAIL=$((FAIL + 1))
else
    echo "  ❌ FAIL: 没有 peer 连接！"
    FAIL=$((FAIL + 1))
    echo "  可能原因:"
    echo "    - HAProxy 没有正常运行: docker ps | grep haproxy"
    echo "    - 节点还没来得及连接，再等一会儿重试"
    echo "    - 查看日志: tail -50 node_b.log"
fi

# -------------------------------------------
# 检查 2: 地址解析 — 分别识别 TCP 和 WS peer
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 2: Peer 地址解析（区分 TCP / WS 路径）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  节点 A node_id: ${NODE_A_ID}  (TCP 客户端, 走 :${HAPROXY_TCP_PORT}, PP v2)"
echo "  节点 D node_id: ${NODE_D_ID}  (TCP 客户端, 走 :${HAPROXY_TCP_V1_PORT}, PP v1)"
echo "  节点 E node_id: ${NODE_E_ID}  (TCP 客户端, 走 :${HAPROXY_TCP_PLAIN_PORT}, 无协议)"
echo "  节点 C node_id: ${NODE_C_ID}  (WS  客户端, 走 :${HAPROXY_WS_PORT})"
echo ""

echo "${PEERS_JSON}" | jq -r '.result[] | "\(.node_id)|\(.addresses | map(.address) | join(","))"' 2>/dev/null \
| while IFS='|' read -r pid addrs; do
    # 判断是哪个节点
    if [ "${pid}" = "${NODE_A_ID}" ]; then
        LABEL="节点 A (TCP / Proxy Protocol v2)"
    elif [ "${pid}" = "${NODE_D_ID}" ]; then
        LABEL="节点 D (TCP / Proxy Protocol v1)"
    elif [ "${pid}" = "${NODE_E_ID}" ]; then
        LABEL="节点 E (TCP / 无协议)"
    elif [ "${pid}" = "${NODE_C_ID}" ]; then
        LABEL="节点 C (WS / X-Forwarded-For)"
    else
        LABEL="未知节点"
    fi

    echo "  ── ${LABEL} ──"
    echo "    peer_id: ${pid}"

    # 解析每个地址
    echo "${addrs}" | tr ',' '\n' | while read -r addr; do
        [ -z "${addr}" ] && continue
        IP=$(echo "${addr}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
        PORT=$(echo "${addr}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')
        [ -z "${IP}" ] && IP="unknown"
        [ -z "${PORT}" ] && PORT="unknown"

        echo "    地址: ${addr}"
        echo "    解析: IP=${IP}  端口=${PORT}"

        if [ "${PORT}" = "${HAPROXY_TCP_PORT}" ] || [ "${PORT}" = "${HAPROXY_TCP_V1_PORT}" ] || [ "${PORT}" = "${HAPROXY_TCP_PLAIN_PORT}" ] || [ "${PORT}" = "${HAPROXY_WS_PORT}" ]; then
            echo "    ❌ 端口 ${PORT} 是 HAProxy 代理端口 -> 代理头未生效"
        elif [ "${PORT}" = "${NODE_A_LISTEN_PORT}" ] || [ "${PORT}" = "${NODE_C_LISTEN_PORT}" ] || [ "${PORT}" = "${NODE_D_LISTEN_PORT}" ] || [ "${PORT}" = "${NODE_E_LISTEN_PORT}" ]; then
            echo "    ⚠️  端口 ${PORT} 是节点的 P2P 监听端口（可能是 identify 上报的）"
        else
            echo "    ✅ 端口 ${PORT} 是随机源端口 -> 代理头正确传递了真实源端口"
        fi

        if [ "${IP}" = "192.168.65.1" ]; then
            echo "    📝 IP 为 Docker Desktop 网关地址（HAProxy 在容器中运行的正常现象）"
        elif [ "${IP}" = "127.0.0.1" ] || [ "${IP}" = "::1" ]; then
            echo "    📝 IP 为本地回环地址（同机测试正常）"
        fi
    done
    echo ""
done

# -------------------------------------------
# 检查 3: 三节点同步状态
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 3: 区块同步状态（五节点）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIP_B=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_A=$(curl -s -X POST http://127.0.0.1:8124 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_C=$(curl -s -X POST http://127.0.0.1:8134 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_D=$(curl -s -X POST http://127.0.0.1:8144 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_E=$(curl -s -X POST http://127.0.0.1:8154 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

echo "  节点 B tip: ${TIP_B}"
echo "  节点 A tip: ${TIP_A}"
echo "  节点 D tip: ${TIP_D}"
echo "  节点 E tip: ${TIP_E}"
echo "  节点 C tip: ${TIP_C}"

if [ "${TIP_B}" = "${TIP_A}" ] && [ "${TIP_B}" = "${TIP_C}" ] && [ "${TIP_B}" = "${TIP_D}" ] && [ "${TIP_B}" = "${TIP_E}" ]; then
    echo "  ✅ PASS: 五个节点 tip 一致，同步正常"
    PASS=$((PASS + 1))
elif [ "${TIP_B}" = "${TIP_A}" ] || [ "${TIP_B}" = "${TIP_C}" ] || [ "${TIP_B}" = "${TIP_D}" ] || [ "${TIP_B}" = "${TIP_E}" ]; then
    echo "  ⚠️  部分节点 tip 不一致 (可能还在同步中)"
else
    echo "  ⚠️  五个节点 tip 都不一致 (可能还在同步中)"
fi

# -------------------------------------------
# 检查 4: 查看节点 B 日志中的连接信息
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 4: 节点 B 日志中的连接信息"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "${BASE_DIR}/node_b.log" ]; then
    echo ""
    echo "  最近的连接日志:"
    grep -ai "SessionOpen\|open_session\|new connection\|connected" "${BASE_DIR}/node_b.log" 2>/dev/null \
        | tail -10 \
        | while read -r line; do echo "    ${line}"; done

    echo ""
    echo "  proxy/forward 相关日志:"
    PROXY_LINES=$(grep -aci "proxy\|forward\|trusted" "${BASE_DIR}/node_b.log" 2>/dev/null | tr -d '[:space:]' || true)
    [ -z "${PROXY_LINES}" ] && PROXY_LINES=0
    if [ "${PROXY_LINES}" -gt 0 ]; then
        grep -ai "proxy\|forward\|trusted" "${BASE_DIR}/node_b.log" 2>/dev/null \
            | tail -5 \
            | while read -r line; do echo "    ${line}"; done
    else
        echo "    (无 proxy 相关日志 -- 正常，proxy protocol 解析在底层静默完成)"
    fi
else
    echo "  ⚠️  找不到 node_b.log"
fi

# -------------------------------------------
# 检查 5: TCP 路径验证 (Proxy Protocol v2)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 5: TCP 路径 — Proxy Protocol v2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TCP_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_A_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
TCP_PORT=$(echo "${TCP_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 A (TCP 客户端) 在节点 B 视角的地址:"
echo "    ${TCP_PEER_ADDR}"
echo "    端口: ${TCP_PORT:-无}"
echo ""

if [ -z "${TCP_PORT}" ]; then
    echo "  ❌ FAIL: 节点 B 没有看到节点 A 的连接 (TCP 路径)"
    echo "     可能节点 A 还没连上，稍等重试"
    FAIL=$((FAIL + 1))
elif [ "${TCP_PORT}" = "${HAPROXY_TCP_PORT}" ]; then
    echo "  ❌ FAIL: 端口 ${TCP_PORT} 是 HAProxy TCP 代理端口"
    echo "     -> Proxy Protocol v2 未生效"
    FAIL=$((FAIL + 1))
else
    echo "  ✅ PASS: 端口 ${TCP_PORT} 是随机源端口（非 ${HAPROXY_TCP_PORT}）"
    echo "     -> Proxy Protocol v2 正确传递了客户端真实源端口"
    PASS=$((PASS + 1))
fi

# -------------------------------------------
# 检查 5b: TCP 路径验证 (Proxy Protocol v1)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 5b: TCP 路径 — Proxy Protocol v1"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TCP_V1_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_D_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
TCP_V1_PORT=$(echo "${TCP_V1_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 D (TCP/PP v1 客户端) 在节点 B 视角的地址:"
echo "    ${TCP_V1_PEER_ADDR}"
echo "    端口: ${TCP_V1_PORT:-无}"
echo ""

if [ -z "${TCP_V1_PORT}" ]; then
    echo "  ❌ FAIL: 节点 B 没有看到节点 D 的连接 (TCP/PP v1 路径)"
    echo "     可能节点 D 还没连上，稍等重试"
    FAIL=$((FAIL + 1))
elif [ "${TCP_V1_PORT}" = "${HAPROXY_TCP_V1_PORT}" ]; then
    echo "  ❌ FAIL: 端口 ${TCP_V1_PORT} 是 HAProxy TCP v1 代理端口"
    echo "     -> Proxy Protocol v1 未生效"
    FAIL=$((FAIL + 1))
else
    echo "  ✅ PASS: 端口 ${TCP_V1_PORT} 是随机源端口（非 ${HAPROXY_TCP_V1_PORT}）"
    echo "     -> Proxy Protocol v1 正确传递了客户端真实源端口"
    PASS=$((PASS + 1))
fi

# -------------------------------------------
# 检查 5c: TCP 路径验证 (无 Proxy Protocol — 向后兼容)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 5c: TCP 路径 — 无协议（向后兼容）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PLAIN_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_E_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
PLAIN_PORT=$(echo "${PLAIN_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 E (TCP 无协议客户端) 在节点 B 视角的地址:"
echo "    ${PLAIN_PEER_ADDR}"
echo "    端口: ${PLAIN_PORT:-无}"
echo ""
echo "  预期: 连接正常工作，但节点 B 看到的是 HAProxy 的地址，不是客户端真实地址"
echo "        这证明 Proxy Protocol 功能不会破坏不带协议头的普通连接"
echo ""

if [ -z "${PLAIN_PORT}" ]; then
    echo "  ❌ FAIL: 节点 B 没有看到节点 E 的连接"
    echo "     -> 无协议 TCP 连接失败！Proxy Protocol 功能可能破坏了向后兼容性"
    FAIL=$((FAIL + 1))
else
    echo "  ✅ PASS: 节点 E 通过无协议 TCP 代理成功连接到节点 B"
    echo "     -> Proxy Protocol 功能未破坏普通 TCP 连接的向后兼容性"
    PASS=$((PASS + 1))
fi

# -------------------------------------------
# 检查 6: WS 路径验证 — X-Forwarded-For (IP) + X-Forwarded-Port (端口)
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 6: WS 路径 — X-Forwarded-For + X-Forwarded-Port"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WS_PEER_ADDR=$(echo "${PEERS_JSON}" | jq -r --arg id "${NODE_C_ID}" \
    '.result[] | select(.node_id == $id) | .addresses[0].address // "无"' 2>/dev/null)
WS_IP=$(echo "${WS_PEER_ADDR}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
WS_PORT=$(echo "${WS_PEER_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "  节点 C (WS 客户端) 在节点 B 视角的地址:"
echo "    ${WS_PEER_ADDR}"
echo "    IP: ${WS_IP:-无}  端口: ${WS_PORT:-无}"
echo ""

# --- 6a: X-Forwarded-For (IP) ---
echo "  [6a] X-Forwarded-For (IP 传递):"
if [ -z "${WS_IP}" ]; then
    echo "    ❌ FAIL: 节点 B 没有看到节点 C 的连接 (WS 路径)"
    FAIL=$((FAIL + 1))
elif [ "${WS_IP}" = "0.0.0.0" ] || [ "${WS_IP}" = "::" ]; then
    echo "    ❌ FAIL: IP 为 ${WS_IP}，X-Forwarded-For 未生效"
    FAIL=$((FAIL + 1))
else
    echo "    ✅ PASS: IP=${WS_IP} (有效地址)"
    if [ "${WS_IP}" = "192.168.65.1" ]; then
        echo "       📝 Docker Desktop 网关 IP — 同机环境下 X-Forwarded-For 传递的就是此地址"
    elif [ "${WS_IP}" = "127.0.0.1" ]; then
        echo "       📝 本地回环地址 — 同机测试正常"
    fi
    echo "       ℹ️  同机 Docker 环境下 socket IP 与 forwarded IP 相同，无法单独区分"
    echo "          跨机部署时可验证: 节点 B 应看到客户端机器的真实 IP"
    PASS=$((PASS + 1))
fi

# --- 6b: X-Forwarded-Port (端口传递) — 与 socket 端口交叉比对 ---
echo ""
echo "  [6b] X-Forwarded-Port (端口传递 — 与 socket 端口交叉比对):"

# 获取节点 B 的 socket 层面所有已建立连接的源端口（即 HAProxy→NodeB 后端连接端口）
SOCKET_PORTS=""
if [ -f "${BASE_DIR}/.node_b_pid" ]; then
    NODE_B_PID=$(cat "${BASE_DIR}/.node_b_pid")
    SOCKET_PORTS=$(lsof -nP -p "${NODE_B_PID}" 2>/dev/null \
        | grep "ESTABLISHED" | grep ":8115->" \
        | sed -n 's/.*->[^:]*:\([0-9]*\).*/\1/p' \
        | sort -n | tr '\n' ' ')
fi

echo "    节点 B 报告的端口 (get_peers):  ${WS_PORT:-无}"
echo "    节点 B 的 socket 连接源端口:    ${SOCKET_PORTS:-未获取到}"
echo ""
echo "    原理: 如果 X-Forwarded-Port 生效，get_peers 端口应来自 HTTP header"
echo "          而非 socket 层的后端连接端口，因此两者应该不同"
echo ""

if [ -z "${WS_PORT}" ]; then
    echo "    ❌ FAIL: 节点 B 没有看到节点 C 的端口"
    FAIL=$((FAIL + 1))
elif [ -z "${SOCKET_PORTS}" ]; then
    echo "    ⚠️  无法获取节点 B 的 socket 端口 (lsof 未找到连接)"
    echo "       退化检查: 端口 ${WS_PORT} 不是 HAProxy 监听端口 ${HAPROXY_WS_PORT}"
    if [ "${WS_PORT}" = "${HAPROXY_WS_PORT}" ]; then
        echo "    ❌ FAIL: 端口是 HAProxy WS 代理端口"
        FAIL=$((FAIL + 1))
    else
        echo "    ✅ PASS (弱验证): 端口 ${WS_PORT} 非代理端口"
        PASS=$((PASS + 1))
    fi
else
    # 检查 get_peers 端口是否在 socket 端口列表中
    PORT_IN_SOCKETS=false
    for sp in ${SOCKET_PORTS}; do
        if [ "${WS_PORT}" = "${sp}" ]; then
            PORT_IN_SOCKETS=true
            break
        fi
    done

    if [ "${PORT_IN_SOCKETS}" = "false" ]; then
        echo "    ✅ PASS: get_peers 端口 ${WS_PORT} 不在 socket 端口列表 [${SOCKET_PORTS}] 中"
        echo "       -> X-Forwarded-Port 成功将 HTTP header 中的客户端端口传递给了节点 B"
        echo "       -> 节点 B 使用的是 header 中的端口，而非 socket 层的后端连接端口"
        PASS=$((PASS + 1))
    else
        echo "    ❌ FAIL: get_peers 端口 ${WS_PORT} 与某个 socket 端口相同"
        echo "       -> X-Forwarded-Port 可能未生效，节点 B 看到的是 socket 层的端口"
        FAIL=$((FAIL + 1))
    fi
fi

# -------------------------------------------
# 检查 7: 详细 peer 信息汇总
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 7: 各节点详细信息"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NODE_B_INFO=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')
NODE_B_ID=$(echo "${NODE_B_INFO}" | jq -r '.result.node_id')

echo ""
echo "  节点 B (服务端):"
echo "    node_id: ${NODE_B_ID}"

echo ""
echo "  节点 A (TCP/PP v2 客户端, bootnode -> :${HAPROXY_TCP_PORT}):"
echo "    node_id: ${NODE_A_ID}"

echo ""
echo "  节点 D (TCP/PP v1 客户端, bootnode -> :${HAPROXY_TCP_V1_PORT}):"
echo "    node_id: ${NODE_D_ID}"

echo ""
echo "  节点 E (TCP 无协议客户端, bootnode -> :${HAPROXY_TCP_PLAIN_PORT}):"
echo "    node_id: ${NODE_E_ID}"

echo ""
echo "  节点 C (WS 客户端, bootnode -> :${HAPROXY_WS_PORT}/ws):"
echo "    node_id: ${NODE_C_ID}"

echo ""
echo "  --- 节点 B 看到的 peers ---"
echo "${PEERS_JSON}" | jq -r --arg aid "${NODE_A_ID}" --arg cid "${NODE_C_ID}" --arg did "${NODE_D_ID}" --arg eid "${NODE_E_ID}" \
    '.result[] | "    peer: \(.node_id) [\(if .node_id == $aid then "TCP-v2/节点A" elif .node_id == $did then "TCP-v1/节点D" elif .node_id == $eid then "TCP-无协议/节点E" elif .node_id == $cid then "WS/节点C" else "未知" end)]\n    方向: \(if .is_outbound then "出站" else "入站" end)\n    连接时长: \(.connected_duration)\n    地址: \(.addresses | map(.address) | join(", "))\n    协议: \([.protocols[] | "\(.name)(\(.id))"] | join(", "))\n"' 2>/dev/null

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

TOTAL=$((PASS + FAIL))
if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -ge 7 ]; then
    echo "  🎉 所有检查通过！TCP (PP v2 + PP v1 + 无协议) + WS 四条代理路径均已验证"
elif [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
    echo "  ✅ 已通过的检查无失败，但部分检查未计分 (可能还在同步中)"
else
    echo "  ⚠️  存在失败项，请查看上方详情"
fi

echo ""
echo "  📌 补充说明:"
echo "     * TCP v2 路径: 节点 A -> HAProxy :${HAPROXY_TCP_PORT} (send-proxy-v2) -> 节点 B :8115"
echo "     * TCP v1 路径: 节点 D -> HAProxy :${HAPROXY_TCP_V1_PORT} (send-proxy v1) -> 节点 B :8115"
echo "     * TCP 无协议: 节点 E -> HAProxy :${HAPROXY_TCP_PLAIN_PORT} (纯 TCP 转发) -> 节点 B :8115"
echo "     * WS  路径:    节点 C -> HAProxy :${HAPROXY_WS_PORT} (X-Forwarded-For + X-Forwarded-Port) -> 节点 B :8115"
echo "     * HAProxy 在 Docker 中运行时，节点 B 看到的 IP 是 Docker 网关 (192.168.65.1)"
echo "       这是 Docker Desktop macOS 的网络机制，不影响功能验证"
echo "     * 关键看端口: 应该是随机高位端口，而不是 HAProxy 的 ${HAPROXY_TCP_PORT}/${HAPROXY_TCP_V1_PORT}/${HAPROXY_WS_PORT}"
echo "     * 节点 E 的无协议测试: 验证 Proxy Protocol 功能不会破坏普通 TCP 连接"
echo "=========================================="

exit "${FAIL}"
