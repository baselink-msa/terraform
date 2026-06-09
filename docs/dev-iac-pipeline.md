# Dev IaC Pipeline

dev 환경 Terraform은 GitHub Actions에서 다음 두 단계로 운영한다.

- PR: `Terraform Plan` workflow가 `terraform fmt`, `init`, `validate`, `plan`을 실행한다.
- 수동 배포: `Terraform Apply Dev` workflow를 GitHub Actions 화면에서 `Run workflow`로 실행한다.

## 최초 bootstrap

GitHub Actions가 AWS에 접근하려면 Terraform용 OIDC IAM Role이 먼저 있어야 한다.

1. 로컬 AWS 인증을 완료한다.
2. `./scripts/infra-up.sh`를 한 번 실행해서 `baselink-github-actions-terraform-role`을 생성한다.
3. `terraform output -raw github_actions_terraform_role_arn` 값으로 GitHub Secret을 등록한다.

## 필요한 GitHub Secrets

- `AWS_TERRAFORM_ROLE_ARN`: GitHub Actions가 assume할 Terraform IAM Role ARN
- `DEV_INFRA_TFVARS`: `env/dev/infra/terraform.tfvars` 내용
- `DEV_ECR_TFVARS`: `env/dev/ecr/terraform.tfvars` 내용
- `DEV_ADDON_TFVARS`: `env/dev/addon/terraform.tfvars` 내용
- `CF_ORIGIN_VERIFY_HEADER_NAME`: CloudFront origin custom header 이름, 기본값은 `X-Origin-Verify`
- `CF_ORIGIN_VERIFY_HEADER_VALUE`: CloudFront origin custom header 값. 비워두면 CloudFront 설정에서 읽는다.

## 후처리 작업

`Terraform Apply Dev`는 `infra -> ecr -> addon` 순서로 apply한 뒤 `scripts/post-apply-dev.sh`를 실행한다.

후처리 스크립트는 다음 작업을 담당한다.

- kubeconfig 업데이트
- `backend-secret` 생성 또는 확인
- Argo CD sync 대기
- ALB Ingress에 CloudFront prefix list, WAF, origin header 조건 annotation 적용
- auth-service rollout 대기
- CloudFront ALB origin 도메인 갱신

로컬 `./scripts/infra-up.sh`도 같은 후처리 스크립트를 호출하므로 로컬 실행과 GitHub Actions 실행의 동작을 맞춘다.
