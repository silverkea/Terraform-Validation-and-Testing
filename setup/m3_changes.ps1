#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script to add a private subnet to the VPC and power down the web instance.

.DESCRIPTION
    This script uses AWS CLI and Terraform outputs to:
    1. Create an additional private subnet in the VPC
    2. Stop the web server EC2 instance
    
.NOTES
    Prerequisites:
    - AWS CLI installed and configured
    - Terraform outputs available from the taco-wagon directory
    - Appropriate AWS permissions to create subnets and stop instances
#>

# Set error action preference
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AWS Infrastructure Changes Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Navigate to the Terraform directory
$TerraformDir = Join-Path $PSScriptRoot "..\taco-wagon"
Set-Location $TerraformDir

Write-Host "Getting Terraform outputs..." -ForegroundColor Yellow

# Get Terraform outputs
try {
    $TfOutputJson = terraform output -json | ConvertFrom-Json
} catch {
    Write-Error "Failed to get Terraform outputs. Make sure Terraform has been applied successfully."
    exit 1
}

# Extract values from outputs
$VpcId = $TfOutputJson.vpc_id.value
$WebInstanceId = $TfOutputJson.web_instance_id.value
$ExistingPrivateSubnets = $TfOutputJson.private_subnet_ids.value

# Get AWS region from Terraform state
Write-Host "Retrieving AWS region from Terraform..." -ForegroundColor Yellow
$TfShowJson = terraform show -json | ConvertFrom-Json

# Get the region from the VPC resource or any AWS resource
$VpcResource = $TfShowJson.values.root_module.resources | Where-Object { $_.type -eq "aws_vpc" } | Select-Object -First 1
if ($VpcResource -and $VpcResource.values.arn) {
    # Parse region from ARN (format: arn:aws:ec2:REGION:ACCOUNT:vpc/VPC-ID)
    $AwsRegion = $VpcResource.values.arn -replace 'arn:aws:[^:]+:([^:]+):.*', '$1'
} else {
    # Fallback: try to get from provider configuration in state
    $AwsRegion = $TfShowJson.values.root_module.resources | Where-Object { $_.type -eq "aws_availability_zones" } | Select-Object -First 1 | ForEach-Object { $_.values.id }
}

# If region detection still fails, use default
if (-not $AwsRegion) {
    $AwsRegion = "us-east-1"  # Default fallback
    Write-Warning "Could not detect AWS region from Terraform state, using default: $AwsRegion"
}

# Set AWS_REGION environment variable
$env:AWS_REGION = $AwsRegion
$env:AWS_DEFAULT_REGION = $AwsRegion

Write-Host "AWS Region: $AwsRegion" -ForegroundColor Green
Write-Host "VPC ID: $VpcId" -ForegroundColor Green
Write-Host "Web Instance ID: $WebInstanceId" -ForegroundColor Green
Write-Host "Existing Private Subnets: $($ExistingPrivateSubnets -join ', ')" -ForegroundColor Green
Write-Host ""

# Get VPC CIDR block
Write-Host "Retrieving VPC information..." -ForegroundColor Yellow
$VpcInfo = aws ec2 describe-vpcs --vpc-ids $VpcId --output json | ConvertFrom-Json
$VpcCidr = $VpcInfo.Vpcs[0].CidrBlock
Write-Host "VPC CIDR Block: $VpcCidr" -ForegroundColor Green
Write-Host ""

# Get available availability zones
Write-Host "Retrieving availability zones..." -ForegroundColor Yellow
$AzsInfo = aws ec2 describe-availability-zones --filters "Name=state,Values=available" --output json | ConvertFrom-Json
$AvailabilityZones = $AzsInfo.AvailabilityZones | Select-Object -First 3

# Get existing subnets to determine next CIDR block
Write-Host "Retrieving existing subnets..." -ForegroundColor Yellow
$ExistingSubnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VpcId" --output json | ConvertFrom-Json
$SubnetCount = $ExistingSubnets.Subnets.Count

Write-Host "Found $SubnetCount existing subnets" -ForegroundColor Green
Write-Host ""

# Calculate next CIDR block for the new private subnet
# The script assumes /20 subnets (matching the cidrsubnet function with newbits=4)
# We'll use the next available subnet index
$NextSubnetIndex = $SubnetCount

# Parse VPC CIDR to calculate new subnet CIDR
# For simplicity, we'll use the third availability zone and increment the subnet counter
$VpcBaseOctets = $VpcCidr.Split("/")[0].Split(".")
$VpcPrefix = [int]$VpcCidr.Split("/")[1]

# Calculate the new subnet CIDR (this is a simplified calculation)
# Assuming /20 subnets from a /16 VPC (similar to cidrsubnet with newbits=4)
$NewSubnetThirdOctet = [int]$VpcBaseOctets[2] + ($NextSubnetIndex * 16)
$NewSubnetCidr = "$($VpcBaseOctets[0]).$($VpcBaseOctets[1]).$NewSubnetThirdOctet.0/20"

# Select the third AZ (or wrap around if needed)
$SelectedAz = $AvailabilityZones[2 % $AvailabilityZones.Count].ZoneName

Write-Host "Creating new private subnet..." -ForegroundColor Yellow
Write-Host "  CIDR: $NewSubnetCidr" -ForegroundColor Cyan
Write-Host "  Availability Zone: $SelectedAz" -ForegroundColor Cyan

try {
    $NewSubnetResult = aws ec2 create-subnet `
        --vpc-id $VpcId `
        --cidr-block $NewSubnetCidr `
        --availability-zone $SelectedAz `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=globomantics-dev-private-subnet-3},{Key=Type,Value=private},{Key=ManagedBy,Value=AWS-CLI},{Key=CreatedBy,Value=m3_changes_script}]" `
        --output json | ConvertFrom-Json
    
    $NewSubnetId = $NewSubnetResult.Subnet.SubnetId
    Write-Host "✓ Successfully created subnet: $NewSubnetId" -ForegroundColor Green
} catch {
    Write-Error "Failed to create subnet: $_"
    exit 1
}
Write-Host ""

# Stop the web instance
Write-Host "Stopping web instance: $WebInstanceId..." -ForegroundColor Yellow

try {
    $StopResult = aws ec2 stop-instances --instance-ids $WebInstanceId --output json | ConvertFrom-Json
    $CurrentState = $StopResult.StoppingInstances[0].CurrentState.Name
    Write-Host "✓ Successfully initiated stop for instance: $WebInstanceId" -ForegroundColor Green
    Write-Host "  Current State: $CurrentState" -ForegroundColor Cyan
} catch {
    Write-Error "Failed to stop instance: $_"
    exit 1
}
Write-Host ""

# Wait for instance to stop (optional)
Write-Host "Waiting for instance to stop (this may take a minute)..." -ForegroundColor Yellow

try {
    aws ec2 wait instance-stopped --instance-ids $WebInstanceId
    Write-Host "✓ Instance has been stopped successfully" -ForegroundColor Green
} catch {
    Write-Warning "Instance stop wait timed out or failed, but the stop command was issued."
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary of Changes" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✓ Created new private subnet: $NewSubnetId" -ForegroundColor Green
Write-Host "  - CIDR: $NewSubnetCidr" -ForegroundColor White
Write-Host "  - AZ: $SelectedAz" -ForegroundColor White
Write-Host "✓ Stopped web instance: $WebInstanceId" -ForegroundColor Green
Write-Host ""
Write-Host "Script completed successfully!" -ForegroundColor Green
Write-Host ""

# Return to original directory
Set-Location $PSScriptRoot
