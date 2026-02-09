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
节点 A -- WebSocket ----| :18080 --X-Fwd-For> :8115 |--> 节点 B
                        +---------------------------+
```

- **TCP 路径**: 用 Proxy Protocol v2 传递真实 IP
- **WS 路径**: 用 X-Forwarded-For / X-Forwarded-Port header 传递真实 IP

### 端口分配

| 组件 | P2P 端口 | RPC 端口 | 说明 |
|------|----------|----------|------|
| 节点 B (服务端) | 8115 | 8114 | 接收代理连接 |
| 节点 A (客户端) | 8116 | 8124 | 通过 HAProxy 连接节点 B |
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
rm -rf node_a node_b node_a.log node_b.log miner.log .node_* .haproxy.darwin.cfg
```

## 如何判断测试通过

`check.sh` 会自动运行 5 项检查并给出 PASS/FAIL 结论，退出码为失败项数量（0 = 全部通过）。

### 自动评分项

| 检查 | 内容 | 通过条件 |
|------|------|----------|
| 检查 1 | peer 连接 | 节点 B 有至少 1 个 peer |
| 检查 3 | 区块同步 | 两个节点 tip 一致 |
| 检查 5 | Proxy Protocol 验证 | 节点 B 看到的端口不是 HAProxy 代理端口 |

### 信息展示项（不计分）

| 检查 | 内容 |
|------|------|
| 检查 2 | 逐个解析 peer 地址，分析 IP 和端口含义 |
| 检查 4 | 查看节点 B 日志中的连接和 proxy 相关信息 |

### 核心判断逻辑

**看端口号**：节点 B 的 `get_peers` 返回的地址中，端口应该是节点 A 的**真实源端口**
（一个随机的高位端口），而**不是** HAProxy 的 `18115` 或 `18080`。

- **同机测试**: IP 为 `127.0.0.1`（直连）或 `192.168.65.1`（Docker 网关），关注端口号即可
- **跨机测试**: 节点 B 看到的 IP 应该是节点 A 所在机器的真实 IP

## check.sh 输出示例

```
检查 1: 节点 B 的已连接 peers
  连接的 peer 数量: 1
  ✅ PASS: 有 peer 连接

检查 2: Proxy Protocol 地址解析
  节点 B 看到的所有 peer 地址:
    地址: /ip4/192.168.65.1/tcp/22821/p2p/Qm...
    解析: IP=192.168.65.1  端口=22821
    ✅ 端口 22821 是随机源端口 -> Proxy Protocol 正确传递了真实源端口
    📝 IP 为 Docker Desktop 网关地址

检查 3: 区块同步状态
  节点 B tip: 0x5
  节点 A tip: 0x5
  ✅ PASS: 两个节点 tip 一致，同步正常

检查 5: 关键对比
    节点 B 看到的对端地址: /ip4/192.168.65.1/tcp/22821/p2p/Qm...
    ✅ PASS: 节点 B 看到的端口 (22821) 不是 HAProxy 代理端口
       -> Proxy Protocol 正确传递了客户端的真实源端口

测试总结
  通过: 3
  失败: 0
  🎉 所有自动检查通过！
```
