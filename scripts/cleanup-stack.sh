#!/bin/bash

# CloudFormationスタックのクリーンアップスクリプト

set -e

# 変数設定
REGION=${AWS_REGION:-ap-northeast-1}
STACK_NAME=${STACK_NAME:-video-converter-lambda}
ENVIRONMENT=${ENVIRONMENT:-dev}

echo "=== CloudFormationスタックのクリーンアップ ==="
echo "Region: $REGION"
echo "Stack Name: $STACK_NAME-$ENVIRONMENT"

# メインスタックの状態確認と削除
echo -e "\n=== メインスタックの確認 ==="
MAIN_STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME}-${ENVIRONMENT} \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --region ${REGION} 2>/dev/null || echo "NOT_EXISTS")

echo "Main stack status: $MAIN_STACK_STATUS"

if [ "$MAIN_STACK_STATUS" != "NOT_EXISTS" ]; then
    echo "Deleting main stack..."
    aws cloudformation delete-stack \
        --stack-name ${STACK_NAME}-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "Waiting for main stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name ${STACK_NAME}-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "Main stack deletion completed"
fi

# ECRスタックの状態確認と削除
echo -e "\n=== ECRスタックの確認 ==="
ECR_STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
    --query 'Stacks[0].StackStatus' \
    --output text \
    --region ${REGION} 2>/dev/null || echo "NOT_EXISTS")

echo "ECR stack status: $ECR_STACK_STATUS"

if [ "$ECR_STACK_STATUS" != "NOT_EXISTS" ]; then
    # ECRリポジトリ内のイメージを削除
    ECR_URI=$(aws cloudformation describe-stacks \
        --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
        --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
        --output text \
        --region ${REGION} 2>/dev/null || echo "")
    
    if [ -n "$ECR_URI" ]; then
        REPO_NAME=$(echo $ECR_URI | cut -d'/' -f2)
        echo "Deleting ECR images in repository: $REPO_NAME"
        
        # すべてのイメージを削除
        aws ecr list-images \
            --repository-name $REPO_NAME \
            --region ${REGION} \
            --query 'imageIds[*]' \
            --output json | jq -r '.[] | @base64' | while read img; do
                IMAGE_DIGEST=$(echo $img | base64 -d | jq -r '.imageDigest // empty')
                IMAGE_TAG=$(echo $img | base64 -d | jq -r '.imageTag // empty')
                
                if [ -n "$IMAGE_DIGEST" ]; then
                    aws ecr batch-delete-image \
                        --repository-name $REPO_NAME \
                        --image-ids imageDigest=$IMAGE_DIGEST \
                        --region ${REGION} >/dev/null 2>&1 || true
                elif [ -n "$IMAGE_TAG" ]; then
                    aws ecr batch-delete-image \
                        --repository-name $REPO_NAME \
                        --image-ids imageTag=$IMAGE_TAG \
                        --region ${REGION} >/dev/null 2>&1 || true
                fi
            done
    fi
    
    echo "Deleting ECR stack..."
    aws cloudformation delete-stack \
        --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "Waiting for ECR stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name ${STACK_NAME}-ecr-${ENVIRONMENT} \
        --region ${REGION}
    
    echo "ECR stack deletion completed"
fi

echo -e "\n=== クリーンアップ完了 ==="