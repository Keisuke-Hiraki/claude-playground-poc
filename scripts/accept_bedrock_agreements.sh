#!/bin/bash
# Accept the AWS Marketplace agreement for each approved Bedrock model.
#
# Why this is a separate script and not Terraform: create-foundation-model-agreement
# consumes a one-time offer token fetched via list-foundation-model-agreement-offers.
# Without this, Claude Code's first Bedrock call fails with:
#   "API Error: 403 Model access is denied due to IAM user or service role is not
#    authorized to perform the required AWS Marketplace actions ..."
# which looks like a hang/retry loop in the CLI before it surfaces, not a deploy-time
# error — so it's easy to miss. Run this once per account/region before first use,
# and again for any new model you add to variables.tf.
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
PROFILE_ARGS=()
if [ -n "${AWS_PROFILE:-}" ]; then
  PROFILE_ARGS=(--profile "$AWS_PROFILE")
fi

MODEL_IDS=(
  "anthropic.claude-opus-4-6-v1"
  "anthropic.claude-sonnet-5"
  "anthropic.claude-haiku-4-5-20251001-v1:0"
)

for model_id in "${MODEL_IDS[@]}"; do
  status=$(aws bedrock get-foundation-model-availability "${PROFILE_ARGS[@]}" --region "$REGION" \
    --model-id "$model_id" --query 'agreementAvailability.status' --output text 2>/dev/null || echo "UNKNOWN")

  if [ "$status" = "AVAILABLE" ]; then
    echo "== $model_id: already AVAILABLE, skipping =="
    continue
  fi

  echo "== $model_id: accepting Marketplace agreement (was: $status) =="
  offer_token=$(aws bedrock list-foundation-model-agreement-offers "${PROFILE_ARGS[@]}" --region "$REGION" \
    --model-id "$model_id" --query 'offers[0].offerToken' --output text)
  aws bedrock create-foundation-model-agreement "${PROFILE_ARGS[@]}" --region "$REGION" \
    --offer-token "$offer_token" --model-id "$model_id" >/dev/null
  echo "   submitted (status may show PENDING for a short while)"
done

echo
echo "Final status:"
for model_id in "${MODEL_IDS[@]}"; do
  status=$(aws bedrock get-foundation-model-availability "${PROFILE_ARGS[@]}" --region "$REGION" \
    --model-id "$model_id" --query 'agreementAvailability.status' --output text 2>/dev/null || echo "UNKNOWN")
  echo "  $model_id: $status"
done
