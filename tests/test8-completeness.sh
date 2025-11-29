#!/bin/bash
# Test 8: Completeness - Send 1000 unique requests and verify all are stored in DynamoDB

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test8-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

# Generate unique test prefix (timestamp-based hash)
# macOS uses 'md5', Linux uses 'md5sum'
if command -v md5sum &> /dev/null; then
  HASH=$(echo $RANDOM | md5sum | cut -c1-8)
else
  HASH=$(echo $RANDOM | md5 | cut -c1-8)
fi
TEST_PREFIX="test_$(date +%s)_${HASH}"
TEST_TENANT="completeness_test"
TOTAL_REQUESTS=1000

# Start writing to results file
{
  echo "=========================================="
  echo "TEST 8: COMPLETENESS (1000 unique requests)"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
  echo "Test Configuration:"
  echo "  Tenant: $TEST_TENANT"
  echo "  Prefix: $TEST_PREFIX"
  echo "  Total requests: $TOTAL_REQUESTS"
  echo "  Each request has unique ID: ${TEST_PREFIX}_<random>"
  echo ""
} | tee "$RESULTS_FILE"

# Create temp file to track sent IDs
SENT_IDS_FILE=$(mktemp)
trap "rm -f $SENT_IDS_FILE" EXIT

{
  echo "========== SENDING UNIQUE REQUESTS =========="
  echo "Sending $TOTAL_REQUESTS requests at 1000 RPM..."
  echo ""
} | tee -a "$RESULTS_FILE"

# Send requests and track IDs
SUCCESS_COUNT=0
FAILED_COUNT=0

for i in $(seq 1 $TOTAL_REQUESTS); do
  # Generate unique ID: prefix + request number + random suffix
  if command -v md5sum &> /dev/null; then
    RANDOM_SUFFIX=$(echo $RANDOM$RANDOM | md5sum | cut -c1-8)
  else
    RANDOM_SUFFIX=$(echo $RANDOM$RANDOM | md5 | cut -c1-8)
  fi
  LOG_ID="${TEST_PREFIX}_${i}_${RANDOM_SUFFIX}"

  # Save ID to tracking file
  echo "$LOG_ID" >> "$SENT_IDS_FILE"

  # Send request (fire and forget, don't wait for response)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_ENDPOINT/ingest" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$TEST_TENANT\",\"log_id\":\"$LOG_ID\",\"text\":\"Completeness test log $i\"}" \
    --max-time 5 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "202" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    # Print progress every 100 requests
    if [ $((i % 100)) -eq 0 ]; then
      echo "  Progress: $i/$TOTAL_REQUESTS sent, $SUCCESS_COUNT accepted" | tee -a "$RESULTS_FILE"
    fi
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi

  # Rate limiting: 1000 RPM = 1 request per 60ms
  sleep 0.06
done

{
  echo ""
  echo "Request Submission Complete:"
  echo "  Accepted (202): $SUCCESS_COUNT"
  echo "  Failed: $FAILED_COUNT"
  echo ""
} | tee -a "$RESULTS_FILE"

# Wait for worker to process all messages
WAIT_TIME=120
{
  echo "Waiting ${WAIT_TIME}s for worker to process all $SUCCESS_COUNT messages..."
  echo "(Processing time: ~5s per message, 2 workers in parallel)"
} | tee -a "$RESULTS_FILE"
sleep $WAIT_TIME

{
  echo ""
  echo "========== VERIFYING COMPLETENESS =========="
  echo ""
} | tee -a "$RESULTS_FILE"

# Query all items for this test tenant
TENANT_PK="TENANT#${TEST_TENANT}"

echo "Querying DynamoDB for tenant: $TEST_TENANT with prefix: $TEST_PREFIX..." | tee -a "$RESULTS_FILE"

# Query for items with this specific test prefix to avoid scanning thousands of old test records
# Use begins_with on the sort key to filter for only this test run
QUERY_RESULT=$(aws dynamodb query \
  --table-name tenant_processed_logs \
  --key-condition-expression "tenant_pk = :pk AND begins_with(log_sk, :prefix)" \
  --expression-attribute-values "{\":pk\":{\"S\":\"$TENANT_PK\"},\":prefix\":{\"S\":\"LOG#${TEST_PREFIX}\"}}" \
  --output json 2>/dev/null)

echo "Query complete, processing results..." | tee -a "$RESULTS_FILE"

FOUND_COUNT=$(echo "$QUERY_RESULT" | jq '.Items | length')

{
  echo ""
  echo "Results:"
  echo "  Requests sent: $TOTAL_REQUESTS"
  echo "  Requests accepted: $SUCCESS_COUNT"
  echo "  Records in DynamoDB: $FOUND_COUNT"
  echo ""
} | tee -a "$RESULTS_FILE"

# Extract log IDs from DynamoDB results
FOUND_IDS_FILE=$(mktemp)
trap "rm -f $SENT_IDS_FILE $FOUND_IDS_FILE" EXIT

echo "$QUERY_RESULT" | jq -r '.Items[].log_sk.S' | sed 's/^LOG#//' | sort > "$FOUND_IDS_FILE"

# Sort sent IDs for comparison
sort "$SENT_IDS_FILE" -o "$SENT_IDS_FILE"

# Find missing IDs (sent but not in DynamoDB)
MISSING_IDS=$(comm -23 "$SENT_IDS_FILE" "$FOUND_IDS_FILE")
MISSING_COUNT=$(echo "$MISSING_IDS" | grep -c . || echo 0)

# Find extra IDs (in DynamoDB but not sent - shouldn't happen)
EXTRA_IDS=$(comm -13 "$SENT_IDS_FILE" "$FOUND_IDS_FILE")
EXTRA_COUNT=$(echo "$EXTRA_IDS" | grep -c . || echo 0)

{
  echo "Verification:"
  echo "  Missing records: $MISSING_COUNT"
  echo "  Extra records: $EXTRA_COUNT"
  echo ""

  if [ "$MISSING_COUNT" -gt 0 ]; then
    echo "MISSING IDs (first 10):"
    echo "$MISSING_IDS" | head -10 | while read id; do
      echo "  - $id"
    done
    echo ""
  fi

  if [ "$EXTRA_COUNT" -gt 0 ]; then
    echo "EXTRA IDs (unexpected, first 10):"
    echo "$EXTRA_IDS" | head -10 | while read id; do
      echo "  - $id"
    done
    echo ""
  fi
} | tee -a "$RESULTS_FILE"

# Calculate success rate
if [ "$SUCCESS_COUNT" -gt 0 ]; then
  COMPLETENESS_RATE=$(echo "scale=2; ($FOUND_COUNT * 100) / $SUCCESS_COUNT" | bc)
else
  COMPLETENESS_RATE="0"
fi

{
  echo "=========================================="
  echo "COMPLETENESS TEST RESULT"
  echo "=========================================="
  echo ""
  echo "Completeness: ${COMPLETENESS_RATE}% (${FOUND_COUNT}/${SUCCESS_COUNT})"
  echo ""

  if [ "$FOUND_COUNT" -eq "$SUCCESS_COUNT" ]; then
    echo "✓ COMPLETENESS TEST PASSED"
    echo "  All accepted requests were successfully processed and stored"
  elif [ "$MISSING_COUNT" -le 5 ]; then
    echo "⚠ COMPLETENESS TEST: MINOR LOSS"
    echo "  ${MISSING_COUNT} requests lost (may still be processing)"
  else
    echo "✗ COMPLETENESS TEST FAILED"
    echo "  ${MISSING_COUNT} requests lost or still processing"
    echo "  Wait longer or check for Lambda errors"
  fi

  echo ""
  echo "Sample records (first 3):"
  echo "$QUERY_RESULT" | jq -r '.Items[:3] | .[] | "  \(.log_sk.S): \(.original_text.S[:50])..."'

  echo ""
  echo "=========================================="
  echo ""
  echo "Results saved to: $RESULTS_FILE"
  echo ""
  echo "To query records manually:"
  echo "  aws dynamodb query --table-name tenant_processed_logs \\"
  echo "    --key-condition-expression \"tenant_pk = :pk\" \\"
  echo "    --expression-attribute-values '{\":pk\":{\"S\":\"$TENANT_PK\"}}'"
} | tee -a "$RESULTS_FILE"
