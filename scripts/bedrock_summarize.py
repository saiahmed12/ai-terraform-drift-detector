import json
import os
import sys
from typing import Any, Dict

import boto3


def build_prompt(plan_text: str, domain: str) -> str:
    domain_line = f"(domain: {domain})" if domain else ""
    instructions = (
        "Summarize the Terraform plan drift in a STRICT, consistent format for Slack. "
        "Do not use code fences. Do not add any extra text. Use exactly these 6 lines:\n"
        "Terraform Plan Drift Summary " + domain_line + "\n"
        "- Resources to add: <number>\n"
        "- Resources to change: <number>\n"
        "- Resources to destroy: <number>\n"
        "- Risk: <None|Destructive|Replacement|Mixed>\n"
        "- Action: <No action|Investigate|Apply>\n\n"
        "Base your counts and risk assessment only on this plan:\n\n"
    )
    return instructions + plan_text


def invoke_bedrock(model_id: str, prompt: str, region: str) -> str:
    client = boto3.client("bedrock-runtime", region_name=region)
    body: Dict[str, Any] = {
        "anthropic_version": "bedrock-2023-05-31",
        "system": (
            "You are a precise formatter. Always output exactly the required 6 lines, "
            "with the same labels and order. No code blocks. No commentary."
        ),
        "max_tokens": 384,
        "temperature": 0.0,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
    }
    response = client.invoke_model(modelId=model_id, body=json.dumps(body))
    payload = json.loads(response["body"].read())
    parts = payload.get("content", [])
    for part in parts:
        if part.get("type") == "text":
            return part.get("text", "")
    return ""


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: python bedrock_summarize.py /path/to/plan.txt [domain]", file=sys.stderr)
        sys.exit(1)

    plan_path = sys.argv[1]
    domain = sys.argv[2] if len(sys.argv) >= 3 else ""
    with open(plan_path, "r") as f:
        plan_text = f.read()

    model_id = os.environ.get(
        "BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20240620-v1:0"
    )
    region = os.environ.get("AWS_REGION", "us-east-1")

    prompt = build_prompt(plan_text, domain)
    summary = invoke_bedrock(model_id=model_id, prompt=prompt, region=region)
    print(summary.strip())


if __name__ == "__main__":
    main()


