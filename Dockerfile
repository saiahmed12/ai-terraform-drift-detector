FROM python:alpine3.19

LABEL target-image="terraform-drift:0.5.0" \
      description="Customized image to find drifts in Terraform resources for the CICD purposes"

# Pls, take care about the docker/atlantis/Dockerfile terraform version
ENV TERRAFORM_VERSION=1.8.3

WORKDIR /tmp

RUN apk update && apk add \
    aws-cli \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssl \
    unzip \
    wget && \
    wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip -d /usr/bin && \
    rm -rf /tmp/* && \
    rm -rf /var/cache/apk/* && \
    rm -rf /var/tmp/*

RUN pip install --no-cache-dir boto3

COPY scripts scripts

RUN chmod +x /tmp/scripts/*.sh
