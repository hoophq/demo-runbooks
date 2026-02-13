#!/bin/bash
# Batch Export Hoop Sessions to S3
# This runbook fetches multiple sessions from Hoop based on filters and uploads them to an S3 bucket
#
# Template Variables:
# - connection_name: Filter sessions by connection name
# - time_range_hours: Export sessions from the last N hours
# - s3_bucket: The target S3 bucket name
# - s3_key_prefix: (optional) Prefix for S3 objects
# - export_format: Session export format (json, csv, txt)
# - max_sessions: Maximum number of sessions to export
# - hoop_api_base_url: Hoop API base URL
# - hoop_api_token: API token for authentication

set -euo pipefail

# Template variables
CONNECTION_NAME="{{ .connection_name | description "Filter sessions by connection name (optional)" }}"
TIME_RANGE_HOURS="{{ .time_range_hours | default "24" | description "Export sessions from the last N hours" | type "number" }}"
S3_BUCKET="{{ .s3_bucket | required "s3_bucket is required" | description "Target S3 bucket name" | pattern "^[a-z0-9][a-z0-9.-]*[a-z0-9]$" }}"
S3_KEY_PREFIX="{{ .s3_key_prefix | default "hoop-sessions" | description "S3 object key prefix (folder path)" }}"
EXPORT_FORMAT="{{ .export_format | default "json" | description "Export format: json, csv, or txt" | pattern "^(json|csv|txt)$" }}"
MAX_SESSIONS="{{ .max_sessions | default "100" | description "Maximum number of sessions to export" | type "number" }}"
HOOP_API_BASE_URL="{{ .hoop_api_base_url | default "https://use.hoop.dev" | description "Hoop API base URL" }}"
HOOP_API_TOKEN="{{ .hoop_api_token | required "hoop_api_token is required" | description "Hoop API authentication token" }}"

# Derived variables
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
BATCH_ID="${TIMESTAMP}_$(openssl rand -hex 4)"
TEMP_DIR="/tmp/hoop_batch_${BATCH_ID}"
mkdir -p "${TEMP_DIR}"

echo "================================================"
echo "Hoop Batch Session Export to S3"
echo "================================================"
echo "Connection Filter: ${CONNECTION_NAME:-"(all connections)"}"
echo "Time Range: Last ${TIME_RANGE_HOURS} hours"
echo "Export Format: ${EXPORT_FORMAT}"
echo "Max Sessions: ${MAX_SESSIONS}"
echo "Target Bucket: s3://${S3_BUCKET}/${S3_KEY_PREFIX}/"
echo "Batch ID: ${BATCH_ID}"
echo "================================================"
echo ""

# Step 1: List sessions from Hoop API
echo "[1/4] Fetching session list from Hoop..."

# Calculate start time (N hours ago)
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS date command
  START_TIME=$(date -u -v-${TIME_RANGE_HOURS}H +"%Y-%m-%dT%H:%M:%SZ")
else
  # Linux date command
  START_TIME=$(date -u -d "${TIME_RANGE_HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")
fi

# Build query parameters
QUERY_PARAMS="limit=${MAX_SESSIONS}&start_time=${START_TIME}"
if [ -n "${CONNECTION_NAME}" ]; then
  QUERY_PARAMS="${QUERY_PARAMS}&connection=${CONNECTION_NAME}"
fi

# Fetch sessions list
LIST_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer ${HOOP_API_TOKEN}" \
  -H "Accept: application/json" \
  "${HOOP_API_BASE_URL}/api/sessions?${QUERY_PARAMS}")

HTTP_CODE=$(echo "$LIST_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$LIST_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "Error: Failed to list sessions (HTTP ${HTTP_CODE})"
  echo "Response: ${RESPONSE_BODY}"
  rm -rf "${TEMP_DIR}"
  exit 1
fi

# Extract session IDs using jq
SESSION_IDS=$(echo "$RESPONSE_BODY" | jq -r '.data[]?.id // empty' | head -n "${MAX_SESSIONS}")
SESSION_COUNT=$(echo "$SESSION_IDS" | wc -l | tr -d ' ')

if [ -z "$SESSION_IDS" ] || [ "$SESSION_COUNT" -eq 0 ]; then
  echo "No sessions found matching the criteria"
  rm -rf "${TEMP_DIR}"
  exit 0
fi

echo "✓ Found ${SESSION_COUNT} session(s) to export"
echo ""

# Step 2: Verify S3 bucket access
echo "[2/4] Verifying S3 bucket access..."
if ! aws s3 ls "s3://${S3_BUCKET}" >/dev/null 2>&1; then
  echo "Error: Cannot access S3 bucket '${S3_BUCKET}'"
  rm -rf "${TEMP_DIR}"
  exit 1
fi
echo "✓ S3 bucket accessible"
echo ""

# Step 3: Download and upload each session
echo "[3/4] Processing sessions..."
SUCCESSFUL=0
FAILED=0
COUNTER=0

while IFS= read -r SESSION_ID; do
  COUNTER=$((COUNTER + 1))
  echo "  [${COUNTER}/${SESSION_COUNT}] Processing session: ${SESSION_ID}"

  # Get download URL
  DOWNLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${HOOP_API_TOKEN}" \
    -H "Accept: application/json" \
    "${HOOP_API_BASE_URL}/api/sessions/${SESSION_ID}?extension=${EXPORT_FORMAT}")

  HTTP_CODE=$(echo "$DOWNLOAD_RESPONSE" | tail -n1)
  RESPONSE_BODY=$(echo "$DOWNLOAD_RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" != "200" ]; then
    echo "    ✗ Failed to get download URL (HTTP ${HTTP_CODE})"
    FAILED=$((FAILED + 1))
    continue
  fi

  DOWNLOAD_URL=$(echo "$RESPONSE_BODY" | jq -r '.download_url // empty')

  if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    echo "    ✗ No download URL in response"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Download session
  TEMP_FILE="${TEMP_DIR}/${SESSION_ID}.${EXPORT_FORMAT}"
  HTTP_CODE=$(curl -s -w "%{http_code}" -o "${TEMP_FILE}" \
    -H "Authorization: Bearer ${HOOP_API_TOKEN}" \
    "${DOWNLOAD_URL}")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "    ✗ Failed to download (HTTP ${HTTP_CODE})"
    FAILED=$((FAILED + 1))
    rm -f "${TEMP_FILE}"
    continue
  fi

  # Upload to S3
  S3_KEY="${S3_KEY_PREFIX}/${BATCH_ID}/${SESSION_ID}.${EXPORT_FORMAT}"
  if aws s3 cp "${TEMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
    --metadata "session-id=${SESSION_ID},batch-id=${BATCH_ID},export-timestamp=${TIMESTAMP}" \
    --quiet; then
    FILE_SIZE=$(wc -c < "${TEMP_FILE}" | tr -d ' ')
    echo "    ✓ Uploaded (${FILE_SIZE} bytes)"
    SUCCESSFUL=$((SUCCESSFUL + 1))
  else
    echo "    ✗ Failed to upload to S3"
    FAILED=$((FAILED + 1))
  fi

  rm -f "${TEMP_FILE}"
done <<< "$SESSION_IDS"

echo ""
echo "✓ Session processing complete"
echo ""

# Step 4: Create manifest file
echo "[4/4] Creating batch manifest..."
MANIFEST_FILE="${TEMP_DIR}/manifest.json"
cat > "${MANIFEST_FILE}" <<EOF
{
  "batch_id": "${BATCH_ID}",
  "export_timestamp": "${TIMESTAMP}",
  "connection_name": "${CONNECTION_NAME:-"all"}",
  "time_range_hours": ${TIME_RANGE_HOURS},
  "export_format": "${EXPORT_FORMAT}",
  "total_sessions": ${SESSION_COUNT},
  "successful_exports": ${SUCCESSFUL},
  "failed_exports": ${FAILED},
  "s3_bucket": "${S3_BUCKET}",
  "s3_key_prefix": "${S3_KEY_PREFIX}/${BATCH_ID}"
}
EOF

aws s3 cp "${MANIFEST_FILE}" "s3://${S3_BUCKET}/${S3_KEY_PREFIX}/${BATCH_ID}/manifest.json" \
  --content-type "application/json" \
  --quiet

echo "✓ Manifest uploaded"
echo ""

# Cleanup
rm -rf "${TEMP_DIR}"

# Final summary
echo "================================================"
echo "Batch Export Complete!"
echo "================================================"
echo "Batch ID: ${BATCH_ID}"
echo "Total Sessions: ${SESSION_COUNT}"
echo "Successful: ${SUCCESSFUL}"
echo "Failed: ${FAILED}"
echo "S3 Location: s3://${S3_BUCKET}/${S3_KEY_PREFIX}/${BATCH_ID}/"
echo ""
echo "View in AWS Console:"
echo "https://s3.console.aws.amazon.com/s3/buckets/${S3_BUCKET}?prefix=${S3_KEY_PREFIX}/${BATCH_ID}/"
echo "================================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
