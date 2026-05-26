# argocd 모듈

EKS 클러스터에 ArgoCD를 설치하고, 선택적으로 Image Updater IRSA를 구성하는 모듈입니다.

## 개요

`eks` 모듈이 클러스터 "본체"를 만들고 `eks-addons` 모듈이 오토스케일링 계층을 담당한다면, 이 모듈은 **GitOps 배포 계층**을 담당합니다.

- **ArgoCD** — Git 저장소를 단일 진실 소스(Single Source of Truth)로 삼아 Kubernetes 리소스를 자동으로 동기화하는 GitOps 도구.
- **ArgoCD Image Updater** — (옵션) ECR의 최신 이미지 태그를 감지해 Git을 자동 업데이트하는 부가 컴포넌트. IRSA로 ECR 조회 권한을 부여.

Helm provider가 살아 있는 클러스터를 필요로 하므로, 이 모듈은 **addon 레이어**에서 별도로 apply됩니다 (infra 레이어의 `eks`가 먼저 완료된 뒤).

## 생성 리소스

- `helm_release` — ArgoCD (`argo-cd` 차트)
- (옵션, `enable_image_updater_irsa = true`) ArgoCD Image Updater IAM 역할·정책 (IRSA)

## 입력 변수

배선용 — 다른 모듈 출력에서 전달받는 필수값:

| 변수 | 설명 | 타입 | 필수 |
|---|---|---|:--:|
| `cluster_name` | EKS 클러스터 이름 (`eks` 모듈 출력) | string | ✓ |
| `oidc_provider_arn` | OIDC provider ARN (`eks` 모듈 출력) | string | ✓ |
| `oidc_provider_url` | OIDC provider URL (`eks` 모듈 출력) | string | ✓ |

설정값 — 기본값이 있는 선택 변수:

| 변수 | 설명 | 타입 | 기본값 |
|---|---|---|---|
| `namespace` | ArgoCD 설치 네임스페이스 | string | `"argocd"` |
| `argocd_version` | argo-cd Helm 차트 버전 | string | `"7.7.5"` |
| `server_service_type` | ArgoCD 서버 Service 타입 | string | `"ClusterIP"` |
| `server_insecure` | HTTP(insecure) 모드 여부 (ALB에서 TLS 종료 시 true) | bool | `false` |
| `enable_image_updater_irsa` | Image Updater ECR 조회용 IRSA 생성 여부 | bool | `false` |
| `extra_helm_values` | 추가 Helm values (YAML 문자열) | string | `""` |
| `tags` | 공통 태그 | map(string) | `{}` |

## 출력값

| 출력 | 설명 |
|---|---|
| `namespace` | ArgoCD가 설치된 네임스페이스 |
| `release_name` | Helm release 이름 |
| `image_updater_role_arn` | Image Updater IRSA 역할 ARN (미활성화 시 빈 문자열) |

## 사용 예시

addon 레이어(`env/dev/addon/main.tf`)에서 infra 레이어 출력을 remote state로 받아 호출합니다.

```hcl
module "argocd" {
  source = "../../../modules/argocd"

  cluster_name      = data.terraform_remote_state.infra.outputs.eks_cluster_name
  oidc_provider_arn = data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.infra.outputs.eks_oidc_provider_url

  namespace           = "argocd"
  server_service_type = "ClusterIP"
  server_insecure     = true   # ALB Ingress에서 TLS 종료 시

  tags = local.common_tags
}
```

Image Updater IRSA까지 활성화하는 경우:

```hcl
module "argocd" {
  source = "../../../modules/argocd"

  cluster_name      = data.terraform_remote_state.infra.outputs.eks_cluster_name
  oidc_provider_arn = data.terraform_remote_state.infra.outputs.eks_oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.infra.outputs.eks_oidc_provider_url

  enable_image_updater_irsa = true

  tags = local.common_tags
}
```

## 다른 모듈과의 관계

- **입력으로 받음**: `cluster_name`, `oidc_provider_arn`, `oidc_provider_url` 모두 `eks` 모듈의 출력에서 옵니다.
- **순서**: infra 레이어(`eks` 포함)가 완료된 뒤 addon 레이어에서 apply됩니다.
- **eks-addons와 동일 레이어**: Karpenter, KEDA와 함께 addon 레이어에서 병렬 또는 순서 없이 적용 가능합니다.

## 참고

- Helm provider는 **2.x 계열로 고정**해야 합니다(`>= 2.12, < 3.0`). 3.x에서 `set` 블록 문법이 바뀌어 모듈 코드와 호환되지 않습니다.
- `server_insecure = true`로 설정하면 ArgoCD 서버가 HTTP로 응답합니다. ALB 또는 Nginx Ingress에서 TLS를 종료하는 구성일 때 사용합니다.
- Image Updater는 `argocd-image-updater` ServiceAccount를 통해 IRSA 역할을 자동으로 획득합니다. ArgoCD Image Updater Helm 차트는 별도로 설치해야 하며, 이 모듈은 IAM 역할만 생성합니다.
- `argocd_version`은 팀에서 최신 stable 버전을 확인 후 명시적으로 고정하는 것을 권장합니다.
