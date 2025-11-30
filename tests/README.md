# Testing Suite

Seven tests covering smoke tests, load tests, idempotency, and crash/DLQ behavior.

**Run order:** Run test1, test6, test7 first (require empty queue). Load tests (test2-5) create queue backlog - wait a good few minutes between them.

## Tests

**Test 1:** Single request smoke test - verifies end-to-end flow.

**Test 2:** Max throughput (concurrency=3, 1 min) - measures throughput without throttling.

**Test 3:** 1000 RPM for 1 minute - repeat normal load.

**Test 4:** 3000 RPM for 1 minute - spike test, expect 90-100% success rate.

**Test 5:** 500 RPM for 2 minutes - sustained moderate load.

**Test 6:** Idempotency test - 5 duplicate JSON requests (same tenant_id + log_id) should create 1 record. 5 unique text/plain requests should create 5 records. Total: 6 records.

**Test 7:** Crash simulation & DLQ - worker crashes on `log_id='crash-test'`, retries 3 times, moves to DLQ. Takes ~3-4 minutes. **Requires `crash_simulation_enabled=true` in terraform/variables.tf (enabled by default).**

## Utility Scripts

**Monitor metrics:** `./tests/monitor-metrics.sh` - real-time SQS queue depth, DynamoDB counts, Lambda metrics.

**Clear DynamoDB:** `./tests/clear-dynamodb.sh` - deletes all items from `tenant_processed_logs` table.
