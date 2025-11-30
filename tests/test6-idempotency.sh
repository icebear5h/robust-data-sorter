#!/bin/bash
# Test 6: Idempotency - Send duplicate requests and verify only one record in DynamoDB

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test6-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)
SQS_QUEUE_URL=$(cd terraform && terraform output -raw sqs_queue_url 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

# Unique test identifiers
TEST_TENANT="idempotency_test"
TEST_LOG_ID="duplicate_log_123"
TEST_TEXT="This is a test log entry for idempotency testing with phone 555-999-8888"

# Start writing to results file
{
  echo "=========================================="
  echo "TEST 6: IDEMPOTENCY (MIXED CONTENT TYPES)"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
  echo "Testing idempotent write behavior with both JSON and text/plain inputs"
  echo "Tenant: $TEST_TENANT"
  echo "JSON Log ID: $TEST_LOG_ID (will be reused 5 times)"
  echo "Text Log IDs: Server-generated UUIDs (5 unique)"
  echo ""
  echo "Expected behavior:"
  echo "  - 5 duplicate JSON requests -> 1 DynamoDB record (idempotent)"
  echo "  - 5 unique text requests -> 5 DynamoDB records (unique log_ids)"
  echo "  - Total: 6 records for this tenant"
  echo ""
} | tee "$RESULTS_FILE"

# Clean up any existing test data first
{
  echo "Cleaning up any existing test data for this tenant..."
  TENANT_PK="TENANT#${TEST_TENANT}"

  # Query all items for this tenant
  EXISTING_ITEMS=$(aws dynamodb query \
    --table-name tenant_processed_logs \
    --region us-east-1 \
    --key-condition-expression "tenant_pk = :pk" \
    --expression-attribute-values "{\":pk\":{\"S\":\"$TENANT_PK\"}}" \
    --output json 2>/dev/null || echo '{"Items":[]}')

  EXISTING_COUNT=$(echo "$EXISTING_ITEMS" | jq '.Items | length')

  if [ "$EXISTING_COUNT" -gt 0 ]; then
    echo "  Found $EXISTING_COUNT existing records for tenant, deleting..."

    # Delete each item
    echo "$EXISTING_ITEMS" | jq -r '.Items[] | .log_sk.S' | while read -r log_sk; do
      aws dynamodb delete-item \
        --table-name tenant_processed_logs \
        --region us-east-1 \
        --key "{\"tenant_pk\":{\"S\":\"$TENANT_PK\"},\"log_sk\":{\"S\":\"$log_sk\"}}" \
        2>/dev/null || true
    done
    echo "  Cleanup complete"
  else
    echo "  No existing records found"
  fi

  echo "Ready to start test"
  echo ""
} | tee -a "$RESULTS_FILE"

# Send duplicate requests with mixed content types
{
  echo "========== SENDING DUPLICATE REQUESTS (MIXED CONTENT TYPES) =========="
  echo "Testing idempotency with both JSON and text/plain inputs"
  echo ""
  echo "Part 1: Sending 5 JSON requests with same tenant_id and log_id..."

  JSON_SUCCESS=0
  for i in {1..5}; do
    echo -n "  JSON Request $i: "

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_ENDPOINT/ingest" \
      -H "Content-Type: application/json" \
      -d "{\"tenant_id\":\"$TEST_TENANT\",\"log_id\":\"$TEST_LOG_ID\",\"text\":\"$TEST_TEXT\"}")

    if [ "$HTTP_CODE" = "202" ]; then
      echo "✓ Accepted (HTTP $HTTP_CODE)"
      JSON_SUCCESS=$((JSON_SUCCESS + 1))
    else
      echo "✗ Failed (HTTP $HTTP_CODE)"
    fi
  done

  echo ""
  echo "Part 2: Sending 5 text/plain requests with same tenant (each gets unique log_id)..."

  TEXT_SUCCESS=0
  for i in {1..5}; do
    echo -n "  Text Request $i: "

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_ENDPOINT/ingest" \
      -H "Content-Type: text/plain" \
      -H "X-Tenant-ID: $TEST_TENANT" \
      -d "Text upload #$i: $TEST_TEXT")

    if [ "$HTTP_CODE" = "202" ]; then
      echo "✓ Accepted (HTTP $HTTP_CODE)"
      TEXT_SUCCESS=$((TEXT_SUCCESS + 1))
    else
      echo "✗ Failed (HTTP $HTTP_CODE)"
    fi
  done

  echo ""
  echo "Successful JSON submissions: $JSON_SUCCESS/5 (should create 1 record)"
  echo "Successful text submissions: $TEXT_SUCCESS/5 (should create 5 records)"
  echo "Expected total records for tenant: 6"
  echo ""
} | tee -a "$RESULTS_FILE"

# Wait for worker to process all messages
{
  echo "Waiting 20 seconds for worker to process all duplicate messages..."
} | tee -a "$RESULTS_FILE"
sleep 20

# Verify only one record exists in DynamoDB
{
  echo ""
  echo "========== VERIFYING IDEMPOTENCY =========="

  TENANT_PK="TENANT#${TEST_TENANT}"
  LOG_SK="LOG#${TEST_LOG_ID}"

  # Query for the specific item
  ITEM=$(aws dynamodb get-item \
    --table-name tenant_processed_logs \
    --region us-east-1 \
    --key "{\"tenant_pk\":{\"S\":\"$TENANT_PK\"},\"log_sk\":{\"S\":\"$LOG_SK\"}}" \
    --output json 2>/dev/null)

  if echo "$ITEM" | jq -e '.Item' > /dev/null 2>&1; then
    echo "✓ Item found in DynamoDB"

    # Extract fields
    SOURCE=$(echo "$ITEM" | jq -r '.Item.source.S // "N/A"')
    ORIGINAL_TEXT=$(echo "$ITEM" | jq -r '.Item.original_text.S // "N/A"')
    MODIFIED_DATA=$(echo "$ITEM" | jq -r '.Item.modified_data.S // "N/A"')
    PROCESSED_AT=$(echo "$ITEM" | jq -r '.Item.processed_at.S // "N/A"')

    echo ""
    echo "Record details:"
    echo "  tenant_pk: $TENANT_PK"
    echo "  log_sk: $LOG_SK"
    echo "  source: $SOURCE"
    echo "  original_text: $ORIGINAL_TEXT"
    echo "  modified_data: $MODIFIED_DATA"
    echo "  processed_at: $PROCESSED_AT"

    # Verify phone number was masked
    if echo "$MODIFIED_DATA" | grep -q "XXX-XXX-8888"; then
      echo ""
      echo "✓ Phone number masking verified (555-999-8888 → XXX-XXX-8888)"
    else
      echo ""
      echo "✗ Phone number masking NOT detected"
    fi
  else
    echo "✗ Item NOT found in DynamoDB"
    echo "  This indicates the worker failed to process the message"
  fi

  # Query all items for this tenant to ensure no duplicates
  ALL_ITEMS=$(aws dynamodb query \
    --table-name tenant_processed_logs \
    --region us-east-1 \
    --key-condition-expression "tenant_pk = :pk" \
    --expression-attribute-values "{\":pk\":{\"S\":\"$TENANT_PK\"}}" \
    --output json 2>/dev/null)

  ITEM_COUNT=$(echo "$ALL_ITEMS" | jq '.Items | length')

  echo ""
  echo "Total items for tenant '$TEST_TENANT': $ITEM_COUNT"

  if [ "$ITEM_COUNT" = "6" ]; then
    echo "✓ IDEMPOTENCY TEST PASSED: Found 6 records as expected"
    echo "  - 1 record from 5 duplicate JSON requests (idempotent)"
    echo "  - 5 records from 5 unique text/plain requests (unique log_ids)"
  else
    echo "✗ IDEMPOTENCY TEST FAILED: Expected 6 records, found $ITEM_COUNT"
    echo "  - Expected: 1 JSON record + 5 text/plain records = 6 total"
    echo "  - Found: $ITEM_COUNT"
  fi

  echo ""
  echo "========== POST-TEST METRICS =========="

  # SQS Queue status
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

  # Total DynamoDB count
  TOTAL_ITEMS=$(aws dynamodb describe-table --table-name tenant_processed_logs --region us-east-1 --output json 2>/dev/null | jq -r '.Table.ItemCount // 0')
  echo ""
  echo "DynamoDB:"
  echo "  Total items (all tenants): $TOTAL_ITEMS"

  echo "========================================"
  echo ""
  echo "Results saved to: $RESULTS_FILE"
} | tee -a "$RESULTS_FILE"
