<<<<<<< HEAD
# --------------------------------------------------------
# SQS 모듈 호출 (파트 B 비동기 예매 확정 큐)
# --------------------------------------------------------
module "sqs_ticket_confirm" {
  source = "../../../modules/sqs"

  # Spring Boot 코드(@SqsListener)에 하드코딩된 큐 이름과 정확히 일치시킵니다.
  queue_name = "ticket-confirm-queue"
}
=======
module "vpc" {
  source = "../../../modules/vpc"

  project_name              = var.project_name
  environment               = var.environment
  vpc_cidr                  = var.vpc_cidr
  availability_zones        = var.availability_zones
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
  single_nat_gateway        = var.single_nat_gateway
  eks_cluster_name          = var.eks_cluster_name
}
>>>>>>> main
