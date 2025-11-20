#!/bin/bash
#
# Script to remove the extra private subnet and power on the web instance.
#
# Description:
#   This script reverses the changes made by m3_changes.sh:
#   1. Removes the private subnet created by m3_changes.sh
#   2. Starts the web server EC2 instance
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Terraform outputs available from the taco-wagon directory
#   - Appropriate AWS permissions to delete subnets and start instances
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
echo -e "${CYAN}AWS Infrastructure Cleanup Script${NC}"
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
echo ""

# Find the subnet created by m3_changes.sh
echo -e "${YELLOW}Looking for subnet created by m3_changes_script...${NC}"

ALL_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --output json)

# Find subnets tagged with CreatedBy=m3_changes_script
SUBNET_TO_DELETE=$(echo "$ALL_SUBNETS" | jq -r '.Subnets[] | select(.Tags[]? | select(.Key == "CreatedBy" and .Value == "m3_changes_script"))')

if [ -n "$SUBNET_TO_DELETE" ]; then
    SUBNET_ID=$(echo "$SUBNET_TO_DELETE" | jq -r '.SubnetId')
    SUBNET_CIDR=$(echo "$SUBNET_TO_DELETE" | jq -r '.CidrBlock')
    echo -e "${GREEN}Found subnet to delete: $SUBNET_ID ($SUBNET_CIDR)${NC}"
else
    echo -e "${YELLOW}Warning: No subnet found with tag CreatedBy=m3_changes_script${NC}"
    echo -e "${YELLOW}Skipping subnet deletion...${NC}"
    SUBNET_ID=""
fi
echo ""

# Delete the subnet if found
if [ -n "$SUBNET_ID" ]; then
    echo -e "${YELLOW}Deleting subnet: $SUBNET_ID...${NC}"
    
    if aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --output json > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Successfully deleted subnet: $SUBNET_ID${NC}"
    else
        echo -e "${RED}Failed to delete subnet${NC}"
        echo -e "${YELLOW}Warning: The subnet may have dependencies (e.g., network interfaces, instances). Please check and remove them first.${NC}"
        exit 1
    fi
    echo ""
fi

# Start the web instance
echo -e "${YELLOW}Starting web instance: $WEB_INSTANCE_ID...${NC}"

# Check current instance state
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" --output json)
CURRENT_STATE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].State.Name')

echo -e "${CYAN}Current instance state: $CURRENT_STATE${NC}"

if [ "$CURRENT_STATE" = "running" ]; then
    echo -e "${GREEN}✓ Instance is already running${NC}"
elif [ "$CURRENT_STATE" = "stopped" ]; then
    # Start the instance
    if START_RESULT=$(aws ec2 start-instances --instance-ids "$WEB_INSTANCE_ID" --output json 2>&1); then
        NEW_STATE=$(echo "$START_RESULT" | jq -r '.StartingInstances[0].CurrentState.Name')
        echo -e "${GREEN}✓ Successfully initiated start for instance: $WEB_INSTANCE_ID${NC}"
        echo -e "${CYAN}  Current State: $NEW_STATE${NC}"
        
        # Wait for instance to start
        echo -e "${YELLOW}Waiting for instance to start (this may take a minute)...${NC}"
        
        if aws ec2 wait instance-running --instance-ids "$WEB_INSTANCE_ID" 2>&1; then
            echo -e "${GREEN}✓ Instance is now running${NC}"
            
            # Get the new public IP
            INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" --output json)
            PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].PublicIpAddress')
            echo -e "${CYAN}  Public IP: $PUBLIC_IP${NC}"
        else
            echo -e "${YELLOW}Warning: Instance start wait timed out or failed, but the start command was issued.${NC}"
        fi
    else
        echo -e "${RED}Failed to start instance: $START_RESULT${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Warning: Instance is in state: $CURRENT_STATE (expected 'stopped' or 'running')${NC}"
fi
echo ""

# Summary
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Summary of Changes${NC}"
echo -e "${CYAN}========================================${NC}"

if [ -n "$SUBNET_ID" ]; then
    echo -e "${GREEN}✓ Deleted private subnet: $SUBNET_ID${NC}"
    echo -e "${WHITE}  - CIDR: $SUBNET_CIDR${NC}"
fi

echo -e "${GREEN}✓ Started web instance: $WEB_INSTANCE_ID${NC}"

# Get final instance info
FINAL_INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$WEB_INSTANCE_ID" --output json)
FINAL_STATE=$(echo "$FINAL_INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].State.Name')
FINAL_PUBLIC_IP=$(echo "$FINAL_INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

echo -e "${WHITE}  - State: $FINAL_STATE${NC}"
if [ "$FINAL_PUBLIC_IP" != "null" ] && [ -n "$FINAL_PUBLIC_IP" ]; then
    echo -e "${WHITE}  - Application URL: http://$FINAL_PUBLIC_IP${NC}"
fi

echo ""
echo -e "${GREEN}Cleanup script completed successfully!${NC}"
echo ""

# Return to original directory
cd "$SCRIPT_DIR"
