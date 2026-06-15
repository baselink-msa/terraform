# AWS Backup 모듈

AWS Backup vault, backup plan, backup selection, service role을 생성하는 모듈입니다.

현재 dev 환경에서는 RDS native PITR은 그대로 유지하고, AWS Backup은 일 단위 snapshot backup을 담당합니다.

## 생성 리소스

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`
- AWS Backup service role
- Backup/restore managed policy attachment

## 기본 정책

```hcl
rule_name         = "daily-rds-snapshot"
schedule          = "cron(0 19 ? * * *)"
delete_after_days = 7
```

`cron(0 19 ? * * *)`는 UTC 19:00, 즉 KST 04:00에 실행됩니다.

## 사용 예시

```hcl
module "backup" {
  source = "../../../modules/backup"

  name_prefix       = local.name_prefix
  rule_name         = "daily-rds-snapshot"
  resource_arns     = [module.rds.db_instance_arn]
  delete_after_days = 7
  tags              = local.common_tags
}
```

## 운영 원칙

- dev 환경은 비용을 줄이기 위해 7일 보존으로 시작합니다.
- cross-region copy는 DR 리전과 비용 정책을 확정한 뒤 추가합니다.
- 복원 테스트 후 생성된 RDS restore instance는 반드시 정리합니다.
