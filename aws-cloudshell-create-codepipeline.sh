#!/usr/bin/env bash
set -euo pipefail

# Script para AWS CloudShell.
# Cria/atualiza uma CodePipeline:
# GitHub (CodeStar/CodeConnections) -> CodeBuild -> CodeDeploy -> EC2.
#
# Repositorio GitHub:
#   https://github.com/fernandodpemt/modulo10
#
# EC2 alvo:
#   i-0619a640370c9d315
#
# Uso:
#   chmod +x aws-cloudshell-create-codepipeline.sh
#   ./aws-cloudshell-create-codepipeline.sh
#
# Se voce ja tem uma connection GitHub autorizada, informe:
#   export CONNECTION_ARN=arn:aws:codeconnections:us-east-1:520578320541:connection/...
#   ./aws-cloudshell-create-codepipeline.sh

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

PIPELINE_NAME="${PIPELINE_NAME:-appmodulo10-pipeline}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-modulo10fernandolopes}"
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-codepipeline}"

GITHUB_OWNER="${GITHUB_OWNER:-fernandodpemt}"
GITHUB_REPO="${GITHUB_REPO:-modulo10}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
CONNECTION_NAME="${CONNECTION_NAME:-github-fernandodpemt-modulo10}"

CODEBUILD_PROJECT_NAME="${CODEBUILD_PROJECT_NAME:-appmodulo10-build}"
CODEDEPLOY_APP_NAME="${CODEDEPLOY_APP_NAME:-appmodulo10}"
CODEDEPLOY_GROUP_NAME="${CODEDEPLOY_GROUP_NAME:-appmodulo10}"
CODEDEPLOY_SERVICE_ROLE_NAME="${CODEDEPLOY_SERVICE_ROLE_NAME:-CodeDeployServiceRole-modulo10}"

EC2_INSTANCE_ID="${EC2_INSTANCE_ID:-i-0619a640370c9d315}"
EC2_TAG_KEY="${EC2_TAG_KEY:-CodeDeploy}"
EC2_TAG_VALUE="${EC2_TAG_VALUE:-modulo10}"

PIPELINE_ROLE_NAME="${PIPELINE_ROLE_NAME:-CodePipelineServiceRole-appmodulo10}"
CODEBUILD_ROLE_NAME="${CODEBUILD_ROLE_NAME:-CodeBuildServiceRole-appmodulo10}"

echo "Regiao: $REGION"
echo "Conta AWS: $ACCOUNT_ID"
echo "Repositorio: $GITHUB_OWNER/$GITHUB_REPO ($GITHUB_BRANCH)"
echo "Pipeline: $PIPELINE_NAME"
echo "EC2 alvo: $EC2_INSTANCE_ID"

echo "Verificando bucket de artefatos: $ARTIFACT_BUCKET"
if ! aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" 2>/dev/null; then
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$ARTIFACT_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

echo "Aplicando tag do CodeDeploy na EC2..."
aws ec2 create-tags \
  --region "$REGION" \
  --resources "$EC2_INSTANCE_ID" \
  --tags "Key=$EC2_TAG_KEY,Value=$EC2_TAG_VALUE" "Key=Name,Value=ec2-appmodulo10"

echo "Criando/atualizando role do CodeDeploy..."
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
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole >/dev/null 2>&1 || true

CODEDEPLOY_SERVICE_ROLE_ARN="$(aws iam get-role \
  --role-name "$CODEDEPLOY_SERVICE_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)"

echo "Garantindo aplicacao e grupo do CodeDeploy..."
if ! aws deploy get-application \
  --region "$REGION" \
  --application-name "$CODEDEPLOY_APP_NAME" >/dev/null 2>&1; then
  aws deploy create-application \
    --region "$REGION" \
    --application-name "$CODEDEPLOY_APP_NAME" \
    --compute-platform Server >/dev/null
fi

if aws deploy get-deployment-group \
  --region "$REGION" \
  --application-name "$CODEDEPLOY_APP_NAME" \
  --deployment-group-name "$CODEDEPLOY_GROUP_NAME" >/dev/null 2>&1; then
  aws deploy update-deployment-group \
    --region "$REGION" \
    --application-name "$CODEDEPLOY_APP_NAME" \
    --current-deployment-group-name "$CODEDEPLOY_GROUP_NAME" \
    --service-role-arn "$CODEDEPLOY_SERVICE_ROLE_ARN" \
    --deployment-config-name CodeDeployDefault.AllAtOnce \
    --ec2-tag-filters "Key=$EC2_TAG_KEY,Value=$EC2_TAG_VALUE,Type=KEY_AND_VALUE" >/dev/null
else
  aws deploy create-deployment-group \
    --region "$REGION" \
    --application-name "$CODEDEPLOY_APP_NAME" \
    --deployment-group-name "$CODEDEPLOY_GROUP_NAME" \
    --service-role-arn "$CODEDEPLOY_SERVICE_ROLE_ARN" \
    --deployment-config-name CodeDeployDefault.AllAtOnce \
    --ec2-tag-filters "Key=$EC2_TAG_KEY,Value=$EC2_TAG_VALUE,Type=KEY_AND_VALUE" >/dev/null
fi

echo "Criando/atualizando role do CodeBuild..."
cat > /tmp/codebuild-trust-policy.json <<'JSON'
{
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
}
JSON

if ! aws iam get-role --role-name "$CODEBUILD_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$CODEBUILD_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/codebuild-trust-policy.json >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$CODEBUILD_ROLE_NAME" \
    --policy-document file:///tmp/codebuild-trust-policy.json >/dev/null
fi

cat > /tmp/codebuild-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:GetBucketAcl",
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$ARTIFACT_BUCKET",
        "arn:aws:s3:::$ARTIFACT_BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:CreateReportGroup",
        "codebuild:CreateReport",
        "codebuild:UpdateReport",
        "codebuild:BatchPutTestCases",
        "codebuild:BatchPutCodeCoverages"
      ],
      "Resource": "*"
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --policy-name "CodeBuildPipelineAccess-$PIPELINE_NAME" \
  --policy-document file:///tmp/codebuild-policy.json

CODEBUILD_ROLE_ARN="$(aws iam get-role \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)"

echo "Aguardando propagacao da role do CodeBuild..."
aws iam wait role-exists --role-name "$CODEBUILD_ROLE_NAME"
sleep 20

cat > /tmp/buildspec-appmodulo10.yml <<'YAML'
version: 0.2

env:
  variables:
    NODE_OPTIONS: "--openssl-legacy-provider"
    CI: "false"

phases:
  install:
    runtime-versions:
      nodejs: 18
    commands:
      - npm ci
  build:
    commands:
      - npm run build
      - test -f build/appspec.yml
      - test -f build/scripts/install.sh
      - test -f build/scripts/start.sh
artifacts:
  base-directory: build
  files:
    - '**/*'
YAML

BUILDSPEC_JSON="$(python3 -c 'import json; print(json.dumps(open("/tmp/buildspec-appmodulo10.yml").read()))')"

cat > /tmp/codebuild-project-appmodulo10.json <<JSON
{
  "name": "$CODEBUILD_PROJECT_NAME",
  "source": {
    "type": "CODEPIPELINE",
    "buildspec": $BUILDSPEC_JSON
  },
  "artifacts": {
    "type": "CODEPIPELINE"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": false
  },
  "serviceRole": "$CODEBUILD_ROLE_ARN"
}
JSON

if aws codebuild batch-get-projects \
  --region "$REGION" \
  --names "$CODEBUILD_PROJECT_NAME" \
  --query "projects[0].name" \
  --output text | grep -q "$CODEBUILD_PROJECT_NAME"; then
  aws codebuild update-project \
    --region "$REGION" \
    --cli-input-json file:///tmp/codebuild-project-appmodulo10.json >/dev/null
else
  aws codebuild create-project \
    --region "$REGION" \
    --cli-input-json file:///tmp/codebuild-project-appmodulo10.json >/dev/null
fi

echo "Preparando conexao GitHub via CodeStar/CodeConnections..."
if [[ -z "${CONNECTION_ARN:-}" ]]; then
  CONNECTION_ARN="$(aws codestar-connections list-connections \
    --region "$REGION" \
    --provider-type GitHub \
    --query "Connections[?ConnectionName=='$CONNECTION_NAME'].ConnectionArn | [0]" \
    --output text 2>/dev/null || true)"
fi

if [[ -z "$CONNECTION_ARN" || "$CONNECTION_ARN" == "None" ]]; then
  CONNECTION_ARN="$(aws codestar-connections create-connection \
    --region "$REGION" \
    --provider-type GitHub \
    --connection-name "$CONNECTION_NAME" \
    --query "ConnectionArn" \
    --output text)"
fi

CONNECTION_STATUS="$(aws codestar-connections get-connection \
  --region "$REGION" \
  --connection-arn "$CONNECTION_ARN" \
  --query "Connection.ConnectionStatus" \
  --output text)"

echo "Connection ARN: $CONNECTION_ARN"
echo "Connection status: $CONNECTION_STATUS"

if [[ "$CONNECTION_STATUS" != "AVAILABLE" ]]; then
  echo ""
  echo "A conexao GitHub ainda precisa ser autorizada no console AWS."
  echo "Abra: Developer Tools > Settings > Connections"
  echo "Regiao: $REGION"
  echo "Conexao: $CONNECTION_NAME"
  echo "Clique em 'Update pending connection' e autorize o GitHub."
  echo "Depois execute este script novamente."
  exit 1
fi

echo "Criando/atualizando role do CodePipeline..."
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

if ! aws iam get-role --role-name "$PIPELINE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$PIPELINE_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/codepipeline-trust-policy.json >/dev/null
fi

cat > /tmp/codepipeline-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation",
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$ARTIFACT_BUCKET",
        "arn:aws:s3:::$ARTIFACT_BUCKET/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codestar-connections:UseConnection"
      ],
      "Resource": "$CONNECTION_ARN"
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "codebuild:BatchGetProjects"
      ],
      "Resource": "arn:aws:codebuild:$REGION:$ACCOUNT_ID:project/$CODEBUILD_PROJECT_NAME"
    },
    {
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
    }
  ]
}
JSON

aws iam put-role-policy \
  --role-name "$PIPELINE_ROLE_NAME" \
  --policy-name "CodePipelineAccess-$PIPELINE_NAME" \
  --policy-document file:///tmp/codepipeline-policy.json

PIPELINE_ROLE_ARN="$(aws iam get-role \
  --role-name "$PIPELINE_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)"

PIPELINE_VERSION="1"
if aws codepipeline get-pipeline --region "$REGION" --name "$PIPELINE_NAME" >/dev/null 2>&1; then
  PIPELINE_VERSION="$(aws codepipeline get-pipeline \
    --region "$REGION" \
    --name "$PIPELINE_NAME" \
    --query "pipeline.version" \
    --output text)"
fi

cat > /tmp/pipeline-appmodulo10.json <<JSON
{
  "pipeline": {
    "name": "$PIPELINE_NAME",
    "roleArn": "$PIPELINE_ROLE_ARN",
    "artifactStore": {
      "type": "S3",
      "location": "$ARTIFACT_BUCKET"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "GitHub_Source",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "CodeStarSourceConnection",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ConnectionArn": "$CONNECTION_ARN",
              "FullRepositoryId": "$GITHUB_OWNER/$GITHUB_REPO",
              "BranchName": "$GITHUB_BRANCH",
              "DetectChanges": "true"
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
            "name": "React_Build",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ProjectName": "$CODEBUILD_PROJECT_NAME"
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
            "name": "CodeDeploy_EC2",
            "actionTypeId": {
              "category": "Deploy",
              "owner": "AWS",
              "provider": "CodeDeploy",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ApplicationName": "$CODEDEPLOY_APP_NAME",
              "DeploymentGroupName": "$CODEDEPLOY_GROUP_NAME"
            },
            "inputArtifacts": [
              {
                "name": "BuildArtifact"
              }
            ]
          }
        ]
      }
    ],
    "version": $PIPELINE_VERSION
  }
}
JSON

if aws codepipeline get-pipeline --region "$REGION" --name "$PIPELINE_NAME" >/dev/null 2>&1; then
  aws codepipeline update-pipeline \
    --region "$REGION" \
    --cli-input-json file:///tmp/pipeline-appmodulo10.json >/dev/null
else
  aws codepipeline create-pipeline \
    --region "$REGION" \
    --cli-input-json file:///tmp/pipeline-appmodulo10.json >/dev/null
fi

echo "Iniciando execucao da pipeline..."
EXECUTION_ID="$(aws codepipeline start-pipeline-execution \
  --region "$REGION" \
  --name "$PIPELINE_NAME" \
  --query "pipelineExecutionId" \
  --output text)"

echo ""
echo "Pipeline pronta."
echo "Pipeline: $PIPELINE_NAME"
echo "Execution ID: $EXECUTION_ID"
echo "GitHub: https://github.com/$GITHUB_OWNER/$GITHUB_REPO/tree/$GITHUB_BRANCH"
echo "CodeBuild: $CODEBUILD_PROJECT_NAME"
echo "CodeDeploy: $CODEDEPLOY_APP_NAME / $CODEDEPLOY_GROUP_NAME"
echo "EC2: $EC2_INSTANCE_ID"
echo ""
echo "Acompanhe com:"
echo "aws codepipeline get-pipeline-execution --region $REGION --pipeline-name $PIPELINE_NAME --pipeline-execution-id $EXECUTION_ID"
