#!/bin/bash
if ! hash aws 2>/dev/null || ! hash kubectl 2>/dev/null || ! hash eksctl 2>/dev/null; then
    echo "This script requires the AWS cli, kubectl, and eksctl installed"
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
echo Create Role and RoleBinding in Kubernetes with kubectl
echo ==========
echo "$RBAC_OBJECT"
echo
while true; do
    read -p "Do you want to create the ClusterRole and ClusterRoleBinding? (y/n)" response
    case $response in
        [Yy]* ) echo "$RBAC_OBJECT" | kubectl apply -f -; break;;
        [Nn]* ) break;;
        * ) echo "Response must start with y or n.";;
    esac
done

echo
echo ==========
echo Update aws-auth configmap with a new mapping
echo ==========
echo Cluster: $CLUSTER_NAME
echo RoleArn: $ROLE_ARN
echo
while true; do
    read -p "Do you want to create the aws-auth configmap entry? (y/n)" response
    case $response in
        [Yy]* ) eksctl create iamidentitymapping --cluster $CLUSTER_NAME --region=us-west-2 --group read-only-group --arn $ROLE_ARN; break;;
        [Nn]* ) break;;
        * ) echo "Response must start with y or n.";;
    esac
done

