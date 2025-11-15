# Configuration Guide

Complete reference for configuring the Terraform Drift AI Detector.

## Table of Contents

1. [Environment Variables](#environment-variables)
2. [Drift Threshold Configuration](#drift-threshold-configuration)
3. [Schedule Configuration](#schedule-configuration)
4. [Terraform Configuration](#terraform-configuration)
5. [AI Model Configuration](#ai-model-configuration)
6. [Resource Limits](#resource-limits)
7. [Advanced Options](#advanced-options)

---

## Environment Variables

Configuration is split between Kubernetes Secrets (sensitive) and ConfigMaps (non-sensitive).

### Secrets (`terraform-drift-secrets`)

These contain sensitive information and should never be committed to version control.

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `GITHUB_APP_ID` | Yes | GitHub App ID for authentication | `123456` |
| `GITHUB_ORG` | Yes | GitHub organization name | `my-company` |
| `GITHUB_REPO` | Yes | Repository containing Terraform code | `infrastructure` |
| `GITHUB_APP_PRIVATE_KEY` | Yes | GitHub App private key (PEM format) | `-----BEGIN RSA PRIVATE KEY-----...` |
| `SLACK_WEBHOOK_URL` | Yes | Slack incoming webhook URL | `https://hooks.slack.com/services/...` |

**Creation Example:**

```bash
kubectl create secret generic terraform-drift-secrets \
  --from-literal=GITHUB_APP_ID="123456" \
  --from-literal=GITHUB_ORG="my-company" \
  --from-literal=GITHUB_REPO="infrastructure" \
  --from-literal=SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T123/B456/xyz" \
  --from-file=GITHUB_APP_PRIVATE_KEY=./github-key.pem \
  -n terraform-drift
```

### ConfigMap (`terraform-drift-config`)

Non-sensitive configuration stored in `argo-workflows/configmap.yaml`.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TERRAFORM_PATH` | No | `terraform/environments` | Path to Terraform code in repository |
| `BEDROCK_MODEL_ID` | No | `anthropic.claude-3-5-sonnet-20241022-v2:0` | AWS Bedrock model identifier |
| `DRIFT_THRESHOLD` | No | `0` | Minimum changes to trigger notification |
| `TERRAFORM_TARGET_MODULES` | No | _(none)_ | Specific modules to target |

**Example ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: terraform-drift-config
  namespace: terraform-drift
data:
  TERRAFORM_PATH: "terraform/environments"
  BEDROCK_MODEL_ID: "anthropic.claude-3-5-sonnet-20241022-v2:0"
  DRIFT_THRESHOLD: "5"
  # Optional: Target specific modules
  # TERRAFORM_TARGET_MODULES: "-target module.vpc -target module.eks"
```

---

## Drift Threshold Configuration

The drift threshold controls when notifications are sent based on the number of resource changes detected.

### How It Works

- Counts total changes across all environments (add + change + destroy)
- Only sends Slack notification if `total_changes >= DRIFT_THRESHOLD`
- Value of `0` means always notify (even if no changes)

### Configuration Examples

#### Always Notify (Default)

Receive notifications even when no drift is detected.

```yaml
DRIFT_THRESHOLD: "0"
```

**Use Case**: Critical production environments where you want confirmation that drift detection ran successfully.

#### Notify on Any Change

Only receive notifications when at least one resource has drifted.

```yaml
DRIFT_THRESHOLD: "1"
```

**Use Case**: Active development environments where some drift is expected but you want to be aware.

#### Notify on Significant Drift

Only alert when multiple resources have changed.

```yaml
DRIFT_THRESHOLD: "5"   # 5+ changes
# or
DRIFT_THRESHOLD: "10"  # 10+ changes
```

**Use Case**: Reduce notification noise in large infrastructures where minor drift is acceptable.

#### Environment-Specific Thresholds

To have different thresholds per environment, create multiple CronWorkflows:

```yaml
# Production: strict monitoring
---
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: terraform-drift-detector-prod
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  workflowSpec:
    templates:
      - name: drift-detection
        steps:
          - - name: detect-drift
              template: terraform-drift-base-template
              arguments:
                parameters:
                  - name: drift-threshold
                    value: "1"  # Alert on any change in prod

---
# Staging: relaxed monitoring
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: terraform-drift-detector-staging
spec:
  schedule: "0 9 * * 1-5"  # Weekdays only
  workflowSpec:
    templates:
      - name: drift-detection
        steps:
          - - name: detect-drift
              template: terraform-drift-base-template
              arguments:
                parameters:
                  - name: drift-threshold
                    value: "10"  # Only alert on significant drift
```

### Behavior Examples

| Total Changes | Threshold | Notification Sent? |
|---------------|-----------|-------------------|
| 0 | 0 | ✅ Yes |
| 0 | 1 | ❌ No |
| 3 | 0 | ✅ Yes |
| 3 | 5 | ❌ No |
| 7 | 5 | ✅ Yes |
| 10 | 10 | ✅ Yes |

---

## Schedule Configuration

Configure when drift detection runs using cron syntax.

### Cron Syntax Reference

```
┌───────────── minute (0 - 59)
│ ┌───────────── hour (0 - 23)
│ │ ┌───────────── day of month (1 - 31)
│ │ │ ┌───────────── month (1 - 12)
│ │ │ │ ┌───────────── day of week (0 - 6) (Sunday=0)
│ │ │ │ │
* * * * *
```

### Common Schedules

#### Daily

```yaml
# Every day at 6 AM UTC
schedule: "0 6 * * *"

# Every day at 9 AM and 5 PM UTC
schedule: "0 9,17 * * *"
```

#### Hourly

```yaml
# Every hour
schedule: "0 * * * *"

# Every 6 hours
schedule: "0 */6 * * *"

# Every 4 hours during business hours (9 AM - 5 PM)
schedule: "0 9-17/4 * * *"
```

#### Weekdays Only

```yaml
# Weekdays at 9 AM UTC
schedule: "0 9 * * 1-5"

# Weekdays every 3 hours during business hours
schedule: "0 9-17/3 * * 1-5"
```

#### Weekly

```yaml
# Every Monday at 8 AM
schedule: "0 8 * * 1"

# Every Friday at 5 PM
schedule: "0 17 * * 5"
```

### Timezone Considerations

Argo CronWorkflows use UTC by default. Convert your local time to UTC:

```bash
# If you want 9 AM EST (UTC-5), use 14:00 UTC
schedule: "0 14 * * *"

# If you want 6 AM PST (UTC-8), use 14:00 UTC
schedule: "0 14 * * *"
```

### Concurrency Policy

Control what happens if a workflow is still running when the next schedule fires:

```yaml
spec:
  # Replace: Stop old run, start new one (default)
  concurrencyPolicy: "Replace"

  # Allow: Run both concurrently
  # concurrencyPolicy: "Allow"

  # Forbid: Skip new run if old one is still running
  # concurrencyPolicy: "Forbid"
```

---

## Terraform Configuration

### Repository Structure

The detector expects Terraform code organized by environment:

```
terraform/
└── environments/
    ├── dev/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── terraform.tfvars
    ├── staging/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── terraform.tfvars
    └── prod/
        ├── main.tf
        ├── variables.tf
        └── terraform.tfvars
```

Update `TERRAFORM_PATH` to match your structure:

```yaml
# For structure: terraform/live/
TERRAFORM_PATH: "terraform/live"

# For structure: infrastructure/
TERRAFORM_PATH: "infrastructure"

# For root-level environments
TERRAFORM_PATH: "."
```

### Terraform Backend Configuration

Ensure each environment has proper backend configuration:

```hcl
# environments/prod/main.tf
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

The drift detector will use existing state from your backend.

### Target Specific Modules

To only check specific modules (faster execution):

```yaml
# In configmap.yaml
TERRAFORM_TARGET_MODULES: "-target module.vpc -target module.eks -target module.rds"
```

This is passed to `terraform plan`:

```bash
terraform plan -target module.vpc -target module.eks -target module.rds
```

---

## AI Model Configuration

### Available Models

Configure which AWS Bedrock model to use for summarization:

| Model ID | Description | Cost | Speed |
|----------|-------------|------|-------|
| `anthropic.claude-3-5-sonnet-20241022-v2:0` | Latest Sonnet (Recommended) | Medium | Fast |
| `anthropic.claude-3-sonnet-20240229-v1:0` | Sonnet v1 | Medium | Fast |
| `anthropic.claude-3-haiku-20240307-v1:0` | Haiku (Budget) | Low | Very Fast |

### Configuration

Update in `configmap.yaml`:

```yaml
BEDROCK_MODEL_ID: "anthropic.claude-3-5-sonnet-20241022-v2:0"
```

### Regional Availability

Ensure your model is available in your AWS region:

- **us-east-1**: All models ✅
- **us-west-2**: All models ✅
- **eu-west-1**: Limited models ⚠️
- **ap-southeast-1**: Limited models ⚠️

Check availability: https://docs.aws.amazon.com/bedrock/latest/userguide/models-regions.html

### Cost Optimization

For large infrastructures with frequent scans:

```yaml
# Use Haiku for cost savings
BEDROCK_MODEL_ID: "anthropic.claude-3-haiku-20240307-v1:0"
```

Haiku provides good summaries at ~1/5 the cost of Sonnet.

---

## Resource Limits

Configure CPU and memory limits in `argo-workflows/base-template.yaml`.

### Default Resources

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "2000m"
```

### Sizing Guidelines

| Infrastructure Size | Memory Request | Memory Limit | CPU Request | CPU Limit |
|---------------------|----------------|--------------|-------------|-----------|
| Small (< 100 resources) | 256Mi | 1Gi | 250m | 1000m |
| Medium (100-500 resources) | 512Mi | 2Gi | 500m | 2000m |
| Large (500-2000 resources) | 1Gi | 4Gi | 1000m | 3000m |
| Very Large (2000+ resources) | 2Gi | 8Gi | 2000m | 4000m |

### Monitoring Resource Usage

```bash
# Watch resource usage during a run
kubectl top pod -n terraform-drift -l workflows.argoproj.io/workflow

# Check if pods are being OOMKilled
kubectl get events -n terraform-drift --field-selector reason=OOMKilled
```

---

## Advanced Options

### Custom Failure Notifications

Modify the failure notification in `cronworkflow.yaml`:

```yaml
- name: failure-notification
  when: "{{steps.detect-drift.status}} == Failed"
  templateRef:
    name: terraform-drift-base-template
    template: terraform-drift-base-template
  arguments:
    parameters:
      - name: step-command
        value: |
          curl -X POST -H "Content-type: application/json" \
            --data '{
              "text": "🚨 *Terraform Drift Detection Failed!*",
              "blocks": [
                {
                  "type": "section",
                  "text": {
                    "type": "mrkdwn",
                    "text": "Workflow failed for repository: '"$GITHUB_REPO"'\n*Environment:* All\n*Time:* $(date -u +\"%Y-%m-%d %H:%M:%S UTC\")"
                  }
                }
              ]
            }' \
            $SLACK_WEBHOOK_URL
```

### Persistent Volume Size

Adjust PVC size based on your Terraform provider cache needs:

```yaml
# In pvc.yaml
spec:
  resources:
    requests:
      storage: 10Gi  # Default
      # storage: 20Gi  # For many providers
      # storage: 50Gi  # For very large setups
```

### Node Selection

Run on specific nodes using node selectors or affinity:

```yaml
# In base-template.yaml or cronworkflow.yaml
spec:
  nodeSelector:
    workload-type: "terraform"

  # Or use affinity for more control
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: "node-type"
                operator: In
                values:
                  - "compute-optimized"
```

### Timeout Configuration

Adjust workflow timeout for large infrastructures:

```yaml
# In cronworkflow.yaml under workflowSpec
spec:
  workflowSpec:
    activeDeadlineSeconds: 3600  # 1 hour (default)
    # activeDeadlineSeconds: 7200  # 2 hours for large infra
```

### Git Branch Selection

To scan a specific branch (not main):

Add to environment variables in `base-template.yaml`:

```yaml
env:
  - name: GIT_BRANCH
    value: "develop"  # or "staging", "production-v2", etc.
```

Update `scripts/detect-drift.sh` clone command:

```bash
git clone --depth 1 --branch ${GIT_BRANCH:-main} $REPO_URL /tmp/repo
```

---

## Configuration File Locations

Quick reference for where to update settings:

| Setting | File |
|---------|------|
| Secrets (GitHub, Slack) | `kubectl create secret` command |
| Drift threshold | `argo-workflows/configmap.yaml` |
| Terraform path | `argo-workflows/configmap.yaml` |
| AI model | `argo-workflows/configmap.yaml` |
| Schedule | `argo-workflows/cronworkflow.yaml` |
| Resource limits | `argo-workflows/base-template.yaml` |
| Docker image | `argo-workflows/base-template.yaml` |
| Node selection | `argo-workflows/base-template.yaml` |
| PVC size | `argo-workflows/pvc.yaml` |

---

## Example Configurations

### High-Frequency Production Monitoring

```yaml
# cronworkflow.yaml
spec:
  schedule: "0 */4 * * *"  # Every 4 hours

# configmap.yaml
data:
  DRIFT_THRESHOLD: "1"  # Alert on any change
  BEDROCK_MODEL_ID: "anthropic.claude-3-5-sonnet-20241022-v2:0"
```

### Cost-Optimized Development

```yaml
# cronworkflow.yaml
spec:
  schedule: "0 9 * * 1-5"  # Weekdays only

# configmap.yaml
data:
  DRIFT_THRESHOLD: "10"  # Only significant drift
  BEDROCK_MODEL_ID: "anthropic.claude-3-haiku-20240307-v1:0"  # Cheaper model
```

### Multi-Region Infrastructure

```yaml
# Create separate workflows per region
---
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: drift-detector-us-east-1
spec:
  schedule: "0 6 * * *"
  workflowSpec:
    templates:
      - name: drift-detection
        container:
          env:
            - name: AWS_REGION
              value: "us-east-1"
            - name: TERRAFORM_PATH
              value: "terraform/us-east-1"
```
