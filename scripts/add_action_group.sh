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
  existing_groups=()
else
  echo "Action groups found for AGENT_ID: ${AGENT_ID}"
  echo "Existing action groups:"
  echo $ACTION_GROUP_LIST
  # Read the newline-separated list into an array
  IFS=$'\n' read -r -d '' -a existing_groups <<< "$ACTION_GROUP_LIST" || true
fi

action_group_options=("k8s-action-group" "trivy-action-group")

available_options=()

# Compare and build list of available options
for option in "${action_group_options[@]}"; do
    is_existing=false
    for existing in "${existing_groups[@]}"; do
        if [ "$option" = "$existing" ]; then
            is_existing=true
            break
        fi
    done
    if [ "$is_existing" = false ]; then
        available_options+=("$option")
    fi
done

# Check if there are any available options
if [ ${#available_options[@]} -eq 0 ]; then
    echo "All available action groups have already been added to the agent."
    exit 0
# Present the user with a list of available options
else
    echo "Choose which action group to add to your Bedrock Agent:"
    select opt in "${available_options[@]}"
    do
        if [ -n "$opt" ]; then
            echo "Adding the $opt action group to your Bedrock Agent"
            ACTION_GROUP=$opt
            break
        else
            echo "Invalid option"
        fi
    done
fi

# Create the build directory if it doesn't already exist locally
if [ ! -d "../build" ]; then
  echo "Creating build directory"
  mkdir ../build
fi

# Delete the previous build artifacts for the action group lambda function if they already exist locally
if [ -d "../build/ag_lambda_build" ]; then
  echo "Deleting previous build artifacts for action group lambda"
  rm -rf ../build/ag_lambda_build ; 
fi 

# Delete the previous build artifacts for the create action group lambda function if they already exist
if [ -d "../build/create_ag_lambda_build" ]; then
  echo "Deleting previous build artifacts for create action group lambda"
  rm -rf ../build/create_ag_lambda_build ; 
fi

# Build the action group lambda function 
mkdir ../build/ag_lambda_build ; cd ../build/ag_lambda_build
cp -r ../../action_groups/${ACTION_GROUP}/lambda/* .
pip3 install --target . -r requirements.txt
cd ../../scripts

# Build the create action group lambda function 
mkdir ../build/create_ag_lambda_build ; cd ../build/create_ag_lambda_build
cp -r ../../custom_resources/create_action_group_lambda/* .
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
  echo "Creating S3 Bucket ${LAMBDA_BUCKET_NAME} to store index lambda artifacts"
  aws s3 mb s3://${LAMBDA_BUCKET_NAME}
fi 

# Upload the API Schema to S3
aws s3 sync ../action_groups/${ACTION_GROUP}/schema s3://${LAMBDA_BUCKET_NAME}/${ACTION_GROUP}/schema/

SCHEMA_KEY="${ACTION_GROUP}/schema/$(ls ../action_groups/${ACTION_GROUP}/schema)"

# Package action group lambda with the agent template 
aws cloudformation package \
 --template-file ../cfn-templates/agent-template.yaml \
 --s3-bucket $LAMBDA_BUCKET_NAME \
 --s3-prefix ${ACTION_GROUP}/lambda \
 --output-template-file ../build/packaged-agent-template.yaml

# # Deploy the action group stack
aws cloudformation deploy \
 --template-file ../build/packaged-agent-template.yaml \
 --stack-name ${ACTION_GROUP}-stack \
 --parameter-overrides ActionGroup=${ACTION_GROUP} SchemaBucket=${LAMBDA_BUCKET_NAME} SchemaKey=${SCHEMA_KEY} EKSClusterName=${EKS_CLUSTER_NAME} \
 --capabilities CAPABILITY_NAMED_IAM

# Create RBAC resources in the EKS Cluster 
RBAC_PATH=../action_groups/${ACTION_GROUP}/rbac/rbac.yaml
echo "Adding these RBAC resources to the ${EKS_CLUSTER_NAME} EKS Cluster:"
cat ${RBAC_PATH}
kubectl apply -f ${RBAC_PATH}
