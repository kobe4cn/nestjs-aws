#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS 生产级云原生基础设施全自动初始化脚本 (IaC Shell 实现)
#
# 功能清单：
#   1. 检查/创建 IAM 角色 ecsTaskExecutionRole 及其 KMS/Secrets/Logs 权限策略
#   2. 检查/创建 ECR 私有仓库 (nestjs-auth / nestjs-order)
#   3. 检查/创建 KMS 客户密钥 (alias/nestjs-prod-key)
#   4. 检查/创建 Secrets Manager 敏感凭据 (nestjs/prod/env)
#   5. 检查/创建 5 个安全组并配置最小权限闭环规则 (alb-sg, ecs-auth-sg, ecs-order-sg, rds-sg, redis-sg)
#   6. 检查/创建 CloudWatch 日志组
#   7. 检查/创建 ECS Fargate 集群及 Service Connect (nestjs.internal) 私有命名空间
#   8. 检查/创建 Target Group (nestjs-auth-tg) 与 ALB (nestjs-alb)
#   9. 自动生成并注册 ARM64 Task Definition (nestjs-order-task & nestjs-auth-task)
#  10. 自动创建并启动 ECS Services (order-service 与 auth-service)
# ==============================================================================

# 默认直连 AWS，清理本地代理环境变量
if [ "${USE_PROXY:-false}" != "true" ]; then
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  export CONTAINERS_CONF="/dev/null"
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "❌ 未检测到 aws CLI，请先安装: brew install awscli && aws configure"
  exit 1
fi

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "❌ 无法获取 AWS 账号信息，请先执行 'aws configure' 或检查凭证是否有效"
  exit 1
fi

echo "=============================================================================="
echo "🚀 开始自动配置/校验 AWS 基础设施"
echo "   AWS Region : ${AWS_REGION}"
echo "   Account ID : ${AWS_ACCOUNT_ID}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. 自动定位 VPC 与公有子网
# ------------------------------------------------------------------------------
echo "==> [1/10] 检查 VPC 与网络环境..."
# 优先查找名称带 '项目' 或 'nest' 的 VPC，没有则取列表中非 default 的 VPC，若没有则取 default VPC
VPC_ID="${VPC_ID:-}"
if [ -z "${VPC_ID}" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=*项目*,*nest*" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --query "Vpcs[?IsDefault==\`false\`]|[0].VpcId" --output text 2>/dev/null || true)
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --query "Vpcs[?IsDefault==\`true\`]|[0].VpcId" --output text 2>/dev/null || true)
fi

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "❌ 未找到可用 VPC，请先在控制台创建一个 VPC"
  exit 1
fi
echo "    已选定 VPC: ${VPC_ID}"

# 获取该 VPC 下的公有子网（至少需要 2 个跨可用区子网用于 ALB）
SUBNET_LIST=$(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "Subnets[?MapPublicIpOnLaunch==\`true\` || contains(Tags[?Key=='Name'].Value | [0] || '', 'public')].[SubnetId]" \
  --output text 2>/dev/null || true)

# 若没有明确标记 public 的子网，取前两个子网
if [ -z "${SUBNET_LIST}" ]; then
  SUBNET_LIST=$(aws ec2 describe-subnets --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[0:2].[SubnetId]" --output text 2>/dev/null || true)
fi

SUBNET_ARR=($SUBNET_LIST)
if [ ${#SUBNET_ARR[@]} -lt 2 ]; then
  echo "❌ VPC ${VPC_ID} 下可用子网少于 2 个，ALB 部署至少需要 2 个跨可用区子网"
  exit 1
fi

SUBNET_ID_1="${SUBNET_ARR[0]}"
SUBNET_ID_2="${SUBNET_ARR[1]}"
SUBNET_IDS="${SUBNET_ID_1},${SUBNET_ID_2}"
echo "    已选定子网: ${SUBNET_IDS}"

# ------------------------------------------------------------------------------
# 2. 检查/创建 IAM 角色与执行权限策略
# ------------------------------------------------------------------------------
echo "==> [2/10] 检查 IAM 角色 ecsTaskExecutionRole 与权限策略..."
ROLE_NAME="ecsTaskExecutionRole"
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    创建 IAM 角色 ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }' >/dev/null
fi

# 附加 AWS 托管策略
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null 2>&1 || true

# 配置内联策略（Secrets Manager 读取 + KMS 解密 + CloudWatch 日志组自动创建）
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "ECS-Secrets-KMS-Decrypt-Policy" \
  --policy-document '{
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
          "arn:aws:secretsmanager:'"${AWS_REGION}"':'"${AWS_ACCOUNT_ID}"':secret:nestjs/prod/env-*",
          "arn:aws:kms:'"${AWS_REGION}"':'"${AWS_ACCOUNT_ID}"':key/*"
        ]
      },
      {
        "Sid": "AllowCreateCloudWatchLogGroup",
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogGroup"
        ],
        "Resource": "arn:aws:logs:'"${AWS_REGION}"':'"${AWS_ACCOUNT_ID}"':log-group:/ecs/*"
      }
    ]
  }' >/dev/null
echo "    IAM 角色 ${ROLE_NAME} 配置完毕"

# ------------------------------------------------------------------------------
# 3. 检查/创建 ECR 仓库
# ------------------------------------------------------------------------------
echo "==> [3/10] 检查 ECR 仓库 (nestjs-auth & nestjs-order)..."
for repo in "nestjs-auth" "nestjs-order"; do
  if ! aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    创建 ECR 仓库: ${repo}..."
    aws ecr create-repository --repository-name "${repo}" --region "${AWS_REGION}" >/dev/null
  else
    echo "    ECR 仓库已存在: ${repo}"
  fi
done

# ------------------------------------------------------------------------------
# 4. 检查/创建 KMS 密钥与 Secrets Manager
# ------------------------------------------------------------------------------
echo "==> [4/10] 检查 KMS 密钥与 Secrets Manager 凭据..."
KMS_KEY_ID=$(aws kms describe-key --key-id "alias/nestjs-prod-key" --region "${AWS_REGION}" --query "KeyMetadata.KeyId" --output text 2>/dev/null || true)
if [ -z "${KMS_KEY_ID}" ] || [ "${KMS_KEY_ID}" = "None" ]; then
  echo "    创建 KMS CMK 密钥 alias/nestjs-prod-key..."
  KMS_KEY_ID=$(aws kms create-key --description "NestJS Production Key" --region "${AWS_REGION}" --query "KeyMetadata.KeyId" --output text)
  aws kms create-alias --alias-name "alias/nestjs-prod-key" --target-key-id "${KMS_KEY_ID}" --region "${AWS_REGION}" >/dev/null
fi
echo "    KMS 密钥 ID: ${KMS_KEY_ID}"

SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "nestjs/prod/env" --region "${AWS_REGION}" --query "ARN" --output text 2>/dev/null || true)
if [ -z "${SECRET_ARN}" ] || [ "${SECRET_ARN}" = "None" ]; then
  echo "    创建 Secrets Manager 机密: nestjs/prod/env..."
  # 预置随机强密码与 JWT 密钥
  DEFAULT_SDB_PASS="${SDB_PASS:-NestJsProd2026!Pass}"
  DEFAULT_REDIS_PASS="${REDIS_PASS:-}"
  DEFAULT_JWT_SECRET="${JWT_SECRET:-$(head -c 32 /dev/urandom | base64)}"
  DEFAULT_MAIL_PASS="${MAIL_PASS:-your_smtp_auth_code}"

  SECRET_JSON=$(node -e '
    console.log(JSON.stringify({
      SDB_PASS: process.env.DEFAULT_SDB_PASS,
      REDIS_PASS: process.env.DEFAULT_REDIS_PASS,
      JWT_SECRET: process.env.DEFAULT_JWT_SECRET,
      MAIL_PASS: process.env.DEFAULT_MAIL_PASS
    }));
  ')

  SECRET_ARN=$(aws secretsmanager create-secret \
    --name "nestjs/prod/env" \
    --kms-key-id "alias/nestjs-prod-key" \
    --secret-string "${SECRET_JSON}" \
    --region "${AWS_REGION}" \
    --query "ARN" --output text)
fi
echo "    Secret ARN: ${SECRET_ARN}"

# ------------------------------------------------------------------------------
# 5. 检查/创建 5 个安全组及其互信规则
# ------------------------------------------------------------------------------
echo "==> [5/10] 检查并配置 5 个安全组 (alb-sg, ecs-auth-sg, ecs-order-sg, rds-sg, redis-sg)..."
get_or_create_sg() {
  local sg_name="$1"
  local sg_desc="$2"
  local id=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${sg_name}" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
  if [ -z "${id}" ] || [ "${id}" = "None" ]; then
    echo "    创建安全组: ${sg_name}..."
    id=$(aws ec2 create-security-group \
      --group-name "${sg_name}" \
      --description "${sg_desc}" \
      --vpc-id "${VPC_ID}" \
      --region "${AWS_REGION}" \
      --query "GroupId" --output text)
  fi
  echo "${id}"
}

ALB_SG_ID=$(get_or_create_sg "alb-sg" "Security group for ALB")
AUTH_SG_ID=$(get_or_create_sg "ecs-auth-sg" "Security group for auth service")
ORDER_SG_ID=$(get_or_create_sg "ecs-order-sg" "Security group for order service")
RDS_SG_ID=$(get_or_create_sg "rds-sg" "Security group for RDS PostgreSQL")
REDIS_SG_ID=$(get_or_create_sg "redis-sg" "Security group for ElastiCache Redis")

# 安全组入站放行（幂等配置，已存在会自动跳过）
# alb-sg: 80, 443 允许全网
aws ec2 authorize-security-group-ingress --group-id "${ALB_SG_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "${AWS_REGION}" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id "${ALB_SG_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "${AWS_REGION}" 2>/dev/null || true

# ecs-auth-sg: 3000 来自 alb-sg
aws ec2 authorize-security-group-ingress --group-id "${AUTH_SG_ID}" --protocol tcp --port 3000 --source-group "${ALB_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true

# ecs-order-sg: 3031 来自 ecs-auth-sg
aws ec2 authorize-security-group-ingress --group-id "${ORDER_SG_ID}" --protocol tcp --port 3031 --source-group "${AUTH_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true

# rds-sg: 5432 来自 ecs-auth-sg 与 ecs-order-sg
aws ec2 authorize-security-group-ingress --group-id "${RDS_SG_ID}" --protocol tcp --port 5432 --source-group "${AUTH_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id "${RDS_SG_ID}" --protocol tcp --port 5432 --source-group "${ORDER_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true

# redis-sg: 6379 来自 ecs-auth-sg
aws ec2 authorize-security-group-ingress --group-id "${REDIS_SG_ID}" --protocol tcp --port 6379 --source-group "${AUTH_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true

echo "    安全组已就绪: alb-sg(${ALB_SG_ID}), auth-sg(${AUTH_SG_ID}), order-sg(${ORDER_SG_ID}), rds-sg(${RDS_SG_ID}), redis-sg(${REDIS_SG_ID})"

# ------------------------------------------------------------------------------
# 6. 检查/创建 CloudWatch 日志组
# ------------------------------------------------------------------------------
echo "==> [6/10] 检查 CloudWatch 日志组..."
for lg in "/ecs/nestjs-auth-task" "/ecs/nestjs-order-task" "/ecs/auth-service" "/ecs/order-service"; do
  aws logs create-log-group --log-group-name "${lg}" --region "${AWS_REGION}" 2>/dev/null || true
done

# ------------------------------------------------------------------------------
# 7. 检查/创建 ECS 集群及 Service Connect 命名空间
# ------------------------------------------------------------------------------
echo "==> [7/10] 检查 ECS 集群 (nestjs-prod-cluster)..."
CLUSTER_NAME="nestjs-prod-cluster"
CLUSTER_ARN=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "clusters[?status=='ACTIVE'].clusterArn | [0]" --output text 2>/dev/null || true)
if [ -z "${CLUSTER_ARN}" ] || [ "${CLUSTER_ARN}" = "None" ]; then
  echo "    创建 ECS 集群: ${CLUSTER_NAME} (启用 Service Connect: nestjs.internal)..."
  CLUSTER_ARN=$(aws ecs create-cluster \
    --cluster-name "${CLUSTER_NAME}" \
    --service-connect-defaults '{"namespace":"nestjs.internal"}' \
    --region "${AWS_REGION}" \
    --query "cluster.clusterArn" --output text)
fi
echo "    ECS 集群 ARN: ${CLUSTER_ARN}"

# ------------------------------------------------------------------------------
# 8. 检查/创建 Target Group 与 ALB
# ------------------------------------------------------------------------------
echo "==> [8/10] 检查 Target Group 与 ALB 负载均衡器..."
TG_NAME="nestjs-auth-tg"
TG_ARN=$(aws elbv2 describe-target-groups --names "${TG_NAME}" --region "${AWS_REGION}" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
if [ -z "${TG_ARN}" ] || [ "${TG_ARN}" = "None" ]; then
  echo "    创建目标组: ${TG_NAME} (IP 模式，探测 /api/v1/health)..."
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port 3000 \
    --target-type ip \
    --vpc-id "${VPC_ID}" \
    --health-check-protocol HTTP \
    --health-check-path "/api/v1/health" \
    --health-check-interval-seconds 10 \
    --healthy-threshold-count 2 \
    --matcher '{"HttpCode":"200"}' \
    --region "${AWS_REGION}" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
fi
# 设置合理的注销排空等待时间 (15s)
aws elbv2 modify-target-group-attributes --target-group-arn "${TG_ARN}" --attributes Key=deregistration_delay.timeout_seconds,Value=15 --region "${AWS_REGION}" >/dev/null 2>&1 || true

ALB_NAME="nestjs-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${ALB_NAME}" --region "${AWS_REGION}" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -z "${ALB_ARN}" ] || [ "${ALB_ARN}" = "None" ]; then
  echo "    创建公网 ALB 负载均衡器: ${ALB_NAME}..."
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets "${SUBNET_ID_1}" "${SUBNET_ID_2}" \
    --security-groups "${ALB_SG_ID}" \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --region "${AWS_REGION}" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)

  echo "    创建 ALB HTTP:80 监听器绑定目标组..."
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TG_ARN}" \
    --region "${AWS_REGION}" >/dev/null
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" --region "${AWS_REGION}" --query "LoadBalancers[0].DNSName" --output text)
echo "    ALB 访问公网域名: http://${ALB_DNS}"

# ------------------------------------------------------------------------------
# 9. 自动检测 RDS 与 ElastiCache 端点并注册 Task Definitions
# ------------------------------------------------------------------------------
echo "==> [9/10] 检测数据层端点并注册 ARM64 Task Definitions..."
RDS_ENDPOINT=$(aws rds describe-db-instances --region "${AWS_REGION}" \
  --filters "Name=db-instance-id,Values=*postgres*,*nest*" \
  --query "DBInstances[0].Endpoint.Address" --output text 2>/dev/null || true)

if [ -z "${RDS_ENDPOINT}" ] || [ "${RDS_ENDPOINT}" = "None" ]; then
  # 降级尝试查找首个可用 RDS 实例
  RDS_ENDPOINT=$(aws rds describe-db-instances --region "${AWS_REGION}" --query "DBInstances[0].Endpoint.Address" --output text 2>/dev/null || true)
fi

if [ -z "${RDS_ENDPOINT}" ] || [ "${RDS_ENDPOINT}" = "None" ]; then
  echo "⚠️  未在当前区域检测到现成 RDS PostgreSQL 实例，请确保已创建 RDS 并绑定安全组 ${RDS_SG_ID}"
  RDS_ENDPOINT="nestjs-postgres.placeholder.rds.amazonaws.com"
else
  echo "    检测到 RDS 端点: ${RDS_ENDPOINT}"
fi

REDIS_ENDPOINT=$(aws elasticache describe-replication-groups --region "${AWS_REGION}" \
  --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" --output text 2>/dev/null || true)

if [ -z "${REDIS_ENDPOINT}" ] || [ "${REDIS_ENDPOINT}" = "None" ]; then
  REDIS_ENDPOINT=$(aws elasticache describe-cache-clusters --region "${AWS_REGION}" --show-cache-node-info \
    --query "CacheClusters[0].CacheNodes[0].Endpoint.Address" --output text 2>/dev/null || true)
fi

if [ -z "${REDIS_ENDPOINT}" ] || [ "${REDIS_ENDPOINT}" = "None" ]; then
  echo "⚠️  未在当前区域检测到现成 ElastiCache Redis 实例，请确保已创建并绑定安全组 ${REDIS_SG_ID}"
  REDIS_ENDPOINT="nestjs-redis.placeholder.cache.amazonaws.com"
else
  echo "    检测到 Redis 端点: ${REDIS_ENDPOINT}"
fi

# 注册 nestjs-order-task
echo "    注册 Task Definition: nestjs-order-task..."
ORDER_TD_JSON=$(cat <<EOF
{
  "family": "nestjs-order-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}",
  "containerDefinitions": [
    {
      "name": "order",
      "image": "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/nestjs-order:latest",
      "essential": true,
      "portMappings": [
        {
          "name": "order-tcp",
          "containerPort": 3031,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "NODE_ENV", "value": "production" },
        { "name": "APP_PORT", "value": "3031" },
        { "name": "ORDER_BIND_HOST", "value": "0.0.0.0" },
        { "name": "SDB_TYPE", "value": "postgres" },
        { "name": "SDB_HOST", "value": "${RDS_ENDPOINT}" },
        { "name": "SDB_PORT", "value": "5432" },
        { "name": "SDB_USER", "value": "crm" },
        { "name": "SDB_DB", "value": "typeorm_test" },
        { "name": "SDB_AUTOLOAD", "value": "true" },
        { "name": "SDB_SSL", "value": "true" }
      ],
      "secrets": [
        {
          "name": "SDB_PASS",
          "valueFrom": "${SECRET_ARN}:SDB_PASS::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/nestjs-order-task",
          "awslogs-create-group": "true",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF
)
aws ecs register-task-definition --region "${AWS_REGION}" --cli-input-json "${ORDER_TD_JSON}" >/dev/null

# 注册 nestjs-auth-task
echo "    注册 Task Definition: nestjs-auth-task..."
AUTH_TD_JSON=$(cat <<EOF
{
  "family": "nestjs-auth-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}",
  "containerDefinitions": [
    {
      "name": "auth",
      "image": "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/nestjs-auth:latest",
      "essential": true,
      "portMappings": [
        {
          "name": "auth-http",
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "NODE_ENV", "value": "production" },
        { "name": "APP_PORT", "value": "3000" },
        { "name": "APP_URL", "value": "http://${ALB_DNS}" },
        { "name": "PREFIX", "value": "api" },
        { "name": "VERSION", "value": "1" },
        { "name": "CORS", "value": "true" },
        { "name": "ORDER_SERVICE_HOST", "value": "order.nestjs.internal" },
        { "name": "ORDER_SERVICE_PORT", "value": "3031" },
        { "name": "SDB_TYPE", "value": "postgres" },
        { "name": "SDB_HOST", "value": "${RDS_ENDPOINT}" },
        { "name": "SDB_PORT", "value": "5432" },
        { "name": "SDB_USER", "value": "crm" },
        { "name": "SDB_DB", "value": "typeorm_test" },
        { "name": "SDB_AUTOLOAD", "value": "true" },
        { "name": "SDB_SSL", "value": "true" },
        { "name": "REDIS_TYPE", "value": "single" },
        { "name": "REDIS_URL", "value": "${REDIS_ENDPOINT}:6379" },
        { "name": "CACHE_TIME", "value": "60000" },
        { "name": "MAIL_HOST", "value": "smtp.qq.com" },
        { "name": "MAIL_PORT", "value": "587" },
        { "name": "MAIL_USER", "value": "${MAIL_USER:-your-email@example.com}" },
        { "name": "MAIL_FROM", "value": "Admin <${MAIL_USER:-your-email@example.com}>" }
      ],
      "secrets": [
        {
          "name": "SDB_PASS",
          "valueFrom": "${SECRET_ARN}:SDB_PASS::"
        },
        {
          "name": "REDIS_PASS",
          "valueFrom": "${SECRET_ARN}:REDIS_PASS::"
        },
        {
          "name": "JWT_SECRET",
          "valueFrom": "${SECRET_ARN}:JWT_SECRET::"
        },
        {
          "name": "MAIL_PASS",
          "valueFrom": "${SECRET_ARN}:MAIL_PASS::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/nestjs-auth-task",
          "awslogs-create-group": "true",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF
)
aws ecs register-task-definition --region "${AWS_REGION}" --cli-input-json "${AUTH_TD_JSON}" >/dev/null

# ------------------------------------------------------------------------------
# 10. 检查/创建 ECS Services (order-service 与 auth-service)
# ------------------------------------------------------------------------------
echo "==> [10/10] 检查并配置 ECS Services..."

# 10.1 order-service (下游微服务)
ORDER_SVC_STATUS=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "order-service" --region "${AWS_REGION}" --query "services[?status=='ACTIVE'].serviceName | [0]" --output text 2>/dev/null || true)
if [ -z "${ORDER_SVC_STATUS}" ] || [ "${ORDER_SVC_STATUS}" = "None" ]; then
  echo "    创建 ECS Service: order-service (配置 Service Connect Server 端)..."
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "order-service" \
    --task-definition "nestjs-order-task" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${ORDER_SG_ID}],assignPublicIp=ENABLED}" \
    --service-connect-configuration '{
      "enabled": true,
      "namespace": "nestjs.internal",
      "services": [
        {
          "portName": "order-tcp",
          "discoveryName": "order",
          "clientAliases": [{ "port": 3031, "dnsName": "order.nestjs.internal" }]
        }
      ]
    }' \
    --region "${AWS_REGION}" >/dev/null
else
  echo "    ECS Service 已就绪: order-service"
fi

# 10.2 auth-service (网关服务，挂载 ALB)
AUTH_SVC_STATUS=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "auth-service" --region "${AWS_REGION}" --query "services[?status=='ACTIVE'].serviceName | [0]" --output text 2>/dev/null || true)
if [ -z "${AUTH_SVC_STATUS}" ] || [ "${AUTH_SVC_STATUS}" = "None" ]; then
  echo "    创建 ECS Service: auth-service (挂载 ALB 与 Service Connect Client 端)..."
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "auth-service" \
    --task-definition "nestjs-auth-task" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${AUTH_SG_ID}],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=auth,containerPort=3000" \
    --health-check-grace-period-seconds 60 \
    --service-connect-configuration '{
      "enabled": true,
      "namespace": "nestjs.internal"
    }' \
    --region "${AWS_REGION}" >/dev/null
else
  echo "    ECS Service 已就绪: auth-service"
fi

echo "=============================================================================="
echo "🎉 AWS UAT 基础设施全自动配置检查完毕！"
echo "   VPC ID            : ${VPC_ID}"
echo "   Subnets           : ${SUBNET_IDS}"
echo "   ALB Domain URL    : http://${ALB_DNS}"
echo "   ECS Cluster       : ${CLUSTER_NAME}"
echo "   Auth Service      : auth-service"
echo "   Order Service     : order-service"
echo "   Auth SG ID        : ${AUTH_SG_ID}"
echo "=============================================================================="

# 若 AUTO_DEPLOY=true (默认开启)，自动调用 AWS CodeBuild 完成首次镜像打包推送、数据库迁移与服务更新
AUTO_DEPLOY="${AUTO_DEPLOY:-true}"
DEPLOY_MODE="${DEPLOY_MODE:-codebuild}"
if [ "${AUTO_DEPLOY}" = "true" ]; then
  if [ "${DEPLOY_MODE}" = "local" ]; then
    echo "==> [Auto-Deploy] 使用本地容器引擎构建推送镜像并执行迁移..."
    AWS_REGION="${AWS_REGION}" bash ./scripts/deploy-aws.sh all
  else
    echo "==> [Auto-Deploy] 触发 AWS CodeBuild 云端流水线完成镜像构建、ECR 推送、数据库迁移与 ECS 发布..."
    AWS_REGION="${AWS_REGION}" bash ./scripts/setup-aws-codebuild.sh setup
    AWS_REGION="${AWS_REGION}" bash ./scripts/setup-aws-codebuild.sh start deploy
  fi
fi

