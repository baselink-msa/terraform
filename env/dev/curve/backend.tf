terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "baselink-tfstate-740831361032"
    key          = "dev/curve/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
