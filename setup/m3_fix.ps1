#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Script to remove the extra private subnet and power on the web instance.

.DESCRIPTION
    This script reverses the changes made by m3_changes.ps1:
    1. Removes the private subnet created by m3_changes.ps1
    2. Starts the web server EC2 instance
    
.NOTES
    Prerequisites:
    - AWS CLI installed and configured
    - Terraform outputs available from the taco-wagon directory
    - Appropriate AWS permissions to delete subnets and start instances
#>

# Set error action preference
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AWS Infrastructure Cleanup Script" -ForegroundColor Cyan
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
Write-Host ""

# Find the subnet created by m3_changes.ps1
Write-Host "Looking for subnet created by m3_changes_script..." -ForegroundColor Yellow

try {
    $AllSubnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VpcId" --output json | ConvertFrom-Json
    
    # Find subnets tagged with CreatedBy=m3_changes_script
    $SubnetToDelete = $AllSubnets.Subnets | Where-Object { 
        $_.Tags | Where-Object { $_.Key -eq "CreatedBy" -and $_.Value -eq "m3_changes_script" }
    } | Select-Object -First 1
    
    if ($SubnetToDelete) {
        $SubnetId = $SubnetToDelete.SubnetId
        $SubnetCidr = $SubnetToDelete.CidrBlock
        Write-Host "Found subnet to delete: $SubnetId ($SubnetCidr)" -ForegroundColor Green
    } else {
        Write-Warning "No subnet found with tag CreatedBy=m3_changes_script"
        Write-Host "Skipping subnet deletion..." -ForegroundColor Yellow
        $SubnetId = $null
    }
} catch {
    Write-Error "Failed to query subnets: $_"
    exit 1
}
Write-Host ""

# Delete the subnet if found
if ($SubnetId) {
    Write-Host "Deleting subnet: $SubnetId..." -ForegroundColor Yellow
    
    try {
        aws ec2 delete-subnet --subnet-id $SubnetId --output json | Out-Null
        Write-Host "✓ Successfully deleted subnet: $SubnetId" -ForegroundColor Green
    } catch {
        Write-Error "Failed to delete subnet: $_"
        Write-Warning "The subnet may have dependencies (e.g., network interfaces, instances). Please check and remove them first."
        exit 1
    }
    Write-Host ""
}

# Start the web instance
Write-Host "Starting web instance: $WebInstanceId..." -ForegroundColor Yellow

try {
    # Check current instance state
    $InstanceInfo = aws ec2 describe-instances --instance-ids $WebInstanceId --output json | ConvertFrom-Json
    $CurrentState = $InstanceInfo.Reservations[0].Instances[0].State.Name
    
    Write-Host "Current instance state: $CurrentState" -ForegroundColor Cyan
    
    if ($CurrentState -eq "running") {
        Write-Host "✓ Instance is already running" -ForegroundColor Green
    } elseif ($CurrentState -eq "stopped") {
        # Start the instance
        $StartResult = aws ec2 start-instances --instance-ids $WebInstanceId --output json | ConvertFrom-Json
        $NewState = $StartResult.StartingInstances[0].CurrentState.Name
        Write-Host "✓ Successfully initiated start for instance: $WebInstanceId" -ForegroundColor Green
        Write-Host "  Current State: $NewState" -ForegroundColor Cyan
        
        # Wait for instance to start
        Write-Host "Waiting for instance to start (this may take a minute)..." -ForegroundColor Yellow
        
        try {
            aws ec2 wait instance-running --instance-ids $WebInstanceId
            Write-Host "✓ Instance is now running" -ForegroundColor Green
            
            # Get the new public IP
            $InstanceInfo = aws ec2 describe-instances --instance-ids $WebInstanceId --output json | ConvertFrom-Json
            $PublicIp = $InstanceInfo.Reservations[0].Instances[0].PublicIpAddress
            Write-Host "  Public IP: $PublicIp" -ForegroundColor Cyan
        } catch {
            Write-Warning "Instance start wait timed out or failed, but the start command was issued."
        }
    } else {
        Write-Warning "Instance is in state: $CurrentState (expected 'stopped' or 'running')"
    }
} catch {
    Write-Error "Failed to start instance: $_"
    exit 1
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary of Changes" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($SubnetId) {
    Write-Host "✓ Deleted private subnet: $SubnetId" -ForegroundColor Green
    Write-Host "  - CIDR: $SubnetCidr" -ForegroundColor White
}

Write-Host "✓ Started web instance: $WebInstanceId" -ForegroundColor Green

# Get final instance info
$FinalInstanceInfo = aws ec2 describe-instances --instance-ids $WebInstanceId --output json | ConvertFrom-Json
$FinalState = $FinalInstanceInfo.Reservations[0].Instances[0].State.Name
$FinalPublicIp = $FinalInstanceInfo.Reservations[0].Instances[0].PublicIpAddress

Write-Host "  - State: $FinalState" -ForegroundColor White
if ($FinalPublicIp) {
    Write-Host "  - Application URL: http://$FinalPublicIp" -ForegroundColor White
}

Write-Host ""
Write-Host "Cleanup script completed successfully!" -ForegroundColor Green
Write-Host ""

# Return to original directory
Set-Location $PSScriptRoot
