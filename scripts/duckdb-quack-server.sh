#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DuckDB Quack Server AWS 自动化运维工具
# 参考: https://github.com/duckdb/duckdb-quack-infra
#
# 功能：
# 1. 自动配置/管理 AWS SSH KeyPair，确保可登录服务器
# 2. 自动创建安全组并放行 22 (SSH), 80 (ACME), 443 (Quack HTTPS)
# 3. 自动解析当前区域官方 Ubuntu 24.04 LTS 最新官方 AMI
# 4. 自动通过 UserData 初始化：DuckDB CLI, quack 扩展, Nginx 反向代理,
#    Let's Encrypt SSL (基于 nip.io 动态解析域名), systemd 守护进程
# 5. 提供 create (创建启动), status (查看状态), ssh (一键登录), destroy (彻底销毁)
# ==============================================================================

# 配置变量（可通过环境变量覆盖）
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
KEY_NAME="${KEY_NAME:-duckdb-quack-key}"
KEY_PATH="${KEY_PATH:-${HOME}/.ssh/${KEY_NAME}.pem}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-duckdb-quack-sg}"
INSTANCE_TAG_NAME="${INSTANCE_TAG_NAME:-duckdb-quack-server}"
VOLUME_SIZE="${VOLUME_SIZE:-20}" # 默认 20GB 系统盘

# 终端彩色输出
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

info() { echo -e "${C_CYAN}ℹ️  [INFO]${C_RESET} $*"; }
success() { echo -e "${C_GREEN}✅ [SUCCESS]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠️  [WARN]${C_RESET} $*"; }
error() { echo -e "${C_RED}❌ [ERROR]${C_RESET} $*" >&2; }
header() {
  echo -e "\n${C_BOLD}${C_BLUE}==============================================================================${C_RESET}"
  echo -e "${C_BOLD}${C_BLUE}  $*${C_RESET}"
  echo -e "${C_BOLD}${C_BLUE}==============================================================================${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# 依赖检查
# ------------------------------------------------------------------------------
check_prerequisites() {
  if ! command -v aws >/dev/null 2>&1; then
    error "未安装 AWS CLI，请先安装并配置 aws configure。"
    exit 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    error "AWS 凭证未配置或已失效，请运行 aws configure 登录。"
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# 获取当前区域最新 Ubuntu 24.04 LTS x86_64 AMI ID
# ------------------------------------------------------------------------------
get_ubuntu_ami() {
  # 优先从 AWS 官方 SSM Parameter Store 查询官方 Canonical 最新 AMI
  local ami_id=""
  ami_id=$(aws ssm get-parameter \
    --name "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" \
    --region "${AWS_REGION}" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true)

  # 若 SSM 不可用，回退至 describe-images 官方 Canonical 账号 (099720109477) 检索
  if [ -z "${ami_id}" ] || [ "${ami_id}" = "None" ]; then
    ami_id=$(aws ec2 describe-images \
      --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
      --query "reverse(sort_by(Images, &CreationDate))[0].ImageId" \
      --region "${AWS_REGION}" \
      --output text 2>/dev/null || true)
  fi

  if [ -z "${ami_id}" ] || [ "${ami_id}" = "None" ]; then
    error "无法在区域 ${AWS_REGION} 获取 Ubuntu 24.04 LTS 官方 AMI。"
    exit 1
  fi
  echo "${ami_id}"
}

# ------------------------------------------------------------------------------
# 检查/创建 SSH 密钥对
# ------------------------------------------------------------------------------
ensure_key_pair() {
  info "检查 SSH 密钥对: ${KEY_NAME}..."
  mkdir -p "$(dirname "${KEY_PATH}")"

  local key_exists_in_aws=false
  if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    key_exists_in_aws=true
  fi

  if [ "${key_exists_in_aws}" = "true" ] && [ -f "${KEY_PATH}" ]; then
    info "    SSH 密钥在 AWS 和本地均已就绪: ${KEY_PATH}"
    return 0
  fi

  if [ "${key_exists_in_aws}" = "true" ] && [ ! -f "${KEY_PATH}" ]; then
    warn "    AWS 中存在密钥对 ${KEY_NAME}，但本地私钥丢失 (${KEY_PATH})。"
    info "    重新生成并覆盖 AWS 密钥对..."
    aws ec2 delete-key-pair --key-name "${KEY_NAME}" --region "${AWS_REGION}" >/dev/null
  fi

  info "    在 AWS 生成新密钥对并保存至本地: ${KEY_PATH}..."
  aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --key-type ed25519 \
    --query "KeyMaterial" \
    --output text \
    --region "${AWS_REGION}" > "${KEY_PATH}"

  chmod 400 "${KEY_PATH}"
  success "    SSH 私钥已保存并设置 400 权限: ${KEY_PATH}"
}

# ------------------------------------------------------------------------------
# 检查/创建安全组 (放行 22, 80, 443)
# ------------------------------------------------------------------------------
ensure_security_group() {
  local vpc_id="$1"
  info "检查安全组: ${SECURITY_GROUP_NAME}..."

  local sg_id=""
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${vpc_id}" \
    --region "${AWS_REGION}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

  if [ -n "${sg_id}" ] && [ "${sg_id}" != "None" ]; then
    info "    安全组已存在: ${sg_id}"
    echo "${sg_id}"
    return 0
  fi

  info "    创建新安全组 ${SECURITY_GROUP_NAME} (VPC: ${vpc_id})..."
  sg_id=$(aws ec2 create-security-group \
    --group-name "${SECURITY_GROUP_NAME}" \
    --description "DuckDB Quack Server (SSH, HTTP/ACME, HTTPS/Quack RPC)" \
    --vpc-id "${vpc_id}" \
    --region "${AWS_REGION}" \
    --query "GroupId" \
    --output text)

  info "    配置入站规则: 开放 22 (SSH), 80 (HTTP), 443 (HTTPS)..."
  aws ec2 authorize-security-group-ingress \
    --group-id "${sg_id}" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" >/dev/null

  aws ec2 authorize-security-group-ingress \
    --group-id "${sg_id}" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" >/dev/null

  aws ec2 authorize-security-group-ingress \
    --group-id "${sg_id}" \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" >/dev/null

  # 添加标签方便管理
  aws ec2 create-tags \
    --resources "${sg_id}" \
    --tags Key=Name,Value="${SECURITY_GROUP_NAME}" \
    --region "${AWS_REGION}" >/dev/null

  success "    安全组创建完毕: ${sg_id}"
  echo "${sg_id}"
}

# ------------------------------------------------------------------------------
# 生成 EC2 UserData 脚本 (Cloud-Init 一键安装与服务编排)
# ------------------------------------------------------------------------------
generate_user_data() {
  cat << 'USERDATA'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee -a /var/log/duckdb-quack-init.log) 2>&1
echo "=== [$(date)] DuckDB Quack Server 初始化启动 ==="

# 1. 系统包与必备依赖安装
apt-get update -y
apt-get install -y curl unzip nginx snapd jq net-tools

# 2. 安装 Certbot (Snap 版 ACME v2)
snap install core
snap refresh core || true
snap install certbot --classic
ln -sf /snap/bin/certbot /usr/bin/certbot

# 3. 安装 DuckDB CLI
echo "--- 安装 DuckDB CLI ---"
curl -fsSL https://install.duckdb.org | HOME_DIR=/root sh
DUCKDB_BIN=$(find /root/.duckdb/cli -name duckdb -type f | sort -V | tail -n 1)
cp "${DUCKDB_BIN}" /usr/local/bin/duckdb
chmod 755 /usr/local/bin/duckdb

# 4. 安装 Quack RPC 扩展
echo "--- 安装 DuckDB Quack 扩展 ---"
/usr/local/bin/duckdb -c "FORCE INSTALL quack FROM core_nightly;"

# 5. 通过 AWS IMDSv2 获取实例元数据与动态 nip.io 域名
echo "--- 获取实例网络信息与 nip.io 域名 ---"
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
IMDS="curl -s -H X-aws-ec2-metadata-token:${IMDS_TOKEN}"
MY_IP=$(${IMDS} http://169.254.169.254/latest/meta-data/public-ipv4)
MY_LOCAL_IP=$(${IMDS} http://169.254.169.254/latest/meta-data/local-ipv4)
MY_INSTANCE_ID=$(${IMDS} http://169.254.169.254/latest/meta-data/instance-id)
MY_INSTANCE_TYPE=$(${IMDS} http://169.254.169.254/latest/meta-data/instance-type)
MY_REGION=$(${IMDS} http://169.254.169.254/latest/meta-data/placement/region)
MY_HOSTNAME="${MY_IP}.nip.io"

echo "公网 IP: ${MY_IP}"
echo "主机域名: ${MY_HOSTNAME}"

# 6. 配置 Nginx 反向代理 (/quack -> 127.0.0.1:1294)
cat > /etc/nginx/sites-available/default << NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${MY_HOSTNAME};
    root /var/www/html;

    location /quack {
        proxy_pass http://127.0.0.1:1294;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive";
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX

nginx -t && systemctl restart nginx

# 7. 申请免费 Let's Encrypt 证书并自动配置 Nginx 443 HTTPS
echo "--- 申请 Let's Encrypt SSL 证书 ---"
certbot --nginx --non-interactive --agree-tos \
    -m "admin@${MY_HOSTNAME}" \
    -d "${MY_HOSTNAME}" || true

# 8. 生成高强度访问令牌与 DuckDB 启动脚本
QUACK_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
mkdir -p /etc/duckdb /var/lib/duckdb /home/ubuntu

cat > /etc/duckdb/init.sql << SQL
LOAD quack;
SET VARIABLE my_ip = '${MY_IP}';
SET VARIABLE my_local_ip = '${MY_LOCAL_IP}';
SET VARIABLE my_hostname = '${MY_HOSTNAME}';
SET VARIABLE my_instance_id = '${MY_INSTANCE_ID}';
SET VARIABLE my_instance_type = '${MY_INSTANCE_TYPE}';
SET VARIABLE my_region = '${MY_REGION}';
CALL quack_serve('quack:0.0.0.0:1294', allow_other_hostname=true, token='${QUACK_TOKEN}');
SQL

# 9. 配置并启动 systemd 守护进程
cat > /etc/systemd/system/duckdb-quack.service << 'UNIT'
[Unit]
Description=DuckDB Quack RPC Server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/duckdb
ExecStart=/bin/sh -c 'sleep infinity | /usr/local/bin/duckdb -init /etc/duckdb/init.sql'
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable duckdb-quack.service
systemctl start duckdb-quack.service

# 10. 保存就绪标记与连接凭证供外部调用
cat > /home/ubuntu/quack-credentials.json << JSON
{
  "instance_id": "${MY_INSTANCE_ID}",
  "public_ip": "${MY_IP}",
  "hostname": "${MY_HOSTNAME}",
  "quack_uri": "quack:${MY_HOSTNAME}:443",
  "token": "${QUACK_TOKEN}",
  "status": "READY"
}
JSON
chmod 644 /home/ubuntu/quack-credentials.json
chown ubuntu:ubuntu /home/ubuntu/quack-credentials.json

echo "READY" > /tmp/quack_ready
echo "=== [$(date)] DuckDB Quack Server 初始化完毕！服务端就绪于 https://${MY_HOSTNAME}/quack ==="
USERDATA
}

# ------------------------------------------------------------------------------
# 创建并启动 EC2 服务器
# ------------------------------------------------------------------------------
cmd_create() {
  header "🚀 开始在 AWS 创建并部署 DuckDB Quack Server (Region: ${AWS_REGION})"
  check_prerequisites

  # 1. 检查/创建 SSH 密钥对
  ensure_key_pair

  # 2. 获取默认 VPC 和公有子网
  info "查找默认 VPC 与子网..."
  local vpc_id=""
  vpc_id=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region "${AWS_REGION}" \
    --query "Vpcs[0].VpcId" \
    --output text)

  if [ -z "${vpc_id}" ] || [ "${vpc_id}" = "None" ]; then
    error "当前区域 ${AWS_REGION} 未找到 Default VPC，请检查网络配置。"
    exit 1
  fi
  info "    Default VPC ID: ${vpc_id}"

  local subnet_id=""
  subnet_id=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=default-for-az,Values=true" \
    --region "${AWS_REGION}" \
    --query "Subnets[0].SubnetId" \
    --output text)
  info "    公有子网 ID: ${subnet_id}"

  # 3. 检查/创建安全组
  local sg_id=""
  sg_id=$(ensure_security_group "${vpc_id}")

  # 4. 获取 Ubuntu 24.04 官方 AMI
  info "检索当前区域最新 Ubuntu 24.04 LTS 官方 AMI..."
  local ami_id=""
  ami_id=$(get_ubuntu_ami)
  success "    使用 AMI: ${ami_id}"

  # 5. 检查是否已有同名且运行中的实例
  local existing_instance=""
  existing_instance=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG_NAME}" "Name=instance-state-name,Values=pending,running,stopped" \
    --region "${AWS_REGION}" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null || true)

  if [ -n "${existing_instance}" ] && [ "${existing_instance}" != "None" ]; then
    warn "检测到已有同名实例存在 (${existing_instance})！"
    echo "可先运行 $0 status 查看，或运行 $0 destroy 销毁后再重新创建。"
    exit 1
  fi

  # 6. 生成 UserData 并 base64 编码
  info "生成 Cloud-Init 初始化自动化脚本..."
  local user_data_file
  user_data_file=$(mktemp)
  generate_user_data > "${user_data_file}"

  # 7. 启动 EC2 实例
  info "正在向 AWS 请求创建 EC2 实例 (${INSTANCE_TYPE}, ${VOLUME_SIZE}GB gp3 卷)..."
  local instance_id
  instance_id=$(aws ec2 run-instances \
    --image-id "${ami_id}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${sg_id}" \
    --subnet-id "${subnet_id}" \
    --associate-public-ip-address \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --user-data "file://${user_data_file}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_TAG_NAME}}]" \
    --region "${AWS_REGION}" \
    --query "Instances[0].InstanceId" \
    --output text)
  rm -f "${user_data_file}"

  success "EC2 实例创建成功！Instance ID: ${instance_id}"

  # 8. 等待实例进入 running 状态
  info "等待实例进入 running 状态..."
  aws ec2 wait instance-running --instance-ids "${instance_id}" --region "${AWS_REGION}"

  local public_ip
  public_ip=$(aws ec2 describe-instances \
    --instance-ids "${instance_id}" \
    --region "${AWS_REGION}" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
  success "实例已启动！公网 IP: ${public_ip}"

  # 9. 轮询等待 Cloud-Init 完成 DuckDB 与 Nginx/SSL 部署 (通常约 1.5 - 2 分钟)
  info "云端正在自动安装 DuckDB、Quack 扩展、Nginx 并通过 nip.io 配置 Let's Encrypt SSL..."
  info "正在探活服务，请稍候 (预计 60~90 秒)..."

  local is_ready=false
  for i in {1..30}; do
    sleep 6
    echo -n "."
    # 尝试通过 SSH 直接读取 credentials
    local creds
    creds=$(ssh -i "${KEY_PATH}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      "ubuntu@${public_ip}" "cat /home/ubuntu/quack-credentials.json 2>/dev/null" 2>/dev/null || true)

    if echo "${creds}" | grep -q '"status": "READY"'; then
      echo ""
      is_ready=true
      break
    fi
  done

  if [ "${is_ready}" != "true" ]; then
    warn "\n服务仍在后台配置中或网络初始化稍有延迟。"
    info "你可以运行 '$0 ssh' 登录后执行 'cat /var/log/duckdb-quack-init.log' 查看进度。"
    info "或者稍后运行 '$0 status' 查看连接信息。"
    return 0
  fi

  # 10. 展示成果与连接信息
  show_connection_details "${instance_id}" "${public_ip}"
}

# ------------------------------------------------------------------------------
# 打印详细连接信息与 DuckDB SQL 示例
# ------------------------------------------------------------------------------
show_connection_details() {
  local instance_id="$1"
  local public_ip="$2"

  local creds
  creds=$(ssh -i "${KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    "ubuntu@${public_ip}" "cat /home/ubuntu/quack-credentials.json 2>/dev/null" 2>/dev/null || true)

  local quack_uri
  local token
  quack_uri=$(echo "${creds}" | jq -r '.quack_uri // empty' 2>/dev/null || true)
  token=$(echo "${creds}" | jq -r '.token // empty' 2>/dev/null || true)

  if [ -z "${quack_uri}" ]; then
    quack_uri="quack:${public_ip}.nip.io:443"
  fi

  header "🎉 DuckDB Quack Server 部署完毕！"

  echo -e "${C_BOLD}📌 服务器基本信息：${C_RESET}"
  echo -e "  - 区域 (Region):        ${AWS_REGION}"
  echo -e "  - 实例 ID (Instance):   ${instance_id}"
  echo -e "  - 公网 IP (Public IP):  ${public_ip}"
  echo -e "  - 动态域名 (Domain):    ${public_ip}.nip.io"
  echo -e "  - Quack RPC URI:        ${C_GREEN}${quack_uri}${C_RESET}"
  echo -e "  - 访问令牌 (Token):     ${C_YELLOW}${token}${C_RESET}"

  echo -e "\n${C_BOLD}🔑 一键 SSH 登录命令：${C_RESET}"
  echo -e "  ${C_CYAN}ssh -i \"${KEY_PATH}\" ubuntu@${public_ip}${C_RESET}"
  echo -e "  或者使用本工具快捷命令: ${C_CYAN}$0 ssh${C_RESET}"

  echo -e "\n${C_BOLD}🦆 在本地 DuckDB 中连接并查询：${C_RESET}"
  cat << SQL
  -- 1. 安装并加载 quack 扩展
  INSTALL quack FROM core_nightly;
  LOAD quack;

  -- 2. 注册服务器凭证
  CREATE SECRET quack_credentials (
      TYPE quack,
      SCOPE '${quack_uri}',
      TOKEN '${token}'
  );

  -- 3. 发起远程 RPC 查询
  FROM rpc_call('${quack_uri}', 'FROM whoami()');
  FROM rpc_call('${quack_uri}', 'SELECT 1 + 1 AS result');

  -- 4. 或者通过 ATTACH 挂载为远程数据库 (支持服务端持久化状态)
  ATTACH '${quack_uri}' AS remote (TYPE QUACK);
  FROM rpc_call_by_name('remote', 'CREATE TEMP TABLE t AS SELECT range AS id FROM range(5)');
  FROM rpc_call_by_name('remote', 'SELECT * FROM t');
SQL

  echo -e "\n${C_BOLD}🌐 Web 端一键在线试用 (shell.duckdb.org)：${C_RESET}"
  local query_url="https://shell.duckdb.org/#queries=v0,INSTALL-quack-FROM-core_nightly~,LOAD-quack~,CREATE-SECRET-quack_credentials-%28TYPE-quack%2C-SCOPE-%27${quack_uri}%27%2C-TOKEN-%27${token}%27%29~,FROM-rpc_call%28%27${quack_uri}%27%2C-%27FROM-whoami%28%29%27%29~"
  echo -e "  ${C_BLUE}${query_url}${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# 查看当前服务器运行状态
# ------------------------------------------------------------------------------
cmd_status() {
  header "🔍 查询 DuckDB Quack Server 状态 (Region: ${AWS_REGION})"
  check_prerequisites

  local instance_info
  instance_info=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --region "${AWS_REGION}" \
    --query "Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress,InstanceType,LaunchTime]" \
    --output text 2>/dev/null || true)

  if [ -z "${instance_info}" ] || [ "${instance_info}" = "None" ]; then
    warn "未找到正在运行的 DuckDB Quack Server 实例。"
    info "你可以运行 '$0 create' 一键创建新服务器。"
    return 0
  fi

  local instance_id state public_ip instance_type launch_time
  instance_id=$(echo "${instance_info}" | awk '{print $1}')
  state=$(echo "${instance_info}" | awk '{print $2}')
  public_ip=$(echo "${instance_info}" | awk '{print $3}')
  instance_type=$(echo "${instance_info}" | awk '{print $4}')
  launch_time=$(echo "${instance_info}" | awk '{print $5}')

  echo -e "${C_BOLD}实例 ID:${C_RESET}     ${instance_id}"
  echo -e "${C_BOLD}实例类型:${C_RESET}   ${instance_type}"
  echo -e "${C_BOLD}运行状态:${C_RESET}   ${state}"
  echo -e "${C_BOLD}公网 IP:${C_RESET}    ${public_ip}"
  echo -e "${C_BOLD}启动时间:${C_RESET}   ${launch_time}"

  if [ "${state}" = "running" ] && [ -n "${public_ip}" ] && [ "${public_ip}" != "None" ]; then
    show_connection_details "${instance_id}" "${public_ip}"
  fi
}

# ------------------------------------------------------------------------------
# 一键 SSH 连接服务器
# ------------------------------------------------------------------------------
cmd_ssh() {
  check_prerequisites

  local public_ip
  public_ip=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG_NAME}" "Name=instance-state-name,Values=running" \
    --region "${AWS_REGION}" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text 2>/dev/null || true)

  if [ -z "${public_ip}" ] || [ "${public_ip}" = "None" ]; then
    error "未找到运行中的 ${INSTANCE_TAG_NAME} 实例，请先创建或检查实例状态。"
    exit 1
  fi

  if [ ! -f "${KEY_PATH}" ]; then
    error "本地找不到私钥文件: ${KEY_PATH}"
    exit 1
  fi

  info "正在连接至 ubuntu@${public_ip}..."
  ssh -i "${KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "ubuntu@${public_ip}"
}

# ------------------------------------------------------------------------------
# 彻底销毁 EC2 实例、安全组与密钥对 (防止扣费)
# ------------------------------------------------------------------------------
cmd_destroy() {
  header "⚠️  开始全量销毁 DuckDB Quack Server 资源 (Region: ${AWS_REGION})"
  check_prerequisites

  # 1. 查找并终止 EC2 实例
  local instance_ids
  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --region "${AWS_REGION}" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text 2>/dev/null || true)

  if [ -n "${instance_ids}" ] && [ "${instance_ids}" != "None" ]; then
    info "正在终止 EC2 实例: ${instance_ids}..."
    aws ec2 terminate-instances --instance-ids ${instance_ids} --region "${AWS_REGION}" >/dev/null

    info "等待实例完全终止 (terminated)..."
    aws ec2 wait instance-terminated --instance-ids ${instance_ids} --region "${AWS_REGION}"
    success "EC2 实例与关联系统盘已彻底销毁！"
  else
    info "未检测到需要销毁的 EC2 实例。"
  fi

  # 2. 删除自定义安全组
  local sg_id
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --region "${AWS_REGION}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

  if [ -n "${sg_id}" ] && [ "${sg_id}" != "None" ]; then
    info "正在删除安全组: ${sg_id} (${SECURITY_GROUP_NAME})..."
    # 稍作等待以确保 ENI 脱离完毕
    sleep 3
    aws ec2 delete-security-group --group-id "${sg_id}" --region "${AWS_REGION}" 2>/dev/null || {
      sleep 5
      aws ec2 delete-security-group --group-id "${sg_id}" --region "${AWS_REGION}" 2>/dev/null || true
    }
    success "安全组已删除！"
  fi

  # 3. 删除 AWS 密钥对 (本地密钥文件可选清理)
  if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    info "正在删除 AWS KeyPair: ${KEY_NAME}..."
    aws ec2 delete-key-pair --key-name "${KEY_NAME}" --region "${AWS_REGION}"
    success "AWS 密钥对已删除！"
  fi

  success "\n🎉 DuckDB Quack 所有云上资源已彻底清理完毕！无任何残留计费项。"
}

# ------------------------------------------------------------------------------
# 帮助信息与路由分发
# ------------------------------------------------------------------------------
usage() {
  cat << USAGE
DuckDB Quack Server AWS 自动化管理 CLI

用法:
  $0 <命令> [选项]

可用命令:
  create    一键在 AWS 创建 EC2、配置安全组/密钥、自动化部署 DuckDB Quack 并启动服务
  status    查看当前 Quack Server 运行状态、公网 IP、RPC URI 与 Token
  ssh       一键免密 SSH 登录进入服务器终端
  destroy   彻底销毁 EC2、磁盘、安全组与密钥对，确保 0 残留、0 费用

常用环境变量 (可选):
  AWS_REGION          AWS 区域 (默认: ap-southeast-2)
  INSTANCE_TYPE       EC2 实例规格 (默认: t3.small)
  VOLUME_SIZE         EBS 磁盘大小 GB (默认: 20)
  KEY_NAME            SSH 密钥名 (默认: duckdb-quack-key)
  KEY_PATH            私钥本地路径 (默认: ~/.ssh/duckdb-quack-key.pem)

示例:
  $0 create
  $0 status
  $0 ssh
  $0 destroy
USAGE
}

ACTION="${1:-}"
case "${ACTION}" in
  create)
    cmd_create
    ;;
  status)
    cmd_status
    ;;
  ssh)
    cmd_ssh
    ;;
  destroy)
    cmd_destroy
    ;;
  help|--help|-h|"")
    usage
    ;;
  *)
    error "未知命令: ${ACTION}"
    usage
    exit 1
    ;;
esac

