#!/bin/bash
if ! hash aws 2>/dev/null || ! hash kubectl 2>/dev/null; then
    echo "This script requires the AWS CLI and kubectl to be installed"
    exit 2
fi

set -eo pipefail

CLUSTER_NAME='bedrock-agent-eks-cluster'

ROLE_ARN=$(aws lambda get-function --function-name bedrock-agent-eks-executor --region us-west-2 --query "Configuration.Role" --output text) 

RBAC_OBJECT='kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: read-only
rules:
- apiGroups: [ "aquasecurity.github.io", ""]
  resources: ["*"]
  verbs: ["get", "watch", "list"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: read-only-binding
roleRef:
  kind: ClusterRole
  name: read-only
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: Group
  name: read-only-group'


echo ==========
echo Delete Role and RoleBinding in Kubernetes with kubectl
echo ==========
echo "$RBAC_OBJECT"
echo
while true; do
    read -p "Do you want to delete the ClusterRole and ClusterRoleBinding? (y/n)" response
    case $response in
        [Yy]* ) echo "$RBAC_OBJECT" | kubectl delete -f -; break;;
        [Nn]* ) break;;
        * ) echo "Response must start with y or n.";;
    esac
done

echo
echo ==========
echo Delete the access entry for the action group Lambda function
echo ==========
echo Cluster: $CLUSTER_NAME
echo RoleArn: $ROLE_ARN
echo
while true; do
    read -p "Do you want to delete the access entry? (y/n)" response
    case $response in
        [Yy]* ) aws eks delete-access-entry --cluster-name $CLUSTER_NAME --principal-arn $ROLE_ARN --region=us-west-2; break;;
        [Nn]* ) break;;
        * ) echo "Response must start with y or n.";;
    esac
done

