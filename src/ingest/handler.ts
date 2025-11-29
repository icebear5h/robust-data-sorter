import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';
import { v4 as uuidv4 } from 'uuid';
import { InternalMessage, JsonLogInput } from '../types';

const sqsClient = new SQSClient({ region: process.env.AWS_REGION || 'us-east-1' });
const QUEUE_URL = process.env.QUEUE_URL!;

export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  try {
    const contentType = event.headers['content-type'] || event.headers['Content-Type'] || '';

    let internalMessage: InternalMessage;

    // Handle JSON input
    if (contentType.includes('application/json')) {
      if (!event.body) {
        return {
          statusCode: 400,
          body: JSON.stringify({ error: 'Request body is required' })
        };
      }

      const jsonInput: JsonLogInput = JSON.parse(event.body);

      // Validate required fields
      if (!jsonInput.tenant_id || !jsonInput.log_id || !jsonInput.text) {
        return {
          statusCode: 400,
          body: JSON.stringify({
            error: 'Missing required fields: tenant_id, log_id, and text are required'
          })
        };
      }

      internalMessage = {
        tenantId: jsonInput.tenant_id,
        logId: jsonInput.log_id,
        source: 'json',
        text: jsonInput.text
      };
    }
    // Handle text/plain input
    else if (contentType.includes('text/plain')) {
      const tenantId = event.headers['x-tenant-id'] || event.headers['X-Tenant-ID'];

      // Validate required fields
      if (!tenantId) {
        return {
          statusCode: 400,
          body: JSON.stringify({ error: 'X-Tenant-ID header is required for text uploads' })
        };
      }

      if (!event.body) {
        return {
          statusCode: 400,
          body: JSON.stringify({ error: 'Request body is required' })
        };
      }

      // Generate a log ID for text uploads
      const generatedLogId = uuidv4();

      internalMessage = {
        tenantId,
        logId: generatedLogId,
        source: 'text_upload',
        text: event.body
      };
    }
    // Unsupported content type
    else {
      return {
        statusCode: 415,
        body: JSON.stringify({
          error: 'Unsupported Media Type. Use application/json or text/plain'
        })
      };
    }

    // Send message to SQS
    await sqsClient.send(new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: JSON.stringify(internalMessage)
    }));

    // Return 202 Accepted immediately
    return {
      statusCode: 202,
      body: JSON.stringify({ status: 'accepted' })
    };
  } catch (error) {
    console.error('Error processing request:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Internal server error' })
    };
  }
};
