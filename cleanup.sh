#!/bin/bash
# =============================================================================
# Cleanup all autoresearch AWS resources
# =============================================================================
#
# Removes: EC2 instance, security group, IAM Instance Profile, IAM Role
# (including the Bedrock inline policy).
#
# Usage:
#   ./cleanup.sh                          # Use defaults
#   REGION=us-east-1 ./cleanup.sh         # Override region
#
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-autoresearch-g5}"
ROLE_NAME="${ROLE_NAME:-autoresearch-ssm-role}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-autoresearch-ssm-profile}"
SG_NAME="${SG_NAME:-autoresearch-ssm-sg}"
BEDROCK_POLICY_NAME="${BEDROCK_POLICY_NAME:-autoresearch-bedrock-policy}"

echo "============================================"
echo " autoresearch AWS Cleanup"
echo " Region: $REGION"
echo "============================================"
echo ""
read -p "⚠️  Delete ALL autoresearch resources? (y/N) " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

# 1. Terminate instance
echo ""
echo "[1/4] Terminating EC2 instance ..."
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null || echo "None")

if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
  echo "  Terminating $INSTANCE_ID ..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
  echo "  Done."
else
  echo "  No instance found, skipping."
fi

# 2. Delete security group
echo ""
echo "[2/4] Deleting security group ..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
  echo "  Deleted security group $SG_ID"
else
  echo "  No security group found, skipping."
fi

# 3. Delete Instance Profile
echo ""
echo "[3/4] Deleting IAM Instance Profile ..."
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME"
  echo "  Deleted Instance Profile."
else
  echo "  No Instance Profile found, skipping."
fi

# 4. Delete IAM Role (detach policies first)
echo ""
echo "[4/4] Deleting IAM Role ..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # Detach managed policy
  aws iam detach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  # Delete inline Bedrock policy
  aws iam delete-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$BEDROCK_POLICY_NAME" 2>/dev/null || true
  # Delete role
  aws iam delete-role --role-name "$ROLE_NAME"
  echo "  Deleted Role $ROLE_NAME (including Bedrock inline policy)."
else
  echo "  No Role found, skipping."
fi

echo ""
echo "============================================"
echo " ✅ Cleanup complete!"
echo "============================================"
