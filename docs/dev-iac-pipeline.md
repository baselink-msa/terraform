# Dev IaC Pipeline

dev 환경 Terraform은 GitHub Actions에서 다음 두 단계로 운영한다.

- PR: `Terraform Plan` workflow가 `terraform fmt`, `init`, `validate`, `plan`을 실행한다.
- 수동 배포: `Terraform Apply Dev` workflow를 GitHub Actions 화면에서 `Run workflow`로 실행한다.

## 최초 bootstrap

GitHub Actions가 AWS에 접근하려면 Terraform용 OIDC IAM Role이 먼저 있어야 한다.

1. 로컬 AWS 인증을 완료한다.
2. `./scripts/infra-up.sh`를 한 번 실행해서 `baselink-github-actions-terraform-role`을 생성한다.
3. self-hosted runner EC2를 GitHub repository runner로 등록한다.
4. `terraform output -raw github_actions_terraform_role_arn` 값으로 GitHub Secret을 등록한다.

## 필요한 GitHub Secrets

- `AWS_TERRAFORM_ROLE_ARN`: GitHub Actions가 assume할 Terraform IAM Role ARN
- `DEV_INFRA_TFVARS`: `env/dev/infra/terraform.tfvars` 내용
- `DEV_ECR_TFVARS`: `env/dev/ecr/terraform.tfvars` 내용
- `DEV_ADDON_TFVARS`: `env/dev/addon/terraform.tfvars` 내용
- `CF_ORIGIN_VERIFY_HEADER_NAME`: CloudFront origin custom header 이름, 기본값은 `X-Origin-Verify`
- `CF_ORIGIN_VERIFY_HEADER_VALUE`: CloudFront origin custom header 값. 비워두면 CloudFront 설정에서 읽는다.

## Self-hosted runner 등록

dev Terraform plan/apply workflow는 VPC 내부 EKS API 접근이 필요하므로 GitHub hosted runner가 아니라 EC2 self-hosted runner에서 실행한다.

Terraform apply 후 runner EC2 instance ID를 확인한다.

```bash
cd baselink-terraform/env/dev/infra
terraform output -raw github_actions_runner_instance_id
```

GitHub에서 runner registration token을 발급한다.

```text
GitHub repository
-> Settings
-> Actions
-> Runners
-> New self-hosted runner
-> Linux
-> x64
```

EC2에는 inbound SSH를 열지 않는다. SSM Session Manager로 접속한다.

```bash
aws ssm start-session \
  --region ap-northeast-2 \
  --target "$(terraform output -raw github_actions_runner_instance_id)"
```

SSM 세션 안에서 아래 명령을 실행한다.

```bash
sudo /opt/baselink/register-github-runner.sh baselink-msa/terraform <GITHUB_RUNNER_REGISTRATION_TOKEN>
```

등록이 끝나면 GitHub repository의 runner 목록에서 다음 라벨을 가진 runner가 online 상태인지 확인한다.

```text
self-hosted
baselink-dev
iac
```

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
