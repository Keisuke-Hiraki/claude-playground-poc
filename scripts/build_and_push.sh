#!/bin/bash
# Build and push the gateway and per-user images to the ECR repositories
# created by Terraform. Run after `terraform apply` (repositories must
# already exist) and before the first `terraform apply` that references
# var.gateway_image_tag/var.user_image_tag — or just re-run this and let the
# ECS services pick up :latest on their next deployment.
set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-ap-northeast-1}"
PROFILE_ARGS=()
if [ -n "${AWS_PROFILE:-}" ]; then
  PROFILE_ARGS=(--profile "$AWS_PROFILE")
fi

ACCOUNT_ID=$(aws sts get-caller-identity "${PROFILE_ARGS[@]}" --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
PROJECT_NAME="${PROJECT_NAME:-claude-playground-poc}"

aws ecr get-login-password "${PROFILE_ARGS[@]}" --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "== building gateway image =="
docker buildx build --platform linux/amd64 \
  -t "${REGISTRY}/${PROJECT_NAME}-gateway:latest" \
  --push ./gateway

echo "== building per-user playground image =="
docker buildx build --platform linux/amd64 \
  -t "${REGISTRY}/${PROJECT_NAME}-user:latest" \
  --push ./docker

echo "done. Force a new ECS deployment to pick up the new gateway image:"
echo "  aws ecs update-service ${PROFILE_ARGS[*]} --region $REGION --cluster ${PROJECT_NAME} --service gateway --force-new-deployment"
