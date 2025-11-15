# Local Development Guide

Run Terraform drift detection locally using Docker Compose without requiring a Kubernetes cluster.

## Quick Start

### 1. Prerequisites

- Docker and Docker Compose installed
- AWS credentials configured (for Bedrock access)
- GitHub App credentials
- Slack webhook URL

### 2. Setup

```bash
# Clone or navigate to the repository
cd terraform-drift-ai-detector

# Copy environment template
cp .env.example .env

# Edit with your values
vim .env
```

### 3. Add GitHub App Private Key

```bash
# Save your GitHub App private key
cat > github-app-key.pem <<EOF
-----BEGIN RSA PRIVATE KEY-----
[Your private key content here]
-----END RSA PRIVATE KEY-----
EOF

# Secure the file
chmod 600 github-app-key.pem
```

### 4. Run Drift Detection

```bash
# Build and run (one-time execution)
docker-compose up terraform-drift-detector

# Or run in background
docker-compose up -d terraform-drift-detector

# View logs
docker-compose logs -f terraform-drift-detector
```

## Docker Compose Services

### `terraform-drift-detector` (Default)

One-time drift detection run.

**Usage:**
```bash
# Run full drift detection
docker-compose up terraform-drift-detector

# Run and remove container after
docker-compose run --rm terraform-drift-detector
```

**Output:**
```
🔐 Authenticating with GitHub...
✅ Successfully authenticated
📥 Cloning repository...
✅ Repository cloned
...
✨ Drift detection complete!
```

### `terraform-drift-scheduled` (Optional)

Runs drift detection on a schedule (every 6 hours by default).

**Usage:**
```bash
# Start scheduled service
docker-compose --profile scheduled up -d terraform-drift-scheduled

# View logs
docker-compose logs -f terraform-drift-scheduled

# Stop scheduled service
docker-compose --profile scheduled down
```

**Customize Schedule:**

Edit `docker-compose.yml`:
```yaml
sleep 21600;  # 6 hours = 21600 seconds
# For 1 hour: 3600
# For 12 hours: 43200
# For 24 hours: 86400
```

### `terraform-drift-debug` (Debug)

Interactive shell for debugging and testing.

**Usage:**
```bash
# Start interactive shell
docker-compose run --rm terraform-drift-debug

# Inside container, you can:
bash-5.1# /tmp/scripts/detect-drift.sh full
bash-5.1# python3 /tmp/scripts/bedrock_summarize.py
bash-5.1# terraform --version
bash-5.1# aws bedrock list-foundation-models --region us-east-1
```

## Configuration

### Environment Variables

All configuration is in `.env`:

```bash
# GitHub Authentication
GITHUB_APP_ID=123456
GITHUB_ORG=my-organization
GITHUB_REPO=infrastructure-repo

# Terraform Configuration
TERRAFORM_PATH=terraform/environments

# Drift Detection
DRIFT_THRESHOLD=5  # Only notify if 5+ changes

# AWS Bedrock
BEDROCK_MODEL_ID=anthropic.claude-3-5-sonnet-20241022-v2:0
AWS_REGION=us-east-1

# Notifications
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK

# GitHub App Key Path (relative to docker-compose.yml)
GITHUB_APP_PRIVATE_KEY_PATH=./github-app-key.pem
```

### AWS Credentials

#### Option 1: Environment Variables (Recommended for local dev)

Add to `.env`:
```bash
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_REGION=us-east-1
```

#### Option 2: Mount AWS Credentials File

Uncomment in `docker-compose.yml`:
```yaml
volumes:
  - ~/.aws:/root/.aws:ro
```

Then use AWS profiles in `.env`:
```bash
AWS_PROFILE=default
AWS_REGION=us-east-1
```

### Custom Terraform Path

To test with local Terraform code:

```yaml
# In docker-compose.yml
volumes:
  - ./my-terraform-code:/tmp/terraform:ro
```

Then set in `.env`:
```bash
TERRAFORM_PATH=/tmp/terraform
```

## Common Tasks

### Test GitHub Authentication

```bash
docker-compose run --rm terraform-drift-detector python3 /tmp/scripts/github_auth.py

# Expected output:
# Successfully authenticated as: my-github-app[bot]
# Installation ID: 12345678
```

### Test Bedrock Connection

```bash
docker-compose run --rm terraform-drift-detector bash -c '
  echo "{\"test\": \"plan output\"}" | python3 /tmp/scripts/bedrock_summarize.py
'

# Should return AI-generated summary
```

### Test Slack Notification

```bash
docker-compose run --rm terraform-drift-detector bash -c '
  curl -X POST -H "Content-type: application/json" \
    --data "{\"text\": \"Test from Docker Compose\"}" \
    $SLACK_WEBHOOK_URL
'

# Check your Slack channel for the message
```

### Run Terraform Plan Manually

```bash
# Start debug shell
docker-compose run --rm terraform-drift-debug

# Inside container:
cd /tmp
git clone https://x-access-token:$(python3 /tmp/scripts/github_auth.py)@github.com/$GITHUB_ORG/$GITHUB_REPO.git repo
cd repo/$TERRAFORM_PATH/dev
terraform init
terraform plan
```

## Troubleshooting

### Container Exits Immediately

**Issue:** Container exits before you can see output.

**Solution:**

```bash
# View full logs
docker-compose logs terraform-drift-detector

# Or run in foreground
docker-compose up terraform-drift-detector
```

### AWS Credentials Not Working

**Issue:** `Unable to locate credentials`

**Solution:**

1. Verify credentials are set:
   ```bash
   docker-compose run --rm terraform-drift-detector env | grep AWS
   ```

2. Test AWS access:
   ```bash
   docker-compose run --rm terraform-drift-detector \
     aws sts get-caller-identity
   ```

3. Ensure `.env` has proper AWS credentials or volume mount is correct.

### GitHub Authentication Fails

**Issue:** `401 Unauthorized`

**Solution:**

1. Check private key file exists:
   ```bash
   ls -l github-app-key.pem
   ```

2. Verify key format:
   ```bash
   head -1 github-app-key.pem
   # Should show: -----BEGIN RSA PRIVATE KEY-----
   ```

3. Test authentication:
   ```bash
   docker-compose run --rm terraform-drift-detector \
     cat /tmp/github-app-private-key.pem | head -1
   ```

### Terraform Init Fails

**Issue:** `Error: Failed to install provider`

**Solution:**

1. Check network connectivity:
   ```bash
   docker-compose run --rm terraform-drift-detector \
     curl -I https://registry.terraform.io
   ```

2. Use persistent cache:
   ```bash
   # Cache is already configured in docker-compose.yml
   docker volume inspect terraform-drift-ai-detector_terraform-cache
   ```

3. Clear cache if corrupted:
   ```bash
   docker-compose down -v
   docker volume rm terraform-drift-ai-detector_terraform-cache
   ```

## Performance Optimization

### Use Build Cache

```bash
# Build once
docker-compose build

# Subsequent runs use cached image
docker-compose up terraform-drift-detector
```

### Persistent Provider Cache

The `terraform-cache` volume persists Terraform providers between runs.

**Check cache size:**
```bash
docker system df -v | grep terraform-cache
```

**Clear cache:**
```bash
docker volume rm terraform-drift-ai-detector_terraform-cache
```

### Resource Limits

Adjust based on your infrastructure size:

```yaml
# In docker-compose.yml
deploy:
  resources:
    limits:
      cpus: '4'        # Increase for large infra
      memory: 4G       # Increase for many resources
```

## Advanced Usage

### Override Default Command

```bash
# Run specific environment only
docker-compose run --rm terraform-drift-detector \
  /tmp/scripts/detect-drift.sh full dev

# Run with custom parameters
docker-compose run --rm \
  -e DRIFT_THRESHOLD=10 \
  -e BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240307-v1:0 \
  terraform-drift-detector
```

### Mount Local Scripts for Development

```yaml
# In docker-compose.yml under debug service
volumes:
  - ./scripts:/tmp/scripts:rw  # Read-write for development
```

Then edit scripts locally and test:
```bash
# Edit script
vim scripts/detect-drift.sh

# Test immediately
docker-compose run --rm terraform-drift-debug /tmp/scripts/detect-drift.sh full
```

### Automated Scheduling with Cron

Instead of `terraform-drift-scheduled` service, use host cron:

```bash
# Add to crontab
0 */6 * * * cd /path/to/terraform-drift-ai-detector && docker-compose run --rm terraform-drift-detector >> /var/log/terraform-drift.log 2>&1
```

### Integration with CI/CD

Run drift detection in CI pipelines:

```yaml
# .github/workflows/drift-check.yml
name: Terraform Drift Check

on:
  schedule:
    - cron: '0 6 * * *'

jobs:
  drift-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Create .env file
        run: |
          cat > .env <<EOF
          GITHUB_APP_ID=${{ secrets.GITHUB_APP_ID }}
          GITHUB_ORG=${{ secrets.GITHUB_ORG }}
          GITHUB_REPO=${{ secrets.GITHUB_REPO }}
          SLACK_WEBHOOK_URL=${{ secrets.SLACK_WEBHOOK_URL }}
          AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }}
          EOF

      - name: Create GitHub App key
        run: echo "${{ secrets.GITHUB_APP_PRIVATE_KEY }}" > github-app-key.pem

      - name: Run drift detection
        run: docker-compose up terraform-drift-detector
```

## Cleanup

```bash
# Stop and remove containers
docker-compose down

# Remove volumes (including Terraform cache)
docker-compose down -v

# Remove images
docker-compose down --rmi all

# Complete cleanup
docker-compose down -v --rmi all
docker volume prune -f
```

## Comparison: Local vs Kubernetes

| Feature | Docker Compose | Kubernetes (Argo) |
|---------|----------------|-------------------|
| **Setup Complexity** | Low | High |
| **Scheduling** | Manual/Cron | Built-in CronWorkflow |
| **Scalability** | Single host | Multi-node cluster |
| **Resource Management** | Basic limits | Advanced quotas/limits |
| **High Availability** | No | Yes |
| **Secrets Management** | .env file | Kubernetes Secrets |
| **Best For** | Development, Testing | Production |

**Recommendation:**
- Use **Docker Compose** for: Local development, testing, proof-of-concept
- Use **Kubernetes** for: Production, scheduled monitoring, team environments
