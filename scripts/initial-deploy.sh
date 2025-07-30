#!/bin/bash

# 初回デプロイスクリプト

set -e

# 変数設定
REGION=${AWS_REGION:-ap-northeast-1}
STACK_NAME=${STACK_NAME:-video-converter-lambda}
ENVIRONMENT=${ENVIRONMENT:-dev}

echo "=== 初回デプロイ開始 ==="
echo "Region: $REGION"
echo "Stack Name: $STACK_NAME"
echo "Environment: $ENVIRONMENT"

# 1. ECRリポジトリのみデプロイ
echo -e "\n=== ECRリポジトリのデプロイ ==="
aws cloudformation deploy \
    --template-file cloudformation/initial-deploy.yaml \
    --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
    --parameter-overrides Environment=${ENVIRONMENT} \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --region ${REGION}

# 2. ECR URIを取得
ECR_URI=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
    --output text \
    --region ${REGION})

echo "ECR URI: $ECR_URI"

# 3. ECRにログイン
echo -e "\n=== ECRにログイン ==="
aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_URI}

# 4. 初回用のダミーイメージをビルドしてプッシュ
echo -e "\n=== 初回用ダミーイメージのビルドとプッシュ ==="
docker build -f Dockerfile.init -t ${ECR_URI}:latest .
docker push ${ECR_URI}:latest

# 5. 失敗したスタックのクリーンアップ
echo -e "\n=== スタック状態の確認とクリーンアップ ==="
STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME}-${ENVIRONMENT} \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --region ${REGION} 2>/dev/null || echo "NOT_EXISTS")

echo "Current stack status: $STACK_STATUS"

if [ "$STACK_STATUS" = "ROLLBACK_COMPLETE" ]; then
    echo "Deleting failed stack..."
    aws cloudformation delete-stack \
        --stack-name ${STACK_NAME}-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name ${STACK_NAME}-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "Stack deletion completed"
fi

# 6. メインスタックのデプロイ
echo -e "\n=== メインスタックのデプロイ ==="
aws cloudformation deploy \
    --template-file cloudformation/template.yaml \
    --stack-name ${STACK_NAME}-${ENVIRONMENT} \
    --parameter-overrides Environment=${ENVIRONMENT} \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --region ${REGION}

# 7. FFmpegバイナリのダウンロード
echo -e "\n=== FFmpegバイナリのダウンロード ==="
mkdir -p bin
curl -L "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/linux-x64" -o bin/ffmpeg
chmod +x bin/ffmpeg

# 8. 本番用イメージのビルドとプッシュ
echo -e "\n=== 本番用イメージのビルドとプッシュ ==="
docker build -t ${ECR_URI}:latest .
docker push ${ECR_URI}:latest

# 9. Lambda関数の更新
echo -e "\n=== Lambda関数の更新 ==="
# Lambda関数をコンテナイメージで更新
aws lambda update-function-code \
    --function-name ${STACK_NAME}-${ENVIRONMENT}-video-converter \
    --image-uri ${ECR_URI}:latest \
    --region ${REGION} || {
    echo "Zip to Image conversion required. Updating function configuration..."
    
    # 設定をリセット
    aws lambda update-function-configuration \
        --function-name ${STACK_NAME}-${ENVIRONMENT}-video-converter \
        --timeout 900 \
        --memory-size 3008 \
        --region ${REGION}
    
    # コンテナイメージでコードを更新
    aws lambda update-function-code \
        --function-name ${STACK_NAME}-${ENVIRONMENT}-video-converter \
        --image-uri ${ECR_URI}:latest \
        --region ${REGION}
}

# 10. 出力情報の表示
echo -e "\n=== デプロイ完了 ==="
aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME}-${ENVIRONMENT} \
    --query 'Stacks[0].Outputs' \
    --output table \
    --region ${REGION}