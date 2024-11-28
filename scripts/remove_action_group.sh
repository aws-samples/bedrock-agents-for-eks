#!/bin/bash
set -eo pipefail

# Run checks 
./preflight_checks.sh

# Check to see which action groups are already deployed
ACTION_GROUP_LIST=$(aws bedrock-agent list-agent-action-groups \
 --agent-version DRAFT \
 --agent-id $AGENT_ID \
 --output json | jq -r '.actionGroupSummaries[].actionGroupName')

if [ -z $ACTION_GROUP_LIST ]; then
  echo "No action groups found for AGENT_ID: ${AGENT_ID}"
  exit 1
else
  echo "Action groups found for AGENT_ID: ${AGENT_ID}"
  echo "Existing action groups:"
  echo $ACTION_GROUP_LIST
  # Read the newline-separated list into an array
  IFS=$'\n' read -r -d '' -a existing_groups <<< "$ACTION_GROUP_LIST" || true

  echo "Choose which action group to remove from your Bedrock Agent:"
  select opt in "${existing_groups[@]}"
  do
        if [ -n "$opt" ]; then
            echo "Removing the $opt action group from your Bedrock Agent"
            ACTION_GROUP=$opt
            break
        else
            echo "Invalid option"
        fi
  done
fi

# Delete the action group stack
aws cloudformation delete-stack --stack-name ${ACTION_GROUP}-stack

echo "Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete --stack-name ${ACTION_GROUP}-stack

echo "Stack deletion complete. Proceeding with S3 cleanup..."

# Set account ID 
AWS_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text)

# Check to see if lambda artifact bucket environment variable is set, use the default otherwise
if [ -z "$LAMBDA_BUCKET_NAME" ]; then 
  echo "LAMBDA_BUCKET_NAME environment variable not set"
  LAMBDA_BUCKET_NAME=bedrock-agents-for-eks-lambda-artifacts-${AWS_ACCOUNT}
  echo "Using default LAMBDA_BUCKET_NAME=${LAMBDA_BUCKET_NAME}"
fi

# Check to see if the lambda artifact bucket exists, exit otherwise
if ! aws s3api head-bucket --bucket $LAMBDA_BUCKET_NAME > /dev/null 2>&1; then
  echo "S3 Bucket ${LAMBDA_BUCKET_NAME} does not exit"
  echo "Please set the LAMBDA_BUCKET_NAME environment variable to an existing S3 bucket that contains the action group lambda artifacts"
  exit 1
fi 

SCHEMA_KEY="${ACTION_GROUP}/schema/$(ls ../action_groups/${ACTION_GROUP}/schema)"

# Remove API Schema from S3 
echo "Removing API Schema from S3"
aws s3 rm s3://${LAMBDA_BUCKET_NAME}/${SCHEMA_KEY}

# Remove action group lambda artifacts from S3
echo "Removing action group lambda artifacts from S3"
aws s3 rm s3://${LAMBDA_BUCKET_NAME}/${ACTION_GROUP}/lambda --recursive

# Remove RBAC resources from the EKS Cluster 
RBAC_PATH=../action_groups/${ACTION_GROUP}/rbac/rbac.yaml
echo "Removing these RBAC resources from the ${EKS_CLUSTER_NAME} EKS Cluster:"
cat ${RBAC_PATH}
kubectl delete -f ${RBAC_PATH}