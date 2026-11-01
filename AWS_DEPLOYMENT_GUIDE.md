# NestJS (`auth` & `order`) AWS 生产环境完整部署手册

本手册基于项目最新适配完成的代码状态编写，涵盖从 **本地 Podman/Docker 容器构建与上传 ECR**，到 **KMS、Secrets Manager、RDS、ElastiCache、IAM、ALB、ECS Fargate 及数据库 Migration** 的全流程配置。

---

## 一、整体云上架构与项目最终状态

### 1.1 云上拓扑架构图

```mermaid
flowchart TD
    Client["客户端 / 浏览器"] -->|HTTPS 443 / HTTP 80| ALB["AWS ALB (应用负载均衡器)<br/>公有子网 / alb-sg"]
    ALB -->|HTTP 3000<br/>健康检查: /api/v1/health| Auth["ECS Service: auth<br/>Fargate / ecs-auth-sg"]
    
    Auth -->|TCP 3031<br/>ECS Service Connect: order.nestjs.internal| Order["ECS Service: order<br/>Fargate / ecs-order-sg"]
    Auth -->|SMTP 465 / 587<br/>经 NAT Gateway 或公网 IP| QQMail["腾讯 QQ 邮箱服务器<br/>smtp.qq.com"]

    Migration["ECS One-off Task: migration<br/>使用 auth 镜像执行 migration:run:prod"] -->|TCP 5432 + SSL| RDS[("Amazon RDS PostgreSQL<br/>私有子网 / rds-sg / KMS 加密")]

    Auth -->|TCP 5432 + SSL| RDS
    Order -->|TCP 5432 + SSL| RDS
    Auth -->|TCP 6379| Redis[("Amazon ElastiCache Redis<br/>私有子网 / redis-sg")]

    KMS["AWS KMS (CMK)<br/>alias/nestjs-prod-key"] -.->|加密存储| RDS
    KMS -.->|加密镜像| ECR["Amazon ECR<br/>nestjs-auth / nestjs-order"]
    KMS -.->|加解密敏感凭据| SM["AWS Secrets Manager<br/>SDB_PASS / JWT_SECRET / MAIL_PASS / REDIS_PASS"]
    SM -.->|容器启动时注入环境变量| Auth
    SM -.->|容器启动时注入环境变量| Order
```

### 1.2 代码适配最终状态核对

| 模块 | 关键文件 | 生产环境行为 |
| :--- | :--- | :--- |
| **容器构建** | [`Dockerfile`](./Dockerfile)、[`.dockerignore`](./.dockerignore) | 支持通过 `--build-arg APP_NAME=auth` 或 `order` 独立打包，自动携带 `.hbs` 邮件模板与编译后的 Migration 脚本 |
| **数据库连接** | [`typeorm.service.ts`](./lib/common/database/typeorm/typeorm.service.ts)、[`data-source.ts`](./lib/common/database/data-source.ts) | 统一读取 `SDB_*` 环境变量；当 `NODE_ENV=production` 或 `SDB_SSL=true` 时自动开启 RDS SSL 连接 |
| **微服务通信** | [`apps/order/src/main.ts`](./apps/order/src/main.ts)、[`user.module.ts`](./apps/auth/src/module/user/user.module.ts) | `order` 默认绑定 `0.0.0.0:3031`；`auth` 通过 `ORDER_SERVICE_HOST` 与 `ORDER_SERVICE_PORT` 连接 `order` |
| **Redis 缓存** | [`cache.redis.module.ts`](./lib/common/cache/cache.redis.module.ts)、[`cache.module.ts`](./lib/common/cache/cache.module.ts) | 自动兼容 `host:port`、`redis://` 与开启 TLS 后的 `rediss://` 地址 |
| **腾讯 SMTP** | [`mail.module.ts`](./lib/common/mail/mail.module.ts) | 自动转换数字端口（`587` STARTTLS / `465` SSL），支持编译后模板路径回退 |
| **日志与健康检查** | [`logs.module.ts`](./lib/common/logger/logs.module.ts)、[`app.controller.ts`](./apps/auth/src/app.controller.ts) | 生产环境向 `stdout` 输出标准 JSON 供 CloudWatch 采集；提供 `GET /api/v1/health` 供 ALB 探测 |

---

## 二、阶段 1：VPC 网络与安全组配置

### 2.1 VPC 与子网规划
在 AWS VPC 控制台使用 **“VPC and more”** 向导创建：
* **VPC CIDR**：`10.0.0.0/16`
* **可用区（AZ）数量**：`2`（RDS 与 ALB 强制要求至少跨 2 个可用区）
* **公有子网（Public Subnets）**：2 个（用于部署 ALB）
* **私有子网（Private Subnets）**：2 个（用于部署 ECS Tasks、RDS、ElastiCache Redis）

> [!IMPORTANT]
> **腾讯 QQ 邮箱（`smtp.qq.com`）两种出网方案详细配置对比**：
> 由于 `auth` 服务需要连接公网的 `smtp.qq.com:587`（或 `465`），同时 ECS 任务拉取 ECR 镜像、读取 Secrets Manager 也需要网络连通，以下提供两种完整配置方案：

| 配置维度 | 方案 A：标准生产方案（私有子网 + NAT Gateway） | 方案 B：低成本方案（公有子网 + 免 NAT Gateway） |
| :--- | :--- | :--- |
| **适用场景** | 正式生产环境、合规要求容器无公网 IP、需要固定出网 IP 白名单 | 开发/测试/初期生产环境，希望省去 NAT Gateway 约 $32+/月的固定费用 |
| **VPC 向导配置** | `NAT gateways` 选择 **`In 1 AZ`**（或 `1 per AZ`） | `NAT gateways` 选择 **`None`**（仅保留免费的 Internet Gateway `IGW`） |
| **RDS 与 Redis 子网** | **私有子网（Private Subnets）**，`Public access = No` | **私有子网（Private Subnets）**，`Public access = No`（数据层依然完全隔离在私有网段） |
| **`auth` ECS 服务子网** | 选择 **私有子网（Private Subnets）** | 选择 **公有子网（Public Subnets）** |
| **`auth` Public IP 开关** | `Assign public IP` = **`DISABLED`** | `Assign public IP` = **`ENABLED`**（必须开启才能通过 IGW 访问 `smtp.qq.com` 和拉取 ECR 镜像） |
| **`order` ECS 服务子网** | 选择 **私有子网**，`Assign public IP` = **`DISABLED`** | 选择 **公有子网**，`Assign public IP` = **`ENABLED`**（因无 NAT 网关，需通过 IGW 拉取 ECR 镜像与读取 Secrets） |
| **入站安全性** | 容器无公网 IP，仅内网可达 | 容器虽有公网 IP，但 `ecs-auth-sg` 入站仅允许 `alb-sg`，`ecs-order-sg` 入站仅允许 `ecs-auth-sg`，**外部公网依然无法直接访问容器端口** |
| **部署脚本环境变量** | `ASSIGN_PUBLIC_IP=DISABLED`<br/>`SUBNET_IDS=私有子网1,私有子网2` | `ASSIGN_PUBLIC_IP=ENABLED`<br/>`SUBNET_IDS=公有子网1,公有子网2` |

### 2.2 创建 5 个安全组（Security Groups）

按以下顺序在同一个 VPC 下创建安全组，严格遵循最小权限原则：

> [!WARNING]
> **为什么在 Source（来源）里选不到 `alb-sg`，只看得到 `default`？**
> 1. **VPC 没选对（最常见原因）**：在 AWS 控制台点击 **Create security group** 时，页面上方的 **VPC** 下拉框默认会选中账号自带的 **默认 VPC（Default VPC）**，而不是你刚才新建的 VPC！
>    * **解决办法**：每创建一个安全组时，**必须先在 `VPC` 一栏点开下拉框，切换为你新建的 VPC**（如 `nestjs-vpc`）。只有处于**同一个 VPC** 下的安全组，才能在 `Source`（来源）中互相引用。
>    * 如果之前创建的 `alb-sg` 不小心建在了默认 VPC 下，请先删掉它，切换到新建的 VPC 下重新创建 `alb-sg`。
> 2. **创建顺序**：必须先完成上一个安全组（如 `alb-sg`）的创建并保存，再创建下一个安全组（如 `ecs-auth-sg`），在 Inbound rules 的 `Source` 类型选 `Custom`，然后在右侧搜索框输入 `sg-` 或 `alb-sg` 即可看到。

| 安全组名称 | 用途 | 入站规则（Inbound Rules） | 出站规则（Outbound Rules） |
| :--- | :--- | :--- | :--- |
| `alb-sg` | 绑定给 ALB 负载均衡器 | `TCP 80` 来源 `0.0.0.0/0`<br/>`TCP 443` 来源 `0.0.0.0/0` | 允许全部 (`0.0.0.0/0`) |
| `ecs-auth-sg` | 绑定给 `auth` ECS 服务及 Migration 任务 | `TCP 3000` 来源选择 **`alb-sg`** | 允许全部 (`0.0.0.0/0`，含访问 587/465 邮件端口) |
| `ecs-order-sg` | 绑定给 `order` ECS 服务 | `TCP 3031` 来源选择 **`ecs-auth-sg`** | 允许全部 (`0.0.0.0/0`) |
| `rds-sg` | 绑定给 RDS PostgreSQL | `TCP 5432` 来源选择 **`ecs-auth-sg`**<br/>`TCP 5432` 来源选择 **`ecs-order-sg`** | 允许全部 (`0.0.0.0/0`) |
| `redis-sg` | 绑定给 ElastiCache Redis | `TCP 6379` 来源选择 **`ecs-auth-sg`** | 允许全部 (`0.0.0.0/0`) |

---

## 三、阶段 2：KMS 密钥与 Secrets Manager 配置

### 3.1 创建 KMS 客户自主管理密钥（CMK）
1. 进入 **AWS KMS** -> **Customer managed keys** -> **Create key**。
2. **Key type**：`Symmetric`（对称加密），**Key usage**：`Encrypt and decrypt`。
3. **Alias（别名）**：输入 `nestjs-prod-key`（即 `alias/nestjs-prod-key`）。
4. 勾选 **Automatically rotate this KMS key every year**（每年自动轮换）。
5. 完成创建并记录下该密钥的 **ARN**（形如：`arn:aws:kms:<region>:<account_id>:key/<kms_key_id>`）。

### 3.2 在 Secrets Manager 中创建加密机密
1. 进入 **AWS Secrets Manager** -> **Store a new secret**。
2. **Secret type**：选择 `Other type of secret`。
3. **Key/value pairs**：点击 `Plaintext` 标签页，粘贴以下 JSON（请将值替换为你的真实生产密码）：
   ```json
   {
     "SDB_PASS": "你的RDS数据库强密码",
     "REDIS_PASS": "你的Redis密码(若ElastiCache未开密码可填任意非空字符或留空)",
     "JWT_SECRET": "E7OkxXjYtwJMoj6MajYqOhryUB0JRfE/q30k8paUE5U=",
     "MAIL_PASS": "your_smtp_authorization_code"
   }
   ```
4. **Encryption key**：下拉选择刚才创建的 **`alias/nestjs-prod-key`**（使用 KMS CMK 加密）。
5. **Secret name**：输入 `nestjs/prod/env`。
6. 完成创建并记录下该 Secret 的 **ARN**（形如：`arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxxxx`）。

---

## 四、阶段 3：RDS PostgreSQL 与 ElastiCache Redis 配置

### 4.1 创建 RDS PostgreSQL
1. 进入 **Amazon RDS** -> **Databases** -> **Create database**。
2. **Engine options**：选择 `PostgreSQL`（推荐 PostgreSQL 16.x）。
3. **Templates**：生产选 `Production`，测试/预发可选 `Dev/Test` 或 `Free tier`。
4. **Settings**：
   * **DB instance identifier**：`nestjs-postgres`
   * **Master username**：`crm`
   * **Credentials management**：选择 `Self managed`，输入与 Secrets Manager 中 `SDB_PASS` 一致的密码。
5. **Connectivity（网络）**：
   * 选择阶段 1 创建的 **VPC**。
   * **DB subnet group**：选择私有子网组。
   * **Public access**：选择 **`No`**。
   * **VPC security group**：选择 Existing -> 勾选 **`rds-sg`**（移除 `default`）。
6. **Additional configuration（重要）**：
   * **Initial database name**：填写 `typeorm_test`（或你的生产库名，**必须填写**，否则 RDS 不会自动创建业务库）。
   * **Encryption**：勾选 **Enable encryption**，并在 **AWS KMS key** 中选择 **`alias/nestjs-prod-key`**。
7. 点击创建，等待状态变为 `Available`，复制其 **Endpoint**（例如 `nestjs-postgres.xxxx.ap-southeast-1.rds.amazonaws.com`）。

### 4.2 创建 ElastiCache Redis
1. 进入 **Amazon ElastiCache** -> **Redis OSS caches** -> **Create cache**。
2. **Deployment option**：选择 `Design your own cache` -> `Node-based cluster`，**Cluster mode**：选择 **`Disabled`**（对应项目中 `REDIS_TYPE=single`）。
3. **Subnet group**：创建并选择包含私有子网的子网组。
4. **Security groups**：选择 **`redis-sg`**。
5. 创建完成后，复制其 **Primary endpoint**（例如 `nestjs-redis.xxxx.ng.0001.apse1.cache.amazonaws.com:6379`）。

---

## 五、阶段 4：ECR 仓库创建、本地容器打包与上传

### 5.1 创建 ECR 私有镜像仓库
1. 进入 **Amazon ECR** -> **Repositories** -> **Create repository**。
2. 分别创建两个私有仓库：
   * 仓库 1 名称：`nestjs-auth`
   * 仓库 2 名称：`nestjs-order`
3. 在每个仓库的创建页面底部展开 **Encryption settings**：
   * 开启 **KMS encryption**。
   * 选择 **`alias/nestjs-prod-key`**。

### 5.2 使用项目内置自动化脚本打包、迁移与发布

项目中已为你生成了本地一键发布脚本 [`scripts/deploy-aws.sh`](./scripts/deploy-aws.sh)、[`package.json`](./package.json) 快捷命令以及 GitHub Actions 自动部署流水线 [`.github/workflows/deploy-aws.yml`](./.github/workflows/deploy-aws.yml)。

#### 方式一：本地命令行一键发布（通过 [`scripts/deploy-aws.sh`](./scripts/deploy-aws.sh)）

```bash
# 0. 若尚未安装 AWS CLI，先通过 Homebrew 安装并配置凭证
#    获取 Access Key 步骤：
#    登录 AWS 控制台 -> 点击右上角账号名 -> Security credentials (安全凭证)
#    -> 下拉到 Access keys (访问密钥) -> 点击 Create access key (创建访问密钥)
#    -> 选择 Command Line Interface (CLI) -> 勾选确认并创建，复制 Access key ID 和 Secret access key
brew install awscli
aws configure
# 依次输入：
#   AWS Access Key ID [None]: 粘贴你的 Access key ID (如 AKIAIOSFODNN7EXAMPLE)
#   AWS Secret Access Key [None]: 粘贴你的 Secret access key
#   Default region name [None]: 输入你的区域代码 (如 ap-southeast-1)
#   Default output format [None]: 输入 json (或直接回车)

# 1. 设置你的 AWS 环境参数
#   - AWS_REGION : AWS 控制台右上角当前区域代码（如新加坡 ap-southeast-1、东京 ap-northeast-1、美东 us-east-1）
#   - SUBNET_IDS : VPC -> Subnets (子网) 列表中，两个子网的 Subnet ID（用英文逗号拼接，中间不要有空格）
#                  方案 A (带 NAT) 填 2 个 Private 子网 ID；方案 B (无 NAT) 填 2 个 Public 子网 ID
#   - AUTH_SG_ID : VPC -> Security Groups (安全组) 列表中，名为 ecs-auth-sg 的 Security group ID
export AWS_REGION="ap-southeast-2"
export SUBNET_IDS="subnet-xxxxxxxxxxxxxxxxx,subnet-yyyyyyyyyyyyyyyyy"
export AUTH_SG_ID="sg-xxxxxxxxxxxxxxxxx"

# 方案 A (私有子网 + NAT Gateway) 设为 DISABLED
# 方案 B (公有子网 + 免 NAT Gateway) 设为 ENABLED
export ASSIGN_PUBLIC_IP="DISABLED"

# 2. 一键执行：构建双镜像推送 ECR -> 运行 ECS Migration 任务并等待完成 -> 滚动更新 order 与 auth
pnpm aws:deploy

# 或者分步独立执行：
pnpm aws:push      # 仅构建并推送 auth 与 order 镜像到 ECR
pnpm aws:migrate   # 仅运行 ECS 一次性任务执行 RDS TypeORM Migration（失败会自动中止并返回非 0 状态码）
pnpm aws:rollout   # 仅触发 order 与 auth ECS 服务强制滚动更新
```

#### 方式二：GitHub Actions 自动发布（[`.github/workflows/deploy-aws.yml`](./.github/workflows/deploy-aws.yml)）

在 GitHub 仓库的 **Settings -> Secrets and variables -> Actions** 中配置以下 3 个 Repository Secrets 后，每次推送到 `main` 分支（或手动在 Actions 页面点击 Run workflow 选择网络模式 `DISABLED` / `ENABLED`）即可全自动完成构建、迁移与滚动发布：
* `AWS_ROLE_ARN`：GitHub OIDC 关联的 AWS IAM Role ARN
* `ECS_SUBNET_IDS`：`subnet-xxxx,subnet-yyyy`
* `ECS_AUTH_SG_ID`：`sg-xxxx` (即 `ecs-auth-sg` 的安全组 ID)

#### 方式三：手动执行原生 Podman 与 AWS CLI 命令

若需手动逐步执行，打开本地终端（位于 `/Users/kevin/dev/nestjs-aws` 目录，确保已运行 `podman machine start` 启动虚拟机）：

```bash
# 1. 设置环境变量（请替换为你的 AWS 区域和 12 位账号 ID）
export AWS_REGION="ap-southeast-1"
export AWS_ACCOUNT_ID="123456789012"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_TAG="v1.0.0"

# 2. 使用 Podman 登录 AWS ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  podman login --username AWS --password-stdin ${ECR_REGISTRY}

# 3. 构建并推送 auth 镜像
# 注意：
#   --platform linux/arm64 : 适配 ECS Fargate Linux/ARM64 (AWS Graviton) 架构
#   --format docker        : 生成标准 Docker v2 镜像清单，确保 ECS Fargate 100% 兼容
podman build \
  --platform linux/arm64 \
  --format docker \
  --build-arg APP_NAME=auth \
  -t ${ECR_REGISTRY}/nestjs-auth:${IMAGE_TAG} \
  -t ${ECR_REGISTRY}/nestjs-auth:latest \
  .

podman push ${ECR_REGISTRY}/nestjs-auth:${IMAGE_TAG}
podman push ${ECR_REGISTRY}/nestjs-auth:latest

# 4. 构建并推送 order 镜像
podman build \
  --platform linux/arm64 \
  --format docker \
  --build-arg APP_NAME=order \
  -t ${ECR_REGISTRY}/nestjs-order:${IMAGE_TAG} \
  -t ${ECR_REGISTRY}/nestjs-order:latest \
  .

podman push ${ECR_REGISTRY}/nestjs-order:${IMAGE_TAG}
podman push ${ECR_REGISTRY}/nestjs-order:latest
```

> [!TIP]
> **本地先行验证镜像**：在推送前，你可以随时在本地执行以下命令使用 Podman 验证镜像构建是否正常：
> ```bash
> pnpm image:build:auth
> pnpm image:build:order
> ```

---

## 六、阶段 5：IAM 角色与 KMS 解密权限配置

### 6.1 配置 `ecsTaskExecutionRole`
1. 进入 **IAM** -> **Roles**，搜索并进入 `ecsTaskExecutionRole`（若不存在则创建 Trusted entity 为 `Elastic Container Service -> Elastic Container Service Task` 的角色，并附加 AWS 托管策略 `AmazonECSTaskExecutionRolePolicy`）。
2. 点击 **Add permissions** -> **Create inline policy**，切换到 `JSON` 视图，粘贴以下策略（替换 `<region>`、`<account_id>`、`<kms_key_id>`）：
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowReadSecretsAndDecryptKMS",
         "Effect": "Allow",
         "Action": [
           "secretsmanager:GetSecretValue",
           "kms:Decrypt"
         ],
         "Resource": [
           "arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-*",
           "arn:aws:kms:<region>:<account_id>:key/<kms_key_id>"
         ]
       },
       {
         "Sid": "AllowCreateCloudWatchLogGroup",
         "Effect": "Allow",
         "Action": [
           "logs:CreateLogGroup"
         ],
         "Resource": "arn:aws:logs:<region>:<account_id>:log-group:/ecs/*"
       }
     ]
   }
   ```
3. 将策略命名为 `ECS-Secrets-KMS-Decrypt-Policy` 并保存。

---

## 七、阶段 6：ECS 集群、Task Definition 与 RDS Migration 执行

### 7.1 创建 ECS 集群

> [!WARNING]
> **注意避开新版 AWS ECS 控制台的“Express Mode（快速模式）”**：
> 当账号下首次使用 ECS 时，控制台可能会默认引导进入 **Express Mode**（将集群、服务、ALB 合并在一个极简页面中）。但 Express Mode **不支持 `order` 纯 TCP 微服务（3031 端口）与 Service Connect 内网服务发现**。
> * 如果看到页面顶部显示 **Express mode**，请点击页面右上角或顶部横幅中的 **`Switch to standard configuration`（切换到标准配置）**（或点击左侧导航栏展开菜单，分别进入 **Clusters** 和 **Task definitions**）。

1. 进入 **Amazon ECS** -> 左侧菜单 **Clusters** -> **Create cluster**：
   * **Cluster name**：`nestjs-prod-cluster`
   * **Infrastructure**：勾选 `AWS Fargate (serverless)`
   * **Service Connect defaults**（或展开 Additional configuration）：填写默认命名空间 `nestjs.internal`（ECS 会自动在 Cloud Map 中创建该私有 DNS 命名空间）。

---

### 7.2 创建 `order` 服务的 Task Definition (`nestjs-order-task`)

进入左侧菜单 **Task definitions** -> 点击 **Create new task definition**（标准可视化表单按以下卡片从上到下填写；或者点击 **`Create new task definition with JSON`** 直接粘贴 JSON）：

#### 卡片 1：Task definition configuration
* **Task definition family**：`nestjs-order-task`

#### 卡片 2：Infrastructure requirements（基础设施要求）
* **Launch type**：勾选 `AWS Fargate`
* **Operating system/Architecture**：选择 **`Linux/ARM64`**
* **Task size**：**CPU** 选 `.5 vCPU`，**Memory** 选 `1 GB`
* **Task roles** -> **Task execution role**：选择 **`ecsTaskExecutionRole`**

#### 卡片 3：Container - 1
1. **Container details**：
   * **Name**：`order`
   * **Image URI**：`<account_id>.dkr.ecr.<region>.amazonaws.com/nestjs-order:latest`
   * **Essential container**：`Yes`
2. **Port mappings**：
   * **Container port**：`3031`
   * **Protocol**：`TCP`
   * **Port name**：`order-tcp`（Service Connect 需要引用此名称）
   * **App protocol**：**点击 `×` 清空（留空 / 不选 `HTTP`）**，因为 `order` 是原生 NestJS TCP 微服务而非 HTTP 服务。
3. **Environment variables（环境变量与 Secrets 合并在同一表格）**：
   > [!IMPORTANT]
   > **新版 ECS 控制台不再有单独的 `Secrets` 区域！**
   > 普通环境变量和 Secrets Manager 机密变量都在 **Environment variables** 表格中添加，通过中间的 **`Value type`（值类型）** 下拉框区分：
   > * 普通变量：**`Value type`** 选 **`Value`**
   > * 敏感密码：**`Value type`** 选 **`ValueFrom`**，然后在右侧 Value 填入 `Secret ARN + :JSON键名::`

   点击 **Add environment variable** 依次添加以下 11 行：

   | Key | Value type（中间下拉框） | Value（右侧输入框） |
   | :--- | :--- | :--- |
   | `NODE_ENV` | **`Value`** | `production` |
   | `APP_PORT` | **`Value`** | `3031` |
   | `ORDER_BIND_HOST` | **`Value`** | `0.0.0.0` |
   | `SDB_TYPE` | **`Value`** | `postgres` |
   | `SDB_HOST` | **`Value`** | `<你的 RDS Endpoint>` |
   | `SDB_PORT` | **`Value`** | `5432` |
   | `SDB_USER` | **`Value`** | `crm` |
   | `SDB_DB` | **`Value`** | `typeorm_test` |
   | `SDB_AUTOLOAD` | **`Value`** | `true` |
   | `SDB_SSL` | **`Value`** | `true` |
   | `SDB_PASS` | **`ValueFrom`** | `arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxx:SDB_PASS::` |

4. **Logging（日志配置）**：
   * 保持默认勾选 **Use log collection**（`Amazon CloudWatch`），新版控制台会自动勾选自动创建日志组（`/ecs/nestjs-order-task`）。

---

### 7.3 创建 `auth` 服务的 Task Definition (`nestjs-auth-task`)

同样在 **Task definitions** -> **Create new task definition** 中按卡片从上到下填写：

#### 卡片 1：Task definition configuration
* **Task definition family**：`nestjs-auth-task`

#### 卡片 2：Infrastructure requirements
* **Launch type**：勾选 `AWS Fargate`
* **Operating system/Architecture**：选择 **`Linux/ARM64`**
* **Task size**：**CPU** 选 `.5 vCPU`，**Memory** 选 `1 GB`
* **Task roles** -> **Task execution role**：选择 **`ecsTaskExecutionRole`**

#### 卡片 3：Container - 1
1. **Container details**：
   * **Name**：`auth`
   * **Image URI**：`<account_id>.dkr.ecr.<region>.amazonaws.com/nestjs-auth:latest`
   * **Essential container**：`Yes`
2. **Port mappings**：
   * **Container port**：`3000`
   * **Protocol**：`TCP`
   * **Port name**：`auth-http`
   * **App protocol**：保持 **`HTTP`**
3. **Environment variables（普通变量选 `Value`，敏感密码选 `ValueFrom`）**：

   | Key | Value type（中间下拉框） | Value（右侧输入框） |
   | :--- | :--- | :--- |
   | `NODE_ENV` | **`Value`** | `production` |
   | `APP_PORT` | **`Value`** | `3000` |
   | `APP_URL` | **`Value`** | `http://localhost:3000`（创建 ALB 后可改为 ALB 域名） |
   | `PREFIX` | **`Value`** | `api` |
   | `VERSION` | **`Value`** | `1` |
   | `CORS` | **`Value`** | `true` |
   | `ORDER_SERVICE_HOST` | **`Value`** | `order.nestjs.internal` |
   | `ORDER_SERVICE_PORT` | **`Value`** | `3031` |
   | `SDB_TYPE` | **`Value`** | `postgres` |
   | `SDB_HOST` | **`Value`** | `<你的 RDS Endpoint>` |
   | `SDB_PORT` | **`Value`** | `5432` |
   | `SDB_USER` | **`Value`** | `crm` |
   | `SDB_DB` | **`Value`** | `typeorm_test` |
   | `SDB_AUTOLOAD` | **`Value`** | `true` |
   | `SDB_SSL` | **`Value`** | `true` |
   | `REDIS_TYPE` | **`Value`** | `single` |
   | `REDIS_URL` | **`Value`** | `<你的 ElastiCache Primary Endpoint>:6379` |
   | `CACHE_TIME` | **`Value`** | `60000` |
   | `MAIL_HOST` | **`Value`** | `smtp.qq.com` |
   | `MAIL_PORT` | **`Value`** | `587` |
   | `MAIL_USER` | **`Value`** | `your-email@example.com` |
   | `MAIL_FROM` | **`Value`** | `Admin <your-email@example.com>` |
   | `SDB_PASS` | **`ValueFrom`** | `arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxx:SDB_PASS::` |
   | `REDIS_PASS` | **`ValueFrom`** | `arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxx:REDIS_PASS::` |
   | `JWT_SECRET` | **`ValueFrom`** | `arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxx:JWT_SECRET::` |
   | `MAIL_PASS` | **`ValueFrom`** | `arn:aws:secretsmanager:<region>:<account_id>:secret:nestjs/prod/env-xxxx:MAIL_PASS::` |

4. **Logging（日志配置）**：
   * 保持默认勾选 **Use log collection**（`Amazon CloudWatch`）。

### 7.4 执行 RDS 数据库 Migration（一次性 ECS Task）

无需单独制作 Migration 镜像，直接在本地终端运行以下命令（脚本中已为你预置好 `ap-southeast-2` 下的 `项目-vpc` 公有子网与 `ecs-auth-sg` 安全组）：

```bash
pnpm aws:migrate
```

> [!WARNING]
> **如果在 ECS 网页控制台手动点击 `Run new task` 执行，必须展开并修改 `Networking（网络）`！**
> 网页控制台 `Run new task` 默认会选中账号自带的 **Default VPC (`172.31.x.x`)** 并新建一个默认安全组，这会导致容器与 `项目-vpc (10.0.x.x)` 下的 RDS 网络不通，报 **`Error: connect ETIMEDOUT 10.0.x.x:5432`**。
> * 在控制台 `Run new task` 页面下拉展开 **Networking**：
>   1. **VPC**：切换为 **`项目-vpc` (`vpc-xxxxxxxx`, `10.0.0.0/16`)**
>   2. **Subnets**：只勾选两个 **`public` 子网**（`项目-subnet-public1` 和 `项目-subnet-public2`，移除 `private` 子网）
>   3. **Security group**：点选 **`Use an existing security group`** -> 下拉勾选 **`ecs-auth-sg`**（否则 RDS 安全组 `rds-sg` 会拦截连接）
>   4. **Public IP**：保持 **`Turned on`**
> * 再下拉展开 **Container Overrides** -> **auth** -> **Command override** 填入：`node,./node_modules/typeorm/cli.js,migration:run,-d,dist/apps/auth/lib/common/database/data-source.js`。

---

## 八、阶段 7：ALB 负载均衡与 ECS 服务启动

### 8.1 创建 Target Group 与 ALB
1. 进入 **EC2** -> **Target Groups** -> **Create target group**：
   * **Target type**：**`IP addresses`**（Fargate 必须选 `IP` 模式）。
   * **Target group name**：`nestjs-auth-tg`
   * **Protocol : Port**：`HTTP : 3000`，选择你的 VPC。
   * **Health check path**：填写 **`/api/v1/health`**。
2. 进入 **EC2** -> **Load Balancers** -> **Create Application Load Balancer**：
   * **Name**：`nestjs-alb`，**Scheme**：`Internet-facing`。
   * **Network mapping**：勾选 2 个**公有子网（Public Subnets）**。
   * **Security groups**：选择 **`alb-sg`**。
   * **Listeners and routing**：`HTTP:80`（及配置 ACM 证书后的 `HTTPS:443`）默认转发至 `nestjs-auth-tg`。

### 8.2 启动 `order` ECS Service（先启动下游服务）
1. 进入 `nestjs-prod-cluster` -> **Services** -> **Create**：
   * **Family**：`nestjs-order-task`，**Service name**：`order-service`，**Desired tasks**：`1`（或 `2`）。
2. **Service Connect configuration（关键）**：
   * 勾选 **Turn on Service Connect**。
   * **Mode**：选择 **`Client and server`**。
   * **Namespace**：`nestjs.internal`。
   * 在 **Port alias** 下选择 `order-tcp`，**Discovery name** 填写 `order`，**Client alias DNS** 自动生成为 **`order.nestjs.internal:3031`**（与 `auth` 中的 `ORDER_SERVICE_HOST` 完全对应）。
3. **Networking**：
   * 方案 A（带 NAT Gateway）：选择**私有子网**，Public IP 设为 `DISABLED`。
   * 方案 B（无 NAT Gateway）：选择**公有子网**，Public IP 设为 `ENABLED`。
   * 安全组选择 **`ecs-order-sg`**。

### 8.3 启动 `auth` ECS Service
1. 进入 `nestjs-prod-cluster` -> **Services** -> **Create**：
   * **Family**：`nestjs-auth-task`，**Service name**：`auth-service`，**Desired tasks**：`1`（或 `2`）。
2. **Service Connect configuration**：
   * 勾选 **Turn on Service Connect**。
   * **Mode**：选择 **`Client only`**，Namespace 选择 `nestjs.internal`。
3. **Networking**：
   * 方案 A（带 NAT Gateway）：选择**私有子网**，Public IP 设为 `DISABLED`。
   * 方案 B（无 NAT Gateway）：选择**公有子网**，Public IP 设为 `ENABLED`。
   * 安全组选择 **`ecs-auth-sg`**。
4. **Load balancing**：
   * 选择 `Application Load Balancer` -> 选择已有的 `nestjs-alb` -> 选择已有的 Target Group `nestjs-auth-tg`。
   * **Health check grace period**：设为 `60` 秒（给容器连接 RDS 和 Redis 留出缓冲时间）。

---

## 九、上线验证清单

部署完成后，依次通过以下接口验证全链路：

1. **验证 ALB 与 `auth` 容器健康状态**：
   ```bash
   curl http://<ALB-DNS-Name>/api/v1/health
   # 预期返回: {"status":"ok","timestamp":"..."}
   ```
2. **验证 ElastiCache Redis 读写**：
   ```bash
   curl http://<ALB-DNS-Name>/api/v1
   ```
3. **验证腾讯 QQ 邮箱发送（含 `.hbs` 模板渲染与外网连通性）**：
   ```bash
   curl http://<ALB-DNS-Name>/api/v1/sendmail
   # 预期返回: {"message":"发送成功"}
   ```
4. **验证 RDS 数据库与 `auth` -> `order` 跨容器 TCP 调用**：
   调用登录与 `/api/v1/user/findcustomerorder/:id` 接口，验证 `auth` 通过 `order.nestjs.internal:3031` 调用 `order` 微服务并查询 RDS 数据。

