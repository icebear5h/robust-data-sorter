#!/bin/bash
# Clear all items from the DynamoDB table

set -e
cd "$(dirname "$0")/.."

TABLE_NAME="tenant_processed_logs"

echo "=========================================="
echo "CLEAR DYNAMODB TABLE"
echo "=========================================="
echo ""
echo "This will delete ALL items from the $TABLE_NAME table"
echo ""

# Get current item count
ITEM_COUNT=$(aws dynamodb describe-table --table-name "$TABLE_NAME" --region us-east-1 --output json 2>/dev/null | jq -r '.Table.ItemCount // 0')

# Handle empty/null values
if [ -z "$ITEM_COUNT" ] || [ "$ITEM_COUNT" = "null" ]; then
  echo "Error: Could not determine item count. Check if table exists."
  exit 1
fi

echo "Current items in table: $ITEM_COUNT"
echo ""

if [ "$ITEM_COUNT" -eq 0 ]; then
  echo "Table is already empty. Nothing to do."
  exit 0
fi

read -p "Are you sure you want to delete all $ITEM_COUNT items? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "Scanning table for all items..."

# Scan to get all partition and sort keys
ALL_KEYS=$(aws dynamodb scan \
  --table-name "$TABLE_NAME" \
  --region us-east-1 \
  --attributes-to-get tenant_pk log_sk \
  --output json 2>/dev/null)

SCANNED_COUNT=$(echo "$ALL_KEYS" | jq '.Items | length')

echo "Found $SCANNED_COUNT items to delete"
echo ""

if [ "$SCANNED_COUNT" -eq 0 ]; then
  echo "No items found. Table may have been cleared already."
  exit 0
fi

echo "Deleting items..."

# Delete items in batches
DELETED=0
echo "$ALL_KEYS" | jq -c '.Items[]' | while read -r item; do
  TENANT_PK=$(echo "$item" | jq -r '.tenant_pk.S')
  LOG_SK=$(echo "$item" | jq -r '.log_sk.S')

  aws dynamodb delete-item \
    --table-name "$TABLE_NAME" \
    --region us-east-1 \
    --key "{\"tenant_pk\":{\"S\":\"$TENANT_PK\"},\"log_sk\":{\"S\":\"$LOG_SK\"}}" \
    2>/dev/null

  DELETED=$((DELETED + 1))

  # Print progress every 100 deletions
  if [ $((DELETED % 100)) -eq 0 ]; then
    echo "  Deleted: $DELETED/$SCANNED_COUNT"
  fi
done

echo ""
echo "=========================================="
echo "Deletion complete!"
echo "=========================================="
echo ""
echo "Verify table is empty:"
echo "  aws dynamodb describe-table --table-name $TABLE_NAME --query 'Table.ItemCount'"
