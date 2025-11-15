#!/bin/bash
set -eo pipefail

# ============================================================================
# Terraform Drift Detection Script with AI Summarization
# ============================================================================
# This script clones a repository, runs terraform plan across workspaces,
# generates AI summaries via AWS Bedrock, and sends notifications to Slack.
# ============================================================================

# Configuration from environment variables
APP_ID="${GITHUB_APP_ID:-}"
ORG="${GITHUB_ORG:-}"
REPO_NAME="${GITHUB_REPO:-}"
PRIVATE_KEY_PATH="${GITHUB_PRIVATE_KEY_PATH:-/tmp/github-app-private-key.pem}"
TERRAFORM_PATH="${TERRAFORM_PATH:-terraform/environments}"
DRIFT_THRESHOLD="${DRIFT_THRESHOLD:-0}"  # Only notify if changes >= this number
DRIFT_TYPE="${1:-full}"  # full or targeted

WORK_DIR=/tmp
REPO_PATH="$ORG/$REPO_NAME"

# Validate required environment variables
if [[ -z "$APP_ID" ]] || [[ -z "$ORG" ]] || [[ -z "$REPO_NAME" ]]; then
    echo "❌ Error: Required environment variables not set"
    echo "   Please set: GITHUB_APP_ID, GITHUB_ORG, GITHUB_REPO"
    exit 1
fi

cd "$WORK_DIR"

# ============================================================================
# GitHub App Authentication
# ============================================================================
echo "🔐 Authenticating with GitHub App..."

# Generate JWT token
ISSUED_AT=$(date +%s)
EXPIRATION=$((ISSUED_AT + 540)) # 9 minutes
HEADER_BASE64=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr -d '=' | tr '/+' '_-')
PAYLOAD_BASE64=$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$ISSUED_AT" "$EXPIRATION" "$APP_ID" | openssl base64 -A | tr -d '=' | tr '/+' '_-')
HEADER_PAYLOAD="${HEADER_BASE64}.${PAYLOAD_BASE64}"
SIGNATURE=$(printf '%s' "$HEADER_PAYLOAD" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | openssl base64 -A | tr -d '=' | tr '/+' '_-')
JWT="${HEADER_PAYLOAD}.${SIGNATURE}"

# Retrieve Installation ID
INSTALLATION_ID=$(curl -s -X GET \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/app/installations | \
    jq -r ".[] | select(.account.login==\"$ORG\") | .id")

if [[ -z "$INSTALLATION_ID" ]]; then
    echo "❌ Installation ID not found. Make sure the GitHub App is installed in organization '$ORG'."
    exit 1
fi

# Request installation access token
TOKEN=$(curl -s -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens | \
    jq -r .token)

if [[ -z "$TOKEN" ]] || [[ "$TOKEN" == "null" ]]; then
    echo "❌ Failed to get installation access token."
    exit 1
fi

echo "✅ GitHub authentication successful"

# ============================================================================
# Clone Repository
# ============================================================================
echo "📥 Cloning https://github.com/${REPO_PATH}.git"
git clone "https://x-access-token:${TOKEN}@github.com/${REPO_PATH}.git" "$REPO_NAME"
echo "✅ Repository successfully cloned into '$REPO_NAME'"

# ============================================================================
# Configure Drift Detection
# ============================================================================
if [[ "$DRIFT_TYPE" == 'targeted' ]]; then
    slack_thread_name="Terraform Targeted Drift Detection"
    target_environments="$WORK_DIR/$REPO_NAME/$TERRAFORM_PATH/staging $WORK_DIR/$REPO_NAME/$TERRAFORM_PATH/production"
    terraform_target_modules="${TERRAFORM_TARGET_MODULES:-}"  # Optional: specific modules
    targeted_drift_skip_count=0
else
    slack_thread_name="Terraform Full Drift Detection"
    target_environments="$WORK_DIR/$REPO_NAME/$TERRAFORM_PATH/*"
    terraform_target_modules=''
fi

# Initialize Slack payload
init_slack_payload=$(cat <<EOF
{
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "$slack_thread_name"
            }
        }
    ]
}
EOF
)
echo "$init_slack_payload" > "$WORK_DIR/slack_payload.json"

# ============================================================================
# Drift Detection Loop
# ============================================================================
total_changes=0
environments_with_drift=0

for env_dir in $target_environments; do
    if [[ ! -d "$env_dir" ]]; then
        echo "⚠️  Skipping non-existent directory: $env_dir"
        continue
    fi

    cd "$env_dir"
    env_name="$(basename $(pwd))"

    # Skip special directories
    if [[ "$env_name" == 'root' ]] || [[ "$env_name" == 'common' ]]; then
        continue
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔍 Checking environment: $env_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Initialize Terraform
    terraform init -input=false

    # Select workspace if it exists
    if terraform workspace list | grep -q "$env_name"; then
        terraform workspace select "$env_name"
    else
        echo "⚠️  Workspace '$env_name' not found, using current workspace"
    fi

    # Run terraform plan
    set +e
    terraform plan -lock=false -detailed-exitcode -out="$WORK_DIR/tfplan-$env_name" $terraform_target_modules
    plan_exit_code=$?
    set -e

    # Exit code 0 = no changes, 1 = error, 2 = changes detected
    if [[ $plan_exit_code -eq 0 ]]; then
        echo "✅ No drift detected in $env_name"

        # For targeted mode: skip if threshold reached
        if [[ "$DRIFT_TYPE" == 'targeted' ]]; then
            let "targeted_drift_skip_count++"
            if [[ $targeted_drift_skip_count -eq 2 ]]; then
                echo "✅ Drift threshold reached for targeted scan, exiting"
                exit 0
            fi
        fi
        continue
    elif [[ $plan_exit_code -eq 1 ]]; then
        echo "❌ Error running terraform plan for $env_name"
        continue
    fi

    # Parse plan output
    tfplan=$(terraform show -no-color "$WORK_DIR/tfplan-$env_name")
    clean_tfplan=$(echo "$tfplan" | awk -v line="Terraform will perform the following actions:" 'found {print} $0 ~ line {found=1}')

    if [[ -z "$clean_tfplan" ]]; then
        clean_tfplan="No changes detected for $env_name environment."
    else
        # Count changes
        changes_add=$(echo "$tfplan" | grep -c "will be created" || echo "0")
        changes_modify=$(echo "$tfplan" | grep -c "will be updated" || echo "0")
        changes_destroy=$(echo "$tfplan" | grep -c "will be destroyed" || echo "0")
        env_total_changes=$((changes_add + changes_modify + changes_destroy))

        total_changes=$((total_changes + env_total_changes))
        environments_with_drift=$((environments_with_drift + 1))

        echo "📊 Changes detected: +$changes_add ~$changes_modify -$changes_destroy (Total: $env_total_changes)"
    fi

    # Save plan to file
    plan_file="$WORK_DIR/plan-$env_name.txt"
    echo "$clean_tfplan" > "$plan_file"

    # Generate AI summary
    echo "🤖 Generating AI summary..."
    ai_summary=$(python3 /tmp/scripts/bedrock_summarize.py "$plan_file" "$env_name" | \
        sed -e 's/\\/\\\\/g; s/"/\\"/g' | \
        sed -e ':a; N; $!ba; s/\n/\\n/g; s/\t/\\t/g')

    # Create Slack block for this environment
    slack_payload_domain_block=$(cat <<EOF
{
    "type": "rich_text",
    "elements": [
        {
            "type": "rich_text_preformatted",
            "elements": [
                {
                    "type": "text",
                    "text": "Environment: $env_name\\n\\n",
                    "style": {
                        "bold": true
                    }
                },
                {
                    "type": "text",
                    "text": "$ai_summary",
                    "style": {
                        "bold": false
                    }
                }
            ]
        }
    ]
}
EOF
    )

    echo "$slack_payload_domain_block" > "$WORK_DIR/slack_payload_env_block.json"
    python3 /tmp/scripts/insert_big_json.py "$WORK_DIR/slack_payload.json" "$WORK_DIR/slack_payload_env_block.json" blocks > "$WORK_DIR/slack_payload_tmp.json"
    mv "$WORK_DIR/slack_payload_tmp.json" "$WORK_DIR/slack_payload.json"

    # Cleanup
    rm -f "$WORK_DIR/tfplan-$env_name"
    rm -f "$plan_file"
done

# ============================================================================
# Send Notification (if threshold met)
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Drift Detection Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total changes detected: $total_changes"
echo "Environments with drift: $environments_with_drift"
echo "Notification threshold: $DRIFT_THRESHOLD"

if [[ $total_changes -ge $DRIFT_THRESHOLD ]] || [[ $DRIFT_THRESHOLD -eq 0 ]]; then
    echo "✉️  Sending notification to Slack..."

    # Add summary footer
    summary_block=$(cat <<EOF
{
    "type": "section",
    "text": {
        "type": "mrkdwn",
        "text": "*Summary:* $total_changes total changes across $environments_with_drift environment(s)"
    }
}
EOF
    )
    echo "$summary_block" > "$WORK_DIR/summary_block.json"
    python3 /tmp/scripts/insert_big_json.py "$WORK_DIR/slack_payload.json" "$WORK_DIR/summary_block.json" blocks > "$WORK_DIR/slack_payload_tmp.json"
    mv "$WORK_DIR/slack_payload_tmp.json" "$WORK_DIR/slack_payload.json"

    # Send to Slack
    cat "$WORK_DIR/slack_payload.json"
    curl -X POST -H "Content-Type: application/json" \
        --data-binary "@$WORK_DIR/slack_payload.json" \
        "$SLACK_WEBHOOK"

    echo ""
    echo "✅ Notification sent successfully"
else
    echo "⏭️  Skipping notification (changes below threshold)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Drift detection complete"
