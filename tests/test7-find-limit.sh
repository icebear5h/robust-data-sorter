#!/bin/bash
# Test 7: Find Maximum Throughput - Progressively increase RPM until failure

set -e
cd "$(dirname "$0")/.."

RESULTS_FILE="tests/test7-results.txt"

API_ENDPOINT=$(cd terraform && terraform output -raw api_endpoint 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint from Terraform"
  exit 1
fi

# Start writing to results file
{
  echo "=========================================="
  echo "TEST 7: FIND MAXIMUM THROUGHPUT"
  echo "=========================================="
  echo "Timestamp: $(date)"
  echo ""
  echo "Testing progressive load increases to find breaking point"
  echo "Each test runs for 30 seconds"
  echo ""
} | tee "$RESULTS_FILE"

# Test at different RPM levels
RPM_LEVELS=(1000 2000 3000 4000 5000 6000 7000 8000)

for RPM in "${RPM_LEVELS[@]}"; do
  {
    echo "=========================================="
    echo "Testing at $RPM RPM..."
    echo "=========================================="
  } | tee -a "$RESULTS_FILE"

  # Run short 30-second test
  API_ENDPOINT="$API_ENDPOINT" RPM="$RPM" DURATION=0.5 node tests/load-test.js 2>&1 | tee -a "$RESULTS_FILE"

  # Extract success rate from output
  SUCCESS_RATE=$(tail -20 "$RESULTS_FILE" | grep "Successful:" | tail -1 | awk '{print $3}' | tr -d '()')

  {
    echo ""
    echo "Result at $RPM RPM: $SUCCESS_RATE success rate"
    echo ""
  } | tee -a "$RESULTS_FILE"

  # If success rate drops below 95%, we've found the limit
  if [ -n "$SUCCESS_RATE" ]; then
    SUCCESS_NUM=$(echo "$SUCCESS_RATE" | tr -d '%')
    if (( $(echo "$SUCCESS_NUM < 95.0" | bc -l) )); then
      {
        echo "=========================================="
        echo "THRESHOLD FOUND: Success rate dropped below 95% at $RPM RPM"
        echo "=========================================="
        echo ""
        echo "Maximum sustainable throughput: ~$((RPM - 1000)) RPM"
        echo ""
      } | tee -a "$RESULTS_FILE"
      break
    fi
  fi

  # Wait between tests
  {
    echo "Waiting 10 seconds before next test..."
    echo ""
  } | tee -a "$RESULTS_FILE"
  sleep 10
done

{
  echo "=========================================="
  echo "THEORETICAL CAPACITY CALCULATION"
  echo "=========================================="
  echo ""
  echo "Current configuration:"
  echo "  - Total concurrent executions: 10"
  echo "  - Worker max concurrency: 2"
  echo "  - Ingest available executions: 8"
  echo ""
  echo "From test results:"
  echo "  - If avg latency = 56ms: 8 * (1000/56) = 142.8 req/s = 8,568 RPM"
  echo "  - If P95 latency = 98ms: 8 * (1000/98) = 81.6 req/s = 4,896 RPM"
  echo "  - If P99 latency = 149ms: 8 * (1000/149) = 53.7 req/s = 3,222 RPM"
  echo ""
  echo "Reality: Sustainable throughput depends on latency variance"
  echo "Expected limit: 4,000-5,000 RPM with 10 concurrent executions"
  echo ""
  echo "=========================================="
  echo ""
  echo "Results saved to: $RESULTS_FILE"
} | tee -a "$RESULTS_FILE"
