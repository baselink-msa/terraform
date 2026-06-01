# eks 모듈

EKS 클러스터(컨트롤 플레인)와 그 운영에 필요한 IAM·OIDC·시스템 노드·기본 애드온을 한 번에 프로비저닝하는 모듈입니다.

## 개요

baselink 플랫폼의 모든 워크로드(티켓팅·주문·챗봇 등 MSA 서비스)가 올라가는 쿠버네티스 클러스터를 만듭니다. 클러스터 본체뿐 아니라, 파드가 AWS 권한을 안전하게 쓰기 위한 OIDC provider, 시스템 파드(CoreDNS 등)를 위한 노드그룹, 네트워킹·DNS 관리형 애드온까지 포함해 "클러스터를 바로 쓸 수 있는 상태"로 만드는 것이 목표입니다.

워크로드용 노드 오토스케일링은 이 모듈이 아니라 `eks-addons` 모듈(Karpenter)이 담당합니다. 이 모듈의 노드그룹은 시스템 파드 전용입니다.

## 생성 리소스

- EKS 클러스터 (`aws_eks_cluster`)
- 클러스터 IAM 역할 / 노드 IAM 역할 + 정책 연결
- 시스템 노드그룹 (`aws_eks_node_group`)
- IAM OIDC provider (`aws_iam_openid_connect_provider`) — IRSA 기반
- 관리형 애드온 (`aws_eks_addon`) — vpc-cni, coredns, kube-proxy
- (옵션) KMS 키·alias — Kubernetes secrets 봉투 암호화용

## 입력 변수

| 변수 | 설명 | 타입 | 기본값 | 필수 |
|---|---|---|---|:--:|
| `cluster_name` | 클러스터 이름 (하위 리소스 이름 접두어) | string | — | ✓ |
| `vpc_id` | 클러스터가 속할 VPC ID | string | — | ✓ |
| `subnet_ids` | 컨트롤 플레인·노드그룹용 서브넷 (프라이빗 권장) | list(string) | — | ✓ |
| `kubernetes_version` | EKS 쿠버네티스 버전 | string | `"1.34"` | |
| `endpoint_public_access` | API 서버 엔드포인트 인터넷 접근 허용 | bool | `true` | |
| `endpoint_private_access` | API 서버 엔드포인트 VPC 내부 접근 허용 | bool | `true` | |
| `public_access_cidrs` | public 엔드포인트 허용 CIDR 목록 — 빈 목록이면 AWS가 0.0.0.0/0으로 해석함. 반드시 사무실·VPN IP로 제한할 것 | list(string) | `[]` | |
| `system_node_instance_types` | 시스템 노드그룹 인스턴스 타입 (Graviton, x86 대비 ~20% 절감) | list(string) | `["t4g.large"]` | |
| `system_node_capacity_type` | 노드 구매 옵션 (ON_DEMAND/SPOT) | string | `"ON_DEMAND"` | |
| `system_node_desired_size` | 시스템 노드 희망 수 | number | `2` | |
| `system_node_min_size` | 시스템 노드 최소 수 | number | `2` | |
| `system_node_max_size` | 시스템 노드 최대 수 | number | `3` | |
| `cluster_addons` | 설치할 관리형 애드온 목록 | list(string) | `["vpc-cni","coredns","kube-proxy"]` | |
| `cluster_addon_versions` | 애드온 버전 고정 맵 (비우면 자동 선택) | map(string) | `{}` | |
| `enable_secrets_encryption` | secrets KMS 봉투 암호화 | bool | `true` | |
| `tags` | 공통 태그 | map(string) | `{}` | |

## 출력값

| 출력 | 설명 |
|---|---|
| `cluster_name` | EKS 클러스터 이름 |
| `cluster_version` | 쿠버네티스 버전 |
| `cluster_endpoint` | API 서버 엔드포인트 URL |
| `cluster_certificate_authority_data` | 클러스터 CA 인증서(base64) |
| `cluster_security_group_id` | EKS 자동 생성 클러스터 보안 그룹 ID |
| `oidc_provider_arn` | IAM OIDC provider ARN (IRSA용) |
| `oidc_provider_url` | OIDC provider URL (IRSA용) |
| `node_role_arn` | 노드 IAM 역할 ARN |
| `secrets_kms_key_arn` | secrets 암호화 KMS 키 ARN (미사용 시 null) |

## 사용 예시

```hcl
module "eks" {
  source       = "../../../modules/eks"
  cluster_name = "baselink-dev"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids

  kubernetes_version = "1.34"
  tags               = local.common_tags
}
```

## 다른 모듈과의 관계

- **입력으로 받음**: `vpc_id`, `subnet_ids` ← vpc 모듈 출력
- **출력 제공**:
  - `oidc_provider_arn` / `oidc_provider_url` → IAM/IRSA 모듈 (파드용 IAM 역할의 신뢰 기반)
  - `cluster_endpoint` / `cluster_certificate_authority_data` / `cluster_name` → addon 레이어의 helm·kubernetes provider 구성
  - `node_role_arn` / `cluster_security_group_id` → `eks-addons` 모듈

## 참고

- `enable_secrets_encryption`은 활성화 후 비활성화할 수 없습니다. 신규 클러스터에서 켜는 것이 안전합니다.
- `subnet_ids`에는 프라이빗 서브넷 사용을 권장합니다.
- `cluster_addon_versions`를 비워 두면 EKS가 클러스터 버전에 맞는 애드온 버전을 자동 선택합니다.
