variables {
  company_name       = "globomantics"
  environment        = "dev"
  aws_region         = "us-east-1"
  availability_zones = 2
  vpc_cidr           = "10.0.0.0/16"
  instance_type      = "t3.micro"
}

run "good_plan" {
  command = plan

  expect_failures = [check.ec2_power_status, check.subnet_count]
}

run "company_name_regex" {
  command = plan

  variables {
    company_name = "globo_mantics!"
  }

  expect_failures = [var.company_name]
}