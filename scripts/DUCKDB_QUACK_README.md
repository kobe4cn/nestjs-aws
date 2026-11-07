# DuckDB Quack Server AWS 自动化管理工具

基于 DuckDB 官方 [`duckdb/duckdb-quack-infra`](https://github.com/duckdb/duckdb-quack-infra) 架构设计，提供跨区域、全自动化的 AWS EC2 部署与运维 CLI。

无需预先烘焙私有 AMI，支持在 AWS 任意区域（包括悉尼 `ap-southeast-2`、新加坡 `ap-southeast-1`、美东 `us-east-1` 等）一键启动生产级具备 HTTPS 证书的 DuckDB Quack RPC 服务器。

---

## 一、核心特性

1. **零 AMI 依赖，全区域通用**：动态解析当前区域官方 Canonical Ubuntu 24.04 LTS 官方最新底包，即开即用。
2. **全自动网络与安全组**：
   - 自动绑定 Default VPC 与公网子网。
   - 自动创建专用安全组并放行 `22 (SSH)`、`80 (ACME HTTP 挑战)`、`443 (Quack HTTPS)`。
3. **SSH 密钥自动纳管**：
   - 自动检查并创建 AWS KeyPair。
   - 私钥自动落盘至本地 `~/.ssh/duckdb-quack-key.pem` 并设置严格的 `400` 权限，支持一键免密 SSH 登录排障。
4. **权威免费 SSL 证书**：
   - 利用 `nip.io` 泛域名服务将机器公网 IP 映射为主机名（如 `54.x.x.x.nip.io`）。
   - 通过 Certbot 自动向 Let's Encrypt 申请权威 TLS 证书并配置到 Nginx。
5. **系统级守护进程**：
   - 将 DuckDB Quack RPC 服务注册为 `systemd` 服务（`duckdb-quack.service`），支持崩溃自愈与守护。
6. **成本完全受控（0 残留销毁）**：
   - 提供 `destroy` 命令，级联终止 EC2 实例、清理卷、移除自定义安全组与密钥对，确保不留任何收费隐患。

---

## 二、快速开始

本工具已集成至工程根目录的 `package.json`，支持使用 `pnpm` 快捷命令，也可以直接运行脚本。

### 1. 一键创建与部署服务器
```bash
# 方式 A：使用 pnpm 命令
pnpm quack:create

# 方式 B：直接执行脚本
./scripts/duckdb-quack-server.sh create
```

**执行流程**：
- 自动生成本地 SSH 密钥对；
- 自动创建安全组；
- 向 AWS 请求创建 `t3.small` 实例；
- 实例启动后，后台自动执行 Cloud-Init：安装 DuckDB CLI、编译加载 `quack` 扩展、配置 Nginx 代理、签发 Let's Encrypt 证书并启动守护进程；
- 探活成功后，终端将输出专属的 **RPC URI**、**访问 Token** 与 **DuckDB 连接示例**。

---

### 2. 一键 SSH 登录服务器
无需手动查找公网 IP 和输入 `-i` 密钥路径：
```bash
pnpm quack:ssh
# 或者: ./scripts/duckdb-quack-server.sh ssh
```

进入服务器后常用命令：
```bash
# 查看云端初始化完整日志
cat /var/log/duckdb-quack-init.log

# 查看 Quack systemd 守护服务状态
systemctl status duckdb-quack.service

# 查看 Nginx 运行状态与证书绑定情况
systemctl status nginx
nginx -T
```

---

### 3. 查看服务器状态与凭据
```bash
pnpm quack:status
# 或者: ./scripts/duckdb-quack-server.sh status
```

---

### 4. 一键彻底销毁（停止计费）
测试完毕或不再使用时，一键彻底释放云上所有关联资源：
```bash
pnpm quack:destroy
# 或者: ./scripts/duckdb-quack-server.sh destroy
```
> [!NOTE]
> 该命令会终止 EC2 实例（附带自动删除 20GB 系统盘）、删除安全组 `duckdb-quack-sg` 并清理 AWS 密钥对，彻底阻断任何后续账单。

---

## 三、客户端连接与调用示例

当创建脚本运行完成后，服务端便就绪于 `quack:<公网IP>.nip.io:443`。

### 1. 本地 DuckDB CLI 或 Python 调用

在你的本地 DuckDB 控制台中执行：

```sql
-- 1. 安装并加载 quack 核心扩展
INSTALL quack FROM core_nightly;
LOAD quack;

-- 2. 注册服务器凭证 (将 <URI> 与 <TOKEN> 替换为 create 命令输出的实际内容)
CREATE SECRET quack_credentials (
    TYPE quack,
    SCOPE 'quack:54.x.x.x.nip.io:443',
    TOKEN 'your_generated_secure_token'
);

-- 3. 发起远程 RPC 单次调用
FROM rpc_call('quack:54.x.x.x.nip.io:443', 'FROM whoami()');
FROM rpc_call('quack:54.x.x.x.nip.io:443', 'SELECT 42 * 2 AS answer');

-- 4. 通过 ATTACH 建立持久化会话（支持临时表与服务端状态保持）
ATTACH 'quack:54.x.x.x.nip.io:443' AS remote (TYPE QUACK);

-- 在远程服务端创建临时数据并计算
FROM rpc_call_by_name('remote', 'CREATE TEMP TABLE test_table AS SELECT range AS id FROM range(1000)');
FROM rpc_call_by_name('remote', 'SELECT count(*), avg(id) FROM test_table');
```

### 2. Web 浏览器直连 (shell.duckdb.org)

`quack:create` 命令输出的末尾会附带一个预填参数的专属链接，格式如下：
```text
https://shell.duckdb.org/#queries=v0,INSTALL-quack-FROM-core_nightly~,LOAD-quack~,CREATE-SECRET-quack_credentials-(TYPE-quack%2C-SCOPE-'quack%3A54.x.x.x.nip.io%3A443'%2C-TOKEN-'your_token')~,FROM-rpc_call('quack%3A54.x.x.x.nip.io%3A443'%2C-'FROM-whoami()')~
```
直接在浏览器中打开该 URL，即可直接在官方 WebAssembly DuckDB Shell 中向你的 AWS 服务器发送查询。

---

## 四、可选环境变量配置

你可以通过环境变量覆盖默认参数：

| 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `AWS_REGION` | `ap-southeast-2` | 部署的 AWS 目标区域代码 |
| `INSTANCE_TYPE` | `t3.small` | EC2 实例类型规格（建议 2 核 2G 或更高） |
| `VOLUME_SIZE` | `20` | 系统盘容量（单位：GB，采用 gp3 高性能卷） |
| `KEY_NAME` | `duckdb-quack-key` | AWS KeyPair 名称 |
| `KEY_PATH` | `~/.ssh/duckdb-quack-key.pem` | 本地 SSH 私钥存放绝对路径 |
| `SECURITY_GROUP_NAME` | `duckdb-quack-sg` | 安全组名称 |
| `INSTANCE_TAG_NAME` | `duckdb-quack-server` | EC2 实例 Name 标签 |

**自定义环境变量示例**：
```bash
# 在新加坡区域启动 4 核 16G 规格的 DuckDB 计算节点
AWS_REGION=ap-southeast-1 INSTANCE_TYPE=m7i.large pnpm quack:create
```

