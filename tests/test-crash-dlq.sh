#!/bin/bash
# Test crash simulation and DLQ behavior

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test-crash-dlq-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)
SQS_DLQ_URL=$(cd terraform && terraform output -raw sqs_dlq_url 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

if [ -z "$SQS_DLQ_URL" ]; then
  echo "Error: Could not get DLQ URL from Terraform"
  exit 1
fi

# Check if crash simulation is enabled
CRASH_SIM_ENABLED=$(aws lambda get-function-configuration \
  --function-name log-worker-lambda \
  --region us-east-1 \
  --query 'Environment.Variables.CRASH_SIMULATION' \
  --output text 2>/dev/null || echo "false")

if [ "$CRASH_SIM_ENABLED" != "true" ]; then
  echo ""
  echo "=========================================="
  echo "ERROR: CRASH SIMULATION IS DISABLED"
  echo "=========================================="
  echo ""
  echo "This test requires crash simulation to be enabled."
  echo ""
  echo "To enable crash simulation:"
  echo "  cd terraform"
  echo "  terraform apply -var='crash_simulation_enabled=true'"
  echo ""
  echo "Or to set it as the default, edit terraform/variables.tf"
  echo "and set crash_simulation_enabled default to \"true\""
  echo ""
  exit 1
fi

{
  echo "=========================================="
  echo "CRASH SIMULATION & DLQ TEST"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
  echo "This test verifies that:"
  echo "  1. Worker crashes when processing log_id='crash-test'"
  echo "  2. Message is retried 3 times"
  echo "  3. Message ends up in DLQ after failures"
  echo ""
  echo "Configuration:"
  echo "  - Visibility timeout: 1 minute (reduced from 5 minutes for faster testing)"
  echo "  - Max receive count: 3 retries"
  echo ""
} | tee "$RESULTS_FILE"

# Purge DLQ to start clean
{
  echo "Purging DLQ to start clean..."
  aws sqs purge-queue --queue-url "$SQS_DLQ_URL" --region us-east-1 2>/dev/null || echo "  (DLQ already empty or purge in progress)"
  sleep 2  # Wait for purge to complete
  echo ""
} | tee -a "$RESULTS_FILE"

# Get initial DLQ count (should be 0 after purge)
INITIAL_DLQ_ATTRS=$(aws sqs get-queue-attributes \
  --queue-url "$SQS_DLQ_URL" \
  --region us-east-1 \
  --attribute-names ApproximateNumberOfMessages \
  --output json 2>/dev/null)
INITIAL_DLQ_COUNT=$(echo "$INITIAL_DLQ_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')

{
  echo "Initial DLQ message count (after purge): $INITIAL_DLQ_COUNT"
  echo ""
} | tee -a "$RESULTS_FILE"

# Send crash-triggering request
{
  echo "Sending crash-triggering request (log_id='crash-test')..."

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_ENDPOINT/ingest" \
    -H "Content-Type: application/json" \
    -d '{"tenant_id":"crash_test_tenant","log_id":"crash-test","text":"This message will trigger a crash"}')

  echo "  HTTP Status: $HTTP_CODE"

  if [ "$HTTP_CODE" = "202" ]; then
    echo "  ✓ Request accepted (message queued)"
  else
    echo "  ✗ Request failed"
    exit 1
  fi
  echo ""
} | tee -a "$RESULTS_FILE"

# Wait for retries to complete
{
  echo "Waiting for retries to complete..."
  echo "  - Worker will attempt to process the message"
  echo "  - Crash simulation will throw an error"
  echo "  - SQS will retry 3 times (visibility timeout: 1 min each)"
  echo "  - After 3 failures, message moves to DLQ"
  echo ""
  echo "This takes ~3-4 minutes for all retries..."
  echo "Waiting 300 seconds (5 minutes) for retry cycle..."
} | tee -a "$RESULTS_FILE"
sleep 300

# Check DLQ for the failed message
{
  echo ""
  echo "========== CHECKING DLQ =========="
  echo ""

  # Get DLQ message count
  DLQ_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_DLQ_URL" \
    --region us-east-1 \
    --attribute-names ApproximateNumberOfMessages \
    --output json 2>&1) || {
    echo "✗ FAILED: Could not fetch DLQ attributes"
    echo "  Error: $DLQ_ATTRS"
    echo "  Check: AWS credentials, region, queue URL, permissions"
    exit 1
  }

  DLQ_COUNT=$(echo "$DLQ_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"') || {
    echo "✗ FAILED: Could not parse DLQ attributes (jq missing or invalid JSON)"
    echo "  Response: $DLQ_ATTRS"
    exit 1
  }

  echo "Current DLQ message count: $DLQ_COUNT"
  echo "Initial DLQ message count: $INITIAL_DLQ_COUNT"
  EXPECTED_COUNT=$((INITIAL_DLQ_COUNT + 1))
  echo "Expected count after test: $EXPECTED_COUNT"
  echo ""

  if [ "$DLQ_COUNT" -eq "$EXPECTED_COUNT" ]; then
    echo "✓ SUCCESS: DLQ count increased by 1 as expected (from $INITIAL_DLQ_COUNT to $DLQ_COUNT)"
    echo ""

    # Receive and display the DLQ message
    echo "DLQ Message Details:"
    DLQ_MSG=$(aws sqs receive-message \
      --queue-url "$SQS_DLQ_URL" \
      --region us-east-1 \
      --max-number-of-messages 1 \
      --output json 2>&1) || {
      echo "  ✗ Could not receive message from DLQ"
      echo "  Error: $DLQ_MSG"
    }

    if [ -n "$DLQ_MSG" ]; then
      echo "$DLQ_MSG" | jq -r '.Messages[0].Body' | jq '.' || echo "  (Could not parse message body)"
    fi

  elif [ "$DLQ_COUNT" -lt "$EXPECTED_COUNT" ]; then
    echo "✗ FAILED: DLQ count did not increase as expected"
    echo "  Expected: $EXPECTED_COUNT, Found: $DLQ_COUNT"
    echo "  Message may still be retrying or crash simulation is not enabled"
    echo ""
    echo "Check CloudWatch Logs for worker Lambda errors:"
    echo "  aws logs tail /aws/lambda/log-worker-lambda --follow"
  else
    echo "⚠ UNEXPECTED: DLQ count is higher than expected"
    echo "  Expected: $EXPECTED_COUNT, Found: $DLQ_COUNT"
    echo "  There may be other failed messages in the DLQ"
  fi

  echo ""
  echo "=========================================="
  echo ""
  echo "To enable crash simulation, redeploy with:"
  echo "  cd terraform"
  echo "  terraform apply -var='crash_simulation_enabled=true'"
  echo ""
  echo "To disable crash simulation:"
  echo "  cd terraform"
  echo "  terraform apply -var='crash_simulation_enabled=false'"
  echo ""
  echo "Results saved to: $RESULTS_FILE"
} | tee -a "$RESULTS_FILE"
