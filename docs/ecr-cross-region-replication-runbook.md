# ECR Cross-Region Replication Runbook

이 문서는 서울 ECR의 backend 이미지를 도쿄 리전으로 복제하고, DR EKS가 서울 리전에 의존하지 않고 이미지를 pull할 수 있는지 검증하는 절차를 정의합니다.

## 1. 이 작업을 하는 이유

도쿄에 RDS와 EKS를 복구해도 컨테이너 이미지가 서울 ECR에만 있으면 서울 리전 장애 중 backend를 실행할 수 없습니다. 소스 코드를 다시 빌드해 도쿄에 push할 수도 있지만, 복구 시간이 길어지고 장애 중 build pipeline까지 정상이어야 한다는 추가 의존성이 생깁니다.

ECR Cross-Region Replication을 적용하면 이후 서울에 push되는 `dev-` repository 이미지가 도쿄에도 같은 repository 이름과 digest로 복제됩니다.

## 2. 구현 범위

| 항목 | 값 |
| --- | --- |
| Source Region | `ap-northeast-2` 서울 |
| Destination Region | `ap-northeast-1` 도쿄 |
| Account | `740831361032` 동일 계정 |
| Repository filter | `dev-` prefix |
| 대상 repository | backend 9개 |
| Destination repository | Terraform으로 사전 생성 |
| Image scanning | push 시 활성화 |
| Tag mutability | `MUTABLE` |
| 암호화 | ECR 기본 AES256 |

대상 repository:

- `dev-auth-service`
- `dev-game-service`
- `dev-waiting-room-service`
- `dev-seat-lock-service`
- `dev-ticket-service`
- `dev-ticket-worker-service`
- `dev-order-service`
- `dev-ai-chatbot-service`
- `dev-admin-service`

repository를 도쿄에 미리 생성하는 이유는 replication이 image는 복제하지만 tag mutability, scan 설정, lifecycle policy 같은 repository 설정은 기본적으로 복제하지 않기 때문입니다.

## 3. 중요한 제한

Replication rule을 생성하기 전에 이미 서울 ECR에 존재하던 이미지는 자동으로 소급 복제되지 않습니다. Rule 활성화 이후 새로 push하거나 restore된 image만 복제됩니다.

따라서 검증은 두 단계로 진행합니다.

1. 신규 test tag 또는 다음 backend 배포 image를 push해 자동 복제 확인
2. 현재 GitOps가 참조하는 기존 image tag를 도쿄에 bootstrap

ECR replication은 source image나 destination image를 자동 삭제하지 않습니다. 이미지 정리 정책은 각 리전 repository에서 별도로 관리해야 합니다.

## 4. Terraform 적용 전 확인

```powershell
terraform -chdir=env/dev/ecr init
terraform -chdir=env/dev/ecr validate
terraform -chdir=env/dev/ecr plan
```

예상 변경:

- 도쿄 ECR repository 9개 생성
- 서울 private registry replication configuration 1개 생성
- 서울 ECR repository 변경 또는 삭제 없음

Replication configuration은 registry당 하나이므로 다른 팀이 별도 replication rule을 관리하는지 확인해야 합니다. 새 규칙을 추가할 때는 기존 registry configuration을 덮어쓰지 않도록 같은 Terraform resource에서 통합 관리합니다.

## 5. 배포 후 Registry 확인

서울 replication configuration:

```powershell
aws ecr describe-registry `
  --region ap-northeast-2 `
  --query "replicationConfiguration.rules"
```

확인 기준:

- destination region이 `ap-northeast-1`
- destination registry ID가 `740831361032`
- filter가 `dev-`, type이 `PREFIX_MATCH`

도쿄 repository:

```powershell
aws ecr describe-repositories `
  --region ap-northeast-1 `
  --query "repositories[].{Name:repositoryName,Uri:repositoryUri,Scan:imageScanningConfiguration.scanOnPush,Encryption:encryptionConfiguration.encryptionType}"
```

## 6. 신규 Image 자동 복제 검증

Replication rule 활성화 이후 backend CI가 새 commit tag를 서울 ECR에 push하도록 합니다. 동일 tag를 양쪽에서 조회합니다.

```powershell
$repository = "dev-ticket-service"
$tag = "<new-commit-sha>"

$seoul = aws ecr describe-images `
  --region ap-northeast-2 `
  --repository-name $repository `
  --image-ids imageTag=$tag `
  --query "imageDetails[0].imageDigest" `
  --output text

$tokyo = aws ecr describe-images `
  --region ap-northeast-1 `
  --repository-name $repository `
  --image-ids imageTag=$tag `
  --query "imageDetails[0].imageDigest" `
  --output text

"Seoul=$seoul"
"Tokyo=$tokyo"
```

완료 기준:

- 도쿄에 같은 tag가 존재
- 서울과 도쿄 digest가 동일
- 복제된 image scan 결과를 조회할 수 있음

대부분의 image는 빠르게 복제되지만 AWS는 일반적인 복제에 최대 수십 분이 걸릴 수 있다고 안내합니다. push 직후 없다고 실패로 단정하지 않고 최대 30분 동안 확인합니다.

## 7. 기존 활성 Image Bootstrap

현재 GitOps `overlays/dev/kustomization.yaml`이 참조하는 tag는 replication 설정 전 이미지이므로 자동 복제 대상이 아닙니다.

안전한 bootstrap 방법:

1. GitOps의 서비스별 repository와 commit tag 목록을 추출합니다.
2. 서울 image를 digest 기준으로 pull합니다.
3. 동일 image를 도쿄 repository의 같은 tag로 push합니다.
4. 양쪽 digest를 비교합니다.
5. 9개 서비스가 모두 확인된 뒤 DR overlay에서 도쿄 URI를 사용합니다.

예시:

```powershell
$account = "740831361032"
$repository = "dev-ticket-service"
$tag = "<gitops-commit-tag>"
$seoul = "$account.dkr.ecr.ap-northeast-2.amazonaws.com"
$tokyo = "$account.dkr.ecr.ap-northeast-1.amazonaws.com"

aws ecr get-login-password --region ap-northeast-2 |
  docker login --username AWS --password-stdin $seoul

aws ecr get-login-password --region ap-northeast-1 |
  docker login --username AWS --password-stdin $tokyo

docker pull "${seoul}/${repository}:${tag}"
docker tag "${seoul}/${repository}:${tag}" "${tokyo}/${repository}:${tag}"
docker push "${tokyo}/${repository}:${tag}"
```

멀티 아키텍처 image라면 단일 platform pull/push로 manifest list가 손실되지 않도록 CI의 원래 build 방식 또는 manifest 복사를 사용합니다. bootstrap 후에는 반드시 tag가 아니라 digest를 비교합니다.

## 8. DR GitOps 전환값

도쿄 overlay의 image URI는 다음 형식을 사용합니다.

```text
740831361032.dkr.ecr.ap-northeast-1.amazonaws.com/dev-<service-name>:<commit-sha>
```

서울 `overlays/dev`는 수정하지 않고 향후 `overlays/dr-tokyo`에서만 도쿄 URI를 사용합니다.

## 9. 장애 대응

복제가 되지 않을 때 확인:

1. 서울 `describe-registry`에 rule이 존재하는지 확인
2. repository 이름이 `dev-` prefix와 일치하는지 확인
3. image가 rule 생성 이후 push됐는지 확인
4. 도쿄 repository와 Region opt-in 상태 확인
5. CloudTrail에서 `ReplicateImage`, `CreateRepository` 실패 확인
6. 동일 tag의 기존 destination image와 tag mutability 충돌 확인

## 10. 완료 기준

- 도쿄 repository 9개 생성
- 서울 registry의 `dev-` replication rule 배포
- 신규 image tag 1개 이상 자동 복제
- 서울/도쿄 digest 일치
- 현재 GitOps 활성 tag 9개 bootstrap
- DR overlay가 도쿄 ECR URI를 사용

이 작업이 완료되면 서울 리전 전체 장애 중에도 도쿄 EKS가 backend image를 도쿄 내부에서 pull할 수 있어, build pipeline 없이 애플리케이션 복구를 시작할 수 있습니다.
