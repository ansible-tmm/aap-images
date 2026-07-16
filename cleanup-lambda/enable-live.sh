#!/bin/bash
set -euo pipefail

FUNCTION_NAME="aap-expired-instance-cleanup"
RULE_NAME="aap-expired-instance-cleanup-schedule"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Switching Lambda to LIVE mode and enabling hourly schedule..."

# Flip DRY_RUN to false
aws lambda update-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --environment "Variables={DRY_RUN=false}" \
  --no-cli-pager

# Create EventBridge rule (every hour)
aws events put-rule \
  --name "$RULE_NAME" \
  --schedule-expression "rate(1 hour)" \
  --state ENABLED \
  --no-cli-pager

# Allow EventBridge to invoke Lambda
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "${RULE_NAME}-invoke" \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}" \
  --no-cli-pager 2>/dev/null || echo "(permission already exists)"

# Add Lambda as target
aws events put-targets \
  --rule "$RULE_NAME" \
  --targets "Id=1,Arn=arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}" \
  --no-cli-pager

echo "Done. Lambda is now LIVE and will terminate expired aap-on-demand instances every hour."
