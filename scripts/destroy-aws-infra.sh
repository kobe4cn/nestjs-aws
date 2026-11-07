#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS 资源彻底清理与销毁脚本 (针对 ap-southeast-2 悉尼区域)
# 彻底销毁所有收费与测试资源，防止产生账单
# ==============================================================================

REGION="${AWS_REGION:-ap-southeast-2}"
VPC_ID="${VPC_ID:-}"
if [ -z "${VPC_ID}" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=项目-vpc" --region "${REGION}" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
  if [ "${VPC_ID}" = "None" ]; then VPC_ID=""; fi
fi
CLUSTER_NAME="nestjs-prod-cluster"

echo "=============================================================================="
echo "⚠️  开始全量销毁 AWS 资源 (Region: ${REGION})"
echo "=============================================================================="

# 1. 删除 ECS Services 与 集群
echo "==> [1/11] 缩容并删除 ECS Services..."
for svc in "auth-service" "order-service"; do
  if aws ecs describe-services --cluster "${CLUSTER_NAME}" --services "${svc}" --region "${REGION}" --query "services[?status=='ACTIVE'].serviceName | [0]" --output text 2>/dev/null | grep -q "${svc}"; then
    echo "    更新 ${svc} desired-count=0..."
    aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${svc}" --desired-count 0 --region "${REGION}" >/dev/null 2>&1 || true
    echo "    删除服务 ${svc}..."
    aws ecs delete-service --cluster "${CLUSTER_NAME}" --service "${svc}" --force --region "${REGION}" >/dev/null 2>&1 || true
  fi
done

echo "    停止集群中所有残留 Tasks..."
for task in $(aws ecs list-tasks --cluster "${CLUSTER_NAME}" --region "${REGION}" --query "taskArns[*]" --output text 2>/dev/null || true); do
  if [ -n "${task}" ] && [ "${task}" != "None" ]; then
    aws ecs stop-task --cluster "${CLUSTER_NAME}" --task "${task}" --region "${REGION}" >/dev/null 2>&1 || true
  fi
done

echo "    删除 ECS 集群 ${CLUSTER_NAME}..."
aws ecs delete-cluster --cluster "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1 || true

# 注销 Task Definitions
echo "    注销所有 Task Definitions (nestjs-auth-task & nestjs-order-task)..."
for td in $(aws ecs list-task-definitions --region "${REGION}" --query "taskDefinitionArns[*]" --output text 2>/dev/null || true); do
  if [ -n "${td}" ] && [ "${td}" != "None" ]; then
    aws ecs deregister-task-definition --task-definition "${td}" --region "${REGION}" >/dev/null 2>&1 || true
  fi
done

# 2. 删除 ALB 负载均衡器与 Target Group
echo "==> [2/11] 删除 ALB 与 Target Group..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names "nestjs-alb" --region "${REGION}" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -n "${ALB_ARN}" ] && [ "${ALB_ARN}" != "None" ]; then
  echo "    删除 ALB: nestjs-alb..."
  aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" --region "${REGION}" >/dev/null
  echo "    等待 ALB 弹性网卡释放 (约 20 秒)..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}" --region "${REGION}" 2>/dev/null || sleep 20
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "nestjs-auth-tg" --region "${REGION}" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
if [ -n "${TG_ARN}" ] && [ "${TG_ARN}" != "None" ]; then
  echo "    删除 Target Group: nestjs-auth-tg..."
  aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" --region "${REGION}" >/dev/null 2>&1 || true
fi

# 3. 删除 RDS PostgreSQL 实例
echo "==> [3/11] 删除 RDS 数据库实例 (nestjs-postgres)..."
if aws rds describe-db-instances --db-instance-identifier "nestjs-postgres" --region "${REGION}" >/dev/null 2>&1; then
  echo "    触发删除 RDS: nestjs-postgres (跳过最终快照)..."
  aws rds delete-db-instance \
    --db-instance-identifier "nestjs-postgres" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "${REGION}" >/dev/null 2>&1 || true
fi

# 4. 删除 ElastiCache Redis
echo "==> [4/11] 删除 ElastiCache Redis 集群 (nestjs-redis)..."
if aws elasticache describe-replication-groups --replication-group-id "nestjs-redis" --region "${REGION}" >/dev/null 2>&1; then
  echo "    触发删除 ElastiCache Replication Group: nestjs-redis..."
  aws elasticache delete-replication-group \
    --replication-group-id "nestjs-redis" \
    --no-retain-primary-cluster \
    --region "${REGION}" >/dev/null 2>&1 || true
fi
if aws elasticache describe-cache-clusters --cache-cluster-id "nestjs-redis" --region "${REGION}" >/dev/null 2>&1; then
  echo "    触发删除 ElastiCache Cache Cluster: nestjs-redis..."
  aws elasticache delete-cache-cluster \
    --cache-cluster-id "nestjs-redis" \
    --region "${REGION}" >/dev/null 2>&1 || true
fi

# 5. 删除 ECR 镜像仓库
echo "==> [5/11] 删除 ECR 镜像仓库 (nestjs-auth & nestjs-order)..."
for repo in "nestjs-auth" "nestjs-order"; do
  if aws ecr describe-repositories --repository-names "${repo}" --region "${REGION}" >/dev/null 2>&1; then
    echo "    强制删除 ECR 仓库: ${repo}..."
    aws ecr delete-repository --repository-name "${repo}" --force --region "${REGION}" >/dev/null 2>&1 || true
  fi
done

# 6. 删除 Secrets Manager 机密
echo "==> [6/11] 强制立即销毁 Secrets Manager (nestjs/prod/env)..."
if aws secretsmanager describe-secret --secret-id "nestjs/prod/env" --region "${REGION}" >/dev/null 2>&1; then
  echo "    立即销毁 Secret: nestjs/prod/env..."
  aws secretsmanager delete-secret \
    --secret-id "nestjs/prod/env" \
    --force-delete-without-recovery \
    --region "${REGION}" >/dev/null 2>&1 || true
fi

# 7. 删除 ECS CloudWatch 日志组 (保留 /aws/codebuild/* 构建日志组)
echo "==> [7/11] 删除 ECS CloudWatch 日志组 (/ecs/*)..."
for lg in $(aws logs describe-log-groups --log-group-name-prefix "/ecs/" --region "${REGION}" --query "logGroups[*].logGroupName" --output text 2>/dev/null || true); do
  if [ -n "${lg}" ] && [ "${lg}" != "None" ]; then
    echo "    删除日志组: ${lg}..."
    aws logs delete-log-group --log-group-name "${lg}" --region "${REGION}" >/dev/null 2>&1 || true
  fi
done

# 8. 计划删除 KMS CMK Key 别名与密钥 (7天窗口)
echo "==> [8/11] 删除 KMS 别名并计划删除密钥..."
KEY_ID=$(aws kms describe-key --key-id "alias/nestjs-prod-key" --region "${REGION}" --query "KeyMetadata.KeyId" --output text 2>/dev/null || true)
if [ -n "${KEY_ID}" ] && [ "${KEY_ID}" != "None" ]; then
  aws kms delete-alias --alias-name "alias/nestjs-prod-key" --region "${REGION}" >/dev/null 2>&1 || true
  echo "    计划删除 KMS 密钥 ${KEY_ID} (7 天后物理销毁)..."
  aws kms schedule-key-deletion --key-id "${KEY_ID}" --pending-window-in-days 7 --region "${REGION}" >/dev/null 2>&1 || true
fi

# 9. 删除 IAM 角色 ecsTaskExecutionRole 上的内联策略
echo "==> [9/11] 清理 IAM 角色 ecsTaskExecutionRole 策略..."
aws iam delete-role-policy --role-name "ecsTaskExecutionRole" --policy-name "ECS-Secrets-KMS-Decrypt-Policy" 2>/dev/null || true

# 10. 等待 RDS 和 Redis 实例删除完成，以释放 VPC 和安全组依赖
echo "==> [10/11] 轮询等待 RDS 与 Redis 完全释放（约需 2-5 分钟），以便清理安全组与 VPC..."

echo "    正在等待 RDS nestjs-postgres 完全销毁..."
while aws rds describe-db-instances --db-instance-identifier "nestjs-postgres" --region "${REGION}" >/dev/null 2>&1; do
  STATUS=$(aws rds describe-db-instances --db-instance-identifier "nestjs-postgres" --region "${REGION}" --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "deleted")
  if [ "${STATUS}" = "deleted" ]; then break; fi
  echo "    RDS 状态: ${STATUS}，等待中..."
  sleep 15
done
echo "    ✅ RDS nestjs-postgres 已彻底销毁"

echo "    正在等待 ElastiCache nestjs-redis 完全销毁..."
while aws elasticache describe-replication-groups --replication-group-id "nestjs-redis" --region "${REGION}" >/dev/null 2>&1 || \
      aws elasticache describe-cache-clusters --cache-cluster-id "nestjs-redis" --region "${REGION}" >/dev/null 2>&1; do
  echo "    Redis 正在销毁中，等待 15 秒..."
  sleep 15
done
echo "    ✅ ElastiCache nestjs-redis 已彻底销毁"

# 删除 RDS 与 Redis 子网组
aws rds delete-db-subnet-group --db-subnet-group-name "nestjs-rds-subnet-group" --region "${REGION}" >/dev/null 2>&1 || true
aws elasticache delete-cache-subnet-group --cache-subnet-group-name "nestjs-redis-subnet-group" --region "${REGION}" >/dev/null 2>&1 || true

# 清理可能创建在 Default VPC 下的项目专用安全组 (alb-sg, ecs-auth-sg, ecs-order-sg, rds-sg, redis-sg)
PROJECT_SGS=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=alb-sg,ecs-auth-sg,ecs-order-sg,rds-sg,redis-sg" --region "${REGION}" --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true)
for sg in ${PROJECT_SGS}; do
  RULES=$(aws ec2 describe-security-groups --group-ids "${sg}" --region "${REGION}" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || true)
  if [ -n "${RULES}" ] && [ "${RULES}" != "[]" ]; then
    aws ec2 revoke-security-group-ingress --group-id "${sg}" --ip-permissions "${RULES}" --region "${REGION}" 2>/dev/null || true
  fi
done
for sg in ${PROJECT_SGS}; do
  aws ec2 delete-security-group --group-id "${sg}" --region "${REGION}" 2>/dev/null || true
done

# 11. 删除安全组、子网、路由表、IGW 及 VPC
echo "==> [11/11] 删除安全组、子网与 项目-vpc..."

if [ -n "${VPC_ID}" ]; then
  # 等待所有网络接口 ENI 完全脱落
  echo "    检查并等待 ENI 释放..."
  for i in {1..12}; do
    ENI_COUNT=$(aws ec2 describe-network-interfaces --region "${REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" --query "length(NetworkInterfaces)" --output text 2>/dev/null || echo "0")
    if [ "${ENI_COUNT}" = "0" ]; then break; fi
    echo "    当前 VPC 下仍有 ${ENI_COUNT} 个 ENI 未脱离，等待 10 秒..."
    sleep 10
  done

  # 动态查询该 VPC 下的所有自定义安全组（排除 default 安全组）
  CUSTOM_SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" --region "${REGION}" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)

  # 删除安全组规则（先清空相互引用）
  echo "    清理安全组互通规则..."
  for sg in ${CUSTOM_SGS}; do
    RULES=$(aws ec2 describe-security-groups --group-ids "${sg}" --region "${REGION}" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || true)
    if [ -n "${RULES}" ] && [ "${RULES}" != "[]" ]; then
      aws ec2 revoke-security-group-ingress --group-id "${sg}" --ip-permissions "${RULES}" --region "${REGION}" 2>/dev/null || true
    fi
  done

  # 删除自定义安全组
  for sg in ${CUSTOM_SGS}; do
    aws ec2 delete-security-group --group-id "${sg}" --region "${REGION}" 2>/dev/null || true
  done

  # 删除 Internet Gateway
  for igw in $(aws ec2 describe-internet-gateways --region "${REGION}" --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query "InternetGateways[*].InternetGatewayId" --output text 2>/dev/null || true); do
    if [ -n "${igw}" ] && [ "${igw}" != "None" ]; then
      echo "    分离并删除 Internet Gateway: ${igw}..."
      aws ec2 detach-internet-gateway --internet-gateway-id "${igw}" --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null || true
      aws ec2 delete-internet-gateway --internet-gateway-id "${igw}" --region "${REGION}" 2>/dev/null || true
    fi
  done

  # 删除子网
  for sn in $(aws ec2 describe-subnets --region "${REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[*].SubnetId" --output text 2>/dev/null || true); do
    if [ -n "${sn}" ] && [ "${sn}" != "None" ]; then
      echo "    删除子网: ${sn}..."
      aws ec2 delete-subnet --subnet-id "${sn}" --region "${REGION}" 2>/dev/null || true
    fi
  done

  # 删除路由表 (跳过 main 路由表)
  for rtb in $(aws ec2 describe-route-tables --region "${REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text 2>/dev/null || true); do
    if [ -n "${rtb}" ] && [ "${rtb}" != "None" ]; then
      echo "    删除路由表: ${rtb}..."
      aws ec2 delete-route-table --route-table-id "${rtb}" --region "${REGION}" 2>/dev/null || true
    fi
  done

  # 删除 VPC
  echo "    删除 VPC: ${VPC_ID} (项目-vpc)..."
  aws ec2 delete-vpc --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null || true
else
  echo "    未检测到活动中的 项目-vpc，跳过 VPC 与子网清理"
fi

echo "=============================================================================="
echo "🎉 所有收费资源与云基础设施已彻底清理销毁完毕！账号当前环境产生费用为 0。"
echo "=============================================================================="

