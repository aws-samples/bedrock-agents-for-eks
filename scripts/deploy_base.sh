#!/bin/bash
set -eo pipefail

if ! hash aws 2>/dev/null || ! hash pip3 2>/dev/null; then
    echo "This script requires the AWS cli, and pip3 installed"
    exit 2
fi

# Create the build directory if it doesn't already exist locally
if [ ! -d "../build" ]; then
  echo "Creating build directory"
  mkdir ../build
fi

# Delete the previous build artifacts for the index lambda function if they already exist locally
if [ -d "../build/index_lambda_build" ]; then
  echo "Deleting previous build artifacts for the index lambda"
  rm -rf ../build/index_lambda_build ; 
fi

# Build the index lambda function 
mkdir ../build/index_lambda_build ; cd ../build/index_lambda_build
cp -r ../../custom_resources/create_vector_index_lambda/* .
pip3 install --target . -r requirements.txt
cd ../../scripts

# Set account ID 
AWS_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text)

# Check to see if lambda artifact bucket environment variable is set, use the default otherwise
if [ -z "$LAMBDA_BUCKET_NAME" ]; then 
  echo "LAMBDA_BUCKET_NAME environment variable not set"
  LAMBDA_BUCKET_NAME=bedrock-agents-for-eks-lambda-artifacts-${AWS_ACCOUNT}
  echo "Using default LAMBDA_BUCKET_NAME=${LAMBDA_BUCKET_NAME}"
fi

# Check to see if the lambda artifact bucket exists, create it otherwise
if ! aws s3api head-bucket --bucket $LAMBDA_BUCKET_NAME > /dev/null 2>&1; then
  echo "S3 Bucket ${LAMBDA_BUCKET_NAME} does not exit"
  echo "Creating S3 Bucket ${LAMBDA_BUCKET_NAME} to store index lamba artifacts"
  aws s3 mb s3://${LAMBDA_BUCKET_NAME}
fi 

# Package index lambda with base template
aws cloudformation package \
 --template-file ../cfn-templates/base-template.yaml \
 --s3-bucket $LAMBDA_BUCKET_NAME \
 --output-template-file ../build/packaged-base-template.yaml

# Check to see if knowledge base bucket environment variable is set, use the default otherwise
if [ -z "$KB_BUCKET_NAME" ]; then 
  echo "KB_BUCKET_NAME environment variable not set"
  KB_BUCKET_NAME=bedrock-agents-for-eks-knowledge-base-${AWS_ACCOUNT}
  echo "Using default KB_BUCKET_NAME=${KB_BUCKET_NAME}"
fi

# Check to see if knowledge base bucket exists, create it otherwise and hydrate with reference docs
if ! aws s3api head-bucket --bucket $KB_BUCKET_NAME > /dev/null 2>&1; then
  echo "S3 Bucket ${KB_BUCKET_NAME} does not exit"
  echo "Creating S3 Bucket ${KB_BUCKET_NAME} as a knowledge base data source"
  aws s3 mb s3://${KB_BUCKET_NAME}
  echo "Downloading Kubernetes and Amazon EKS reference documentation"

  if [ -d "../build/data_sources" ]; then
    echo "Deleting previous data_sources directory"
    rm -rf ../build/data_sources ; 
  fi

  mkdir ../build/data_sources

  # Get the Kubernetes Documentation: 
  git clone git@github.com:kubernetes/website.git ../build/kubernetes_docs  
  cp -r ../build/kubernetes_docs/content/en ../build/data_sources/kubernetes_docs
  rm -rf ../build/kubernetes_docs

  # Get the Amazon EKS Best Practices Guide:
  curl https://docs.aws.amazon.com/pdfs/eks/latest/best-practices/eks-bpg.pdf -o ../build/data_sources/eks-dest-practices-guide.pdf

  # Get the Amazon EKS User Guide: 
  curl https://docs.aws.amazon.com/pdfs/eks/latest/userguide/eks-ug.pdf -o ../build/data_sources/eks-user-guide.pdf

  # Get the Amazon EKS API Reference: 
  curl https://docs.aws.amazon.com/pdfs/eks/latest/APIReference/eks-api.pdf -o ../build/data_sources/eks-api-ref.pdf

  # Upload the docs to S3 
  echo "Uploading Kubernetes and Amazon EKS reference documentation to S3 Bucket for knowledge base"
  aws s3 sync ../build/data_sources s3://${KB_BUCKET_NAME} \
   --exclude "*" \
   --include "*.txt" \
   --include "*.md" \
   --include "*.html" \
   --include "*.pdf" 
fi 

# Deploy the base stack
aws cloudformation deploy \
 --template-file ../build/packaged-base-template.yaml \
 --stack-name bedrock-agents-for-eks-stack \
 --parameter-overrides KnowledgeBaseBucketName=${KB_BUCKET_NAME} SchemaBucketName=${LAMBDA_BUCKET_NAME}\
 --capabilities CAPABILITY_NAMED_IAM

# Catch the agent id in an environment variable 
export AGENT_ID=$(aws cloudformation describe-stacks \
 --stack-name bedrock-agents-for-eks-stack \
 --query 'Stacks[0].Outputs[?OutputKey==`BedrockAgentId`].OutputValue' --output text)