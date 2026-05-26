###############################################################################
# environments/dev/addon/backend.tf
###############################################################################
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "baselink-tfstate-740831361032"
    key          = "dev/addon/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
