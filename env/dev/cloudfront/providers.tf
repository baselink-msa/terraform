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

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = "baselink-tfstate-740831361032"
    key    = "dev/infra/terraform.tfstate"
    region = var.aws_region
  }
}
