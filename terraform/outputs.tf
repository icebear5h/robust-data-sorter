output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.log_api.api_endpoint
}

output "ingest_url" {
  description = "Full URL for the /ingest endpoint"
  value       = "${aws_apigatewayv2_api.log_api.api_endpoint}/ingest"
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.tenant_processed_logs.name
}

output "sqs_queue_url" {
  description = "URL of the SQS queue"
  value       = aws_sqs_queue.log_ingest_queue.url
}

output "sqs_dlq_url" {
  description = "URL of the SQS dead letter queue"
  value       = aws_sqs_queue.log_ingest_dlq.url
}
