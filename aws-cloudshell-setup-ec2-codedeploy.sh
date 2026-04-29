#!/usr/bin/env bash
set -euo pipefail

# Script para AWS CloudShell.
# Ele cria uma EC2 Amazon Linux 2023 pronta para CodeDeploy, usando VPC/subnet existentes.
#
# Opcionalmente informe antes de executar:
#   export AWS_REGION=us-east-1
#   export VPC_ID=vpc-003e9231467ebdb08
#   export SUBNET_NAME=sub-net-publica1
#   export SUBNET_ID=subnet-xxxxxxxx
#   export SG_ID=sg-xxxxxxxx
#   export KEY_NAME=nome-da-chave-ec2
#   export SSH_CIDR=seu.ip.publico/32
#
# Execucao:
#   chmod +x aws-cloudshell-setup-ec2-codedeploy.sh
#   ./aws-cloudshell-setup-ec2-codedeploy.sh

APP_NAME="${APP_NAME:-appmodulo10}"
DEPLOYMENT_GROUP_NAME="${DEPLOYMENT_GROUP_NAME:-appmodulo10}"
BUCKET_NAME="${BUCKET_NAME:-modulo10fernandolopes}"
CODEDEPLOY_TAG_KEY="${CODEDEPLOY_TAG_KEY:-CodeDeploy}"
CODEDEPLOY_TAG_VALUE="${CODEDEPLOY_TAG_VALUE:-modulo10}"
INSTANCE_NAME="${INSTANCE_NAME:-ec2-appmodulo10}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
VPC_ID="${VPC_ID:-vpc-003e9231467ebdb08}"
VPC_NAME="${VPC_NAME:-vpc-curso}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
SUBNET_NAME="${SUBNET_NAME:-sub-net-publica1}"

REGION="${AWS_REGION:-us-east-1}"
if [[ -z "$REGION" ]]; then
  REGION="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].RegionName' --output text)"
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "Regiao: $REGION"
echo "Conta AWS: $ACCOUNT_ID"
echo "VPC configurada: $VPC_ID ($VPC_NAME, $VPC_CIDR)"
echo "Subnet publica preferida: $SUBNET_NAME"

FOUND_VPC_ID="None"
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  FOUND_VPC_ID="$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --vpc-ids "$VPC_ID" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)"
fi

if [[ -z "$FOUND_VPC_ID" || "$FOUND_VPC_ID" == "None" ]]; then
  echo "VPC $VPC_ID nao encontrada diretamente. Procurando por tag Name=$VPC_NAME..."
  FOUND_VPC_ID="$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query "Vpcs[0].VpcId" \
    --output text)"
fi

if [[ -z "$FOUND_VPC_ID" || "$FOUND_VPC_ID" == "None" ]]; then
  echo "VPC com tag $VPC_NAME nao encontrada. Procurando pelo CIDR $VPC_CIDR..."
  FOUND_VPC_ID="$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=cidr,Values=$VPC_CIDR" \
    --query "Vpcs[0].VpcId" \
    --output text)"
fi

if [[ -z "$FOUND_VPC_ID" || "$FOUND_VPC_ID" == "None" ]]; then
  echo "Nao encontrei a VPC na regiao $REGION."
  echo "VPCs disponiveis nessa regiao:"
  aws ec2 describe-vpcs \
    --region "$REGION" \
    --query "Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
    --output table
  echo ""
  echo "Copie o VpcId correto e execute novamente assim:"
  echo "export VPC_ID=vpc-xxxxxxxx"
  echo "./aws-cloudshell-setup-ec2-codedeploy.sh"
  exit 1
fi

VPC_ID="$FOUND_VPC_ID"

if [[ -z "${SUBNET_ID:-}" ]]; then
  SUBNET_ID="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$SUBNET_NAME" "Name=state,Values=available" \
    --query "Subnets[0].SubnetId" \
    --output text)"
fi

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  SUBNET_ID="$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=sub-net-publica*" "Name=state,Values=available" \
    --query "Subnets[0].SubnetId" \
    --output text)"
fi

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "Nenhuma subnet disponivel encontrada na VPC $VPC_ID. Informe uma subnet existente:"
  echo "export SUBNET_ID=subnet-xxxxxxxx"
  exit 1
fi

SUBNET_CIDR="$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$SUBNET_ID" \
  --query "Subnets[0].CidrBlock" \
  --output text)"

SUBNET_AZ="$(aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "$SUBNET_ID" \
  --query "Subnets[0].AvailabilityZone" \
  --output text)"

echo "VPC usada: $VPC_ID ($VPC_NAME)"
echo "Subnet usada: $SUBNET_ID"
echo "Subnet esperada: publica ($SUBNET_NAME), CIDR detectado: $SUBNET_CIDR, AZ: $SUBNET_AZ"

echo "Criando/atualizando IAM Role da EC2 para CodeDeploy..."
EC2_ROLE_NAME="${EC2_ROLE_NAME:-EC2Role-appmodulo10-codedeploy}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-EC2Profile-appmodulo10-codedeploy}"

cat > /tmp/ec2-trust-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if ! aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$EC2_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/ec2-trust-policy.json >/dev/null
fi

cat > /tmp/ec2-codedeploy-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadDeploymentBundlesFromProjectBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET_NAME",
        "arn:aws:s3:::$BUCKET_NAME/*"
      ]
    },
    {
      "Sid": "ReadCodeDeployAgentInstaller",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::aws-codedeploy-$REGION",
        "arn:aws:s3:::aws-codedeploy-$REGION/*"
      ]
    },
    {
      "Sid": "AllowCloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-name "EC2CodeDeployS3Access-$APP_NAME" \
  --policy-document file:///tmp/ec2-codedeploy-policy.json

if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
fi

if ! aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query "InstanceProfile.Roles[?RoleName=='$EC2_ROLE_NAME'].RoleName" \
  --output text | grep -q "$EC2_ROLE_NAME"; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$EC2_ROLE_NAME"
fi

echo "Criando/atualizando IAM Role do CodeDeploy..."
CODEDEPLOY_SERVICE_ROLE_NAME="${CODEDEPLOY_SERVICE_ROLE_NAME:-CodeDeployServiceRole-modulo10}"

cat > /tmp/codedeploy-trust-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if ! aws iam get-role --role-name "$CODEDEPLOY_SERVICE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$CODEDEPLOY_SERVICE_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/codedeploy-trust-policy.json >/dev/null
fi

aws iam attach-role-policy \
  --role-name "$CODEDEPLOY_SERVICE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole || true

CODEDEPLOY_SERVICE_ROLE_ARN="$(aws iam get-role \
  --role-name "$CODEDEPLOY_SERVICE_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)"

echo "Criando/atualizando IAM Role do CodePipeline..."
CODEPIPELINE_ROLE_NAME="${CODEPIPELINE_ROLE_NAME:-CodePipelineServiceRole-appmodulo10}"

cat > /tmp/codepipeline-trust-policy.json <<'JSON'
{
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
}
JSON

if ! aws iam get-role --role-name "$CODEPIPELINE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$CODEPIPELINE_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/codepipeline-trust-policy.json >/dev/null
fi

cat > /tmp/codepipeline-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UsePipelineArtifactsBucket",
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
        "arn:aws:s3:::$BUCKET_NAME",
        "arn:aws:s3:::$BUCKET_NAME/*"
      ]
    },
    {
      "Sid": "DeployWithCodeDeploy",
      "Effect": "Allow",
      "Action": [
        "codedeploy:GetApplication",
        "codedeploy:GetApplicationRevision",
        "codedeploy:RegisterApplicationRevision",
        "codedeploy:CreateDeployment",
        "codedeploy:GetDeployment",
        "codedeploy:GetDeploymentConfig",
        "codedeploy:GetDeploymentGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassCodeDeployServiceRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "$CODEDEPLOY_SERVICE_ROLE_ARN"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$CODEPIPELINE_ROLE_NAME" \
  --policy-name "CodePipelineDeployAccess-$APP_NAME" \
  --policy-document file:///tmp/codepipeline-policy.json

CODEPIPELINE_ROLE_ARN="$(aws iam get-role \
  --role-name "$CODEPIPELINE_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)"

echo "Garantindo aplicacao e grupo no CodeDeploy..."
if ! aws deploy get-application \
  --application-name "$APP_NAME" \
  --region "$REGION" >/dev/null 2>&1; then
  aws deploy create-application \
    --application-name "$APP_NAME" \
    --compute-platform Server \
    --region "$REGION" >/dev/null
fi

if ! aws deploy get-deployment-group \
  --application-name "$APP_NAME" \
  --deployment-group-name "$DEPLOYMENT_GROUP_NAME" \
  --region "$REGION" >/dev/null 2>&1; then
  aws deploy create-deployment-group \
    --application-name "$APP_NAME" \
    --deployment-group-name "$DEPLOYMENT_GROUP_NAME" \
    --service-role-arn "$CODEDEPLOY_SERVICE_ROLE_ARN" \
    --deployment-config-name CodeDeployDefault.AllAtOnce \
    --ec2-tag-filters "Key=$CODEDEPLOY_TAG_KEY,Value=$CODEDEPLOY_TAG_VALUE,Type=KEY_AND_VALUE" \
    --region "$REGION" >/dev/null
fi

echo "Criando/atualizando Security Group..."
SG_NAME="${SG_NAME:-appmodulo10-web}"

if [[ "$SG_NAME" == sg-* ]]; then
  echo "SG_NAME nao pode comecar com sg-. Usando appmodulo10-web."
  SG_NAME="appmodulo10-web"
fi

if [[ -z "${SG_ID:-}" ]]; then
  SG_ID="$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text)"
fi

if [[ -z "${SG_ID:-}" || "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --group-name "$SG_NAME" \
    --description "HTTP/SSH access for appmodulo10" \
    --query GroupId \
    --output text)"
fi

aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]" \
  >/dev/null 2>&1 || true

if [[ -n "${KEY_NAME:-}" ]]; then
  if [[ -z "${SSH_CIDR:-}" ]]; then
    SSH_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
  fi

  aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SSH_CIDR,Description=SSH}]" \
    >/dev/null 2>&1 || true
fi

AMI_ID="${AMI_ID:-$(aws ssm get-parameter \
  --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value \
  --output text)}"

echo "AMI Amazon Linux 2023: $AMI_ID"

cat > /tmp/user-data-appmodulo10.sh <<USERDATA
#!/bin/bash
set -euxo pipefail

dnf update -y
dnf install -y ruby wget httpd

systemctl enable httpd
systemctl start httpd

mkdir -p /var/www/html/modulo10
chown -R apache:apache /var/www/html/modulo10
chmod -R 755 /var/www/html/modulo10

cd /tmp
wget "https://aws-codedeploy-$REGION.s3.$REGION.amazonaws.com/latest/install" -O install
chmod +x install
./install auto

systemctl enable codedeploy-agent
systemctl restart codedeploy-agent
USERDATA

echo "Aguardando propagacao do IAM instance profile..."
sleep 15

RUN_ARGS=(
  --region "$REGION"
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=[$SG_ID],AssociatePublicIpAddress=true"
  --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME"
  --user-data "file:///tmp/user-data-appmodulo10.sh"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=$CODEDEPLOY_TAG_KEY,Value=$CODEDEPLOY_TAG_VALUE}]"
  --query "Instances[0].InstanceId"
  --output text
)

if [[ -n "${KEY_NAME:-}" ]]; then
  RUN_ARGS+=(--key-name "$KEY_NAME")
fi

INSTANCE_ID="$(aws ec2 run-instances "${RUN_ARGS[@]}")"

echo "Instancia criada: $INSTANCE_ID"
echo "Aguardando status running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_DNS="$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicDnsName" \
  --output text)"

PUBLIC_IP="$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)"

echo ""
echo "Pronto."
echo "EC2 Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Public DNS: $PUBLIC_DNS"
echo "URL esperada depois do deploy: http://$PUBLIC_DNS/modulo10/"
echo ""
echo "Roles criadas/usadas:"
echo "EC2 Role: $EC2_ROLE_NAME"
echo "EC2 Instance Profile: $INSTANCE_PROFILE_NAME"
echo "CodeDeploy Service Role: $CODEDEPLOY_SERVICE_ROLE_ARN"
echo "CodePipeline Service Role: $CODEPIPELINE_ROLE_ARN"
echo ""
echo "O grupo CodeDeploy usa a tag: $CODEDEPLOY_TAG_KEY=$CODEDEPLOY_TAG_VALUE"
