# Testing Suite

Comprehensive testing suite for the robust-data-sorter system, including load tests, crash simulation, and idempotency verification.

## Configuration Variables

### Terraform Variables

These variables configure the infrastructure. Set them when deploying:

```bash
cd terraform
terraform apply -var='crash_simulation_enabled=true'
```

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `aws_region` | AWS region to deploy resources | `us-east-1` | - |
| `environment` | Environment name (e.g., dev, prod) | `dev` | - |
| `ingest_lambda_zip` | Path to ingest Lambda package | `../ingest-lambda.zip` | - |
| `worker_lambda_zip` | Path to worker Lambda package | `../worker-lambda.zip` | - |
| `crash_simulation_enabled` | Enable crash simulation for DLQ testing | `true` | Set to `false` to disable crash tests |

### System Configuration (Terraform)

Key infrastructure settings:

| Parameter | Value | Purpose |
|-----------|-------|----------|
| **SQS visibility_timeout** | `60 seconds` | Time before failed message retries (reduced from 5 min for faster testing) |
| **Lambda worker timeout** | `30 seconds` | Max processing time per message |
| **Lambda ingest timeout** | `30 seconds` | Max time to queue messages |
| **DLQ maxReceiveCount** | `3` | Number of retries before moving to DLQ |
| **DLQ retention** | `14 days` | How long failed messages are kept |
| **Main queue retention** | `4 days` | How long unprocessed messages are kept |
| **Worker concurrency** | `7` | Max concurrent Lambda workers |
| **Batch size** | `10` | Messages per Lambda invocation |

### Load Test Variables

Configure load tests via environment variables:

```bash
API_ENDPOINT=https://your-api.execute-api.us-east-1.amazonaws.com \
  TEST_CONCURRENCY=2 \
  DURATION=3 \
  node tests/load-test.js
```

| Variable | Description | Default |
|----------|-------------|---------|
| `API_ENDPOINT` | API Gateway endpoint URL | Required |
| `TEST_CONCURRENCY` | Number of concurrent in-flight requests | `2` |
| `DURATION` | Duration in minutes | `1` |

**How Load Test Works (Max Throughput Mode):**
1. Fires requests continuously as fast as possible
2. Maintains exactly `TEST_CONCURRENCY` in-flight requests at all times
3. When a request completes, immediately launches another
4. Runs for `DURATION` minutes, then reports throughput

**Test Concurrency vs Lambda Slots:**
- Your AWS account has a total Lambda concurrency limit (check with `aws lambda get-account-settings`)
- Worker Lambda reserved: 7 concurrent executions
- Ingest Lambda available: ~3 concurrent executions (10 total - 7 workers)
- **If TEST_CONCURRENCY > 3**: API Gateway returns HTTP 503 (throttling)
- **Optimal TEST_CONCURRENCY**: 2-3 for best success rate

## Running Tests

**IMPORTANT: Do NOT run tests sequentially without waiting for queue to drain.**

Load tests create large SQS backlogs that interfere with subsequent tests, especially idempotency tests.

### Why Queue Backlog Happens

The system is intentionally constrained by AWS account concurrency limits to demonstrate real-world behavior:

**Processing capacity calculation:**
- AWS account limit: **10 concurrent Lambda executions total**
- Worker Lambda allocation: **7 concurrent executions** (configured in terraform/main.tf)
- Ingest Lambda allocation: **~3 concurrent executions** (remaining capacity)

**Load test throughput vs processing capacity:**
- Load test rate: **1000 RPM = ~16.7 messages/second**
- Average message size: **~50 characters**
- Processing time per message: **50 chars × 0.05s/char = 2.5 seconds**
- Worker throughput: **7 workers ÷ 2.5s = 2.8 messages/second**
- **Queue backlog growth: 16.7 - 2.8 = ~14 messages/second**

During a 1-minute load test at 1000 RPM, the queue builds up ~840 messages that need to drain after the test completes. This takes several minutes and interferes with subsequent tests that expect an empty queue.

**Recommended test order:**
1. Clean/isolated tests first: test1 (smoke), test6 (idempotency), test-crash-dlq
2. Load tests second: test2-5 (with queue monitoring between tests)

See individual test descriptions below.

## Tests

### Load Tests

#### Test 2: Max Throughput (Concurrency=2)
```bash
./tests/test2-normal.sh
```
- **Load**: Max throughput with concurrency=2 for 1 minute
- **Purpose**: Measure actual throughput without hitting Lambda throttling
- **Expected**: High success rate (>99%), ~900-1200 req/min throughput


### Functional Tests

#### Test 1: Single Request (Smoke Test)
```bash
./tests/test1-single.sh
```
- **Purpose**: Verify basic end-to-end flow with a single message
- **Expected**: Message queued, processed, and stored in DynamoDB

#### Test 6: Idempotency (Mixed Content Types)
```bash
./tests/test6-idempotency.sh
```
- **Purpose**: Verify idempotent writes with both JSON and text/plain inputs
- **Load**:
  - 5 duplicate JSON requests (same tenant_id + log_id)
  - 5 unique text/plain requests (same tenant_id, server-generated log_ids)
- **Expected**:
  - 1 DynamoDB record from 5 duplicate JSON requests (idempotent)
  - 5 DynamoDB records from 5 text/plain requests (unique log_ids)
  - Total: 6 records for the tenant

### Crash & DLQ Tests

#### Test: Crash Simulation & DLQ
```bash
./tests/test-crash-dlq.sh
```
- **Purpose**: Verify retry logic and DLQ behavior
- **Prerequisites**: **REQUIRES** `crash_simulation_enabled=true` in Terraform (default: enabled)
- **Behavior**: Sends `log_id='crash-test'` which triggers worker crash
- **Expected**: Message retried 3 times, then moved to DLQ
- **Duration**: ~3-4 minutes (visibility timeout × retries)

**The test script automatically checks if crash simulation is enabled and exits with an error if disabled.**

**Crash simulation is ENABLED BY DEFAULT** (set in terraform/variables.tf).

To disable crash simulation for production:
```bash
cd terraform
terraform apply -var='crash_simulation_enabled=false'
```

To re-enable crash simulation:
```bash
cd terraform
terraform apply -var='crash_simulation_enabled=true'
```

### Utility Scripts

#### Monitor Metrics
```bash
./tests/monitor-metrics.sh
```
- Real-time monitoring of SQS queue depth, DynamoDB counts, Lambda metrics
- Updates every 5 seconds
- Press Ctrl+C to stop

#### Clear DynamoDB
```bash
./tests/clear-dynamodb.sh
```
- Deletes all items from the `tenant_processed_logs` table
- Interactive confirmation required
- Useful for starting fresh between test runs

#### Run All Tests (DEPRECATED)
```bash
./tests/run-all-tests.sh
```
- **NOT RECOMMENDED**: Running tests sequentially causes queue backlog interference
- Idempotency tests will fail or give false results if run after load tests
- Better approach: Run tests individually in the recommended order (see "Running Tests" section)

## Results

Each test writes results to `tests/test{N}-results.txt` containing:
- Timestamp
- Load test metrics (total requests, success rate, latency P50/P95/P99, errors)
- Post-test infrastructure metrics (SQS queue depth, DynamoDB items, Lambda errors)

## Good Performance Indicators

- **Success rate**: >99.9%
- **API Gateway P99 latency**: <100ms
- **API Gateway P50 latency**: <50ms
- **SQS queue drain time**: <60 seconds after load stops
- **Lambda errors**: 0
- **DynamoDB write success**: 100%

## Usage

### Running Tests

**Run tests individually in this recommended order:**
```bash
# 1. Clean/isolated tests FIRST (require empty queue)
./tests/test1-single.sh          # Smoke test
./tests/test6-idempotency.sh     # Idempotency (MUST run before load tests)
./tests/test-crash-dlq.sh        # Crash & DLQ (requires crash_simulation_enabled=true)

# 2. Load tests SECOND (creates queue backlog)
./tests/test2-normal.sh          # Wait 30-60s between load tests
./tests/test3-normal-repeat.sh   # Monitor queue with ./tests/monitor-metrics.sh
./tests/test4-spike.sh
./tests/test5-sustained.sh
```

**DO NOT run idempotency after load tests** - queue backlog will cause false results.

**Monitor in real-time:**
```bash
./tests/monitor-metrics.sh
```

**Custom load test:**
```bash
API_ENDPOINT=https://your-api.execute-api.us-east-1.amazonaws.com \
  RPM=2000 \
  DURATION=3 \
  node tests/load-test.js
```

### Best Practices

1. **Wait between tests**: Allow queue to drain (check with `monitor-metrics.sh`)
2. **Clear data**: Run `./tests/clear-dynamodb.sh` for clean baseline
3. **Monitor CloudWatch**: Check Lambda logs for errors
   ```bash
   aws logs tail /aws/lambda/log-worker-lambda --follow --region us-east-1
   ```
4. **Check DLQ**: Verify no unexpected failures
   ```bash
   aws sqs get-queue-attributes --queue-url <DLQ_URL> --region us-east-1 \
     --attribute-names ApproximateNumberOfMessages
   ```

### Adjusting Performance

**To reduce retry time** (faster crash testing):
- Reduce `visibility_timeout_seconds` in `terraform/main.tf` (currently 60s)
- Reduce `timeout` for worker Lambda (currently 30s)
- Remember: visibility_timeout must be ≥ Lambda timeout

**To increase throughput**:
- Increase `maximum_concurrency` in event source mapping (currently 7)
- Increase `batch_size` for more messages per invocation (currently 10)
- Monitor Lambda concurrent executions to avoid throttling

**To adjust load test concurrency**:
- Edit `concurrency` in `tests/load-test.js` (currently 2)
- Higher = faster requests, but may hit API rate limits
