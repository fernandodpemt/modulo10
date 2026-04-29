param(
  [string]$Region = "",
  [string]$Bucket = "modulo10fernandolopes",
  [string]$ApplicationName = "appmodulo10",
  [string]$DeploymentGroupName = "appmodulo10"
)

$ErrorActionPreference = "Stop"

if (-not $Region) {
  $Region = (aws configure get region)
}

if (-not $Region) {
  throw "Informe a regiao com -Region ou configure com: aws configure set region <sua-regiao>"
}

$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$bundleName = "$ApplicationName-$timestamp.zip"
$bundlePath = Join-Path $PSScriptRoot $bundleName
$s3Key = "codedeploy/$bundleName"

Write-Host "Gerando build de producao..."
$env:NODE_OPTIONS = "--openssl-legacy-provider"
npm run build

Write-Host "Criando pacote $bundleName..."
if (Test-Path $bundlePath) {
  Remove-Item $bundlePath -Force
}
Compress-Archive -Path (Join-Path $PSScriptRoot "build\*") -DestinationPath $bundlePath -Force

Write-Host "Enviando para s3://$Bucket/$s3Key..."
aws s3 cp $bundlePath "s3://$Bucket/$s3Key" --region $Region

Write-Host "Criando implantacao no CodeDeploy..."
$deploymentId = aws deploy create-deployment `
  --application-name $ApplicationName `
  --deployment-group-name $DeploymentGroupName `
  --deployment-config-name CodeDeployDefault.AllAtOnce `
  --s3-location bucket=$Bucket,key=$s3Key,bundleType=zip `
  --region $Region `
  --query "deploymentId" `
  --output text

Write-Host "Deployment criado: $deploymentId"
Write-Host "Acompanhe com:"
Write-Host "aws deploy get-deployment --deployment-id $deploymentId --region $Region"
