#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AWS CodePipeline 三阶段可视化流水线自动化配置与管理脚本
#
# 可视化阶段结构 (AWS Console -> CodePipeline -> nestjs-aws-pipeline)：
#   1. Source 阶段 : GitHub-Main-Source (拉取 Git 提交源码包)
#   2. Build  阶段 : CodeBuild-ARM64-Build-And-Migrate (编译单测、推 ECR、编排 UAT 资源、跑 Migration)
#   3. Deploy 阶段 : Amazon ECS 原生部署阶段 (并行展示 Deploy-Order-Service 与 Deploy-Auth-Service 状态)
#
# 用法：
#   setup   : 创建/更新 S3 工件桶、IAM 角色与三阶段 CodePipeline 流水线
#   start   : 打包当前代码上传并触发一次完整的 CodePipeline 三阶段可视化执行
#   status  : 查看 CodePipeline 各阶段与动作的当前状态
#   destroy : 删除 CodePipeline 流水线、IAM 角色与 S3 工件桶
# ==============================================================================

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
PIPELINE_NAME="${PIPELINE_NAME:-nestjs-aws-pipeline}"
CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-nestjs-aws-cicd}"
PIPELINE_ROLE_NAME="${PIPELINE_ROLE_NAME:-nestjs-codepipeline-service-role}"
ECS_CLUSTER="${ECS_CLUSTER:-nestjs-prod-cluster}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "❌ 无法获取 AWS Account ID，请检查 aws configure 登录状态。"
  exit 1
fi

ARTIFACT_BUCKET="nestjs-codepipeline-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}"

ensure_artifact_bucket() {
  echo "==> [1/3] 检查/创建 CodePipeline S3 工件存储桶 (${ARTIFACT_BUCKET})..."
  if ! aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
    echo "    创建 S3 存储桶: ${ARTIFACT_BUCKET}..."
    aws s3api create-bucket \
      --bucket "${ARTIFACT_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi

  # 启用版本控制（CodePipeline S3 Source 阶段必需）
  aws s3api put-bucket-versioning \
    --bucket "${ARTIFACT_BUCKET}" \
    --versioning-configuration Status=Enabled \
    --region "${AWS_REGION}"
  echo "    ✅ S3 工件桶已就绪 (已启用 Versioning)"
}

ensure_pipeline_role() {
  echo "==> [2/3] 检查/配置 CodePipeline IAM 服务角色 (${PIPELINE_ROLE_NAME})..."

  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codepipeline.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

  if ! aws iam get-role --role-name "${PIPELINE_ROLE_NAME}" >/dev/null 2>&1; then
    echo "    创建 IAM 角色: ${PIPELINE_ROLE_NAME}..."
    aws iam create-role \
      --role-name "${PIPELINE_ROLE_NAME}" \
      --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
  else
    aws iam update-assume-role-policy \
      --role-name "${PIPELINE_ROLE_NAME}" \
      --policy-document "${TRUST_POLICY}" >/dev/null
  fi

  INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ArtifactBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${ARTIFACT_BUCKET}",
        "arn:aws:s3:::${ARTIFACT_BUCKET}/*"
      ]
    },
    {
      "Sid": "CodeBuildAccess",
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "arn:aws:codebuild:${AWS_REGION}:${AWS_ACCOUNT_ID}:project/${CODEBUILD_PROJECT}"
    },
    {
      "Sid": "ECSDeployAccess",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRoleToECS",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

  aws iam put-role-policy \
    --role-name "${PIPELINE_ROLE_NAME}" \
    --policy-name "NestJSCodePipelineAccessPolicy" \
    --policy-document "${INLINE_POLICY}"

  echo "    ✅ CodePipeline IAM 角色配置完成"
}

setup_pipeline() {
  ensure_artifact_bucket
  ensure_pipeline_role

  # 确保 S3 中存在初始 source.zip，防止流水线首次创建时因找不到对象而报错
  if ! aws s3api head-object --bucket "${ARTIFACT_BUCKET}" --key "source.zip" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    打包当前代码上传初始 source.zip 到 S3..."
    package_and_upload_source
  fi

  echo "==> [3/3] 创建/更新三阶段可视化 AWS CodePipeline (${PIPELINE_NAME})..."
  ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PIPELINE_ROLE_NAME}"

  PIPELINE_JSON=$(cat <<EOF
{
  "pipeline": {
    "name": "${PIPELINE_NAME}",
    "roleArn": "${ROLE_ARN}",
    "pipelineType": "V2",
    "artifactStore": {
      "type": "S3",
      "location": "${ARTIFACT_BUCKET}"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "GitHub-Main-Source",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "S3",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "S3Bucket": "${ARTIFACT_BUCKET}",
              "S3ObjectKey": "source.zip",
              "PollForSourceChanges": "false"
            },
            "outputArtifacts": [
              {
                "name": "SourceArtifact"
              }
            ]
          }
        ]
      },
      {
        "name": "Build",
        "actions": [
          {
            "name": "CodeBuild-ARM64-Build-And-Migrate",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ProjectName": "${CODEBUILD_PROJECT}"
            },
            "inputArtifacts": [
              {
                "name": "SourceArtifact"
              }
            ],
            "outputArtifacts": [
              {
                "name": "BuildArtifact"
              }
            ]
          }
        ]
      },
      {
        "name": "Deploy",
        "actions": [
          {
            "name": "Deploy-Order-Service",
            "actionTypeId": {
              "category": "Deploy",
              "owner": "AWS",
              "provider": "ECS",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ClusterName": "${ECS_CLUSTER}",
              "ServiceName": "order-service",
              "FileName": "imagedefinitions-order.json"
            },
            "inputArtifacts": [
              {
                "name": "BuildArtifact"
              }
            ]
          },
          {
            "name": "Deploy-Auth-Service",
            "actionTypeId": {
              "category": "Deploy",
              "owner": "AWS",
              "provider": "ECS",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ClusterName": "${ECS_CLUSTER}",
              "ServiceName": "auth-service",
              "FileName": "imagedefinitions-auth.json"
            },
            "inputArtifacts": [
              {
                "name": "BuildArtifact"
              }
            ]
          }
        ]
      }
    ]
  }
}
EOF
)

  if aws codepipeline get-pipeline --name "${PIPELINE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "    更新现有 CodePipeline: ${PIPELINE_NAME}..."
    aws codepipeline update-pipeline --cli-input-json "${PIPELINE_JSON}" --region "${AWS_REGION}" >/dev/null
  else
    echo "    等待 IAM 角色传播生效 (8 秒)..."
    sleep 8
    echo "    创建 CodePipeline: ${PIPELINE_NAME}..."
    aws codepipeline create-pipeline --cli-input-json "${PIPELINE_JSON}" --region "${AWS_REGION}" >/dev/null
  fi

  echo "=============================================================================="
  echo "✅ AWS CodePipeline 三阶段可视化流水线已配置就绪！"
  echo "   - 流水线名称: ${PIPELINE_NAME}"
  echo "   - 阶段 1 (Source): GitHub-Main-Source"
  echo "   - 阶段 2 (Build) : CodeBuild-ARM64-Build-And-Migrate (${CODEBUILD_PROJECT})"
  echo "   - 阶段 3 (Deploy): Deploy-Order-Service & Deploy-Auth-Service (Amazon ECS)"
  echo "   - 可视化看板链接: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view?region=${AWS_REGION}"
  echo "=============================================================================="
}

package_and_upload_source() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local zip_path="${tmp_dir}/source.zip"
  local commit_sha
  commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "latest")

  git archive --format=zip -o "${zip_path}" HEAD
  echo "${commit_sha}" > "${tmp_dir}/.git_commit_sha"
  (cd "${tmp_dir}" && zip -q "${zip_path}" .git_commit_sha)

  aws s3 cp "${zip_path}" "s3://${ARTIFACT_BUCKET}/source.zip" --region "${AWS_REGION}" >/dev/null
  rm -rf "${tmp_dir}"
}

start_pipeline() {
  echo "==> [1/2] 打包最新 Git 代码并上传至 CodePipeline S3 源 (${ARTIFACT_BUCKET}/source.zip)..."
  package_and_upload_source

  echo "==> [2/2] 触发 AWS CodePipeline (${PIPELINE_NAME}) 执行..."
  EXECUTION_ID=$(aws codepipeline start-pipeline-execution \
    --name "${PIPELINE_NAME}" \
    --region "${AWS_REGION}" \
    --query "pipelineExecutionId" \
    --output text)

  echo "    已启动流水线执行，Execution ID: ${EXECUTION_ID}"
  echo "    📊 可视化看板: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view?region=${AWS_REGION}"
  echo "    正在实时跟踪三阶段 (Source -> Build -> Deploy) 状态..."

  LAST_SUMMARY=""
  while true; do
    EXEC_STATUS=$(aws codepipeline get-pipeline-execution \
      --pipeline-name "${PIPELINE_NAME}" \
      --pipeline-execution-id "${EXECUTION_ID}" \
      --region "${AWS_REGION}" \
      --query "pipelineExecution.status" \
      --output text)

    STAGE_SUMMARY=$(aws codepipeline get-pipeline-state \
      --name "${PIPELINE_NAME}" \
      --region "${AWS_REGION}" \
      --query "stageStates[*].[stageName,latestExecution.status]" \
      --output text | awk '{printf "%s:%s  ", $1, $2}')

    if [ "${STAGE_SUMMARY}" != "${LAST_SUMMARY}" ]; then
      echo "    [$(date +%H:%M:%S)] 流水线总状态: ${EXEC_STATUS} | 阶段状态 -> ${STAGE_SUMMARY}"
      LAST_SUMMARY="${STAGE_SUMMARY}"
    fi

    if [ "${EXEC_STATUS}" = "Succeeded" ]; then
      echo "✅ AWS CodePipeline 三阶段全流程 (Source -> Build -> Deploy to ECS) 执行成功！"
      break
    elif [ "${EXEC_STATUS}" != "InProgress" ]; then
      echo "❌ AWS CodePipeline 执行结束，最终状态: ${EXEC_STATUS} (Execution ID: ${EXECUTION_ID})"
      exit 1
    fi
    sleep 8
  done
}

show_status() {
  echo "==> AWS CodePipeline (${PIPELINE_NAME}) 各阶段实时状态："
  aws codepipeline get-pipeline-state \
    --name "${PIPELINE_NAME}" \
    --region "${AWS_REGION}" \
    --query "stageStates[*].{Stage:stageName,Status:latestExecution.status,Actions:actionStates[*].[actionName,latestExecution.status,latestExecution.lastStatusChange]}" \
    --output json
}

destroy_pipeline() {
  echo "==> 清理 AWS CodePipeline 资源 (${PIPELINE_NAME})..."
  aws codepipeline delete-pipeline --name "${PIPELINE_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "    ✅ 已删除 CodePipeline: ${PIPELINE_NAME}"

  aws iam delete-role-policy --role-name "${PIPELINE_ROLE_NAME}" --policy-name "NestJSCodePipelineAccessPolicy" 2>/dev/null || true
  aws iam delete-role --role-name "${PIPELINE_ROLE_NAME}" 2>/dev/null || true
  echo "    ✅ 已删除 IAM 角色: ${PIPELINE_ROLE_NAME}"

  if aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" 2>/dev/null; then
    echo "    正在清空并删除 S3 工件桶: ${ARTIFACT_BUCKET}..."
    # 清理带版本控制的所有历史对象版本
    VERSIONS=$(aws s3api list-object-versions --bucket "${ARTIFACT_BUCKET}" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo "")
    if echo "${VERSIONS}" | grep -q '"Key"'; then
      aws s3api delete-objects --bucket "${ARTIFACT_BUCKET}" --delete "${VERSIONS}" >/dev/null 2>&1 || true
    fi
    MARKERS=$(aws s3api list-object-versions --bucket "${ARTIFACT_BUCKET}" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null || echo "")
    if echo "${MARKERS}" | grep -q '"Key"'; then
      aws s3api delete-objects --bucket "${ARTIFACT_BUCKET}" --delete "${MARKERS}" >/dev/null 2>&1 || true
    fi
    aws s3 rb "s3://${ARTIFACT_BUCKET}" --force >/dev/null 2>&1 || true
    echo "    ✅ 已删除 S3 工件桶: ${ARTIFACT_BUCKET}"
  fi
}

ACTION="${1:-setup}"
case "${ACTION}" in
  setup)
    setup_pipeline
    ;;
  start)
    start_pipeline
    ;;
  status)
    show_status
    ;;
  destroy)
    destroy_pipeline
    ;;
  *)
    echo "用法: $0 [setup|start|status|destroy]"
    exit 1
    ;;
esac

