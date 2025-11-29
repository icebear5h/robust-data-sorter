#!/bin/bash
# Run all load tests in sequence with pauses between

set -e

cd "$(dirname "$0")/.."

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "==========================================="
echo "RUNNING FULL LOAD TEST SUITE"
echo "==========================================="
echo ""
echo "This will run 8 tests in sequence:"
echo "  1. Smoke Test (single request)"
echo "  2. Normal (1000 RPM, 1 min)"
echo "  3. Normal repeat (1000 RPM, 1 min)"
echo "  4. Spike (3000 RPM, 1 min)"
echo "  5. Sustained (500 RPM, 2 min)"
echo "  6. Idempotency (10 duplicate requests)"
echo "  7. Find Limit (progressive load 1K-8K RPM)"
echo "  8. Completeness (1000 unique requests, verify all stored)"
echo ""
echo "Total runtime: ~14 minutes"
echo ""
read -p "Press Enter to start..."

# Test 1: Smoke Test
echo ""
echo -e "${GREEN}Running Test 1: Smoke Test${NC}"
./tests/test1-warmup.sh
echo ""
echo -e "${YELLOW}Waiting 10 seconds before next test...${NC}"
sleep 10

# Test 2: Normal
echo ""
echo -e "${GREEN}Running Test 2: Normal Load${NC}"
./tests/test2-normal.sh
echo ""
echo -e "${YELLOW}Waiting 10 seconds before next test...${NC}"
sleep 10

# Test 3: Normal repeat
echo ""
echo -e "${GREEN}Running Test 3: Normal Load (Repeat)${NC}"
./tests/test3-normal-repeat.sh
echo ""
echo -e "${YELLOW}Waiting 10 seconds before next test...${NC}"
sleep 10

# Test 4: Spike
echo ""
echo -e "${GREEN}Running Test 4: Spike Test${NC}"
./tests/test4-spike.sh
echo ""
echo -e "${YELLOW}Waiting 30 seconds for queue to drain...${NC}"
sleep 30

# Test 5: Sustained
echo ""
echo -e "${GREEN}Running Test 5: Sustained Load (this takes 2 minutes)${NC}"
./tests/test5-sustained.sh
echo ""
echo -e "${YELLOW}Waiting 15 seconds before next test...${NC}"
sleep 15

# Test 6: Idempotency
echo ""
echo -e "${GREEN}Running Test 6: Idempotency${NC}"
./tests/test6-idempotency.sh
echo ""
echo -e "${YELLOW}Waiting 10 seconds before final test...${NC}"
sleep 10

# Test 7: Find Limit
echo ""
echo -e "${GREEN}Running Test 7: Find Maximum Throughput (this takes ~5 minutes)${NC}"
./tests/test7-find-limit.sh
echo ""
echo -e "${YELLOW}Waiting 30 seconds before final test...${NC}"
sleep 30

# Test 8: Completeness
echo ""
echo -e "${GREEN}Running Test 8: Completeness (this takes ~3 minutes)${NC}"
./tests/test8-completeness.sh

echo ""
echo "==========================================="
echo -e "${GREEN}ALL TESTS COMPLETE${NC}"
echo "==========================================="
echo ""
echo "Check final system state:"
echo "  ./tests/monitor-metrics.sh"
echo ""
echo "Query processed logs:"
echo "  aws dynamodb scan --table-name tenant_processed_logs --max-items 5"
echo ""
