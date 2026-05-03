#!/bin/bash
# =============================================================================
# autoresearch on AWS — One-Click Setup
# =============================================================================
#
# Launches a GPU EC2 instance with SSM Session Manager + Amazon Bedrock
# for running Karpathy's autoresearch experiment autonomously.
#
# What this script does:
#   1. Creates an IAM Role with SSM + Bedrock permissions
#   2. Creates a security group with zero inbound ports
#   3. Launches a GPU instance with Deep Learning AMI
#   4. Installs uv, Node.js, Claude Code, and clones autoresearch via User Data
#   5. Waits for SSM Agent to come online
#
# Prerequisites:
#   - AWS CLI v2 configured with appropriate permissions
#   - SSM Session Manager Plugin installed locally
#     (https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
#   - Claude models enabled in Amazon Bedrock (submit use case form once)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh                          # Use defaults (g5.xlarge, us-west-2)
#   REGION=us-east-1 ./setup.sh         # Override region
#   INSTANCE_TYPE=g6e.xlarge ./setup.sh # Use L40S 48GB instead
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------
REGION="${REGION:-us-west-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"                    # GB, EBS gp3
INSTANCE_NAME="${INSTANCE_NAME:-autoresearch-g5}"
ROLE_NAME="${ROLE_NAME:-autoresearch-ssm-role}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-autoresearch-ssm-profile}"
SG_NAME="${SG_NAME:-autoresearch-ssm-sg}"
BEDROCK_POLICY_NAME="${BEDROCK_POLICY_NAME:-autoresearch-bedrock-policy}"

# Bedrock model configuration for Claude Code
BEDROCK_PRIMARY_MODEL="${BEDROCK_PRIMARY_MODEL:-us.anthropic.claude-sonnet-4-6}"
BEDROCK_OPUS_MODEL="${BEDROCK_OPUS_MODEL:-us.anthropic.claude-opus-4-6-v1}"

# ---------------------------------------------------------------------------
# Auto-detect AMI — find the latest Deep Learning AMI for the target region
# ---------------------------------------------------------------------------
echo "============================================"
echo " autoresearch AWS Setup"
echo " Instance:  $INSTANCE_TYPE"
echo " Region:    $REGION"
echo " Connect:   SSM Session Manager"
echo " AI Agent:  Claude Code via Bedrock"
echo "============================================"
echo ""

echo "[0/5] Finding latest Deep Learning AMI in $REGION ..."
AMI_ID=$(aws ec2 describe-images --region "$REGION" \
  --owners amazon \
  --filters \
    "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2*Ubuntu 22.04*" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text 2>/dev/null)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  echo "  ❌ No Deep Learning AMI found in $REGION."
  echo "     Try a different region (us-east-1, us-west-2 usually have it)."
  exit 1
fi
echo "  AMI: $AMI_ID"

# ---------------------------------------------------------------------------
# 1. IAM Role (SSM + Bedrock)
# ---------------------------------------------------------------------------
echo ""
echo "[1/5] Creating IAM Role: $ROLE_NAME ..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}'

BEDROCK_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockModelAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*",
        "arn:aws:bedrock:*:*:foundation-model/*"
      ]
    },
    {
      "Sid": "BedrockMarketplace",
      "Effect": "Allow",
      "Action": [
        "aws-marketplace:ViewSubscriptions",
        "aws-marketplace:Subscribe"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:CalledViaLast": "bedrock.amazonaws.com"
        }
      }
    }
  ]
}'

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "  Role already exists, skipping creation"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "autoresearch EC2 role for SSM + Bedrock access" >/dev/null

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  echo "  Created Role and attached AmazonSSMManagedInstanceCore"
fi

# Always update Bedrock inline policy (idempotent)
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$BEDROCK_POLICY_NAME" \
  --policy-document "$BEDROCK_POLICY"
echo "  Bedrock inline policy attached"

# Instance Profile
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "  Instance Profile already exists, skipping"
else
  aws iam create-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null
  echo "  Created Instance Profile, waiting 10s for propagation ..."
  sleep 10
fi

# ---------------------------------------------------------------------------
# 2. Security Group (zero inbound ports)
# ---------------------------------------------------------------------------
echo ""
echo "[2/5] Creating Security Group: $SG_NAME ..."

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null) || true
SG_ID=$(echo "$SG_ID" | tr -d '[:space:]')

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  echo "  Security group $SG_NAME ($SG_ID) already exists, skipping"
else
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "autoresearch - SSM only, no inbound ports" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query "GroupId" --output text)
  echo "  Created security group $SG_ID (no inbound rules)"
fi

# ---------------------------------------------------------------------------
# 3. User Data (bootstrap script)
# ---------------------------------------------------------------------------
echo ""
echo "[3/5] Preparing User Data bootstrap script ..."

# Note: cloud-init on Deep Learning AMI can take 15-20 min on first boot.
# The script waits for it, but you can connect via SSM and install manually
# if you don't want to wait.
USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -e
exec > /var/log/autoresearch-setup.log 2>&1
echo "=== autoresearch setup started at \$(date) ==="

cloud-init status --wait

# Install Node.js 22.x (required by Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Switch to ubuntu user for remaining setup
sudo -u ubuntu bash <<'EOF'
cd /home/ubuntu

# Install uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="\$HOME/.local/bin:\$PATH"

# Clone autoresearch
git clone https://github.com/karpathy/autoresearch.git
cd autoresearch

# Install Python dependencies
/home/ubuntu/.local/bin/uv sync

# Configure Claude Code to use Bedrock
mkdir -p /home/ubuntu/.claude
cat > /home/ubuntu/.claude/.env <<'ENVFILE'
CLAUDE_CODE_USE_BEDROCK=1
AWS_REGION=${REGION}
ANTHROPIC_MODEL=${BEDROCK_PRIMARY_MODEL}
ANTHROPIC_DEFAULT_SONNET_MODEL=${BEDROCK_PRIMARY_MODEL}
ANTHROPIC_DEFAULT_OPUS_MODEL=${BEDROCK_OPUS_MODEL}
ENVFILE

echo "=== autoresearch setup completed at \$(date) ==="
echo "READY" > /home/ubuntu/autoresearch/.setup-complete
EOF
USERDATA
)

USER_DATA_B64=$(echo "$USER_DATA" | base64)

# ---------------------------------------------------------------------------
# 4. Launch instance
# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Launching EC2 instance ..."

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "$USER_DATA_B64" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "  Instance ID: $INSTANCE_ID"
echo "  Waiting for instance to start ..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "  Instance is running!"

# ---------------------------------------------------------------------------
# 5. Wait for SSM Agent
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Waiting for SSM Agent ..."

MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  SSM_STATUS=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || echo "None")

  if [ "$SSM_STATUS" = "Online" ]; then
    echo "  SSM Agent is online!"
    break
  fi

  echo "  Waiting ... ($WAITED/${MAX_WAIT}s)"
  sleep 10
  WAITED=$((WAITED + 10))
done

if [ "$SSM_STATUS" != "Online" ]; then
  echo "  ⚠️  SSM Agent not online within ${MAX_WAIT}s. It may need more time."
  echo "  Check manually: aws ssm describe-instance-information --filters Key=InstanceIds,Values=$INSTANCE_ID"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " ✅ Setup complete!"
echo "============================================"
echo ""
echo " Instance ID:  $INSTANCE_ID"
echo " Instance:     $INSTANCE_TYPE"
echo " AMI:          $AMI_ID"
echo " Security:     $SG_ID (no inbound ports)"
echo " Connection:   SSM Session Manager"
echo ""
echo " Connect:"
echo "   aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo " After connecting:"
echo "   sudo -u ubuntu -i"
echo "   cd autoresearch"
echo "   cat .setup-complete          # Confirm setup finished (may take a few min)"
echo "   nvidia-smi                   # Confirm GPU is available"
echo ""
echo " Start autoresearch:"
echo "   tmux new -s research"
echo "   cd ~/autoresearch"
echo "   claude --dangerously-skip-permissions"
echo "   # Then type: Hi have a look at program.md and let's kick off a new experiment!"
echo ""
echo " ⚠️  Stop instance when done (\$1.24/hr for g5.xlarge):"
echo "   aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION"
echo ""
echo " 🗑️  Full cleanup:"
echo "   ./cleanup.sh"
echo "============================================"
