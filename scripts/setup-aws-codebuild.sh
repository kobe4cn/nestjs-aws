#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS CodeBuild 自动化配置与管理脚本
# 功能：
#   setup   : 创建/更新 CodeBuild IAM 服务角色与 CodeBuild 项目 (ARM64 构建环境)
#   start   : 触发云端 CodeBuild 构建 (支持 deploy / init / destroy) 并实时输出构建日志
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

  # 附加 PowerUserAccess 以支持 ECR/ECS 发布以及按需自动编排/销毁 UAT 基础设施
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" 2>/dev/null || true

  # 授予管理与传递 ecsTaskExecutionRole 的最小 IAM 权限
  INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageAndPassECSTaskExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:CreateRole",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:PassRole",
        "iam:CreateServiceLinkedRole"
      ],
      "Resource": "*"
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
      --timeout-in-minutes 45 \
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
      --timeout-in-minutes 45 \
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
  local action_mode="${1:-${PIPELINE_ACTION:-deploy}}"
  local commit_Or_branch="${2:-${SOURCE_VERSION}}"

  local existing
  existing=$(aws codebuild batch-get-projects --names "${PROJECT_NAME}" --region "${AWS_REGION}" --query "projects[0].name" --output text 2>/dev/null || echo "None")
  if [ "${existing}" != "${PROJECT_NAME}" ]; then
    echo "==> [自动自愈] 检测到 CodeBuild 项目 (${PROJECT_NAME}) 不存在，正在自动创建..."
    setup_project
  fi

  echo "==> 触发 AWS CodeBuild 构建 (${PROJECT_NAME}, 模式: ${action_mode}, 版本: ${commit_Or_branch})..."
  BUILD_ID=$(aws codebuild start-build \
    --project-name "${PROJECT_NAME}" \
    --source-version "${commit_Or_branch}" \
    --environment-variables-override "name=PIPELINE_ACTION,value=${action_mode},type=PLAINTEXT" \
    --region "${AWS_REGION}" \
    --query "build.id" \
    --output text)

  BUILD_UUID="${BUILD_ID#*:}"
  LOG_GROUP="/aws/codebuild/${PROJECT_NAME}"
  LOG_STREAM="${BUILD_UUID}"

  echo "    构建已启动，Build ID: ${BUILD_ID}"
  echo "    正在实时跟踪构建状态与日志..."

  NEXT_TOKEN=""
  LAST_PHASE=""

  while true; do
    BUILD_INFO=$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${AWS_REGION}" --query "builds[0].[buildStatus,currentPhase]" --output text)
    STATUS=$(echo "${BUILD_INFO}" | awk '{print $1}')
    PHASE=$(echo "${BUILD_INFO}" | awk '{print $2}')

    if [ "${PHASE}" != "${LAST_PHASE}" ]; then
      echo "==> [$(date +%H:%M:%S)] CodeBuild 阶段切换: ${PHASE} (状态: ${STATUS})"
      LAST_PHASE="${PHASE}"
    fi

    # 尝试拉取增量 CloudWatch 日志输出
    if [ -z "${NEXT_TOKEN}" ]; then
      LOG_JSON=$(aws logs get-log-events \
        --log-group-name "${LOG_GROUP}" \
        --log-stream-name "${LOG_STREAM}" \
        --start-from-head \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null || echo "")
    else
      LOG_JSON=$(aws logs get-log-events \
        --log-group-name "${LOG_GROUP}" \
        --log-stream-name "${LOG_STREAM}" \
        --next-token "${NEXT_TOKEN}" \
        --region "${AWS_REGION}" \
        --output json 2>/dev/null || echo "")
    fi

    if [ -n "${LOG_JSON}" ]; then
      NEW_TOKEN=$(echo "${LOG_JSON}" | node -e "const fs=require('fs'); try { const d=JSON.parse(fs.readFileSync(0,'utf8')); (d.events||[]).forEach(e=>process.stdout.write(e.message)); } catch(e){}")
      if [ -n "${NEW_TOKEN}" ]; then
        printf "%s" "${NEW_TOKEN}"
      fi
      UPDATED_TOKEN=$(echo "${LOG_JSON}" | node -e "const fs=require('fs'); try { const d=JSON.parse(fs.readFileSync(0,'utf8')); if(d.nextForwardToken) process.stdout.write(d.nextForwardToken); } catch(e){}")
      if [ -n "${UPDATED_TOKEN}" ]; then
        NEXT_TOKEN="${UPDATED_TOKEN}"
      fi
    fi

    if [ "${STATUS}" = "SUCCEEDED" ]; then
      echo ""
      echo "✅ CodeBuild 构建成功 (${BUILD_ID})！"
      break
    elif [ "${STATUS}" != "IN_PROGRESS" ]; then
      echo ""
      echo "❌ CodeBuild 构建失败，最终状态: ${STATUS} (${BUILD_ID})"
      exit 1
    fi
    sleep 5
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

  aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" 2>/dev/null || true
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "NestJSCodeBuildCICDPolicy" 2>/dev/null || true
  aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
  echo "    ✅ 已删除 IAM 角色: ${ROLE_NAME}"

  aws logs delete-log-group --log-group-name "/aws/codebuild/${PROJECT_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "    ✅ 已删除 CloudWatch 日志组: /aws/codebuild/${PROJECT_NAME}"
}

ACTION="${1:-setup}"
shift || true
case "${ACTION}" in
  setup)
    setup_project
    ;;
  start)
    start_build "$@"
    ;;
  status)
    show_status
    ;;
  destroy)
    destroy_codebuild
    ;;
  *)
    echo "用法: $0 [setup|start [deploy|init|destroy] [commit/branch]|status|destroy]"
    exit 1
    ;;
esac
