terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }

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

provider "aws" {
  alias   = "tokyo"
  region  = var.dr_region
  profile = var.aws_profile
  default_tags {
    tags = {
      Env     = "DEV"
      Service = "bl"
    }
  }
}
