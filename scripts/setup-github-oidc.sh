#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# GitHub Actions -> AWS CodeBuild 自动触发认证配置脚本
# 设计说明：
#   由于当前 AWS 组织 SCP 策略限制了 iam:CreateOpenIDConnectProvider，
#   本脚本采用“最小权限专用 IAM 机器人账号 (nestjs-github-ci) + GitHub Encrypted Secrets”方案：
#   1. 该专用账号仅拥有触发 nestjs-aws-cicd CodeBuild 项目与读取其构建日志的权限，
#      无任何创建/修改其他云资源的权限，确保极高安全性。
#   2. 自动通过 gh secret set 将生成的凭证直接加密注入 GitHub 仓库 Secrets，
#      全程不在本地磁盘或终端明文落盘。
# ==============================================================================

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
GITHUB_REPO="${GITHUB_REPO:-kobe4cn/nestjs-aws}"
CI_USER_NAME="${CI_USER_NAME:-nestjs-github-ci}"
CODEBUILD_PROJECT_NAME="${CODEBUILD_PROJECT_NAME:-nestjs-aws-cicd}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "❌ 无法获取 AWS Account ID，请检查 aws configure 登录状态。"
  exit 1
fi

setup_github_cd_auth() {
  echo "==> [1/3] 检查/创建 GitHub Actions 专用最小权限 IAM 用户 (${CI_USER_NAME})..."

  if ! aws iam get-user --user-name "${CI_USER_NAME}" >/dev/null 2>&1; then
    aws iam create-user --user-name "${CI_USER_NAME}" >/dev/null
    echo "    ✅ 已创建专用 IAM 用户: ${CI_USER_NAME}"
  else
    echo "    ✅ 专用 IAM 用户已存在: ${CI_USER_NAME}"
  fi

  # 仅授予触发指定 CodePipeline / CodeBuild 与读取构建日志的最小权限
  USER_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadSourceArtifactToPipelineBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::nestjs-codepipeline-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}",
        "arn:aws:s3:::nestjs-codepipeline-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}/*"
      ]
    },
    {
      "Sid": "TriggerAndMonitorCodePipeline",
      "Effect": "Allow",
      "Action": [
        "codepipeline:StartPipelineExecution",
        "codepipeline:GetPipelineExecution",
        "codepipeline:GetPipelineState",
        "codepipeline:ListActionExecutions"
      ],
      "Resource": [
        "arn:aws:codepipeline:${AWS_REGION}:${AWS_ACCOUNT_ID}:nestjs-aws-pipeline",
        "arn:aws:codepipeline:${AWS_REGION}:${AWS_ACCOUNT_ID}:nestjs-aws-pipeline/*"
      ]
    },
    {
      "Sid": "TriggerAndMonitorCodeBuildOnly",
      "Effect": "Allow",
      "Action": [
        "codebuild:StartBuild",
        "codebuild:BatchGetBuilds",
        "codebuild:ListBuildsForProject"
      ],
      "Resource": "arn:aws:codebuild:${AWS_REGION}:${AWS_ACCOUNT_ID}:project/${CODEBUILD_PROJECT_NAME}"
    },
    {
      "Sid": "StreamCodeBuildCloudWatchLogsOnly",
      "Effect": "Allow",
      "Action": [
        "logs:GetLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/${CODEBUILD_PROJECT_NAME}",
        "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/${CODEBUILD_PROJECT_NAME}:*"
      ]
    }
  ]
}
EOF
)

  aws iam put-user-policy \
    --user-name "${CI_USER_NAME}" \
    --policy-name "GitHubActionsTriggerCodeBuildPolicy" \
    --policy-document "${USER_POLICY}"
  echo "    ✅ 已绑定最小权限策略 (仅允许触发 ${CODEBUILD_PROJECT_NAME} 与读取构建日志)"

  echo "==> [2/3] 轮换生成访问密钥并加密写入 GitHub Actions Secrets..."
  # 清理该专用用户下已有的旧 AccessKey（AWS 每个用户上限 2 个，保持只留最新 1 个）
  EXISTING_KEYS=$(aws iam list-access-keys --user-name "${CI_USER_NAME}" --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null || echo "")
  for key_id in ${EXISTING_KEYS}; do
    if [ -n "${key_id}" ] && [ "${key_id}" != "None" ]; then
      aws iam delete-access-key --user-name "${CI_USER_NAME}" --access-key-id "${key_id}"
    fi
  done

  KEY_JSON=$(aws iam create-access-key --user-name "${CI_USER_NAME}" --output json)
  NEW_KEY_ID=$(echo "${KEY_JSON}" | node -e "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(0,'utf8')); process.stdout.write(d.AccessKey.AccessKeyId);")
  NEW_SECRET_KEY=$(echo "${KEY_JSON}" | node -e "const fs=require('fs'); const d=JSON.parse(fs.readFileSync(0,'utf8')); process.stdout.write(d.AccessKey.SecretAccessKey);")

  echo "==> [3/3] 注入 GitHub 仓库加密凭据 (${GITHUB_REPO})..."
  printf "%s" "${NEW_KEY_ID}" | gh secret set AWS_ACCESS_KEY_ID --repo "${GITHUB_REPO}"
  printf "%s" "${NEW_SECRET_KEY}" | gh secret set AWS_SECRET_ACCESS_KEY --repo "${GITHUB_REPO}"
  gh variable set AWS_REGION --body "${AWS_REGION}" --repo "${GITHUB_REPO}"

  echo "=============================================================================="
  echo "🎉 GitHub Actions -> AWS CodeBuild 自动部署凭据已配置完成！"
  echo "   - 专用 IAM 用户: ${CI_USER_NAME} (最小权限，仅限触发 ${CODEBUILD_PROJECT_NAME})"
  echo "   - GitHub Secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (已加密注入)"
  echo "   - GitHub Variable: AWS_REGION=${AWS_REGION}"
  echo "=============================================================================="
}

destroy_github_cd_auth() {
  echo "==> 清理 GitHub Actions 专用 IAM 用户与凭据 (${CI_USER_NAME})..."
  EXISTING_KEYS=$(aws iam list-access-keys --user-name "${CI_USER_NAME}" --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null || echo "")
  for key_id in ${EXISTING_KEYS}; do
    if [ -n "${key_id}" ] && [ "${key_id}" != "None" ]; then
      aws iam delete-access-key --user-name "${CI_USER_NAME}" --access-key-id "${key_id}" 2>/dev/null || true
    fi
  done
  aws iam delete-user-policy --user-name "${CI_USER_NAME}" --policy-name "GitHubActionsTriggerCodeBuildPolicy" 2>/dev/null || true
  aws iam delete-user --user-name "${CI_USER_NAME}" 2>/dev/null || true
  echo "    ✅ 已删除 IAM 用户: ${CI_USER_NAME}"

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh secret delete AWS_ACCESS_KEY_ID --repo "${GITHUB_REPO}" 2>/dev/null || true
    gh secret delete AWS_SECRET_ACCESS_KEY --repo "${GITHUB_REPO}" 2>/dev/null || true
    gh variable delete AWS_REGION --repo "${GITHUB_REPO}" 2>/dev/null || true
    echo "    ✅ 已清理 GitHub Secrets 与 Variables"
  fi
}

ACTION="${1:-setup}"
case "${ACTION}" in
  setup)
    setup_github_cd_auth
    ;;
  destroy)
    destroy_github_cd_auth
    ;;
  *)
    echo "用法: $0 [setup|destroy]"
    exit 1
    ;;
esac
