variables {
  company_name       = "globomantics"
  environment        = "dev"
  aws_region         = "us-east-1"
  availability_zones = 2
  vpc_cidr           = "10.0.0.0/16"
  instance_type      = "t3.micro"
}

run "setup" {
  command = apply
}

run "test_site" {
  command = apply

  module {
    source = "../setup/http_test"
  }

  variables {
    url = run.setup.application_url
  }

  assert {
    condition     = data.http.site_check.status_code == 200
    error_message = "The web application is not returning HTTP 200 OK. The code returned was ${data.http.site_check.status_code}."
  }
}