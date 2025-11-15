# Terraform Drift AI Detector

🤖 **AI-Powered Drift Detection** | 🔄 **Automated Monitoring** | 📊 **Smart Notifications**

Automated Terraform drift detection using Argo Workflows, with AI-powered summaries via AWS Bedrock and intelligent Slack notifications. Runs on Kubernetes for scheduled infrastructure monitoring.

## 🌟 Features

### 🔍 **Intelligent Drift Detection**
- **Automated Scanning**: Scheduled cron workflows for continuous monitoring
- **Multi-Environment Support**: Scan across multiple Terraform workspaces/environments
- **Targeted Detection**: Option to scan specific modules or full infrastructure
- **Threshold-Based Alerting**: Only notify when drift exceeds configured thresholds

### 🤖 **AI-Powered Analysis**
- **AWS Bedrock Integration**: Uses Claude AI for intelligent plan summarization
- **Structured Summaries**: Consistent, actionable drift reports
- **Risk Assessment**: Automatic classification of changes (None/Destructive/Replacement/Mixed)
- **Action Recommendations**: Suggests next steps based on drift analysis

### 📱 **Smart Notifications**
- **Slack Integration**: Rich formatted notifications with drift details
- **Configurable Thresholds**: Only alert when changes exceed your threshold
- **Environment Grouping**: Organized reports by environment
- **Failure Alerts**: Automatic notification on workflow failures

### ⚙️ **Kubernetes Native**
- **Argo Workflows**: Leverages battle-tested workflow orchestration
- **GitOps Ready**: All configurations in YAML for version control
- **RBAC Support**: Proper Kubernetes security with service accounts
- **Persistent Caching**: Terraform plugin cache for faster execution

## 🏗️ Architecture

```
┌─────────────────┐
│  Argo Workflow  │  ← Scheduled via CronWorkflow
│   (Kubernetes)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Container Job  │
│  ┌───────────┐  │
│  │ Terraform │  │  ← Clone repo, run plan
│  └───────────┘  │
│  ┌───────────┐  │
│  │  Bedrock  │  │  ← AI summarization
│  └───────────┘  │
│  ┌───────────┐  │
│  │   Slack   │  │  ← Send notification
│  └───────────┘  │
└─────────────────┘
```

**Workflow Steps:**
1. **Authenticate** with GitHub App
2. **Clone** infrastructure repository
3. **Initialize** Terraform in each environment
4. **Execute** `terraform plan` across workspaces
5. **Analyze** changes with AI (AWS Bedrock Claude)
6. **Evaluate** against drift threshold
7. **Notify** via Slack if threshold exceeded

## 🚀 Quick Start

### Prerequisites

- **Kubernetes Cluster** (1.19+)
- **Argo Workflows** installed
- **AWS Account** with Bedrock access
- **GitHub App** for repository authentication
- **Slack Webhook** for notifications

### 1. Clone Repository

```bash
git clone https://github.com/YOUR_USERNAME/terraform-drift-ai-detector.git
cd terraform-drift-ai-detector
```

### 2. Build Docker Image

```bash
# Build the image
docker build -t terraform-drift-detector:latest .

# Tag and push to your registry
docker tag terraform-drift-detector:latest YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/terraform-drift:latest
docker push YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/terraform-drift:latest
```

### 3. Configure Kubernetes Secrets

```bash
# Create namespace
kubectl create namespace terraform-drift

# Create secret with sensitive values
kubectl create secret generic terraform-drift-secrets \
  --from-literal=GITHUB_APP_ID="your_app_id" \
  --from-literal=GITHUB_ORG="your_org" \
  --from-literal=GITHUB_REPO="your_repo" \
  --from-literal=SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK" \
  --from-file=GITHUB_APP_PRIVATE_KEY=./github-app-key.pem \
  -n terraform-drift
```

### 4. Deploy to Kubernetes

```bash
# Apply all configurations
kubectl apply -f argo-workflows/configmap.yaml
kubectl apply -f argo-workflows/pvc.yaml
kubectl apply -f argo-workflows/rbac.yaml
kubectl apply -f argo-workflows/base-template.yaml
kubectl apply -f argo-workflows/cronworkflow.yaml
```

### 5. Verify Deployment

```bash
# Check workflow status
kubectl get cronworkflows -n terraform-drift

# View workflow runs
kubectl get workflows -n terraform-drift

# Check logs
kubectl logs -n terraform-drift -l workflows.argoproj.io/workflow
```

## 📋 Configuration

### Environment Variables

Key configuration options (see [.env.example](.env.example)):

| Variable | Description | Default |
|----------|-------------|---------|
| `GITHUB_APP_ID` | GitHub App ID | Required |
| `GITHUB_ORG` | GitHub organization | Required |
| `GITHUB_REPO` | Repository name | Required |
| `TERRAFORM_PATH` | Path to Terraform code | `terraform/environments` |
| `DRIFT_THRESHOLD` | Minimum changes to notify | `0` (always notify) |
| `BEDROCK_MODEL_ID` | AI model to use | `anthropic.claude-3-5-sonnet-*` |
| `SLACK_WEBHOOK_URL` | Slack webhook URL | Required |

### Drift Threshold Examples

```yaml
# Never skip notifications (notify on any changes)
DRIFT_THRESHOLD: "0"

# Only notify if 5+ resources changed
DRIFT_THRESHOLD: "5"

# Only notify on significant drift (10+ changes)
DRIFT_THRESHOLD: "10"
```

### Schedule Configuration

Update the cron schedule in `argo-workflows/cronworkflow.yaml`:

```yaml
spec:
  schedule: "0 6 * * *"  # Daily at 6 AM UTC
  # schedule: "0 */6 * * *"  # Every 6 hours
  # schedule: "0 9 * * 1-5"  # Weekdays at 9 AM
```

## 🔧 Usage

### Manual Trigger

```bash
# Trigger a drift detection run manually
argo submit --from cronworkflow/terraform-drift-detector -n terraform-drift

# Watch the workflow
argo watch @latest -n terraform-drift
```

### View Workflow History

```bash
# List recent workflows
argo list -n terraform-drift

# Get workflow details
argo get WORKFLOW_NAME -n terraform-drift

# View logs
argo logs WORKFLOW_NAME -n terraform-drift
```

### Local Testing

```bash
# Set environment variables
cp .env.example .env
# Edit .env with your values

# Run locally with Docker
docker run --rm \
  --env-file .env \
  -v $(pwd)/github-key.pem:/tmp/github-app-private-key.pem \
  terraform-drift-detector:latest \
  /tmp/scripts/detect-drift.sh full
```

## 📊 Output Examples

### Slack Notification Format

```
Terraform Full Drift Detection

Environment: production

Terraform Plan Drift Summary (domain: production)
- Resources to add: 3
- Resources to change: 7
- Resources to destroy: 0
- Risk: Replacement
- Action: Investigate

Environment: staging

Terraform Plan Drift Summary (domain: staging)
- Resources to add: 0
- Resources to change: 2
- Resources to destroy: 0
- Risk: None
- Action: Apply

Summary: 12 total changes across 2 environment(s)
```

## 🔒 Security

### AWS IAM Permissions

Minimum required IAM policy for Bedrock:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel"
      ],
      "Resource": "arn:aws:bedrock:*:*:foundation-model/*"
    }
  ]
}
```

### GitHub App Permissions

Required GitHub App permissions:
- **Contents**: Read-only
- **Metadata**: Read-only

### Kubernetes RBAC

The workflow uses a dedicated service account with minimal permissions:
- Read secrets: `terraform-drift-secrets`
- Read configmaps: `terraform-drift-config`
- Read PVCs: `terraform-drift-pvc`

## 🛠️ Troubleshooting

### Common Issues

**Workflow fails with "Installation ID not found"**
- Ensure GitHub App is installed in your organization
- Verify `GITHUB_ORG` matches the App installation

**No Slack notifications received**
- Check `SLACK_WEBHOOK_URL` is correct
- Verify drift threshold (`DRIFT_THRESHOLD`) isn't too high
- Check workflow logs for errors

**Terraform init fails**
- Ensure PVC has enough space for provider cache
- Check network connectivity from pods
- Verify Terraform version compatibility

**Bedrock errors**
- Confirm Bedrock model access in your AWS region
- Check IAM permissions for service account
- Verify model ID is correct for your region

### Debug Mode

Enable verbose logging:

```bash
# View detailed logs
argo logs -n terraform-drift WORKFLOW_NAME --follow

# Check pod events
kubectl describe pod -n terraform-drift POD_NAME

# View Terraform output
kubectl logs -n terraform-drift POD_NAME -c main
```

## 📈 Advanced Features

### Multi-Repository Support

To scan multiple repositories, create separate CronWorkflows:

```bash
# Copy and modify cronworkflow.yaml for each repo
cp argo-workflows/cronworkflow.yaml argo-workflows/cronworkflow-repo2.yaml
# Update GITHUB_REPO in the workflow
```

### Custom AI Prompts

Modify `scripts/bedrock_summarize.py` to customize the AI summary format.

### Integration with Other Tools

- **Email Notifications**: Extend script to send HTML reports
- **Metrics**: Export drift counts to Prometheus
- **Ticketing**: Automatically create Jira tickets for drift

## 🔗 Related Resources

- [Terraform Documentation](https://www.terraform.io/docs)
- [Argo Workflows](https://argoproj.github.io/workflows/)
- [AWS Bedrock](https://aws.amazon.com/bedrock/)
- [Slack Webhooks](https://api.slack.com/messaging/webhooks)
# ai-terraform-drift-detector
