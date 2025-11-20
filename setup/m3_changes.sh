#!/bin/bash
#
# Script to add a private subnet to the VPC and power down the web instance.
#
# Description:
#   This script uses AWS CLI and Terraform outputs to:
#   1. Create an additional private subnet in the VPC
#   2. Stop the web server EC2 instance
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Terraform outputs available from the taco-wagon directory
#   - Appropriate AWS permissions to create subnets and stop instances
#   - jq for JSON parsing

set -e  # Exit on error

# Colors for output
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}AWS Infrastructure Changes Script${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TERRAFORM_DIR="$SCRIPT_DIR/../taco-wagon"

# Navigate to the Terraform directory
cd "$TERRAFORM_DIR"

echo -e "${YELLOW}Getting Terraform outputs...${NC}"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed. Please install jq to parse JSON.${NC}"
    exit 1
fi

# Get Terraform outputs
if ! TF_OUTPUT=$(terraform output -json 2>&1); then
    echo -e "${RED}Failed to get Terraform outputs. Make sure Terraform has been applied successfully.${NC}"
    exit 1
fi

# Extract values from outputs
VPC_ID=$(echo "$TF_OUTPUT" | jq -r '.vpc_id.value')
WEB_INSTANCE_ID=$(echo "$TF_OUTPUT" | jq -r '.web_instance_id.value')
EXISTING_PRIVATE_SUBNETS=$(echo "$TF_OUTPUT" | jq -r '.private_subnet_ids.value | join(", ")')

# Get AWS region from Terraform state
echo -e "${YELLOW}Retrieving AWS region from Terraform...${NC}"
TF_SHOW=$(terraform show -json)

# Get the region from the VPC resource ARN
VPC_ARN=$(echo "$TF_SHOW" | jq -r '.values.root_module.resources[] | select(.type == "aws_vpc") | .values.arn' | head -n 1)

if [ -n "$VPC_ARN" ]; then
    # Parse region from ARN (format: arn:aws:ec2:REGION:ACCOUNT:vpc/VPC-ID)
    AWS_REGION=$(echo "$VPC_ARN" | cut -d: -f4)
else
    # Fallback: try to get from availability zones data source
    AWS_REGION=$(echo "$TF_SHOW" | jq -r '.values.root_module.resources[] | select(.type == "aws_availability_zones") | .values.id' | head -n 1)
fi

# If region detection still fails, use default
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-east-1"
    echo -e "${YELLOW}Warning: Could not detect AWS region from Terraform state, using default: $AWS_REGION${NC}"
fi

# Set AWS_REGION environment variable
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

echo -e "${GREEN}AWS Region: $AWS_REGION${NC}"
echo -e "${GREEN}VPC ID: $VPC_ID${NC}"
echo -e "${GREEN}Web Instance ID: $WEB_INSTANCE_ID${NC}"
echo -e "${GREEN}Existing Private Subnets: $EXISTING_PRIVATE_SUBNETS${NC}"
echo ""

# Get VPC CIDR block
echo -e "${YELLOW}Retrieving VPC information...${NC}"
VPC_INFO=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --output json)
VPC_CIDR=$(echo "$VPC_INFO" | jq -r '.Vpcs[0].CidrBlock')
echo -e "${GREEN}VPC CIDR Block: $VPC_CIDR${NC}"
echo ""

# Get available availability zones
echo -e "${YELLOW}Retrieving availability zones...${NC}"
AZS_INFO=$(aws ec2 describe-availability-zones --filters "Name=state,Values=available" --output json)
SELECTED_AZ=$(echo "$AZS_INFO" | jq -r '.AvailabilityZones[2].ZoneName')

# Get existing subnets to determine next CIDR block
echo -e "${YELLOW}Retrieving existing subnets...${NC}"
EXISTING_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json)
SUBNET_COUNT=$(echo "$EXISTING_SUBNETS" | jq '.Subnets | length')

echo -e "${GREEN}Found $SUBNET_COUNT existing subnets${NC}"
echo ""

# Calculate next CIDR block for the new private subnet
# The script assumes /20 subnets (matching the cidrsubnet function with newbits=4)
NEXT_SUBNET_INDEX=$SUBNET_COUNT

# Parse VPC CIDR to calculate new subnet CIDR
IFS='/' read -r VPC_BASE VPC_PREFIX <<< "$VPC_CIDR"
IFS='.' read -r OCTET1 OCTET2 OCTET3 OCTET4 <<< "$VPC_BASE"

# Calculate the new subnet CIDR (this is a simplified calculation)
# Assuming /20 subnets from a /16 VPC (similar to cidrsubnet with newbits=4)
NEW_SUBNET_THIRD_OCTET=$((OCTET3 + (NEXT_SUBNET_INDEX * 16)))
NEW_SUBNET_CIDR="${OCTET1}.${OCTET2}.${NEW_SUBNET_THIRD_OCTET}.0/20"

echo -e "${YELLOW}Creating new private subnet...${NC}"
echo -e "${CYAN}  CIDR: $NEW_SUBNET_CIDR${NC}"
echo -e "${CYAN}  Availability Zone: $SELECTED_AZ${NC}"

# Create the subnet
if NEW_SUBNET_RESULT=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$NEW_SUBNET_CIDR" \
    --availability-zone "$SELECTED_AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=globomantics-dev-private-subnet-3},{Key=Type,Value=private},{Key=ManagedBy,Value=AWS-CLI},{Key=CreatedBy,Value=m3_changes_script}]" \
    --output json 2>&1); then
    
    NEW_SUBNET_ID=$(echo "$NEW_SUBNET_RESULT" | jq -r '.Subnet.SubnetId')
    echo -e "${GREEN}✓ Successfully created subnet: $NEW_SUBNET_ID${NC}"
else
    echo -e "${RED}Failed to create subnet: $NEW_SUBNET_RESULT${NC}"
    exit 1
fi
echo ""

# Stop the web instance
echo -e "${YELLOW}Stopping web instance: $WEB_INSTANCE_ID...${NC}"

if STOP_RESULT=$(aws ec2 stop-instances --instance-ids "$WEB_INSTANCE_ID" --output json 2>&1); then
    CURRENT_STATE=$(echo "$STOP_RESULT" | jq -r '.StoppingInstances[0].CurrentState.Name')
    echo -e "${GREEN}✓ Successfully initiated stop for instance: $WEB_INSTANCE_ID${NC}"
    echo -e "${CYAN}  Current State: $CURRENT_STATE${NC}"
else
    echo -e "${RED}Failed to stop instance: $STOP_RESULT${NC}"
    exit 1
fi
echo ""

# Wait for instance to stop
echo -e "${YELLOW}Waiting for instance to stop (this may take a minute)...${NC}"

if aws ec2 wait instance-stopped --instance-ids "$WEB_INSTANCE_ID" 2>&1; then
    echo -e "${GREEN}✓ Instance has been stopped successfully${NC}"
else
    echo -e "${YELLOW}Warning: Instance stop wait timed out or failed, but the stop command was issued.${NC}"
fi
echo ""

# Summary
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Summary of Changes${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}✓ Created new private subnet: $NEW_SUBNET_ID${NC}"
echo -e "${WHITE}  - CIDR: $NEW_SUBNET_CIDR${NC}"
echo -e "${WHITE}  - AZ: $SELECTED_AZ${NC}"
echo -e "${GREEN}✓ Stopped web instance: $WEB_INSTANCE_ID${NC}"
echo ""
echo -e "${GREEN}Script completed successfully!${NC}"
echo ""

# Return to original directory
cd "$SCRIPT_DIR"
