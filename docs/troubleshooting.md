# Troubleshooting Guide

Common issues and solutions for the Terraform Drift AI Detector.

## Table of Contents

1. [GitHub Authentication Issues](#github-authentication-issues)
2. [Terraform Failures](#terraform-failures)
3. [AWS Bedrock Errors](#aws-bedrock-errors)
4. [Slack Notification Issues](#slack-notification-issues)
5. [Kubernetes/Argo Issues](#kubernetesargo-issues)
6. [Performance Issues](#performance-issues)
7. [Debugging Techniques](#debugging-techniques)

---

## GitHub Authentication Issues

### Error: "Installation ID not found"

**Symptom:**
```
❌ Error: Could not find installation ID for organization: my-org
```

**Cause:** GitHub App is not installed in the specified organization.

**Solution:**

1. Verify the GitHub App is installed:
   ```bash
   # Check GitHub App installations
   # Visit: https://github.com/organizations/YOUR_ORG/settings/installations
   ```

2. Ensure `GITHUB_ORG` matches exactly:
   ```bash
   kubectl get secret terraform-drift-secrets -n terraform-drift -o jsonpath='{.data.GITHUB_ORG}' | base64 -d
   ```

3. Reinstall the GitHub App if necessary:
   - Go to GitHub App settings
   - Click "Install App"
   - Select your organization
   - Grant repository access

### Error: "401 Unauthorized" or "403 Forbidden"

**Symptom:**
```
fatal: could not read Username for 'https://github.com': No such device or address
```

**Cause:** Invalid GitHub App credentials or insufficient permissions.

**Solution:**

1. Verify GitHub App ID is correct:
   ```bash
   # Check the secret
   kubectl get secret terraform-drift-secrets -n terraform-drift -o jsonpath='{.data.GITHUB_APP_ID}' | base64 -d
   echo

   # Compare with your GitHub App settings page
   ```

2. Check private key format:
   ```bash
   # Private key should start with -----BEGIN RSA PRIVATE KEY-----
   kubectl get secret terraform-drift-secrets -n terraform-drift -o jsonpath='{.data.GITHUB_APP_PRIVATE_KEY}' | base64 -d | head -1
   ```

3. Verify GitHub App permissions:
   - **Contents**: Read-only ✅
   - **Metadata**: Read-only ✅

4. Recreate secret with correct key:
   ```bash
   kubectl delete secret terraform-drift-secrets -n terraform-drift

   kubectl create secret generic terraform-drift-secrets \
     --from-literal=GITHUB_APP_ID="YOUR_APP_ID" \
     --from-literal=GITHUB_ORG="your-org" \
     --from-literal=GITHUB_REPO="your-repo" \
     --from-literal=SLACK_WEBHOOK_URL="YOUR_WEBHOOK" \
     --from-file=GITHUB_APP_PRIVATE_KEY=./github-key.pem \
     -n terraform-drift
   ```

### Error: "Repository not found"

**Symptom:**
```
fatal: repository 'https://github.com/my-org/my-repo.git/' not found
```

**Cause:** Repository name is incorrect or App doesn't have access.

**Solution:**

1. Verify repository name:
   ```bash
   kubectl get secret terraform-drift-secrets -n terraform-drift -o jsonpath='{.data.GITHUB_REPO}' | base64 -d
   echo
   ```

2. Check GitHub App has access to the repository:
   - Go to: `https://github.com/organizations/YOUR_ORG/settings/installations`
   - Click "Configure" on your app
   - Ensure the repository is listed under "Repository access"

3. If using "Only select repositories", add your repo to the list

---

## Terraform Failures

### Error: "terraform init failed"

**Symptom:**
```
❌ Terraform init failed in dev
```

**Cause:** Backend configuration issues, network problems, or missing provider credentials.

**Solution:**

1. Check backend configuration:
   ```bash
   # View logs to see the actual error
   argo logs -n terraform-drift @latest | grep -A 10 "terraform init"
   ```

2. Common backend issues:

   **S3 Backend:**
   ```bash
   # Ensure IAM role has S3 access
   # Add to IAM policy:
   {
     "Effect": "Allow",
     "Action": [
       "s3:GetObject",
       "s3:PutObject",
       "s3:ListBucket"
     ],
     "Resource": [
       "arn:aws:s3:::my-terraform-state/*",
       "arn:aws:s3:::my-terraform-state"
     ]
   }
   ```

   **DynamoDB Locks:**
   ```json
   {
     "Effect": "Allow",
     "Action": [
       "dynamodb:GetItem",
       "dynamodb:PutItem",
       "dynamodb:DeleteItem"
     ],
     "Resource": "arn:aws:dynamodb:*:*:table/terraform-locks"
   }
   ```

3. Check network connectivity:
   ```bash
   # Test from a pod in the same namespace
   kubectl run -it --rm debug --image=curlimages/curl -n terraform-drift -- sh
   curl -I https://registry.terraform.io
   ```

### Error: "No changes. Infrastructure is up-to-date."

**Symptom:** Drift detection runs but always reports 0 changes, even when drift exists.

**Cause:** Terraform state is newer than actual infrastructure, or detection is running against wrong environment.

**Solution:**

1. Verify Terraform path is correct:
   ```bash
   kubectl get configmap terraform-drift-config -n terraform-drift -o yaml
   ```

2. Check that backend state matches your environments:
   ```bash
   # Manually verify state
   cd /path/to/terraform/environments/prod
   terraform init
   terraform plan  # Should show drift if it exists
   ```

3. Ensure environments are properly structured:
   ```bash
   # Directory structure should match TERRAFORM_PATH
   ls -la terraform/environments/
   # Should show: dev/, staging/, prod/
   ```

### Error: "Provider plugin not found"

**Symptom:**
```
Error: Could not load plugin
```

**Cause:** Provider cache is not working or disk space is full.

**Solution:**

1. Check PVC status:
   ```bash
   kubectl get pvc terraform-drift-pvc -n terraform-drift

   # Should show Bound status
   # NAME                   STATUS   VOLUME    CAPACITY
   # terraform-drift-pvc    Bound    pvc-xxx   10Gi
   ```

2. Check disk usage:
   ```bash
   # Exec into a running workflow pod
   kubectl exec -it -n terraform-drift POD_NAME -- df -h /cache

   # If full, increase PVC size in pvc.yaml
   ```

3. Clear provider cache if corrupted:
   ```bash
   # Delete and recreate PVC (will download providers again)
   kubectl delete pvc terraform-drift-pvc -n terraform-drift
   kubectl apply -f argo-workflows/pvc.yaml
   ```

---

## AWS Bedrock Errors

### Error: "AccessDeniedException"

**Symptom:**
```
❌ AI summary generation failed
botocore.exceptions.ClientError: An error occurred (AccessDeniedException) when calling the InvokeModel operation
```

**Cause:** IAM permissions are missing or Bedrock is not enabled in your region.

**Solution:**

1. Verify IAM policy is attached:
   ```bash
   # For EKS IRSA
   aws iam get-role --role-name TerraformDriftDetectorRole

   # Check attached policies
   aws iam list-attached-role-policies --role-name TerraformDriftDetectorRole
   ```

2. Ensure policy allows `bedrock:InvokeModel`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["bedrock:InvokeModel"],
         "Resource": "arn:aws:bedrock:*:*:foundation-model/anthropic.claude*"
       }
     ]
   }
   ```

3. Check service account annotation (for EKS):
   ```bash
   kubectl get serviceaccount terraform-drift-sa -n terraform-drift -o yaml | grep eks.amazonaws.com/role-arn

   # Should show:
   # eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/TerraformDriftDetectorRole
   ```

4. For non-EKS, verify AWS credentials:
   ```bash
   kubectl get secret aws-credentials -n terraform-drift
   ```

### Error: "ResourceNotFoundException" or "ModelNotFound"

**Symptom:**
```
Could not find model anthropic.claude-3-5-sonnet-20241022-v2:0 in region us-east-1
```

**Cause:** Model is not available in your AWS region or you don't have access.

**Solution:**

1. Check model availability in your region:
   ```bash
   aws bedrock list-foundation-models --region us-east-1 | grep claude
   ```

2. Request model access:
   - Go to AWS Bedrock Console
   - Click "Model access" in left sidebar
   - Request access to Claude models
   - Wait for approval (usually instant)

3. Use a different model if necessary:
   ```yaml
   # In configmap.yaml
   BEDROCK_MODEL_ID: "anthropic.claude-3-haiku-20240307-v1:0"
   ```

4. Check available regions:
   - **us-east-1**: Full model availability ✅
   - **us-west-2**: Full model availability ✅
   - Other regions: Limited availability ⚠️

### Error: "ThrottlingException" or "ServiceQuotaExceededException"

**Symptom:**
```
Rate exceeded for model anthropic.claude-3-5-sonnet-20241022-v2:0
```

**Cause:** Too many requests to Bedrock API or quota exceeded.

**Solution:**

1. Reduce scan frequency:
   ```yaml
   # In cronworkflow.yaml
   schedule: "0 6 * * *"  # Once daily instead of hourly
   ```

2. Request quota increase:
   - Go to AWS Service Quotas
   - Search for "Bedrock"
   - Request increase for "InvokeModel transactions per minute"

3. Switch to a model with higher quota:
   ```yaml
   # Haiku typically has higher quotas
   BEDROCK_MODEL_ID: "anthropic.claude-3-haiku-20240307-v1:0"
   ```

---

## Slack Notification Issues

### Error: "Slack notification failed" or "404 Not Found"

**Symptom:**
```
✉️  Sending notification to Slack...
curl: (22) The requested URL returned error: 404
```

**Cause:** Slack webhook URL is invalid or the webhook was deleted.

**Solution:**

1. Verify webhook URL:
   ```bash
   kubectl get secret terraform-drift-secrets -n terraform-drift -o jsonpath='{.data.SLACK_WEBHOOK_URL}' | base64 -d
   echo

   # Should be: https://hooks.slack.com/services/T.../B.../...
   ```

2. Test webhook manually:
   ```bash
   WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK"

   curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"Test message from Terraform Drift Detector"}' \
     $WEBHOOK_URL
   ```

3. Recreate webhook if necessary:
   - Go to https://api.slack.com/apps
   - Select your app
   - Incoming Webhooks → Add New Webhook
   - Update Kubernetes secret

### Error: "No Slack notifications received" (but no errors)

**Symptom:** Workflow completes successfully, but no message appears in Slack.

**Cause:** Drift threshold is set too high, or changes are below threshold.

**Solution:**

1. Check drift threshold:
   ```bash
   kubectl get configmap terraform-drift-config -n terraform-drift -o jsonpath='{.data.DRIFT_THRESHOLD}'
   ```

2. Review workflow logs:
   ```bash
   argo logs -n terraform-drift @latest | grep -E "(Total changes|Skipping notification|Sending notification)"

   # Look for:
   # ⏭️  Skipping notification (changes below threshold)
   ```

3. Temporarily set threshold to 0:
   ```bash
   kubectl edit configmap terraform-drift-config -n terraform-drift
   # Change DRIFT_THRESHOLD to "0"
   ```

### Error: "invalid_payload" or formatting issues

**Symptom:**
```
{"ok":false,"error":"invalid_payload"}
```

**Cause:** Malformed JSON in Slack message.

**Solution:**

1. Check for special characters in Terraform output:
   - Quotes, newlines, backslashes can break JSON

2. The script escapes JSON properly, but if you modified it, ensure:
   ```bash
   # In detect-drift.sh
   ESCAPED_SUMMARY=$(echo "$SUMMARY" | jq -Rs .)

   curl -X POST -H "Content-type: application/json" \
     --data "{\"text\": $ESCAPED_SUMMARY}" \
     $SLACK_WEBHOOK_URL
   ```

---

## Kubernetes/Argo Issues

### Error: "CronWorkflow suspended"

**Symptom:** CronWorkflow exists but doesn't trigger.

**Solution:**

1. Check if suspended:
   ```bash
   kubectl get cronworkflow terraform-drift-detector -n terraform-drift -o jsonpath='{.spec.suspend}'
   ```

2. Unsuspend if necessary:
   ```bash
   kubectl patch cronworkflow terraform-drift-detector -n terraform-drift \
     -p '{"spec":{"suspend":false}}'
   ```

### Error: "ImagePullBackOff" or "ErrImagePull"

**Symptom:**
```
Failed to pull image "123456789012.dkr.ecr.us-east-1.amazonaws.com/terraform-drift:latest"
```

**Cause:** Kubernetes cannot pull Docker image from registry.

**Solution:**

1. For ECR, ensure proper IAM permissions:
   ```json
   {
     "Effect": "Allow",
     "Action": [
       "ecr:GetDownloadUrlForLayer",
       "ecr:BatchGetImage",
       "ecr:GetAuthorizationToken"
     ],
     "Resource": "*"
   }
   ```

2. Check if image exists:
   ```bash
   aws ecr describe-images --repository-name terraform-drift-detector --region us-east-1
   ```

3. For EKS, ensure nodes can pull from ECR:
   ```bash
   # Nodes should have AmazonEC2ContainerRegistryReadOnly policy
   ```

4. For private registries, create image pull secret:
   ```bash
   kubectl create secret docker-registry ecr-registry \
     --docker-server=123456789012.dkr.ecr.us-east-1.amazonaws.com \
     --docker-username=AWS \
     --docker-password=$(aws ecr get-login-password --region us-east-1) \
     -n terraform-drift

   # Update base-template.yaml
   imagePullSecrets:
     - name: ecr-registry
   ```

### Error: "PVC pending" or "FailedScheduling"

**Symptom:**
```
persistentvolumeclaim "terraform-drift-pvc" not found
```

**Cause:** PVC is not bound or storage class is unavailable.

**Solution:**

1. Check PVC status:
   ```bash
   kubectl get pvc terraform-drift-pvc -n terraform-drift

   # If Pending, check events
   kubectl describe pvc terraform-drift-pvc -n terraform-drift
   ```

2. Check available storage classes:
   ```bash
   kubectl get storageclass

   # Should show at least one with (default) marker
   ```

3. Specify storage class if needed:
   ```yaml
   # In pvc.yaml
   spec:
     storageClassName: "gp3"  # or "standard", "ebs-sc", etc.
   ```

4. For EKS, ensure EBS CSI driver is installed:
   ```bash
   kubectl get pods -n kube-system | grep ebs-csi
   ```

---

## Performance Issues

### Issue: "Workflow takes too long"

**Symptom:** Workflows running for 30+ minutes.

**Cause:** Large infrastructure or slow Terraform operations.

**Solution:**

1. Target specific modules:
   ```yaml
   # In configmap.yaml
   TERRAFORM_TARGET_MODULES: "-target module.critical_infra"
   ```

2. Increase resources:
   ```yaml
   # In base-template.yaml
   resources:
     requests:
       memory: "2Gi"
       cpu: "2000m"
     limits:
       memory: "4Gi"
       cpu: "4000m"
   ```

3. Use faster AI model:
   ```yaml
   # Haiku is 3x faster than Sonnet
   BEDROCK_MODEL_ID: "anthropic.claude-3-haiku-20240307-v1:0"
   ```

4. Optimize Terraform:
   - Use `-parallelism=20` flag
   - Ensure provider plugins are cached
   - Consider breaking large environments into smaller ones

### Issue: "Out of memory" (OOMKilled)

**Symptom:**
```
Error: OOMKilled
```

**Cause:** Insufficient memory for Terraform operations.

**Solution:**

1. Check memory usage during run:
   ```bash
   kubectl top pod -n terraform-drift
   ```

2. Increase memory limits:
   ```yaml
   # In base-template.yaml
   limits:
     memory: "4Gi"  # or higher
   ```

3. Check for memory leaks in Terraform providers

---

## Debugging Techniques

### View Real-Time Logs

```bash
# Watch latest workflow
argo watch @latest -n terraform-drift

# Follow logs
argo logs -n terraform-drift @latest --follow

# Get specific step logs
argo logs -n terraform-drift WORKFLOW_NAME --step detect-drift
```

### Inspect Workflow Details

```bash
# Get workflow status
argo get -n terraform-drift WORKFLOW_NAME

# Get workflow as YAML
kubectl get workflow WORKFLOW_NAME -n terraform-drift -o yaml

# Check pod events
kubectl describe pod -n terraform-drift POD_NAME
```

### Manual Execution for Testing

```bash
# Run detect-drift.sh locally
docker run --rm -it \
  --env-file .env \
  -v $(pwd)/github-key.pem:/tmp/github-app-private-key.pem \
  terraform-drift-detector:latest \
  bash

# Inside container
/tmp/scripts/detect-drift.sh full
```

### Check Secret Values (Carefully!)

```bash
# Verify secrets exist (don't print sensitive values)
kubectl get secret terraform-drift-secrets -n terraform-drift \
  -o jsonpath='{.data}' | jq 'keys'

# Check if a specific key exists
kubectl get secret terraform-drift-secrets -n terraform-drift \
  -o jsonpath='{.data.GITHUB_APP_ID}' | base64 -d | wc -c
# Should output a non-zero number
```

### Enable Debug Mode

Add to `base-template.yaml`:

```yaml
env:
  - name: DEBUG
    value: "true"
  - name: TF_LOG
    value: "DEBUG"  # Terraform debug logs
```

### Test Individual Components

```bash
# Test GitHub authentication
kubectl run -it --rm test \
  --image=terraform-drift-detector:latest \
  --env="GITHUB_APP_ID=..." \
  -- python3 /tmp/scripts/github_auth.py

# Test Slack webhook
kubectl run -it --rm test \
  --image=curlimages/curl \
  -- curl -X POST -H 'Content-type: application/json' \
    --data '{"text":"Test"}' \
    https://hooks.slack.com/services/YOUR/WEBHOOK
```

---

## Getting Help

If you're still stuck:

1. **Check Logs**: Always start with workflow logs
2. **Review Events**: Check Kubernetes events for infrastructure issues
3. **Test Components**: Test GitHub, Slack, Bedrock independently
4. **Verify Configuration**: Double-check all environment variables and secrets
5. **Search Issues**: Look for similar issues in the repository

### Useful Log Filters

```bash
# Show only errors
argo logs -n terraform-drift @latest | grep -i error

# Show drift summary
argo logs -n terraform-drift @latest | grep -A 5 "Terraform Plan Drift Summary"

# Show timing information
argo logs -n terraform-drift @latest | grep "⏱"
```
