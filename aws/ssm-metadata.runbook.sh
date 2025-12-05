# instance-id={{ .instance_id | required "true" }}

# Get IMDSv2 token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Verify token was retrieved
if [ -z "$TOKEN" ]; then
  echo "Failed to get IMDS token"
  exit 1
fi

# Query instance metadata
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-type)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/availability-zone)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4)
AMI_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/ami-id)

# Display results
echo "=== AWS Instance Metadata ==="
echo "Instance ID: ${INSTANCE_ID}"
echo "Instance Type: ${INSTANCE_TYPE}"
echo "Region: ${REGION}"
echo "Availability Zone: ${AZ}"
echo "Private IP: ${PRIVATE_IP}"
echo "Public IP: ${PUBLIC_IP}"
echo "AMI ID: ${AMI_ID}"
