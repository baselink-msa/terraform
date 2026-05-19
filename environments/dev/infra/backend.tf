###############################################################################
# environments/dev/infra/backend.tf
###############################################################################
terraform {
  required_version = ">= 1.10"   # use_lockfile(S3 네이티브 락)은 Terraform 1.10+ 필요

  backend "s3" {
    bucket       = "baselink-tfstate-740831361032"   # 부트스트랩으로 만든 S3 버킷명
    key          = "dev/infra/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
