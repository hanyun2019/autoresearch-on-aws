#!/bin/bash
# =============================================================================
# Connect to autoresearch instance via SSM Session Manager
# =============================================================================
#
# Finds the running autoresearch instance by Name tag and opens an SSM session.
#
# Usage:
#   ./connect.sh                          # Use defaults
#   REGION=us-east-1 ./connect.sh         # Override region
#
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-autoresearch-g5}"

# Find instance ID by Name tag
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "❌ No running instance found with Name=$INSTANCE_NAME in $REGION"
  echo ""
  echo "Possible causes:"
  echo "  1. Instance not launched — run ./setup.sh first"
  echo "  2. Instance stopped — start it:"
  echo "     aws ec2 start-instances --instance-ids <id> --region $REGION"
  echo "  3. Wrong region — set REGION=<your-region> ./connect.sh"
  exit 1
fi

echo "🔗 Connecting to $INSTANCE_NAME ($INSTANCE_ID) in $REGION ..."
echo "   Tip: Run 'sudo -u ubuntu -i' after connecting to switch to the ubuntu user"
echo ""

aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
