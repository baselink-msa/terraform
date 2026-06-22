# AWS Backup 모듈

AWS Backup vault, backup plan, backup selection, service role을 생성하는 모듈입니다.

현재 dev 환경에서는 RDS native PITR은 그대로 유지하고, AWS Backup은 일 단위 snapshot backup을 담당합니다.

## 생성 리소스

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`
- AWS Backup service role
- Backup/restore managed policy attachment
- 선택적 cross-Region `copy_action`

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
  copy_destination_vault_arn = aws_backup_vault.tokyo.arn
  copy_delete_after_days     = 14
  tags              = local.common_tags
}
```

## 운영 원칙

- dev 환경은 비용을 줄이기 위해 7일 보존으로 시작합니다.
- cross-region copy를 사용하면 destination vault는 다른 provider alias로 환경 레이어에서 생성하고 ARN만 모듈에 전달합니다.
- 도쿄 복사본은 dev 기준 14일 보존합니다.
- 복원 테스트 후 생성된 RDS restore instance는 반드시 정리합니다.
