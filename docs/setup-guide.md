# Setup Guide

This guide walks you through the complete setup process for the Terraform Drift AI Detector.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [AWS Setup](#aws-setup)
3. [GitHub App Setup](#github-app-setup)
4. [Slack Webhook Setup](#slack-webhook-setup)
5. [Kubernetes Setup](#kubernetes-setup)
6. [Deployment](#deployment)
7. [Verification](#verification)

---

## Prerequisites

Before you begin, ensure you have:

- **Kubernetes Cluster** (v1.19 or later)
  - EKS, GKE, AKS, or any other Kubernetes distribution
  - kubectl configured and connected to your cluster

- **Argo Workflows** installed in your cluster
  ```bash
  kubectl create namespace argo
  kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml
  ```

- **AWS Account** with Bedrock access enabled in your region
  - Bedrock must be enabled in your AWS region (us-east-1, us-west-2, etc.)
  - IAM permissions to create roles and policies

- **Docker** installed for building the container image

- **GitHub repository** with Terraform code

---

## AWS Setup

### 1. Enable AWS Bedrock

1. Navigate to AWS Bedrock console in your region
2. Request access to Claude models (if not already enabled)
3. Wait for access approval (usually immediate for Claude 3.5 Sonnet)

### 2. Create IAM Policy

Create an IAM policy for Bedrock access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel"
      ],
      "Resource": "arn:aws:bedrock:*:*:foundation-model/anthropic.claude*"
    }
  ]
}
```

Save this as `bedrock-invoke-policy.json` and create:

```bash
aws iam create-policy \
  --policy-name TerraformDriftBedrockAccess \
  --policy-document file://bedrock-invoke-policy.json
```

### 3. Configure IRSA (for EKS)

If using EKS, configure IAM Roles for Service Accounts:

```bash
# Get your cluster OIDC provider
OIDC_PROVIDER=$(aws eks describe-cluster \
  --name YOUR_CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

# Create trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/$OIDC_PROVIDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$OIDC_PROVIDER:sub": "system:serviceaccount:terraform-drift:terraform-drift-sa"
        }
      }
    }
  ]
}
EOF

# Create IAM role
aws iam create-role \
  --role-name TerraformDriftDetectorRole \
  --assume-role-policy-document file://trust-policy.json

# Attach Bedrock policy
aws iam attach-role-policy \
  --role-name TerraformDriftDetectorRole \
  --policy-arn arn:aws:iam::YOUR_ACCOUNT_ID:policy/TerraformDriftBedrockAccess
```

### 4. For Non-EKS Clusters

If not using EKS, you'll need to provide AWS credentials via secrets:

```bash
kubectl create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY \
  --from-literal=AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY \
  -n terraform-drift
```

Then update `argo-workflows/base-template.yaml` to include these environment variables.

---

## GitHub App Setup

### 1. Create GitHub App

1. Navigate to your GitHub organization settings
2. Go to **Developer settings** > **GitHub Apps** > **New GitHub App**

3. Configure the app:
   - **Name**: `Terraform Drift Detector` (or your choice)
   - **Homepage URL**: Your repository or documentation URL
   - **Webhook**: Disable (uncheck "Active")
   - **Permissions**:
     - Repository permissions:
       - Contents: **Read-only**
       - Metadata: **Read-only**
   - **Where can this GitHub App be installed?**: Only on this account

4. Click **Create GitHub App**

### 2. Generate Private Key

1. Scroll down to **Private keys**
2. Click **Generate a private key**
3. Save the downloaded `.pem` file securely

### 3. Install the App

1. Click **Install App** in the left sidebar
2. Select your organization
3. Choose **All repositories** or select specific repositories
4. Click **Install**

### 4. Note Important Values

You'll need:
- **App ID**: Found at the top of your app's settings page
- **Installation ID**: Found in the URL after installing (or via API)
- **Private Key**: The `.pem` file you downloaded

---

## Slack Webhook Setup

### 1. Create Slack App

1. Go to https://api.slack.com/apps
2. Click **Create New App** > **From scratch**
3. Name: `Terraform Drift Alerts`
4. Choose your workspace

### 2. Enable Incoming Webhooks

1. Click **Incoming Webhooks** in the left sidebar
2. Toggle **Activate Incoming Webhooks** to On
3. Click **Add New Webhook to Workspace**
4. Select the channel for notifications (e.g., `#infrastructure-alerts`)
5. Click **Allow**

### 3. Copy Webhook URL

Copy the webhook URL (format: `https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX`)

You'll use this as `SLACK_WEBHOOK_URL`.

---

## Kubernetes Setup

### 1. Create Namespace

```bash
kubectl create namespace terraform-drift
```

### 2. Build and Push Docker Image

```bash
cd terraform-drift-ai-detector

# Build image
docker build -t terraform-drift-detector:latest .

# Tag for your registry (example using ECR)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1

# Create ECR repository if it doesn't exist
aws ecr create-repository \
  --repository-name terraform-drift-detector \
  --region $AWS_REGION || true

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Tag and push
docker tag terraform-drift-detector:latest \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/terraform-drift-detector:latest

docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/terraform-drift-detector:latest
```

### 3. Update Image Reference

Update `argo-workflows/base-template.yaml`:

```yaml
image: YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/terraform-drift-detector:latest
```

### 4. Create Kubernetes Secrets

```bash
# Prepare GitHub App private key
cat > github-app-key.pem <<EOF
-----BEGIN RSA PRIVATE KEY-----
[Your private key content]
-----END RSA PRIVATE KEY-----
EOF

# Create secret
kubectl create secret generic terraform-drift-secrets \
  --from-literal=GITHUB_APP_ID="123456" \
  --from-literal=GITHUB_ORG="your-org" \
  --from-literal=GITHUB_REPO="your-infrastructure-repo" \
  --from-literal=SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK" \
  --from-file=GITHUB_APP_PRIVATE_KEY=./github-app-key.pem \
  -n terraform-drift

# Remove temporary file
rm github-app-key.pem
```

### 5. Update ConfigMap

Edit `argo-workflows/configmap.yaml` with your settings:

```yaml
data:
  TERRAFORM_PATH: "terraform/environments"  # Path to your Terraform code
  BEDROCK_MODEL_ID: "anthropic.claude-3-5-sonnet-20241022-v2:0"
  DRIFT_THRESHOLD: "5"  # Only notify if 5+ resources changed
```

---

## Deployment

### 1. Deploy Resources

Apply Kubernetes manifests in order:

```bash
cd argo-workflows

# 1. ConfigMap (non-sensitive configuration)
kubectl apply -f configmap.yaml

# 2. PVC (persistent storage for Terraform cache)
kubectl apply -f pvc.yaml

# 3. RBAC (service account and permissions)
kubectl apply -f rbac.yaml

# 4. For EKS: Annotate service account with IAM role
kubectl annotate serviceaccount terraform-drift-sa \
  -n terraform-drift \
  eks.amazonaws.com/role-arn=arn:aws:iam::YOUR_ACCOUNT_ID:role/TerraformDriftDetectorRole

# 5. Base template (reusable workflow template)
kubectl apply -f base-template.yaml

# 6. CronWorkflow (scheduled execution)
kubectl apply -f cronworkflow.yaml
```

### 2. Verify Deployment

```bash
# Check CronWorkflow is created
kubectl get cronworkflows -n terraform-drift

# Should show:
# NAME                        SCHEDULE      SUSPENDED   AGE
# terraform-drift-detector    0 6 * * *     False       10s

# Check service account
kubectl get serviceaccount terraform-drift-sa -n terraform-drift

# Check secrets
kubectl get secrets terraform-drift-secrets -n terraform-drift
```

---

## Verification

### 1. Manual Test Run

Trigger a manual execution to test:

```bash
# Submit a workflow from the CronWorkflow template
argo submit --from cronworkflow/terraform-drift-detector -n terraform-drift

# Watch the workflow
argo watch @latest -n terraform-drift
```

### 2. Check Logs

```bash
# Get the workflow name
WORKFLOW_NAME=$(argo list -n terraform-drift -o name | head -1)

# View logs
argo logs $WORKFLOW_NAME -n terraform-drift --follow
```

### 3. Expected Output

You should see:

```
🔐 Authenticating with GitHub...
✅ Successfully authenticated

📥 Cloning repository...
✅ Repository cloned

📂 Found environments: dev, staging, prod

🔍 Processing environment: dev
  📋 Initializing Terraform...
  ✅ Terraform initialized
  🔍 Running terraform plan...
  ✅ Plan completed
  📊 Changes detected: 3 to add, 2 to change, 0 to destroy

🤖 Generating AI summary...
✅ Summary generated

📊 Total changes across all environments: 5
✉️  Sending notification to Slack...
✅ Notification sent

✨ Drift detection complete!
```

### 4. Check Slack

You should receive a notification in your configured Slack channel with:
- Environment breakdown
- Resource changes per environment
- AI-generated summary
- Risk assessment
- Recommended actions

### 5. Troubleshooting

If the workflow fails, check:

```bash
# Describe the workflow
argo get $WORKFLOW_NAME -n terraform-drift

# Check pod logs
kubectl logs -n terraform-drift -l workflows.argoproj.io/workflow=$WORKFLOW_NAME

# Check events
kubectl get events -n terraform-drift --sort-by='.lastTimestamp'
```

---

## Next Steps

1. **Adjust Schedule**: Modify `cronworkflow.yaml` schedule to fit your needs
2. **Configure Thresholds**: Update `DRIFT_THRESHOLD` in ConfigMap
3. **Add More Environments**: Update your Terraform repository structure
4. **Set Up Alerts**: Configure additional notification channels
5. **Monitor Performance**: Watch resource usage and adjust limits

See [Configuration Guide](configuration.md) for advanced configuration options.
