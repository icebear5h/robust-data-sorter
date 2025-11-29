# Load Tests

Performance and load testing suite for the robust-data-sorter system.

## Tests

### Test 1: Warmup
```bash
./tests/test1-warmup.sh
```
- **Load**: 100 RPM for 1 minute
- **Purpose**: Wake up cold Lambdas, establish baseline performance
- **Expected**: Fast response times, no errors

### Test 2: Normal Load
```bash
./tests/test2-normal.sh
```
- **Load**: 1000 RPM for 1 minute
- **Purpose**: Verify system handles expected production load
- **Expected**: Success rate >99.9%, P99 latency <100ms

### Test 3: Normal Load (Repeat)
```bash
./tests/test3-normal-repeat.sh
```
- **Load**: 1000 RPM for 1 minute
- **Purpose**: Verify consistent performance (no degradation)
- **Expected**: Similar metrics to Test 2

### Test 4: Spike Test
```bash
./tests/test4-spike.sh
```
- **Load**: 5000 RPM for 1 minute
- **Purpose**: Verify system handles sudden traffic spikes (5x normal)
- **Expected**: API accepts all requests, queue may backlog temporarily

### Test 5: Sustained Load
```bash
./tests/test5-sustained.sh
```
- **Load**: 500 RPM for 2 minutes
- **Purpose**: Verify system stability under prolonged moderate load
- **Expected**: Steady-state performance, queue drains within 60s after test

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

Run tests individually:
```bash
./tests/test1-warmup.sh
# Wait for queue to drain, check metrics
./tests/test2-normal.sh
```

Or run a custom load test:
```bash
API_ENDPOINT=https://your-api.execute-api.us-east-1.amazonaws.com \
  RPM=2000 \
  DURATION=3 \
  node tests/load-test.js
```
