#!/bin/bash
if ! hash aws 2>/dev/null || ! hash pip3 2>/dev/null; then
    echo "This script requires the AWS cli, and pip3 installed"
    exit 2
fi

if [ -z "$EKS_CLUSTER_NAME" ]; then 
    echo "Error: EKS_CLUSTER_NAME environment variable not set"
    echo "This script requires an EKS_CLUSTER_NAME environment variable to be set"
    exit 1
fi 

set -eo pipefail

echo "Choose which action group to add to your Bedrock Agent:"
action_group_options=("k8s-action-group" "trivy-action-group")

select opt in "${action_group_options[@]}"

do
  case $REPLY in
    1)
      echo "Adding the k8s action group to your Bedrock Agent"
      ACTION_GROUP=k8s-action-group
      break
      ;;
    2)
      echo "Adding the trivy action group to your Bedrock Agent"
      ACTION_GROUP=trivy-action-group
      break
      ;;
    *)
      echo "Invalid option"
      ;;
  esac
done

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
  echo "Creating S3 Bucket ${LAMBDA_BUCKET_NAME} to store index lamba artifacts"
  aws s3 mb s3://${LAMBDA_BUCKET_NAME} --region us-west-2
fi 

# Upload the API Schema to S3
aws s3 sync ../action_groups/${ACTION_GROUP}/schema s3://${LAMBDA_BUCKET_NAME}/${ACTION_GROUP}/schema/ \
 --region us-west-2

SCHEMA_KEY="${ACTION_GROUP}/schema/$(ls ../action_groups/${ACTION_GROUP}/schema)"

# Package action group lambda with the agent template 
aws cloudformation package \
 --template-file ../cfn-templates/agent-template.yaml \
 --s3-bucket $LAMBDA_BUCKET_NAME \
 --output-template-file ../build/packaged-agent-template.yaml \
 --region us-west-2

# # Deploy the action group stack
aws cloudformation deploy \
 --template-file ../build/packaged-agent-template.yaml \
 --stack-name ${ACTION_GROUP}-stack \
 --parameter-overrides ActionGroup=${ACTION_GROUP} SchemaBucket=${LAMBDA_BUCKET_NAME} SchemaKey=${SCHEMA_KEY} EKSClusterName=${EKS_CLUSTER_NAME}\
 --capabilities CAPABILITY_NAMED_IAM \
 --region us-west-2

# Create RBAC resources in the EKS Cluster 
echo ==========
echo Create Role and RoleBinding in Kubernetes with kubectl
echo ==========
RBAC_PATH=../action_groups/${ACTION_GROUP}/rbac/rbac.yaml
RBAC_OBJECT=$(cat ${RBAC_PATH})
echo $RBAC_OBJECT
while true; do
    read -p "Do you want to create the ClusterRole and ClusterRoleBinding? (y/n)" response
    case $response in
        [Yy]* ) echo "$RBAC_OBJECT" | kubectl apply -f -; break;;
        [Nn]* ) break;;
        * ) echo "Response must start with y or n.";;
    esac
done


