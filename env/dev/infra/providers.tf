terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
  default_tags {
    tags = {
      Env     = "DEV"
      Service = "bl"
    }
  }
}

provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
  profile = var.aws_profile
  default_tags {
    tags = {
      Env     = "DEV"
      Service = "bl"
    }
  }
}
