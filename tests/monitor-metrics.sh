#!/bin/bash

# Monitor key metrics during load test
# Run this in a separate terminal while load testing

set -e

# Get the API endpoint from Terraform
cd "$(dirname "$0")/../terraform"
SQS_QUEUE_URL=$(terraform output -raw sqs_queue_url 2>/dev/null || echo "")
cd ..

if [ -z "$SQS_QUEUE_URL" ]; then
  echo "Error: Could not get SQS queue URL from Terraform"
  exit 1
fi

echo "Monitoring metrics (Ctrl+C to stop)..."
echo ""

while true; do
  clear
  echo "=========================== METRICS ==========================="
  date
  echo ""

  # SQS Queue depth
  echo "SQS Queue:"
  QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --region us-east-1 \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
    --output json 2>/dev/null || echo "{}")

  MESSAGES=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
  IN_FLIGHT=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')
  OLDEST=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateAgeOfOldestMessage // "0"')

  echo "  Messages in queue:     $MESSAGES"
  echo "  Messages in flight:    $IN_FLIGHT"
  echo "  Oldest message age:    ${OLDEST}s"
  echo ""

  # DynamoDB table stats
  echo "DynamoDB (tenant_processed_logs):"
  TABLE_INFO=$(aws dynamodb describe-table --table-name tenant_processed_logs --region us-east-1 --output json 2>/dev/null || echo "{}")
  ITEM_COUNT=$(echo "$TABLE_INFO" | jq -r '.Table.ItemCount // "N/A"')
  TABLE_SIZE=$(echo "$TABLE_INFO" | jq -r '.Table.TableSizeBytes // 0')
  TABLE_SIZE_MB=$(echo "scale=2; $TABLE_SIZE / 1024 / 1024" | bc 2>/dev/null || echo "0")

  echo "  Approx item count:     $ITEM_COUNT"
  echo "  Table size:            ${TABLE_SIZE_MB} MB"
  echo ""

  # Lambda metrics (last 5 minutes)
  echo "Lambda Functions (last 5 min):"
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
  START_TIME=$(date -u -v-5M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")

  if [ -n "$START_TIME" ]; then
    # Ingest Lambda
    INGEST_INVOCATIONS=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/Lambda \
      --metric-name Invocations \
      --dimensions Name=FunctionName,Value=ingest-lambda \
      --start-time "$START_TIME" \
      --end-time "$END_TIME" \
      --period 300 \
      --statistics Sum \
      --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

    INGEST_ERRORS=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/Lambda \
      --metric-name Errors \
      --dimensions Name=FunctionName,Value=ingest-lambda \
      --start-time "$START_TIME" \
      --end-time "$END_TIME" \
      --period 300 \
      --statistics Sum \
      --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

    echo "  Ingest invocations:    $INGEST_INVOCATIONS"
    echo "  Ingest errors:         $INGEST_ERRORS"

    # Worker Lambda
    WORKER_INVOCATIONS=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/Lambda \
      --metric-name Invocations \
      --dimensions Name=FunctionName,Value=worker-lambda \
      --start-time "$START_TIME" \
      --end-time "$END_TIME" \
      --period 300 \
      --statistics Sum \
      --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

    WORKER_ERRORS=$(aws cloudwatch get-metric-statistics \
      --namespace AWS/Lambda \
      --metric-name Errors \
      --dimensions Name=FunctionName,Value=worker-lambda \
      --start-time "$START_TIME" \
      --end-time "$END_TIME" \
      --period 300 \
      --statistics Sum \
      --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

    echo "  Worker invocations:    $WORKER_INVOCATIONS"
    echo "  Worker errors:         $WORKER_ERRORS"
  fi

  echo ""
  echo "==============================================================="
  echo "Refreshing in 5 seconds..."
  sleep 5
done
