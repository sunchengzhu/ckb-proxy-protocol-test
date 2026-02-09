# CKB Proxy Protocol 测试

测试 [ckb#5105](https://github.com/nervosnetwork/ckb/pull/5105) 的 proxy protocol 支持。

## 前置条件

- CKB 二进制（包含 PR #5105 的代码）在 PATH 中，或在 `.env` 中指定 `CKB_BIN`
- Docker（用来跑 HAProxy）
- jq（用来解析 JSON）
- curl

```bash
# 确认 ckb 可用
ckb --version

# 确认 docker 可用
docker --version

# 确认 jq 可用
jq --version
```

如果你的 ckb 不在 PATH 中，推荐在项目根目录创建 `.env`，避免每次开新终端都要 export：

```bash
# .env (与 setup.sh 同级)
CKB_BIN=/path/to/ckb
```

## 测试架构

```
                        +---------------------------+
                        |         HAProxy           |
节点 A -- TCP ----------| :18115 --proxy-v2-> :8115 |--> 节点 B
节点 C -- WebSocket ----| :18080 -X-Fwd-For/Port> :8115 |--> 节点 B
                        +---------------------------+
```

- **TCP 路径 (节点 A)**: 用 Proxy Protocol v2 传递真实 IP
- **WS 路径 (节点 C)**: 用 X-Forwarded-For 传递真实 IP + X-Forwarded-Port 传递真实源端口

> 为什么需要两个客户端节点？CKB 对同一个 peer 只维护一条连接，
> 所以用节点 A 专走 TCP、节点 C 专走 WS，才能同时验证两条代理路径。

### 端口分配

| 组件 | P2P 端口 | RPC 端口 | 说明 |
|------|----------|----------|------|
| 节点 B (服务端) | 8115 | 8114 | 接收代理连接 |
| 节点 A (TCP 客户端) | 8116 | 8124 | 通过 HAProxy TCP 连接节点 B |
| 节点 C (WS 客户端) | 8117 | 8134 | 通过 HAProxy WS 连接节点 B |
| HAProxy TCP | 18115 | - | send-proxy-v2 转发到 :8115 |
| HAProxy WS | 18080 | - | X-Forwarded-For 转发到 :8115 |

> **macOS Docker Desktop 说明**: HAProxy 在 Docker 容器中运行，macOS 不支持 `--network host`，
> 因此使用端口映射 (`-p 18115:18115 -p 18080:18080`) + `host.docker.internal` 指向宿主机。
> 节点 B 看到的 peer IP 会是 Docker 网关地址 `192.168.65.1`，这是正常的。

## 使用方法

```bash
# 第 1 步: 初始化节点
bash setup.sh

# 第 2 步: 启动所有组件 (HAProxy + 矿工出块 + 节点B + 节点A)
bash start.sh

# 第 3 步: 检查测试结果
bash check.sh

# 停止所有组件
bash stop.sh

# 清理所有数据（重新开始）
bash stop.sh
rm -rf node_a node_b node_c node_a.log node_b.log node_c.log miner.log .node_* .haproxy.darwin.cfg
```

## 如何判断测试通过

`check.sh` 会自动运行 7 项检查并给出 PASS/FAIL 结论，退出码为失败项数量（0 = 全部通过）。

### 自动评分项

| 检查 | 内容 | 通过条件 |
|------|------|----------|
| 检查 1 | peer 连接 | 节点 B 有至少 2 个 peer（TCP + WS） |
| 检查 3 | 区块同步 | 三个节点 tip 一致 |
| 检查 5 | TCP 路径验证 | 节点 A 的端口不是 HAProxy TCP 代理端口 (18115) |
| 检查 6a | X-Forwarded-For (IP) | 节点 C 的 IP 为有效地址 |
| 检查 6b | X-Forwarded-Port (端口) | get_peers 端口 ≠ Node B socket 端口 (证明端口来自 header) |

### 信息展示项（不计分）

| 检查 | 内容 |
|------|------|
| 检查 2 | 区分 TCP/WS 路径，逐个解析 peer 地址 |
| 检查 4 | 查看节点 B 日志中的连接和 proxy 相关信息 |
| 检查 7 | 各节点详细 peer 信息汇总 |

### 核心判断逻辑

**看端口号**：节点 B 的 `get_peers` 返回的地址中，端口应该是客户端的**真实源端口**
（一个随机的高位端口），而**不是** HAProxy 的 `18115`（TCP）或 `18080`（WS）。

- **TCP 路径**: 节点 A → HAProxy :18115 (Proxy Protocol v2) → 节点 B
- **WS 路径**: 节点 C → HAProxy :18080 (X-Forwarded-For + X-Forwarded-Port) → 节点 B
- **同机测试**: IP 为 `127.0.0.1`（直连）或 `192.168.65.1`（Docker 网关），关注端口号即可
- **跨机测试**: 节点 B 看到的 IP 应该是客户端机器的真实 IP

## 跨机测试

如果需要在**两台机器**（如 AWS EC2）上进行跨机测试，请参考 [cross-machine/README.md](cross-machine/README.md)。

跨机测试的 HAProxy 代理端口使用 **8230** (TCP) 和 **8231** (WS)，与同机测试不同。

## check.sh 输出示例

```
检查 1: 节点 B 的已连接 peers
  连接的 peer 数量: 2（期望: 2）
  ✅ PASS: 有 2 个 peer 连接 (TCP + WS 两条路径)

检查 3: 区块同步状态（三节点）
  节点 B tip: 0x5
  节点 A tip: 0x5
  节点 C tip: 0x5
  ✅ PASS: 三个节点 tip 一致，同步正常

检查 5: TCP 路径 — Proxy Protocol v2
  节点 A (TCP 客户端) 在节点 B 视角的地址:
    /ip4/192.168.65.1/tcp/22821/p2p/Qm...
  ✅ PASS: 端口 22821 是随机源端口（非 18115）
     -> Proxy Protocol v2 正确传递了客户端真实源端口

检查 6: WS 路径 — X-Forwarded-For + X-Forwarded-Port
  节点 C (WS 客户端) 在节点 B 视角的地址:
    /ip4/192.168.65.1/tcp/33456/p2p/Qm...

  [6a] X-Forwarded-For (IP 传递):
    ✅ PASS: IP=192.168.65.1 (有效地址)
       📝 Docker Desktop 网关 IP

  [6b] X-Forwarded-Port (端口传递 — 与 socket 端口交叉比对):
    节点 B 报告的端口 (get_peers):  33456
    节点 B 的 socket 连接源端口:    55371 55381

    原理: 如果 X-Forwarded-Port 生效，get_peers 端口应来自 HTTP header
          而非 socket 层的后端连接端口，因此两者应该不同

    ✅ PASS: get_peers 端口 33456 不在 socket 端口列表 [55371 55381] 中
       -> X-Forwarded-Port 成功将 HTTP header 中的客户端端口传递给了节点 B

测试总结
  通过: 5
  失败: 0
  🎉 所有检查通过！TCP + WS 两条代理路径均已验证
```
