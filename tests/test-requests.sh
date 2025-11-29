#!/bin/bash

# Get the API endpoint from Terraform output
API_ENDPOINT=$(cd terraform && terraform output -raw ingest_url 2>/dev/null)

if [ -z "$API_ENDPOINT" ]; then
  echo "Error: Could not get API endpoint. Make sure Terraform is deployed."
  exit 1
fi

echo "Testing API endpoint: $API_ENDPOINT"
echo ""

# Test 1: JSON input
echo "Test 1: JSON log input"
curl -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "acme_corp",
    "log_id": "log-001",
    "text": "User login from IP 192.168.1.1, phone: 555-123-4567"
  }'
echo -e "\n"

# Test 2: Text/plain input
echo "Test 2: Text/plain log input"
curl -X POST "$API_ENDPOINT" \
  -H "Content-Type: text/plain" \
  -H "X-Tenant-ID: beta_inc" \
  -d "Error: Database connection failed at 2025-11-28T10:30:00Z. Contact: 555-987-6543"
echo -e "\n"

# Test 3: Another JSON input with longer text (to test processing delay)
echo "Test 3: JSON with longer text"
curl -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_id": "gamma_llc",
    "log_id": "log-002",
    "text": "This is a longer log entry that contains multiple pieces of information including timestamps, IP addresses, and phone numbers like 555-111-2222. The system should process this and mask sensitive data appropriately."
  }'
echo -e "\n"

echo "Tests complete! Wait a few seconds for processing, then check DynamoDB."
