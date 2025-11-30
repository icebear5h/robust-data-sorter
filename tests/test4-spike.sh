#!/bin/bash
# Test 4: Spike test - 3000 RPM for 1 minute (high load, may show some throttling)

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test4-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)
SQS_QUEUE_URL=$(cd terraform && terraform output -raw sqs_queue_url 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

{
  echo "=========================================="
  echo "TEST 4: SPIKE TEST (3000 RPM, 1 minute)"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
  echo "NOTE: 3000 RPM approaches the theoretical limit"
  echo "With 8 concurrent executions at P95 latency (~98ms):"
  echo "  Max = 8 * (1000/98) = 81.6 req/s = 4,896 RPM"
  echo "Expect 90-100% success rate"
  echo ""
} | tee "$RESULTS_FILE"

# Run load test
API_ENDPOINT="$API_ENDPOINT" RPM=3000 DURATION=1 node tests/load-test.js | tee -a "$RESULTS_FILE"

# Wait for processing to complete
{
  echo ""
  echo "Waiting 30 seconds for queue processing..."
} | tee -a "$RESULTS_FILE"
sleep 30

# Check metrics
{
  echo ""
  echo "========== POST-TEST METRICS =========="

  QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --region us-east-1 \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
    --output json 2>/dev/null)

  MESSAGES=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
  IN_FLIGHT=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')
  OLDEST=$(echo "$QUEUE_ATTRS" | jq -r '.Attributes.ApproximateAgeOfOldestMessage // "0"')

  echo "SQS Queue:"
  echo "  Messages remaining: $MESSAGES (expect some backlog)"
  echo "  In-flight: $IN_FLIGHT"
  echo "  Oldest message: ${OLDEST}s"

  ITEM_COUNT=$(aws dynamodb describe-table --table-name tenant_processed_logs --region us-east-1 --output json 2>/dev/null | jq -r '.Table.ItemCount // 0')
  echo ""
  echo "DynamoDB:"
  echo "  Total items: $ITEM_COUNT"

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
  echo "NOTE: Queue may still have messages after spike."
  echo "Check queue drain: aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --region us-east-1 --attribute-names ApproximateNumberOfMessages"
  echo ""
  echo "Results saved to: $RESULTS_FILE"
} | tee -a "$RESULTS_FILE"
