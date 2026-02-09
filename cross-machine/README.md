# CKB Proxy Protocol 跨机测试

跨机版本的 CKB Proxy Protocol 测试，验证 [ckb#5105](https://github.com/nervosnetwork/ckb/pull/5105)。

与同机测试的区别：
- HAProxy 在 Ubuntu 上**原生运行**（不用 Docker）
- 节点分布在**两台机器**上，可以真正验证 IP 传递
- X-Forwarded-For 的 IP 验证在同机环境下是弱验证，跨机环境下可以**强验证**

## 架构

```
  客户端机器 (CLIENT_IP)            服务端机器 (SERVER_IP)
  +---------------------+          +---------------------------+
  | 节点 A (TCP, P2P:8116)  ----TCP---->| HAProxy :8220             |
  |                     |          |   send-proxy-v2 -> :8115  |
  | 节点 C (WS,  P2P:8117)  ----WS---->| HAProxy :8221             |-->  节点 B
  |                     |          |   X-Fwd-For/Port -> :8115 |    P2P:8115
  +---------------------+          +---------------------------+    RPC:8114
```

## 前置条件

**两台机器都需要:**
- CKB 二进制（包含 PR #5105 的代码）
- curl, jq

**服务端额外需要:**
- HAProxy: `sudo apt update && sudo apt install -y haproxy`

**网络要求:**
- 客户端能访问服务端的 **8114** (RPC)、**8220** (TCP 代理)、**8221** (WS 代理) 端口
- 如有防火墙 / AWS Security Group，需放行这三个端口

## 端口分配

| 组件 | 所在机器 | 端口 | 说明 |
|------|---------|------|------|
| 节点 B (P2P) | 服务端 | 8115 | 接收代理连接 |
| 节点 B (RPC) | 服务端 | 8114 | 监听 0.0.0.0，远程可访问 |
| HAProxy TCP | 服务端 | 8220 | send-proxy-v2 -> :8115 |
| HAProxy WS | 服务端 | 8221 | X-Forwarded-For/Port -> :8115 |
| 节点 A (P2P) | 客户端 | 8116 | TCP 客户端 |
| 节点 A (RPC) | 客户端 | 8124 | 本地 RPC |
| 节点 C (P2P) | 客户端 | 8117 | WS 客户端 |
| 节点 C (RPC) | 客户端 | 8134 | 本地 RPC |

## 使用方法

### 第 1 步：服务端设置

在服务端机器上：

```bash
cd cross-machine/server

# 配置 CKB 路径
echo 'CKB_BIN=/path/to/ckb' > .env

# 初始化
bash setup.sh

# 启动
bash start.sh
```

记下输出的 `peer_id`，下一步要用。

### 第 2 步：传递文件到客户端

将服务端的 peer_id 和 dev.toml 传到客户端：

```bash
# 在服务端执行
scp server/.node_b_peer_id  user@CLIENT_IP:cross-machine/client/.node_b_peer_id
scp server/node_b/specs/dev.toml  user@CLIENT_IP:cross-machine/client/.dev.toml
```

或者手动创建：

```bash
# 在客户端执行
echo '<上一步看到的 peer_id>' > client/.node_b_peer_id
```

### 第 3 步：客户端设置

在客户端机器上：

```bash
cd cross-machine/client

# 配置服务端 IP 和 CKB 路径
cat > .env << 'EOF'
SERVER_IP=<服务端IP>
CKB_BIN=/path/to/ckb
EOF

# 初始化
bash setup.sh

# 启动
bash start.sh
```

### 第 4 步：检查结果

在客户端机器上运行（脚本会自动从 `client/.env` 读取 `SERVER_IP`）：

```bash
cd cross-machine
bash check.sh
```

### 停止

```bash
# 客户端
cd cross-machine/client && bash stop.sh

# 服务端
cd cross-machine/server && bash stop.sh
```

## 检查项目

| 检查 | 内容 | 通过条件 |
|------|------|----------|
| 检查 1 | peer 连接 | 节点 B 有至少 2 个 peer |
| 检查 3 | 区块同步 | 三个节点 tip 一致 |
| 检查 4a | TCP IP | 节点 B 看到客户端真实 IP (Proxy Protocol v2) |
| 检查 4b | TCP 端口 | 端口非 HAProxy 代理端口 8220 |
| 检查 5 | WS IP | 节点 B 看到客户端真实 IP (X-Forwarded-For) |
| 检查 6 | WS 端口 | 节点 C 源端口 == 节点 B 看到的端口 (X-Forwarded-Port) |
| 检查 7 | IP 一致性 | TCP 和 WS 路径看到的客户端 IP 相同 |

### 跨机 vs 同机的关键区别

| 验证项 | 同机 | 跨机 |
|--------|------|------|
| X-Forwarded-For (IP) | ⚠️ 弱验证（socket IP == forwarded IP） | ✅ **强验证**（IP 必须是客户端机器的真实 IP） |
| X-Forwarded-Port (端口) | ⚠️ 间接验证（socket 端口交叉比对） | ✅ **精确匹配**（`ss` 查到的源端口 == `get_peers` 端口） |
| Proxy Protocol v2 (IP) | ⚠️ 弱验证（Docker 网关 IP） | ✅ **强验证**（IP 必须是客户端 IP） |

## 预期输出示例

```
CKB Proxy Protocol 跨机测试检查
  服务端: 10.0.1.100
  客户端: 10.0.1.200

检查 4: TCP 路径 — Proxy Protocol v2
  [4a] Proxy Protocol v2 — IP 传递:
    ✅ PASS: IP=10.0.1.200 是客户端机器的真实 IP
  [4b] Proxy Protocol v2 — 端口传递:
    ✅ PASS: 端口 45678 是随机源端口（非 8220）

检查 5: WS 路径 — X-Forwarded-For (IP)
  ✅ PASS: IP=10.0.1.200 是客户端机器的真实 IP

检查 6: WS 路径 — X-Forwarded-Port (端口)
  节点 B 报告的端口 (get_peers): 52341
  节点 C 到 HAProxy 的实际源端口 (ss): 52341
  ✅ PASS: 端口完全匹配！

检查 7: TCP 与 WS 路径 IP 一致性
  ✅ PASS: 两条路径看到的 IP 一致 (10.0.1.200)

测试总结
  通过: 7
  失败: 0
  🎉 所有检查通过！
```
