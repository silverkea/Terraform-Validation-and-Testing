variables {
  company_name       = "globomantics"
  environment        = "dev"
  aws_region         = "us-east-1"
  availability_zones = 2
  vpc_cidr           = "10.0.0.0/16"
  instance_type      = "t3.micro"
}

run "good_test" {
    command = plan

    expect_failures = [ check.subnet_count, check.ec2_power_status ]
}

run "regex_company_name" {
    command = plan

    variables {
        company_name = "globo@mantics$#%"
    }

    expect_failures = [ var.company_name ]
}