# autoresearch on AWS — Deployment Scripts

Scripts for running [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) on AWS with SSM Session Manager and Amazon Bedrock.

## What These Scripts Do

| Script | Purpose |
|--------|---------|
| `setup.sh` | Creates IAM Role, security group, launches GPU instance, installs everything |
| `connect.sh` | Finds the running instance and opens an SSM session |
| `cleanup.sh` | Terminates instance and deletes all created AWS resources |

## Architecture

```
┌─────────────────┐     SSM Session Manager     ┌──────────────────────────┐
│   Your MacBook   │ ◄──────────────────────────► │   EC2 g5.xlarge          │
│                  │     (no SSH, no open ports)  │   NVIDIA A10G 24GB       │
│   AWS CLI        │                              │                          │
│   SSM Plugin     │                              │   Claude Code            │
└─────────────────┘                               │     ↕ (Instance Role)    │
                                                  │   Amazon Bedrock         │
                                                  │     Claude Sonnet 4.6    │
                                                  │                          │
                                                  │   autoresearch           │
                                                  │     train.py (agent)     │
                                                  │     program.md (human)   │
                                                  │     prepare.py (fixed)   │
                                                  └──────────────────────────┘
```

## Prerequisites

1. **AWS CLI v2** configured with credentials that have permissions for EC2, IAM, SSM, and Bedrock
2. **SSM Session Manager Plugin** installed on your local machine
   ```bash
   # macOS
   brew install --cask session-manager-plugin
   ```
3. **Claude models enabled in Bedrock** — submit the use case form once in the Bedrock console

## Quick Start

```bash
# Make scripts executable
chmod +x setup.sh connect.sh cleanup.sh

# 1. Launch everything
./setup.sh

# 2. Connect to the instance
./connect.sh

# 3. On the instance — start autoresearch
sudo -u ubuntu -i
cd autoresearch
tmux new -s research
claude --dangerously-skip-permissions
# Type: Hi have a look at program.md and let's kick off a new experiment!

# 4. Detach tmux and go to sleep
# Ctrl+B, D

# 5. Next morning — check results
./connect.sh
sudo -u ubuntu -i
cd autoresearch
cat results.tsv
git log --oneline

# 6. When done — clean up everything
./cleanup.sh
```

## Configuration

All scripts accept environment variables to override defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `REGION` | `us-west-2` | AWS region |
| `INSTANCE_TYPE` | `g5.xlarge` | EC2 instance type |
| `VOLUME_SIZE` | `100` | EBS volume size in GB |
| `INSTANCE_NAME` | `autoresearch-g5` | Name tag for the instance |
| `BEDROCK_PRIMARY_MODEL` | `us.anthropic.claude-sonnet-4-6` | Primary Claude model |
| `BEDROCK_OPUS_MODEL` | `us.anthropic.claude-opus-4-6-v1` | Opus model for complex reasoning |

Example — use a different region and instance type:
```bash
REGION=us-east-1 INSTANCE_TYPE=g6e.xlarge ./setup.sh
```

## Instance Type Options

| Instance | GPU | VRAM | On-Demand | Notes |
|----------|-----|------|-----------|-------|
| `g5.xlarge` | A10G | 24 GB | ~$1.24/hr | Budget option, needs smaller model config |
| `g6e.xlarge` | L40S | 48 GB | ~$2.19/hr | Can run default autoresearch config |
| `p5.4xlarge` | H100 | 80 GB | ~$7.91/hr | Full reproduction of Karpathy's setup |

For 24GB GPUs (g5, g6), Claude Code will automatically scale down the model (DEPTH=4, smaller batch) to fit in VRAM.

## AMI Details

The script auto-detects the latest **Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.x (Ubuntu 22.04)** in your target region.

**Pre-installed:** Ubuntu 22.04, NVIDIA drivers, CUDA 12.x, PyTorch 2.x, Python 3.10+, SSM Agent

**Installed by User Data:** uv, Node.js 22.x, Claude Code, autoresearch repo + dependencies

**⚠️ Note:** cloud-init on the Deep Learning AMI takes 15-20 minutes on first boot. The SSM Agent comes online in ~30 seconds, so you can connect and install manually if you prefer not to wait.

## Cost Estimate

For an overnight run (~8-10 hours, ~100 experiments):

| Item | Cost |
|------|------|
| EC2 g5.xlarge (10h × $1.24/hr) | ~$12 |
| Bedrock API (Claude Sonnet 4.6) | ~$8-12 |
| **Total** | **~$20-24** |

## Security

- **Zero inbound ports** — the security group has no inbound rules
- **SSM Session Manager** — connections go through AWS APIs, not SSH
- **Instance Role** — Bedrock credentials are acquired automatically, no API keys stored on disk
- **IMDSv2 enforced** — instance metadata requires token-based access

## License

MIT
