# eks-addons 모듈

EKS 클러스터에 오토스케일링 도구 두 가지 — Karpenter(노드)와 KEDA(워크로드) — 를 설치·구성하는 모듈입니다.

## 개요

`eks` 모듈이 클러스터 "본체"를 만든다면, 이 모듈은 그 위에서 동작하는 **확장(scale) 계층**을 담당합니다.

- **Karpenter** — 파드가 자리가 없어 대기하면 즉시 적절한 EC2 노드를 띄우고, 비면 정리하는 노드 오토스케일러.
- **KEDA** — CPU뿐 아니라 SQS 큐 길이 같은 이벤트 지표로 파드 수를 조절하는 워크로드 오토스케일러.

티켓팅 예매 오픈처럼 트래픽이 급변하는 baselink 특성상, 노드·파드를 빠르게 늘리고 줄이는 이 계층이 핵심입니다.

Helm provider가 살아 있는 클러스터를 필요로 하므로, 이 모듈은 **addon 레이어**에서 별도로 apply됩니다 (infra 레이어의 `eks`가 먼저 완료된 뒤).

## 생성 리소스

- Karpenter 컨트롤러 IAM 역할·정책 (IRSA)
- Karpenter 노드 IAM 역할·인스턴스 프로파일
- `helm_release` — Karpenter, KEDA
- Karpenter 매니페스트 — EC2NodeClass(노드 템플릿), NodePool(노드 채용 기준·총량 상한)
- (옵션) 스팟 중단 알림용 SQS 큐 + EventBridge 규칙

## 입력 변수

배선용 — 다른 모듈 출력에서 전달받는 필수값:

| 변수 | 설명 | 타입 | 필수 |
|---|---|---|:--:|
| `cluster_name` | EKS 클러스터 이름 (`eks` 모듈 출력) | string | ✓ |
| `oidc_provider_arn` | OIDC provider ARN (`eks` 모듈 출력) | string | ✓ |
| `oidc_provider_url` | OIDC provider URL (`eks` 모듈 출력) | string | ✓ |
| `node_subnet_ids` | Karpenter 노드용 서브넷 (보통 프라이빗) | list(string) | ✓ |
| `node_security_group_ids` | Karpenter 노드 보안 그룹 | list(string) | ✓ |

설정값 — 기본값이 있는 선택 변수:

| 변수 | 설명 | 타입 | 기본값 |
|---|---|---|---|
| `karpenter_version` | Karpenter Helm 차트 버전 | string | `"1.11.1"` |
| `keda_version` | KEDA Helm 차트 버전 | string | `"2.19.0"` |
| `karpenter_namespace` | Karpenter 설치 네임스페이스 | string | `"karpenter"` |
| `keda_namespace` | KEDA 설치 네임스페이스 | string | `"keda"` |
| `enable_interruption_queue` | 스팟 중단 알림 SQS+EventBridge 생성 | bool | `true` |
| `ami_alias` | EC2NodeClass AMI alias | string | `"al2023@latest"` |
| `node_capacity_types` | 노드 구매 옵션 (spot/on-demand) | list(string) | `["spot","on-demand"]` |
| `node_arch` | 노드 CPU 아키텍처 | list(string) | `["amd64"]` |
| `node_instance_categories` | 허용 인스턴스 카테고리 | list(string) | `["c","m","r"]` |
| `nodepool_cpu_limit` | NodePool 전체 CPU 상한 (코어) | string | `"1000"` |
| `nodepool_memory_limit` | NodePool 전체 메모리 상한 | string | `"1000Gi"` |
| `tags` | 공통 태그 | map(string) | `{}` |

## 출력값

| 출력 | 설명 |
|---|---|
| `karpenter_controller_role_arn` | Karpenter 컨트롤러 IAM 역할 ARN |
| `karpenter_node_role_arn` | Karpenter 노드 IAM 역할 ARN |
| `karpenter_node_instance_profile` | Karpenter 노드 인스턴스 프로파일 이름 |
| `interruption_queue_name` | 중단 알림 SQS 큐 이름 (미사용 시 null) |
| `karpenter_namespace` | Karpenter 네임스페이스 |
| `keda_namespace` | KEDA 네임스페이스 |

## 사용 예시

addon 레이어에서 infra 레이어 출력을 remote state로 받아 호출합니다.

```hcl
data "terraform_remote_state" "infra" {
  backend = "s3"
  config  = { /* infra 레이어 state 위치 */ }
}

module "eks_addons" {
  source = "../../../modules/eks-addons"

  cluster_name            = data.terraform_remote_state.infra.outputs.cluster_name
  oidc_provider_arn       = data.terraform_remote_state.infra.outputs.oidc_provider_arn
  oidc_provider_url       = data.terraform_remote_state.infra.outputs.oidc_provider_url
  node_subnet_ids         = data.terraform_remote_state.infra.outputs.private_subnet_ids
  node_security_group_ids = [data.terraform_remote_state.infra.outputs.cluster_security_group_id]
}
```

## 다른 모듈과의 관계

- **입력으로 받음**: 필수 입력 5개 모두 `eks` 모듈과 `vpc` 모듈의 출력에서 옵니다.
- **순서**: infra 레이어(`eks` 포함)가 완료된 뒤 addon 레이어에서 apply됩니다.

## 참고

- Helm provider는 **2.x 계열로 고정**해야 합니다(`>= 2.12, < 3.0`). 3.x에서 `set` 블록 문법이 바뀌어 모듈 코드와 호환되지 않습니다.
- 이 모듈은 KEDA "엔진"만 설치합니다. 서비스별 스케일 규칙(`ScaledObject`)은 각 서비스 배포와 함께 작성하며 이 모듈의 범위가 아닙니다.
- `nodepool_cpu_limit` / `nodepool_memory_limit`는 Karpenter가 노드를 무한히 늘리지 않도록 막는 비용 안전장치입니다.
