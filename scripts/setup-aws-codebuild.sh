#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS CodeBuild 自动化配置与管理脚本
# 功能：
#   setup   : 创建/更新 CodeBuild IAM 服务角色与 CodeBuild 项目 (ARM64 构建环境)
#   start   : 立即触发一次云端 CodeBuild 构建并实时跟踪状态
#   status  : 查看 CodeBuild 项目信息与最近一次构建记录
#   destroy : 删除 CodeBuild 项目、IAM 角色与关联 CloudWatch 日志组 (零残留)
# ==============================================================================

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
PROJECT_NAME="${PROJECT_NAME:-nestjs-aws-cicd}"
ROLE_NAME="${ROLE_NAME:-nestjs-codebuild-service-role}"
GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/kobe4cn/nestjs-aws.git}"
SOURCE_VERSION="${SOURCE_VERSION:-main}"
COMPUTE_TYPE="${COMPUTE_TYPE:-BUILD_GENERAL1_SMALL}"
ENVIRONMENT_IMAGE="${ENVIRONMENT_IMAGE:-aws/codebuild/amazonlinux-aarch64-standard:4.0}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "❌ 无法获取 AWS Account ID，请检查 aws configure 登录状态。"
  exit 1
fi

ensure_iam_role() {
  echo "==> [1/2] 检查/配置 CodeBuild IAM 服务角色 (${ROLE_NAME})..."

  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codebuild.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

  if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    echo "    创建 IAM 角色 ${ROLE_NAME}..."
    aws iam create-role \
      --role-name "${ROLE_NAME}" \
      --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
  else
    echo "    IAM 角色 ${ROLE_NAME} 已存在，更新信任策略..."
    aws iam update-assume-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-document "${TRUST_POLICY}" >/dev/null
  fi

  # 授予日志、ECR 镜像推送、ECS 迁移与服务滚动更新权限
  INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/${PROJECT_NAME}",
        "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/${PROJECT_NAME}:*"
      ]
    },
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:GetRepositoryPolicy",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:DescribeImages",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSDeployAccess",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeClusters",
        "ecs:DescribeServices",
        "ecs:UpdateService",
        "ecs:RunTask",
        "ecs:DescribeTasks",
        "ecs:DescribeTaskDefinition",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassTaskExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole"
    }
  ]
}
EOF
)

  aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "NestJSCodeBuildCICDPolicy" \
    --policy-document "${INLINE_POLICY}"

  echo "    ✅ IAM 角色权限配置完毕"
}

setup_project() {
  ensure_iam_role

  ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
  echo "==> [2/2] 创建/更新 AWS CodeBuild 项目 (${PROJECT_NAME})..."

  SOURCE_CONFIG="type=GITHUB,location=${GITHUB_REPO_URL},gitCloneDepth=1,buildspec=buildspec.yml"
  ARTIFACTS_CONFIG="type=NO_ARTIFACTS"
  ENVIRONMENT_CONFIG="type=ARM_CONTAINER,image=${ENVIRONMENT_IMAGE},computeType=${COMPUTE_TYPE},privilegedMode=true,imagePullCredentialsType=CODEBUILD"
  LOGS_CONFIG="cloudWatchLogs={status=ENABLED,groupName=/aws/codebuild/${PROJECT_NAME}}"

  EXISTING=$(aws codebuild batch-get-projects --names "${PROJECT_NAME}" --region "${AWS_REGION}" --query "projects[0].name" --output text 2>/dev/null || echo "None")

  if [ "${EXISTING}" = "${PROJECT_NAME}" ]; then
    echo "    项目 ${PROJECT_NAME} 已存在，执行更新..."
    aws codebuild update-project \
      --name "${PROJECT_NAME}" \
      --description "NestJS Auth & Order Microservices ARM64 CI/CD Pipeline" \
      --source "${SOURCE_CONFIG}" \
      --source-version "${SOURCE_VERSION}" \
      --artifacts "${ARTIFACTS_CONFIG}" \
      --environment "${ENVIRONMENT_CONFIG}" \
      --service-role "${ROLE_ARN}" \
      --logs-config "${LOGS_CONFIG}" \
      --region "${AWS_REGION}" >/dev/null
  else
    echo "    等待 IAM 角色生效 (8 秒)..."
    sleep 8
    echo "    创建新 CodeBuild 项目 ${PROJECT_NAME}..."
    aws codebuild create-project \
      --name "${PROJECT_NAME}" \
      --description "NestJS Auth & Order Microservices ARM64 CI/CD Pipeline" \
      --source "${SOURCE_CONFIG}" \
      --source-version "${SOURCE_VERSION}" \
      --artifacts "${ARTIFACTS_CONFIG}" \
      --environment "${ENVIRONMENT_CONFIG}" \
      --service-role "${ROLE_ARN}" \
      --logs-config "${LOGS_CONFIG}" \
      --region "${AWS_REGION}" >/dev/null
  fi

  echo "=============================================================================="
  echo "✅ AWS CodeBuild 项目已配置就绪！"
  echo "   - 项目名称: ${PROJECT_NAME}"
  echo "   - 所在区域: ${AWS_REGION}"
  echo "   - 构建架构: ARM_CONTAINER (${ENVIRONMENT_IMAGE}, ${COMPUTE_TYPE})"
  echo "   - 代码仓库: ${GITHUB_REPO_URL} (分支: ${SOURCE_VERSION})"
  echo "   - 控制台链接: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codebuild/projects/${PROJECT_NAME}/history?region=${AWS_REGION}"
  echo "=============================================================================="
}

start_build() {
  echo "==> 触发 AWS CodeBuild 构建 (${PROJECT_NAME}, 分支: ${SOURCE_VERSION})..."
  BUILD_ID=$(aws codebuild start-build \
    --project-name "${PROJECT_NAME}" \
    --source-version "${SOURCE_VERSION}" \
    --region "${AWS_REGION}" \
    --query "build.id" \
    --output text)

  echo "    构建已启动，Build ID: ${BUILD_ID}"
  echo "    正在轮询构建状态..."

  while true; do
    BUILD_INFO=$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${AWS_REGION}" --query "builds[0].[buildStatus,currentPhase]" --output text)
    STATUS=$(echo "${BUILD_INFO}" | awk '{print $1}')
    PHASE=$(echo "${BUILD_INFO}" | awk '{print $2}')
    echo "    [$(date +%H:%M:%S)] 状态: ${STATUS} | 当前阶段: ${PHASE}"

    if [ "${STATUS}" = "SUCCEEDED" ]; then
      echo "✅ CodeBuild 构建成功 (${BUILD_ID})！"
      break
    elif [ "${STATUS}" != "IN_PROGRESS" ]; then
      echo "❌ CodeBuild 构建结束，状态: ${STATUS} (${BUILD_ID})"
      exit 1
    fi
    sleep 10
  done
}

show_status() {
  echo "==> 查询 CodeBuild 项目状态 (${PROJECT_NAME})..."
  aws codebuild batch-get-projects \
    --names "${PROJECT_NAME}" \
    --region "${AWS_REGION}" \
    --query "projects[0].{Name:name,Source:source.location,Branch:sourceVersion,Image:environment.image,ComputeType:environment.computeType,LastModified:lastModified}" \
    --output table

  echo "==> 最近 5 次构建记录："
  BUILD_IDS=$(aws codebuild list-builds-for-project --project-name "${PROJECT_NAME}" --region "${AWS_REGION}" --query "ids[0:5]" --output text 2>/dev/null || echo "")
  if [ -n "${BUILD_IDS}" ] && [ "${BUILD_IDS}" != "None" ]; then
    aws codebuild batch-get-builds \
      --ids ${BUILD_IDS} \
      --region "${AWS_REGION}" \
      --query "builds[*].[id,buildStatus,currentPhase,startTime,endTime]" \
      --output table
  else
    echo "    暂无构建记录。"
  fi
}

destroy_codebuild() {
  echo "==> 清理 AWS CodeBuild 资源 (${PROJECT_NAME})..."
  aws codebuild delete-project --name "${PROJECT_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  echo "    ✅ 已删除 CodeBuild 项目: ${PROJECT_NAME}"

  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "NestJSCodeBuildCICDPolicy" 2>/dev/null || true
  aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
  echo "    ✅ 已删除 IAM 角色: ${ROLE_NAME}"

  aws logs delete-log-group --log-group-name "/aws/codebuild/${PROJECT_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "    ✅ 已删除 CloudWatch 日志组: /aws/codebuild/${PROJECT_NAME}"
}

ACTION="${1:-setup}"
case "${ACTION}" in
  setup)
    setup_project
    ;;
  start)
    start_build
    ;;
  status)
    show_status
    ;;
  destroy)
    destroy_codebuild
    ;;
  *)
    echo "用法: $0 [setup|start|status|destroy]"
    exit 1
    ;;
esac
