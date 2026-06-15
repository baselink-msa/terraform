# RDS PostgreSQL 모듈

BaseLink dev 환경에서 사용하는 PostgreSQL RDS 인스턴스를 생성하는 Terraform 모듈입니다.

기본적으로 PostgreSQL 16 계열을 사용하며, dev 환경에서는 `baselink-dev-postgres` 인스턴스를 생성합니다.

## 주요 역할

- PostgreSQL RDS 인스턴스 생성
- RDS master password를 AWS Secrets Manager에서 관리
- VPC private data subnet에 배치
- EKS에서 접근 가능한 security group 연결
- Multi-AZ 구성 지원
- 자동 백업과 PITR(Point-In-Time Recovery) 설정 지원

## 사용 예시

```hcl
module "rds" {
  source = "../../../modules/rds"

  identifier             = "${local.name_prefix}-postgres"
  db_name                = "baseball_platform"
  username               = "baseball"
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  publicly_accessible    = false
  multi_az               = true

  backup_retention_period = 7
  backup_window           = "18:00-18:30"
  copy_tags_to_snapshot   = true

  tags = local.common_tags
}
```

## 백업과 PITR

dev 환경에서는 RDS 자동 백업을 7일 동안 보존하도록 설정합니다.

```hcl
backup_retention_period = 7
backup_window           = "18:00-18:30"
copy_tags_to_snapshot   = true
```

각 설정의 의미는 다음과 같습니다.

- `backup_retention_period`: 자동 백업 보존 기간입니다. 1 이상이면 PITR을 사용할 수 있습니다.
- `backup_window`: 자동 백업이 주로 수행되는 UTC 시간대입니다. `18:00-18:30`은 KST 기준 03:00-03:30입니다.
- `copy_tags_to_snapshot`: RDS 인스턴스 태그를 자동 백업/스냅샷에도 복사합니다.

PITR은 기존 DB를 직접 되감는 기능이 아니라, 특정 시점의 새 RDS 인스턴스를 생성하는 복구 방식입니다.

```text
기존 RDS 유지
-> 문제 발생 직전 시점으로 새 RDS 복원
-> 복원 DB 검증
-> 필요한 데이터만 추출하거나 애플리케이션 연결 전환
```

현재 백업/PITR 상태는 다음 명령으로 확인합니다.

```powershell
aws rds describe-db-instances `
  --db-instance-identifier baselink-dev-postgres `
  --query "DBInstances[0].{BackupRetentionPeriod:BackupRetentionPeriod,PreferredBackupWindow:PreferredBackupWindow,LatestRestorableTime:LatestRestorableTime,PendingModifiedValues:PendingModifiedValues,CopyTagsToSnapshot:CopyTagsToSnapshot}"
```

실제 장애 복구 절차는 [RUNBOOK.md](./RUNBOOK.md)를 참고합니다.

## 삭제 보호와 최종 스냅샷

RDS는 데이터가 저장되는 핵심 리소스이므로 실수 삭제를 막기 위해 삭제 보호를 사용할 수 있습니다.

```hcl
deletion_protection       = true
skip_final_snapshot       = false
final_snapshot_identifier = "${local.name_prefix}-postgres-final-snapshot"
```

각 설정의 의미는 다음과 같습니다.

- `deletion_protection`: RDS 인스턴스 삭제를 AWS API 수준에서 차단합니다. 이 값이 `true`이면 `terraform destroy`나 실수 삭제가 바로 성공하지 않습니다.
- `skip_final_snapshot`: RDS를 삭제할 때 마지막 스냅샷을 생략할지 여부입니다. `false`이면 삭제 전에 최종 스냅샷을 남깁니다.
- `final_snapshot_identifier`: 최종 스냅샷 이름입니다. 삭제 보호를 의도적으로 끄고 RDS를 삭제하는 경우 이 이름으로 마지막 복구 지점을 남깁니다.

운영 원칙:

- 일반적인 비용 절감 목적의 destroy에서는 RDS 삭제를 피합니다.
- 정말 RDS를 삭제해야 한다면 팀 합의 후 `deletion_protection = false`로 변경하는 PR을 먼저 머지합니다.
- 삭제 전에는 자동 백업/PITR 상태와 최종 스냅샷 이름 충돌 여부를 확인합니다.

## Multi-AZ와 PITR 차이

Multi-AZ와 PITR은 모두 안정성을 위한 설정이지만 해결하는 문제가 다릅니다.

- Multi-AZ: primary DB 인스턴스 장애에 대응합니다.
- PITR: 데이터 삭제, 잘못된 migration, 데이터 오염 같은 논리적 장애에 대응합니다.

예를 들어 primary DB 인스턴스가 장애 나면 Multi-AZ failover가 도움이 됩니다. 하지만 누군가 데이터를 잘못 삭제하면 그 삭제도 standby에 복제되므로 PITR로 삭제 직전 시점의 DB를 복원해야 합니다.
