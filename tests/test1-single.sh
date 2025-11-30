#!/bin/bash
# Test 1: Smoke Test - Single request to verify basic functionality

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test1-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)
SQS_QUEUE_URL=$(cd terraform && terraform output -raw sqs_queue_url 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

# Start writing to results file
{
  echo "=========================================="
  echo "TEST 1: SMOKE TEST (Single Request)"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
} | tee "$RESULTS_FILE"

# Send a single test request
{
  echo "Sending single JSON request..."

  # Use curl's built-in timing which is cross-platform
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -X POST "$API_ENDPOINT/ingest" \
    -H "Content-Type: application/json" \
    -d '{"tenant_id":"DEMO_TEST_TENANT_LIVE","log_id":"smoke_test_1","text":"Smoke test log with phone 555-123-4567"}')

  HTTP_CODE=$(echo "$RESPONSE" | cut -d'|' -f1)
  TIME_TOTAL=$(echo "$RESPONSE" | cut -d'|' -f2)
  LATENCY_MS=$(echo "$TIME_TOTAL * 1000 / 1" | bc)

  echo "  HTTP Status: $HTTP_CODE"
  echo "  Latency: ${LATENCY_MS}ms"

  if [ "$HTTP_CODE" = "202" ]; then
    echo "  ✓ Request accepted"
  else
    echo "  ✗ Request failed"
  fi
  echo ""
} | tee -a "$RESULTS_FILE"

# Wait for processing to complete
{
  echo "Waiting 10 seconds for message to be processed..."
} | tee -a "$RESULTS_FILE"
sleep 10

# Check metrics
{
  echo ""
  echo "========== POST-TEST METRICS =========="

  # SQS Queue
  QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --region us-east-1 \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --output json 2>/dev/null)

  MESSAGES=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
  IN_FLIGHT=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')

  echo "SQS Queue:"
  echo "  Messages remaining: $MESSAGES"
  echo "  In-flight: $IN_FLIGHT"

  # DynamoDB count
  ITEM_COUNT=$(aws dynamodb describe-table --table-name tenant_processed_logs --region us-east-1 --output json 2>/dev/null | jq -r '.Table.ItemCount // 0')
  echo ""
  echo "DynamoDB:"
  echo "  Total items: $ITEM_COUNT"

  # Lambda errors (last 5 min)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
  START_TIME=$(date -u -v-5M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)

  INGEST_ERRORS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Errors \
    --dimensions Name=FunctionName,Value=ingest-lambda \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --period 300 --statistics Sum --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

  WORKER_ERRORS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Errors \
    --dimensions Name=FunctionName,Value=worker-lambda \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --period 300 --statistics Sum --output json 2>/dev/null | jq -r '.Datapoints[0].Sum // 0')

  echo ""
  echo "Lambda Errors (last 5 min):"
  echo "  Ingest: $INGEST_ERRORS"
  echo "  Worker: $WORKER_ERRORS"
  echo "========================================"
  echo ""
  echo "Results saved to: $RESULTS_FILE"
} | tee -a "$RESULTS_FILE"
