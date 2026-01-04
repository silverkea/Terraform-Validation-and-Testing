check "subnet_count" {
  data "aws_subnets" "all_subnets" {
    filter {
      name   = "vpc-id"
      values = [aws_vpc.main.id]
    }
  }

  assert {
    condition     = length(data.aws_subnets.all_subnets.ids) == (var.availability_zones * 2)
    error_message = "The number of subnets does not equal the expected count."
  }
}

check "ec2_power_status" {
  data "aws_instance" "web" {
    instance_id = aws_instance.web.id
  }

  assert {
    condition     = data.aws_instance.web.instance_state == "running"
    error_message = "The EC2 instance is not in the 'running' state."
  }
}
