from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth
import boto3
import time
import json
import os
import cfnresponse

region = os.environ['AWS_REGION']
collection_endpoint = os.environ['COLLECTION_ENDPOINT']
vector_field = os.environ['VECTOR_FIELD_NAME']
vector_index_name = os.environ['VECTOR_INDEX_NAME']
text_field = os.environ['TEXT_FIELD']
metadata_field = os.environ['METADATA_FIELD']


def on_event(event, context):
  physical_id = "CreatedIndexId"
  reason = ''
  print(json.dumps(event))
  request_type = event['RequestType']

  if request_type == 'Create': 
    reason = on_create(event, physical_id=physical_id, region=region, endpoint=collection_endpoint, vector_field=vector_field,
                            vector_index_name=vector_index_name, text_field=text_field, metadata_field=metadata_field)
  
  elif request_type == 'Update': 
    reason = on_update(event, physical_id=physical_id)

  elif request_type == 'Delete': 
    reason = on_delete(event, physical_id=physical_id)
  
  else: 
    responseData = {
        'Status': 'FAILED',
        'Reason': "Invalid request type: %s" % request_type,
        'PhysicalResourceId': physical_id
    }
    cfnresponse.send(event, context, cfnresponse.FAILED, responseData)

  responseData = {
    'Status': 'SUCCESS',
        'Reason': reason,
        'PhysicalResourceId': physical_id
  }
  cfnresponse.send(event, context, cfnresponse.SUCCESS, responseData)
 


def on_create(event, physical_id, region, endpoint, vector_index_name,
              vector_field, text_field, metadata_field):
  props = event["ResourceProperties"]
  print("create new resource with props %s" % props)

  index_data(region=region, vector_index_name=vector_index_name, 
             text_field=text_field, metadata_field=metadata_field, 
             vector_field=vector_field, endpoint=endpoint)

  reason = "Created new resource with props %s" % props
  return reason


def on_update(event, physical_id):
  # physical_id = event["PhysicalResourceId"]
  props = event["ResourceProperties"]
  print("update resource %s with props %s" % (physical_id, props))

  reason = "Updated resource %s with props %s" % (physical_id, props)
  return reason


def on_delete(event, physical_id):
  # physical_id = event["PhysicalResourceId"]
  print("delete resource %s" % physical_id)

  reason = "Deleted resource %s" % physical_id
  return reason


def index_data(region, vector_index_name, text_field, 
               metadata_field, vector_field, endpoint):
    
    host = endpoint.replace("https://", "")
    
    # Set up auth for Opensearch client
    service = 'aoss'
    credentials = boto3.Session().get_credentials()
    awsauth = AWS4Auth(credentials.access_key, credentials.secret_key,
                       region, service, session_token=credentials.token)
    
    """Create an index"""
    # Build the OpenSearch client
    client = OpenSearch(
        hosts=[{'host': host, 'port': 443}],
        http_auth=awsauth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=300
    )
    # It can take up to a minute for data access rules to be enforced
    time.sleep(45)
    
    # Create index
    body = {
      "mappings": {
        "properties": {
          f"{metadata_field}": {
            "type": "text",
            "index": False
          },
          "id": {
            "type": "text",
            "fields": {
            "keyword": {
              "type": "keyword",
              "ignore_above": 256
              }
            }
          },
          f"{text_field}": {
            "type": "text",
            "index": True
          },
          f"{vector_field}": {
            "type": "knn_vector",
            "dimension": 1024,
            "method": {
              "engine": "faiss",
              "space_type": "l2",
              "name": "hnsw"
            }
          }
        }
      },
      "settings": {
        "index": {
          "number_of_shards": 2,
          "knn.algo_param": {
            "ef_search": 512
          },
          "knn": True,
        }
      }
    }

    response = client.indices.create(index=vector_index_name, body=body)
    print('\nCreating index:')
    print(response)
    