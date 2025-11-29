/**
 * Internal message format used between Ingest Lambda and Worker Lambda
 */
export interface InternalMessage {
  tenantId: string;
  logId: string;
  source: 'json' | 'text_upload';
  text: string;
}

/**
 * JSON input format for POST /ingest
 */
export interface JsonLogInput {
  tenant_id: string;
  log_id: string;
  text: string;
}

/**
 * DynamoDB record structure
 */
export interface ProcessedLog {
  tenant_pk: string;  // Format: "TENANT#{tenant_id}"
  log_sk: string;      // Format: "LOG#{log_id}"
  source: 'json' | 'text_upload';
  original_text: string;
  modified_data: string;
  processed_at: string;
}
