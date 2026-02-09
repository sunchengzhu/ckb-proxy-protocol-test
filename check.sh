#!/usr/bin/env bash
set -uo pipefail
# 注意: 不用 set -e，因为 grep 找不到匹配会返回非零

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo " CKB Proxy Protocol 测试检查"
echo "=========================================="

PASS=0
FAIL=0

# -------------------------------------------
# 检查 1: 节点 B 是否有连接的 peers
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 1: 节点 B 的已连接 peers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PEERS_JSON=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_peers","params":[]}')

PEER_COUNT=$(echo "${PEERS_JSON}" | jq '.result | length')
echo "  连接的 peer 数量: ${PEER_COUNT}"

if [ "${PEER_COUNT}" -gt 0 ]; then
    echo "  ✅ PASS: 有 peer 连接"
    PASS=$((PASS + 1))
else
    echo "  ❌ FAIL: 没有 peer 连接！"
    FAIL=$((FAIL + 1))
    echo ""
    echo "  可能原因:"
    echo "    - HAProxy 没有正常运行: docker ps | grep haproxy"
    echo "    - 节点还没来得及连接，再等一会儿重试"
    echo "    - 查看日志: tail -50 node_b.log"
fi

# -------------------------------------------
# 检查 2: Proxy Protocol 地址解析
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 2: Proxy Protocol 地址解析"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NODE_A_LISTEN_PORT=8116
HAPROXY_TCP_PORT=18115
HAPROXY_WS_PORT=18080

ADDR_LIST=$(echo "${PEERS_JSON}" | jq -r '.result[] | .addresses[] | .address' 2>/dev/null)
echo ""
echo "  节点 B 看到的所有 peer 地址:"

if [ -z "${ADDR_LIST}" ]; then
    echo "    (无地址)"
else
    echo "${ADDR_LIST}" | while read -r addr; do
        IP=$(echo "${addr}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
        PORT=$(echo "${addr}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')
        [ -z "${IP}" ] && IP="unknown"
        [ -z "${PORT}" ] && PORT="unknown"

        echo ""
        echo "    地址: ${addr}"
        echo "    解析: IP=${IP}  端口=${PORT}"

        if [ "${PORT}" = "${HAPROXY_TCP_PORT}" ] || [ "${PORT}" = "${HAPROXY_WS_PORT}" ]; then
            echo "    ❌ 端口 ${PORT} 是 HAProxy 代理端口 -> Proxy Protocol 未生效"
        elif [ "${PORT}" = "${NODE_A_LISTEN_PORT}" ]; then
            echo "    ⚠️  端口 ${PORT} 是节点 A 的 P2P 监听端口（可能是 identify 上报的）"
        else
            echo "    ✅ 端口 ${PORT} 是随机源端口 -> Proxy Protocol 正确传递了真实源端口"
        fi

        if [ "${IP}" = "127.0.0.1" ] || [ "${IP}" = "::1" ]; then
            echo "    📝 IP 为本地回环地址 (同机测试正常，关注端口号即可)"
        elif [ "${IP}" = "192.168.65.1" ]; then
            echo "    📝 IP 为 Docker Desktop 网关地址"
            echo "       说明: HAProxy 在 Docker 中运行时，看到的客户端 IP 是 Docker 虚拟网关"
            echo "       Proxy Protocol 已生效（传递了 HAProxy 看到的真实源 IP）"
            echo "       如果需要看到真正的 127.0.0.1，可以改用宿主机直接运行 HAProxy"
        else
            echo "    ✅ IP 为非本地地址: ${IP}"
        fi
    done
fi

# -------------------------------------------
# 检查 3: 同步状态
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 3: 区块同步状态"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIP_B=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

TIP_A=$(curl -s -X POST http://127.0.0.1:8124 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
    | jq -r '.result')

echo "  节点 B tip: ${TIP_B}"
echo "  节点 A tip: ${TIP_A}"

if [ "${TIP_B}" = "${TIP_A}" ]; then
    echo "  ✅ PASS: 两个节点 tip 一致，同步正常"
    PASS=$((PASS + 1))
else
    echo "  ⚠️  两个节点 tip 不一致 (可能还在同步中)"
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
# 检查 5: 节点 B & 节点 A 详细 peer 信息对比
# -------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 检查 5: 节点 B & 节点 A 详细 peer 信息"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NODE_B_INFO=$(curl -s -X POST http://127.0.0.1:8114 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')

NODE_B_ID=$(echo "${NODE_B_INFO}" | jq -r '.result.node_id')
echo ""
echo "  节点 B (服务端):"
echo "    node_id: ${NODE_B_ID}"
echo "    监听地址:"
echo "${NODE_B_INFO}" | jq -r '.result.addresses[] | .address' 2>/dev/null | while read -r a; do
    echo "      ${a}"
done

NODE_A_INFO=$(curl -s -X POST http://127.0.0.1:8124 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"local_node_info","params":[]}')

NODE_A_ID=$(echo "${NODE_A_INFO}" | jq -r '.result.node_id')
echo ""
echo "  节点 A (客户端):"
echo "    node_id: ${NODE_A_ID}"
echo "    监听地址:"
echo "${NODE_A_INFO}" | jq -r '.result.addresses[] | .address' 2>/dev/null | while read -r a; do
    echo "      ${a}"
done

echo ""
echo "  --- 节点 B 看到的 peers ---"
echo "${PEERS_JSON}" | jq -r '.result[] | "    peer: \(.node_id)\n    方向: \(if .is_outbound then "出站" else "入站" end)\n    连接时长: \(.connected_duration)\n    地址: \(.addresses | map(.address) | join(", "))\n    协议: \([.protocols[] | "\(.name)(\(.id))"] | join(", "))"' 2>/dev/null

PEERS_A_JSON=$(curl -s -X POST http://127.0.0.1:8124 \
    -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"get_peers","params":[]}')

echo ""
echo "  --- 节点 A 看到的 peers ---"
echo "${PEERS_A_JSON}" | jq -r '.result[] | "    peer: \(.node_id)\n    方向: \(if .is_outbound then "出站" else "入站" end)\n    连接时长: \(.connected_duration)\n    地址: \(.addresses | map(.address) | join(", "))\n    协议: \([.protocols[] | "\(.name)(\(.id))"] | join(", "))"' 2>/dev/null

echo ""
echo "  --- 关键对比 ---"
B_SEES_ADDR=$(echo "${PEERS_JSON}" | jq -r '.result[0].addresses[0].address // "无"' 2>/dev/null)
B_SEES_IP=$(echo "${B_SEES_ADDR}" | sed -n 's|.*/ip4/\([^/]*\).*|\1|p')
B_SEES_PORT=$(echo "${B_SEES_ADDR}" | sed -n 's|.*/tcp/\([^/]*\).*|\1|p')

echo "    节点 B 看到的对端地址: ${B_SEES_ADDR}"
echo "    其中 IP=${B_SEES_IP:-unknown}  端口=${B_SEES_PORT:-unknown}"
echo ""
echo "    HAProxy TCP 代理端口: ${HAPROXY_TCP_PORT}"
echo "    HAProxy WS  代理端口: ${HAPROXY_WS_PORT}"
echo "    节点 A P2P 监听端口:  ${NODE_A_LISTEN_PORT}"
echo ""

if [ -z "${B_SEES_PORT}" ]; then
    echo "    ❌ FAIL: 节点 B 没有看到任何 peer，无法验证 Proxy Protocol"
    echo "       可能原因: 节点 B 进程已退出、连接尚未建立、或端口被残留进程占用"
    echo "       尝试: bash stop.sh && bash start.sh"
    FAIL=$((FAIL + 1))
elif [ "${B_SEES_PORT}" = "${HAPROXY_TCP_PORT}" ] || [ "${B_SEES_PORT}" = "${HAPROXY_WS_PORT}" ]; then
    echo "    ❌ FAIL: 节点 B 看到的端口是 HAProxy 代理端口，Proxy Protocol 未生效"
    FAIL=$((FAIL + 1))
else
    echo "    ✅ PASS: 节点 B 看到的端口 (${B_SEES_PORT}) 不是 HAProxy 代理端口"
    echo "       -> Proxy Protocol 正确传递了客户端的真实源端口"
    PASS=$((PASS + 1))
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

if [ "${FAIL}" -eq 0 ] && [ "${PASS}" -gt 0 ]; then
    echo "  🎉 所有自动检查通过！"
else
    echo "  ⚠️  存在失败项，请查看上方详情"
fi

echo ""
echo "  📌 补充说明:"
echo "     * HAProxy 在 Docker 中运行时，节点 B 看到的 IP 是 Docker 网关 (192.168.65.1)"
echo "       这是 Docker Desktop macOS 的网络机制，不影响 Proxy Protocol 功能验证"
echo "     * 关键看端口: 应该是随机高位端口，而不是 HAProxy 的 18115/18080"
echo "     * 跨机部署时 IP 会更直观 (节点 B 能看到节点 A 机器的真实 IP)"
echo "=========================================="

exit "${FAIL}"
