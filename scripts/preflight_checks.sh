#!/bin/bash
set -eo pipefail

if ! hash aws 2>/dev/null || ! hash pip3 2>/dev/null || ! hash kubectl 2>/dev/null; then
    echo "This script requires the AWS cli, pip3, and kubectl to be installed"
    exit 2
fi

if [ -z "$EKS_CLUSTER_NAME" ]; then 
    echo "Error: EKS_CLUSTER_NAME environment variable not set"
    echo "This script requires an EKS_CLUSTER_NAME environment variable to be set"
    exit 1
fi 

if aws eks describe-cluster --name $EKS_CLUSTER_NAME >/dev/null 2>&1; then
    echo "Updating kubeconfig for cluster $EKS_CLUSTER_NAME"
    aws eks update-kubeconfig --name $EKS_CLUSTER_NAME
else
    echo "Cluster $EKS_CLUSTER_NAME does not exist"
    exit 1
fi

if [ -z "$AGENT_ID" ]; then 
    output=$(aws cloudformation describe-stacks \
        --stack-name bedrock-agents-for-eks-stack \
        --query 'Stacks[0].Outputs[?OutputKey==`BedrockAgentId`].OutputValue' \
        --output text 2>&1)
    cmd_status=$?

    if [ $cmd_status -eq 0 ] && [ -n "$output" ]; then
        export AGENT_ID=$output
    else
        echo "Error: AGENT_ID environment variable not set and unable to retrieve from base CloudFormation stack."
        echo "This script requires an AGENT_ID environment variable to be set or the base CloudFormation stack to be deployed."
        exit 1
    fi
fi