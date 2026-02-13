#!/bin/bash
# Export Hoop Session to S3 (Secrets Manager Version)
# This runbook fetches the Hoop API token from AWS Secrets Manager to avoid
# exposing it in session recordings
#
# Template Variables:
# - session_id: The Hoop session ID to export
# - s3_bucket: The target S3 bucket name
# - s3_key_prefix: (optional) Prefix for the S3 object key
# - export_format: Session export format (json, csv, txt)
# - hoop_api_base_url: Hoop API base URL
# - hoop_api_token_secret_name: AWS Secrets Manager secret name containing the Hoop API token
# - hoop_api_token_secret_key: (optional) JSON key if secret is JSON format

set -euo pipefail

# Template variables
SESSION_ID="{{ .session_id | required "session_id is required" | description "The Hoop session ID to export" }}"
S3_BUCKET="{{ .s3_bucket | required "s3_bucket is required" | description "Target S3 bucket name" | pattern "^[a-z0-9][a-z0-9.-]*[a-z0-9]$" }}"
S3_KEY_PREFIX="{{ .s3_key_prefix | default "hoop-sessions" | description "S3 object key prefix (folder path)" }}"
EXPORT_FORMAT="{{ .export_format | default "json" | description "Export format: json, csv, or txt" | pattern "^(json|csv|txt)$" }}"
HOOP_API_BASE_URL="{{ .hoop_api_base_url | default "https://demo.hoop.dev" | description "Hoop API base URL" }}"
TOKEN_SECRET_NAME="{{ .hoop_api_token_secret_name | required "hoop_api_token_secret_name is required" | description "AWS Secrets Manager secret name containing Hoop API token" }}"
TOKEN_SECRET_KEY="{{ .hoop_api_token_secret_key | default "" | description "JSON key if secret is JSON format (leave empty if plaintext)" }}"

# Derived variables
TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
TEMP_FILE="/tmp/hoop_session_${SESSION_ID}_${TIMESTAMP}.${EXPORT_FORMAT}"
S3_KEY="${S3_KEY_PREFIX}/${SESSION_ID}_${TIMESTAMP}.${EXPORT_FORMAT}"

echo "================================================"
echo "Hoop Session Export to S3 (Secrets-Safe)"
echo "================================================"
echo "Session ID: ${SESSION_ID}"
echo "Export Format: ${EXPORT_FORMAT}"
echo "Target Bucket: s3://${S3_BUCKET}/${S3_KEY}"
echo "Token Source: AWS Secrets Manager (${TOKEN_SECRET_NAME})"
echo "================================================"
echo ""

# Step 0: Fetch Hoop API token from AWS Secrets Manager
echo "[0/4] Retrieving Hoop API token from Secrets Manager..."
echo "  Secret: ${TOKEN_SECRET_NAME}"

# Try to fetch secret from default region first, then fall back to common regions
SECRET_VALUE=""
SECRET_REGION=""

# Try default region first
if SECRET_VALUE=$(aws secretsmanager get-secret-value \
  --secret-id "${TOKEN_SECRET_NAME}" \
  --query SecretString \
  --output text 2>/dev/null); then
  SECRET_REGION=$(aws configure get region 2>/dev/null || echo "default")
else
  # Try common regions
  for region in us-west-2 us-east-1 us-east-2 eu-west-1; do
    if SECRET_VALUE=$(aws secretsmanager get-secret-value \
      --secret-id "${TOKEN_SECRET_NAME}" \
      --region "${region}" \
      --query SecretString \
      --output text 2>/dev/null); then
      SECRET_REGION="${region}"
      break
    fi
  done
fi

if [ -z "${SECRET_VALUE}" ]; then
  echo "Error: Failed to retrieve secret from AWS Secrets Manager"
  echo ""
  echo "Possible causes:"
  echo "  - Secret '${TOKEN_SECRET_NAME}' does not exist"
  echo "  - IAM permissions missing: secretsmanager:GetSecretValue"
  echo "  - Secret exists in unsupported region"
  exit 1
fi

if [ -n "${SECRET_REGION}" ] && [ "${SECRET_REGION}" != "default" ]; then
  echo "  Region: ${SECRET_REGION}"
fi

# Extract token from secret (handle JSON or plaintext)
if [ -n "${TOKEN_SECRET_KEY}" ]; then
  # Secret is JSON format, extract specific key
  HOOP_API_TOKEN=$(echo "${SECRET_VALUE}" | jq -r ".${TOKEN_SECRET_KEY} // empty")
  if [ -z "${HOOP_API_TOKEN}" ] || [ "${HOOP_API_TOKEN}" = "null" ]; then
    echo "Error: Key '${TOKEN_SECRET_KEY}' not found in secret JSON"
    exit 1
  fi
else
  # Secret is plaintext
  HOOP_API_TOKEN="${SECRET_VALUE}"
fi

# Validate token format (basic check)
if [ ${#HOOP_API_TOKEN} -lt 20 ]; then
  echo "Error: Retrieved token appears invalid (too short)"
  exit 1
fi

echo "✓ API token retrieved successfully"
echo "  Token length: ${#HOOP_API_TOKEN} characters"
echo ""

# Step 1: Get download URL from Hoop API
echo "[1/4] Fetching session download URL from Hoop..."
DOWNLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer ${HOOP_API_TOKEN}" \
  -H "Accept: application/json" \
  "${HOOP_API_BASE_URL}/api/sessions/${SESSION_ID}?extension=${EXPORT_FORMAT}")

# Extract HTTP status code
HTTP_CODE=$(echo "$DOWNLOAD_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$DOWNLOAD_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
  echo "Error: Failed to fetch session (HTTP ${HTTP_CODE})"
  echo "Response: ${RESPONSE_BODY}"
  exit 1
fi

# Extract download URL and expiration
DOWNLOAD_URL=$(echo "$RESPONSE_BODY" | jq -r '.download_url // empty')
EXPIRE_AT=$(echo "$RESPONSE_BODY" | jq -r '.expire_at // empty')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  echo "Error: No download URL in response"
  echo "Response: ${RESPONSE_BODY}"
  exit 1
fi

echo "✓ Download URL obtained"
if [ -n "$EXPIRE_AT" ] && [ "$EXPIRE_AT" != "null" ]; then
  echo "  URL expires at: ${EXPIRE_AT}"
fi
echo ""

# Step 2: Download session data
echo "[2/4] Downloading session data..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o "${TEMP_FILE}" \
  -H "Authorization: Bearer ${HOOP_API_TOKEN}" \
  "${DOWNLOAD_URL}")

if [ "$HTTP_CODE" != "200" ]; then
  echo "Error: Failed to download session (HTTP ${HTTP_CODE})"
  rm -f "${TEMP_FILE}"
  exit 1
fi

FILE_SIZE=$(wc -c < "${TEMP_FILE}" | tr -d ' ')
FILE_SIZE_MB=$(echo "scale=2; ${FILE_SIZE}/1048576" | bc)
echo "✓ Session downloaded (${FILE_SIZE} bytes / ${FILE_SIZE_MB} MB)"
echo ""

# Step 3: Verify AWS credentials and bucket access
echo "[3/4] Verifying S3 bucket access..."

# Get AWS identity for logging (without exposing credentials)
AWS_IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "unknown")
echo "  AWS Identity: ${AWS_IDENTITY}"

if ! aws s3 ls "s3://${S3_BUCKET}" >/dev/null 2>&1; then
  echo "Error: Cannot access S3 bucket '${S3_BUCKET}'"
  echo "Please verify:"
  echo "  - AWS credentials are configured"
  echo "  - The bucket exists"
  echo "  - You have s3:ListBucket permission"
  rm -f "${TEMP_FILE}"
  exit 1
fi
echo "✓ S3 bucket accessible"
echo ""

# Step 4: Upload to S3 with metadata
echo "[4/4] Uploading to S3..."

# Calculate file checksum for integrity verification
FILE_MD5=$(md5sum "${TEMP_FILE}" 2>/dev/null | awk '{print $1}' || md5 -q "${TEMP_FILE}" 2>/dev/null)

if aws s3 cp "${TEMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
  --metadata "session-id=${SESSION_ID},export-timestamp=${TIMESTAMP},format=${EXPORT_FORMAT},md5=${FILE_MD5}" \
  --content-type "application/${EXPORT_FORMAT}" \
  --storage-class STANDARD; then

  echo "✓ Upload successful"

  # Verify upload by checking object existence
  if aws s3api head-object --bucket "${S3_BUCKET}" --key "${S3_KEY}" >/dev/null 2>&1; then
    echo "✓ Upload verified"
  fi

  echo ""
  echo "================================================"
  echo "Export Complete!"
  echo "================================================"
  echo "Session ID: ${SESSION_ID}"
  echo "S3 Location: s3://${S3_BUCKET}/${S3_KEY}"
  echo "File Size: ${FILE_SIZE} bytes (${FILE_SIZE_MB} MB)"
  echo "Format: ${EXPORT_FORMAT}"
  echo "MD5 Checksum: ${FILE_MD5}"
  echo "Timestamp: ${TIMESTAMP}"
  echo ""
  echo "Download Command:"
  echo "aws s3 cp s3://${S3_BUCKET}/${S3_KEY} ./"
  echo ""
  echo "View in AWS Console:"
  echo "https://s3.console.aws.amazon.com/s3/object/${S3_BUCKET}?prefix=${S3_KEY}"
  echo "================================================"
else
  echo "Error: Failed to upload to S3"
  rm -f "${TEMP_FILE}"
  exit 1
fi

# Cleanup with secure deletion
echo ""
echo "Cleaning up temporary files..."
if command -v shred >/dev/null 2>&1; then
  shred -u "${TEMP_FILE}" 2>/dev/null || rm -f "${TEMP_FILE}"
else
  rm -f "${TEMP_FILE}"
fi
echo "✓ Temporary file securely deleted"

# Clear sensitive variables from memory
unset HOOP_API_TOKEN
unset SECRET_VALUE
