#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS ECR 镜像构建推送、RDS Migration 执行与 ECS 服务更新脚本
# 用法:
#   ./scripts/deploy-aws.sh all        # 构建推送 + 执行迁移 + 更新 ECS 服务
#   ./scripts/deploy-aws.sh push       # 仅构建并推送 auth 与 order 镜像到 ECR
#   ./scripts/deploy-aws.sh migrate    # 仅触发 ECS 一次性任务执行 RDS Migration
#   ./scripts/deploy-aws.sh rollout    # 仅强制滚动更新 order 与 auth ECS 服务
# ==============================================================================

ACTION="${1:-all}"

# 默认直连 AWS，清除终端及 ~/.config/containers/containers.conf 残留的本地代理配置（如 127.0.0.1:1082 未启动导致的 connection refused）
# 若确实需要走代理，可在执行前设置 export USE_PROXY=true
if [ "${USE_PROXY:-false}" != "true" ]; then
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  export CONTAINERS_CONF="/dev/null"
fi

# 环境依赖与容器运行时检测（自动兼容 podman 与 docker）
if [ -z "${CONTAINER_CLI:-}" ]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI="docker"
  else
    echo "❌ 未检测到 podman 或 docker，请先安装并启动 Podman (podman machine start) 或 Docker"
    exit 1
  fi
fi
echo "ℹ️  使用容器运行时: ${CONTAINER_CLI}"

# 若使用 Podman 且未开启 USE_PROXY，同步清理 Podman 虚拟机内部残留的死代理配置
if [ "${CONTAINER_CLI}" = "podman" ] && [ "${USE_PROXY:-false}" != "true" ]; then
  podman machine ssh "sudo systemctl unset-environment http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; sudo rm -f /etc/profile.d/default-env.sh /etc/environment.d/default-env.conf /etc/systemd/system.conf.d/default-env.conf; sudo systemctl daemon-reload" >/dev/null 2>&1 || true
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "❌ 未检测到 aws CLI，请先在终端执行: brew install awscli && aws configure"
  exit 1
fi

# 基础 AWS 配置（可通过外部环境变量覆盖）
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "❌ 无法获取 AWS 账号信息，请先执行 'aws configure' 配置 Access Key，或检查凭证是否有效"
  exit 1
fi
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"

# ECR 仓库与 ECS 配置
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/arm64}"
AUTH_REPO="${AUTH_REPO:-nestjs-auth}"
ORDER_REPO="${ORDER_REPO:-nestjs-order}"
ECS_CLUSTER="${ECS_CLUSTER:-nestjs-prod-cluster}"
AUTH_SERVICE="${AUTH_SERVICE:-auth-service}"
ORDER_SERVICE="${ORDER_SERVICE:-order-service}"
MIGRATION_TASK_DEF="${MIGRATION_TASK_DEF:-nestjs-auth-task}"

# 网络模式配置（用于 Migration 一次性任务）
# 可通过环境变量 SUBNET_IDS 与 AUTH_SG_ID 传入；未指定时自动通过 VPC 标签与安全组名称动态查询
if [ -z "${SUBNET_IDS:-}" ]; then
  SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=项目-subnet-public*" --region "${AWS_REGION}" --query "Subnets[].SubnetId" --output text 2>/dev/null | tr '\t' ',' || true)
fi
if [ -z "${AUTH_SG_ID:-}" ] || [ "${AUTH_SG_ID}" = "None" ]; then
  AUTH_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ecs-auth-sg" --region "${AWS_REGION}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
fi
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-ENABLED}"

login_ecr() {
  echo "==> [1/4] 登录 AWS ECR (${ECR_REGISTRY})..."
  aws ecr get-login-password --region "${AWS_REGION}" | \
    "${CONTAINER_CLI}" login --username AWS --password-stdin "${ECR_REGISTRY}"
}

build_and_push() {
  login_ecr

  # Podman 默认构建 OCI 镜像格式，指定 --format docker 确保与 AWS ECR / ECS Fargate 100% 兼容
   EXTRA_BUILD_ARGS=()
  if [ "${CONTAINER_CLI}" = "podman" ]; then
    EXTRA_BUILD_ARGS+=(--format docker)
  fi

  echo "==> [2/4] 构建并推送 auth 镜像 (platform: ${IMAGE_PLATFORM}, tag: ${IMAGE_TAG})..."
  "${CONTAINER_CLI}" build \
    --platform "${IMAGE_PLATFORM}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    --build-arg APP_NAME=auth \
    -t "${ECR_REGISTRY}/${AUTH_REPO}:${IMAGE_TAG}" \
    -t "${ECR_REGISTRY}/${AUTH_REPO}:latest" \
    .
  "${CONTAINER_CLI}" push "${ECR_REGISTRY}/${AUTH_REPO}:${IMAGE_TAG}"
  "${CONTAINER_CLI}" push "${ECR_REGISTRY}/${AUTH_REPO}:latest"

  echo "==> [2/4] 构建并推送 order 镜像 (platform: ${IMAGE_PLATFORM}, tag: ${IMAGE_TAG})..."
  "${CONTAINER_CLI}" build \
    --platform "${IMAGE_PLATFORM}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    --build-arg APP_NAME=order \
    -t "${ECR_REGISTRY}/${ORDER_REPO}:${IMAGE_TAG}" \
    -t "${ECR_REGISTRY}/${ORDER_REPO}:latest" \
    .
  "${CONTAINER_CLI}" push "${ECR_REGISTRY}/${ORDER_REPO}:${IMAGE_TAG}"
  "${CONTAINER_CLI}" push "${ECR_REGISTRY}/${ORDER_REPO}:latest"
}

run_migration() {
  echo "==> [3/4] 启动 ECS 一次性任务执行 RDS TypeORM Migration..."
  TASK_ARN=$(aws ecs run-task \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --task-definition "${MIGRATION_TASK_DEF}" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${AUTH_SG_ID}],assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
    --overrides '{
      "containerOverrides": [
        {
          "name": "auth",
          "command": ["node", "./node_modules/typeorm/cli.js", "migration:run", "-d", "dist/apps/auth/lib/common/database/data-source.js"]
        }
      ]
    }' \
    --query 'tasks[0].taskArn' \
    --output text)

  echo "    已创建 Migration Task: ${TASK_ARN}，等待执行完成..."
  aws ecs wait tasks-stopped \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}"

  # 校验容器退出码，若非 0 则中止后续服务发布
  EXIT_CODE=$(aws ecs describe-tasks \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --query 'tasks[0].containers[0].exitCode' \
    --output text)

  if [ "${EXIT_CODE}" != "0" ]; then
    STOP_REASON=$(aws ecs describe-tasks \
      --region "${AWS_REGION}" \
      --cluster "${ECS_CLUSTER}" \
      --tasks "${TASK_ARN}" \
      --query 'tasks[0].stoppedReason' \
      --output text)
    echo "❌ Migration 执行失败，容器退出码: ${EXIT_CODE}"
    echo "   停止原因 (stoppedReason): ${STOP_REASON}"
    echo "   请检查 CloudWatch 日志 /ecs/nestjs-auth-task 或 /ecs/nestjs-auth"
    exit 1
  fi
  echo "✅ RDS Migration 执行成功！"
}

rollout_services() {
  echo "==> [4/4] 触发 ECS 服务滚动更新..."
  echo "    正在更新下游服务: ${ORDER_SERVICE}..."
  aws ecs update-service \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --service "${ORDER_SERVICE}" \
    --force-new-deployment >/dev/null

  echo "    正在更新网关服务: ${AUTH_SERVICE}..."
  aws ecs update-service \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --service "${AUTH_SERVICE}" \
    --force-new-deployment >/dev/null

  echo "✅ ECS 服务滚动更新已触发！"
}

case "${ACTION}" in
  push)
    build_and_push
    ;;
  migrate)
    run_migration
    ;;
  rollout)
    rollout_services
    ;;
  all)
    build_and_push
    run_migration
    rollout_services
    ;;
  *)
    echo "用法: $0 {all|push|migrate|rollout}"
    exit 1
    ;;
esac

