# Dev IaC Pipeline

dev 환경 Terraform은 GitHub Actions에서 다음 두 단계로 운영한다.

- PR: `Terraform Plan` workflow가 `terraform fmt`, `init`, `validate`, `plan`을 실행한다.
- dev 배포: `main` merge 후 `Terraform Apply Dev` workflow가 자동 실행된다. 필요하면 GitHub Actions 화면에서 `Run workflow`로 수동 실행할 수도 있다.

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

## Merge 권한 설정

`main`에 merge되면 dev apply가 자동 실행되므로, GitHub repository에서 branch protection 또는 ruleset을 설정해 `main` merge 권한을 제한한다.

개인 승인 리뷰를 필수로 두면 PR 작성자 본인이 직접 approve할 수 없어 흐름이 복잡해질 수 있다. dev 환경에서는 `main` 업데이트 권한을 `@ShimDongseup`에게만 허용하고, PR plan 성공 후 직접 merge하는 방식을 사용한다.

권장 설정은 다음과 같다.

```text
GitHub repository
-> Settings
-> Rules
-> Rulesets
-> New branch ruleset
```

대상 브랜치는 `main`으로 지정한다.

```text
Target branches: main
```

아래 항목을 활성화한다.

```text
Require a pull request before merging
Require status checks to pass
Restrict updates
```

필수 status check에는 PR plan job을 추가한다.

```text
Plan dev infrastructure
```

`Restrict updates`를 켠 뒤 bypass 또는 allowed actor에 `@ShimDongseup`만 추가한다. 이 설정을 켜면 다른 팀원은 `main`에 직접 push하거나 PR을 merge할 수 없고, `@ShimDongseup`만 plan 결과를 확인한 뒤 merge할 수 있다. merge가 완료되면 `Terraform Apply Dev`가 자동으로 실행된다.

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

`Terraform Apply Dev`는 `main` push 또는 수동 실행 시 `infra -> ecr -> addon` 순서로 apply한 뒤 `scripts/post-apply-dev.sh`를 실행한다.

후처리 스크립트는 다음 작업을 담당한다.

- kubeconfig 업데이트
- `backend-secret`을 RDS Secrets Manager 값과 동기화
- DB credential 변경 시 Reloader가 `backend-secret`을 사용하는 backend deployment 자동 재시작
- Argo CD sync 대기
- ALB Ingress에 CloudFront prefix list, WAF, origin header 조건 annotation 적용
- auth-service rollout 대기
- CloudFront ALB origin 도메인 갱신

로컬 `./scripts/infra-up.sh`도 같은 후처리 스크립트를 호출하므로 로컬 실행과 GitHub Actions 실행의 동작을 맞춘다.
