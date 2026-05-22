# RDS (PostgreSQL) 모듈

야구장 플랫폼(파트 A, B, C)에서 공통으로 사용할 PostgreSQL 데이터베이스 인스턴스를 생성하는 테라폼 모듈입니다. 도커 환경과 동일하게 PostgreSQL 16 버전을 기본으로 지원합니다.

## 🚀 사용 예시 (Usage)

`environments/dev/infra/main.tf` 등에서 아래와 같이 호출하여 사용할 수 있습니다.

```hcl
module "rds" {
  source = "../../../modules/rds"

  identifier        = "baseball-db-dev"
  engine_version    = "16.3"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  
  db_name           = "baseball_platform"
  username          = "baseball"
  
  # 주의: 비밀번호는 하드코딩하지 않고 변수(tfvars)로 주입받습니다.
  password          = var.db_password 
}