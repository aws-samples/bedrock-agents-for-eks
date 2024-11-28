import boto3
import os
import cfnresponse
from botocore.exceptions import ClientError

# Environment variables
agent_id = os.environ["AGENT_ID"]
lambda_arn = os.environ["LAMBDA_ARN"]
action_group = os.environ["ACTION_GROUP"]
schema_bucket = os.environ["SCHEMA_BUCKET"]
schema_key = os.environ["SCHEMA_KEY"]

def lambda_handler(event, context):
    """
    Handle CloudFormation custom resource requests for managing Bedrock agent action groups
    """
    try:
        request_type = event['RequestType']

        if request_type == 'Create':
            response_data = on_create()
        elif request_type == 'Update':
            response_data = on_update()
        elif request_type == 'Delete':
            response_data = on_delete()
        else:
            raise ValueError(f"Invalid request type: {request_type}")
        
        # Check the Status in response_data to determine success/failure
        status = cfnresponse.SUCCESS if response_data.get("Status") == "SUCCESS" else cfnresponse.FAILED

        cfnresponse.send(
            event,
            context,
            status,
            response_data,
            action_group  # Using action_group name as physical ID
        )

    except Exception as e:
        print(f"Error: {str(e)}")
        cfnresponse.send(
            event,
            context,
            cfnresponse.FAILED,
            {
                "Status": "FAILED",
                "Reason": str(e)
            },
            action_group  # Using action_group name as physical ID
        )

def on_create():
    """
    Handle Create request
    """
    try:
        client = boto3.client('bedrock-agent')
        response = client.create_agent_action_group(
            actionGroupExecutor={
                'lambda': lambda_arn
            },
            actionGroupName=action_group,
            actionGroupState='ENABLED',
            agentId=agent_id,
            agentVersion='DRAFT',
            apiSchema={
                's3': {
                    's3BucketName': schema_bucket,
                    's3ObjectKey': schema_key
                }
            },
            description='Use this action group to determine what namespaces exist on the EKS cluster, what pods have been deployed within each namespace, and retrieve details of the CIS Benchmark compliance report checks.'
        )
        
        action_group_id = response['agentActionGroup']['actionGroupId']
        
        return {
            "Status": "SUCCESS",
            "ActionGroupId": action_group_id,
            "Message": "Action Group created successfully"
        }
    
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        error_message = e.response.get('Error', {}).get('Message', str(e))
        raise Exception(f"Failed to create action group: {error_code} - {error_message}")

def on_update():
    """
    Handle Update request
    """
    try:
        client = boto3.client('bedrock-agent')
        
        try:
            response = client.list_agent_action_groups(
                agentId=agent_id,
                agentVersion='DRAFT'
            )
            
            # Find the action group with matching name
            action_group_id = None
            for group in response.get('agentActionGroupSummaries', []):
                if group.get('actionGroupName') == action_group:
                    action_group_id = group.get('actionGroupId')
                    break
            
            if not action_group_id:
                raise Exception(f"No action group found with name: {action_group}")

            # Update the action group using the found ID
            response = client.update_agent_action_group(
                agentId=agent_id,
                agentVersion='DRAFT',
                actionGroupId=action_group_id,
                actionGroupName=action_group,
                actionGroupState='ENABLED',
                apiSchema={
                    's3': {
                        's3BucketName': schema_bucket,
                        's3ObjectKey': schema_key
                    }
                },
                actionGroupExecutor={
                    'lambda': lambda_arn
                },
                description='Use this action group to determine what namespaces exist on the EKS cluster, what pods have been deployed within each namespace, and retrieve details of the CIS Benchmark compliance report checks.'
            )

            return {
                "Status": "SUCCESS",
                "ActionGroupId": action_group_id,
                "Message": "Action Group updated successfully"
            }

        except ClientError as e:
            if e.response['Error']['Code'] == 'ResourceNotFoundException':
                raise Exception(f"Action group not found: {action_group}")
            raise e

    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        error_message = e.response.get('Error', {}).get('Message', str(e))
        raise Exception(f"Failed to update action group: {error_code} - {error_message}")

def on_delete():
    """
    Handle Delete request
    """
    try:
        client = boto3.client('bedrock-agent')
        action_group_id = None
        
        try:
            response = client.list_agent_action_groups(
                agentId=agent_id,
                agentVersion='DRAFT'
            )
            
            # Find the action group with matching name
            for group in response.get('actionGroupSummaries', []):
                if group.get('actionGroupName') == action_group:
                    action_group_id = group.get('actionGroupId')
                    break
            
            if not action_group_id:
                error_msg = f"No action group found with name: {action_group}"
                print(f"Error: {error_msg}")
                return {
                    "Status": "FAILED",
                    "Message": error_msg
                }

            # First disable the action group
            try:
                client.update_agent_action_group(
                    agentId=agent_id,
                    agentVersion='DRAFT',
                    actionGroupId=action_group_id,
                    actionGroupName=action_group,
                    actionGroupState='DISABLED',
                    apiSchema={
                        's3': {
                            's3BucketName': schema_bucket,
                            's3ObjectKey': schema_key
                        }
                    },
                    actionGroupExecutor={
                        'lambda': lambda_arn
                    }
                )
                print(f"Successfully disabled action group: {action_group}")
                
                # Then delete the action group
                client.delete_agent_action_group(
                    actionGroupId=action_group_id,
                    agentId=agent_id,
                    agentVersion='DRAFT'
                )
                return {
                    "Status": "SUCCESS",
                    "ActionGroupId": action_group_id,
                    "Message": f"Action Group {action_group} deleted successfully"
                }
            except ClientError as modify_error:
                error_msg = f"Failed to modify/delete action group: {str(modify_error)}"
                print(f"Error: {error_msg}")
                return {
                    "Status": "FAILED",
                    "Message": error_msg
                }
                
        except ClientError as list_error:
            error_msg = f"Failed to list action groups: {str(list_error)}"
            print(f"Error: {error_msg}")
            return {
                "Status": "FAILED",
                "Message": error_msg
            }

    except Exception as e:
        error_msg = f"Unexpected error during deletion: {str(e)}"
        print(f"Error: {error_msg}")
        return {
            "Status": "FAILED",
            "Message": error_msg
        }


