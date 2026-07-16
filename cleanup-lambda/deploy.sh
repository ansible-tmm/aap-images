#!/bin/bash
set -euo pipefail

FUNCTION_NAME="aap-expired-instance-cleanup"
ROLE_NAME="aap-expired-instance-cleanup-role"
RULE_NAME="aap-expired-instance-cleanup-schedule"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Deploying to account $ACCOUNT_ID in $REGION"

# 1. Create IAM role
echo "Creating IAM role..."
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' --no-cli-pager

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${FUNCTION_NAME}-policy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ec2:DescribeInstances",
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": "ec2:TerminateInstances",
        "Resource": "*",
        "Condition": {
          "StringEquals": {
            "ec2:ResourceTag/Project": "aap-on-demand"
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource": "arn:aws:logs:*:*:*"
      }
    ]
  }' --no-cli-pager

echo "Waiting for role to propagate..."
sleep 10

# 2. Package and create Lambda
echo "Packaging Lambda..."
cd "$(dirname "$0")"
zip -j /tmp/cleanup-lambda.zip lambda_function.py

echo "Creating Lambda function (DRY_RUN=true by default)..."
aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime python3.12 \
  --handler lambda_function.lambda_handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
  --zip-file fileb:///tmp/cleanup-lambda.zip \
  --timeout 60 \
  --environment "Variables={DRY_RUN=true}" \
  --no-cli-pager

rm -f /tmp/cleanup-lambda.zip

echo ""
echo "Deployed in DRY RUN mode (no EventBridge schedule yet)."
echo ""
echo "Test it now:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --payload '{\"dry_run\":\"true\"}' --cli-binary-format raw-in-base64-out /dev/stdout"
echo ""
echo "When ready to go live, run:"
echo "  cd $(pwd) && ./enable-live.sh"
