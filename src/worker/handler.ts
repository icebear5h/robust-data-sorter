import { SQSEvent, SQSRecord } from 'aws-lambda';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import { InternalMessage, ProcessedLog } from '../types';

const ddbClient = new DynamoDBClient({ region: process.env.AWS_REGION || 'us-east-1' });
const docClient = DynamoDBDocumentClient.from(ddbClient);
const TABLE_NAME = process.env.TABLE_NAME!;

/**
 * Simulates heavy CPU processing by sleeping for 0.05 seconds per character
 */
async function simulateHeavyProcessing(text: string): Promise<void> {
  const sleepTimeMs = text.length * 50; // 0.05 seconds = 50ms per character
  await new Promise(resolve => setTimeout(resolve, sleepTimeMs));
}


/**
 * Processes a single SQS message
 */
async function processMessage(record: SQSRecord): Promise<void> {
  const message: InternalMessage = JSON.parse(record.body);

  // Crash simulation for testing DLQ behavior
  if (process.env.CRASH_SIMULATION === 'true' && message.logId === 'crash-test') {
    console.error(`CRASH SIMULATION: Throwing error for log_id=${message.logId}`);
    throw new Error('Simulated worker crash for testing');
  }

  // Simulate heavy CPU-bound processing
  await simulateHeavyProcessing(message.text);


  // Build the DynamoDB record
  const processedLog: ProcessedLog = {
    tenant_pk: `TENANT#${message.tenantId}`,
    log_sk: `LOG#${message.logId}`,
    source: message.source,
    original_text: message.text,
    modified_data: message.text,
    processed_at: new Date().toISOString()
  };

  // Write to DynamoDB
  await docClient.send(new PutCommand({
    TableName: TABLE_NAME,
    Item: processedLog
  }));

  console.log(`Processed log ${message.logId} for tenant ${message.tenantId}`);
}

export const handler = async (event: SQSEvent): Promise<void> => {
  // Process all messages in the batch
  const promises = event.Records.map(record => processMessage(record));

  try {
    await Promise.all(promises);
  } catch (error) {
    console.error('Error processing messages:', error);
    // Throwing an error will cause the batch to be retried
    throw error;
  }
};
