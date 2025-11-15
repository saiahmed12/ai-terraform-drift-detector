# Examples

This directory contains example configurations and outputs for the Terraform Drift AI Detector.

## Contents

### 1. Sample Terraform Configuration (`sample-terraform/`)

Example Terraform code demonstrating the expected structure for drift detection.

**Directory Structure:**
```
sample-terraform/
└── dev/
    ├── main.tf          # Main Terraform configuration
    ├── variables.tf     # Variable definitions
    ├── outputs.tf       # Output definitions
    └── terraform.tfvars # Environment-specific values
```

**What's Included:**
- AWS VPC with public and private subnets
- Security groups for application tier
- EC2 instances
- S3 bucket with versioning and encryption
- CloudWatch log groups

**Usage:**

To use this as a template for your infrastructure:

```bash
# Copy to your infrastructure repository
cp -r sample-terraform/dev your-repo/terraform/environments/dev

# Update terraform.tfvars with your values
cd your-repo/terraform/environments/dev
vim terraform.tfvars

# Initialize and apply
terraform init
terraform plan
terraform apply
```

### 2. Sample Slack Output (`sample-slack-output.json`)

Example of the JSON payload sent to Slack when drift is detected.

**Format:**

The notification includes:
- **Header**: Detection type (full or targeted scan)
- **Per-Environment Details**:
  - Environment name
  - Resources to add
  - Resources to change
  - Resources to destroy
  - Risk level (None/Destructive/Replacement/Mixed)
  - Recommended action
- **Summary**: Total changes across all environments

**Usage:**

Test your Slack webhook with this example:

```bash
# Replace with your actual webhook URL
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK"

# Send sample notification
curl -X POST \
  -H "Content-type: application/json" \
  --data @examples/sample-slack-output.json \
  $SLACK_WEBHOOK
```

### 3. Local Development (`docker-compose.yml`)

See the root-level `docker-compose.yml` for running drift detection locally without Kubernetes.

## Adapting to Your Infrastructure

### Repository Structure

The drift detector expects Terraform code organized by environment:

```
your-repo/
└── terraform/
    └── environments/     # or whatever path you configure
        ├── dev/
        │   ├── main.tf
        │   └── ...
        ├── staging/
        │   ├── main.tf
        │   └── ...
        └── prod/
            ├── main.tf
            └── ...
```

Update `TERRAFORM_PATH` in ConfigMap to match your structure:

```yaml
# argo-workflows/configmap.yaml
data:
  TERRAFORM_PATH: "terraform/environments"  # Adjust to your path
```

### Backend Configuration

Each environment should have its own state file:

```hcl
# dev/main.tf
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"
  }
}

# staging/main.tf
terraform {
  backend "s3" {
    bucket = "my-terraform-state"
    key    = "staging/terraform.tfstate"
    region = "us-east-1"
  }
}
```

### Alternative Structures

#### Workspaces

If using Terraform workspaces instead of directories:

```bash
# Modify detect-drift.sh to use workspaces
terraform workspace select dev
terraform plan
```

#### Terragrunt

If using Terragrunt for DRY configurations:

```bash
# Modify detect-drift.sh to use terragrunt
cd environments/dev
terragrunt plan
```

## Testing Drift Detection

### 1. Create Intentional Drift

Make a manual change in your cloud provider console:

```bash
# Example: Change an EC2 instance tag
aws ec2 create-tags \
  --resources i-1234567890abcdef0 \
  --tags Key=Name,Value=modified-manually
```

### 2. Run Detection

```bash
# Trigger workflow manually
argo submit --from cronworkflow/terraform-drift-detector -n terraform-drift

# Watch for results
argo watch @latest -n terraform-drift
```

### 3. Expected Results

You should receive a Slack notification showing:

```
Environment: dev
- Resources to change: 1
- Risk: None
- Action: Apply or Review
```

### 4. Fix Drift

```bash
# Apply Terraform to fix drift
cd environments/dev
terraform apply
```

## Common Scenarios

### Scenario 1: New Resource Added Manually

**What happened:** Someone created an S3 bucket through the console

**Drift Output:**
```
Resources to add: 0
Resources to change: 0
Resources to destroy: 0
```

**Why:** Drift detection only shows changes to managed resources. Unmanaged resources won't appear.

**Solution:** Import the resource or delete it manually.

### Scenario 2: Resource Modified Outside Terraform

**What happened:** Security group rules were changed in the console

**Drift Output:**
```
Resources to add: 0
Resources to change: 1
Resources to destroy: 0
Risk: None
```

**Solution:** Run `terraform apply` to restore configuration.

### Scenario 3: Resource Deleted Outside Terraform

**What happened:** An EC2 instance was terminated manually

**Drift Output:**
```
Resources to add: 1
Resources to change: 0
Resources to destroy: 0
Risk: Replacement
```

**Solution:** Run `terraform apply` to recreate, or remove from Terraform if intentional.

### Scenario 4: Terraform Code Updated but Not Applied

**What happened:** Someone merged a PR that changed instance types

**Drift Output:**
```
Resources to add: 0
Resources to change: 3
Resources to destroy: 0
Risk: Replacement
```

**Solution:** Review and apply the changes.

## Customization Ideas

### 1. Add Cost Estimation

Integrate with Infracost to show cost impact:

```bash
# In detect-drift.sh
infracost breakdown --path . --format json > cost.json
# Parse and add to Slack notification
```

### 2. Create Jira Tickets

Automatically create tickets for drift:

```bash
# After drift detection
if [[ $total_changes -gt 0 ]]; then
  curl -X POST https://your-jira.atlassian.net/rest/api/2/issue \
    -H "Content-Type: application/json" \
    -d '{"fields": {"project": {"key": "OPS"}, ...}}'
fi
```

### 3. Export Metrics

Send drift metrics to Prometheus:

```bash
# Add to detect-drift.sh
echo "terraform_drift_total $total_changes" | curl --data-binary @- \
  http://pushgateway:9091/metrics/job/terraform-drift
```

### 4. Differential Alerting

Different alert channels based on severity:

```bash
if [[ $RISK == "Destructive" ]]; then
  SLACK_WEBHOOK=$CRITICAL_WEBHOOK  # Page on-call
elif [[ $total_changes -gt 10 ]]; then
  SLACK_WEBHOOK=$WARNING_WEBHOOK   # Post to warnings channel
else
  SLACK_WEBHOOK=$INFO_WEBHOOK      # Post to info channel
fi
```
