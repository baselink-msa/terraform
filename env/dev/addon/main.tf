###############################################################################
# environments/dev/addon/main.tf
#
# TODO: 이 레이어에서 사용할 모듈을 호출하세요.
#       addon 레이어 대상: eks-addons
#       infra 레이어 output은 terraform_remote_state 로 참조합니다.
###############################################################################

# RDS 모듈 호출 (개발 환경 조립)
module "rds" {
  source = "../../../modules/rds"

  # 개발 환경(dev)에 맞는 설정값 주입
  identifier        = "baseball-db-dev"
  engine_version    = "16.3"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20

  db_name  = "baseball_platform"
  username = "baseball"

  # 비밀번호는 보안상 로컬의 terraform.tfvars 파일에서 주입받아야 하므로
  # 일단 변수로 연결해 둡니다. (environments/dev/infra/variables.tf 에 선언 필요)
  password = var.db_password

  skip_final_snapshot = true
  publicly_accessible = true # 개발/테스트용이므로 일단 열어둠
}