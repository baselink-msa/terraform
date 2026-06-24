# VPC Module

이 모듈은 dev/prod 환경에서 공통으로 사용할 VPC 네트워크 기반을 만든다.

현재 dev 환경에서는 Baselink 프로젝트의 EKS, Public ALB, RDS, Redis 같은 리소스가 올라갈 네트워크를 준비하는 역할을 한다.

## 생성 리소스

- VPC
- Internet Gateway
- Public Subnet
- Private App Subnet
- Private Data Subnet
- NAT Gateway
- Elastic IP for NAT Gateway
- Public Route Table
- Private Route Table
- Route Table Association
- S3 Gateway VPC Endpoint
- Interface VPC Endpoint
- Security Group for Interface VPC Endpoint

## 네트워크 구조

dev 기본값은 아래와 같다.

```text
VPC
- CIDR: 10.0.0.0/16

ap-northeast-2a
- Public Subnet A:      10.0.0.0/24
- Private App Subnet A: 10.0.20.0/24
- Private Data Subnet A: 10.0.40.0/24

ap-northeast-2c
- Public Subnet C:      10.0.10.0/24
- Private App Subnet C: 10.0.30.0/24
- Private Data Subnet C: 10.0.50.0/24
```

## Subnet 용도

### Public Subnet

인터넷과 직접 연결되는 리소스를 배치한다.

예상 용도:

- Public ALB
- NAT Gateway
- 필요 시 운영 테스트용 public EC2

Public subnet에는 아래 Kubernetes 태그가 붙는다.

```hcl
"kubernetes.io/role/elb" = "1"
```

이 태그는 AWS Load Balancer Controller가 internet-facing ALB를 만들 때 public subnet을 찾는 데 사용한다.

### Private App Subnet

애플리케이션 실행 영역이다.

예상 용도:

- EKS worker node
- Backend pod
- Internal service

Private app subnet에는 아래 Kubernetes 태그가 붙는다.

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

이 태그는 internal load balancer를 만들 때 사용된다.

### Private Data Subnet

데이터 계층 리소스를 배치한다.

예상 용도:

- RDS PostgreSQL
- ElastiCache Redis
- 기타 외부 직접 노출이 없어야 하는 데이터 리소스

## Routing

Public subnet은 Internet Gateway를 통해 인터넷과 통신한다.

```text
Public Subnet
-> Public Route Table
-> Internet Gateway
-> Internet
```

Private app/data subnet은 NAT Gateway를 통해 외부로 나간다.

```text
Private Subnet
-> Private Route Table
-> NAT Gateway
-> Internet Gateway
-> Internet
```

dev 기본값은 운영 전환을 고려해 `single_nat_gateway = false`이다.

이 경우 public subnet이 있는 AZ마다 NAT Gateway를 1개씩 만들고, private app/data subnet은 같은 AZ의 private route table을 통해 같은 AZ의 NAT Gateway로 나간다.

```text
Private App Subnet A -> Private Route Table A -> NAT Gateway A
Private App Subnet C -> Private Route Table C -> NAT Gateway C
Private Data Subnet A -> Private Route Table A -> NAT Gateway A
Private Data Subnet C -> Private Route Table C -> NAT Gateway C
```

이 구조는 NAT Gateway 장애 범위를 AZ 단위로 격리하고, 다른 AZ의 NAT Gateway를 경유하면서 발생할 수 있는 cross-AZ 데이터 처리 비용을 줄인다.

비용을 우선하는 임시 dev 환경에서는 `single_nat_gateway = true`로 되돌려 NAT Gateway를 1개만 사용할 수 있다.

## VPC Endpoint

이 모듈은 기본적으로 S3 Gateway Endpoint를 private route table에 연결한다.

ECR 이미지 pull 최적화를 위해 interface endpoint도 선택적으로 생성할 수 있다.

dev 환경 기본 interface endpoint:

```text
ecr.api
ecr.dkr
monitoring
sqs
sts
```

ECR image pull 경로는 아래처럼 나뉜다.

```text
EKS Node / Pod
-> ECR API / ECR Docker Registry: Interface Endpoint
-> ECR image layer object: S3 Gateway Endpoint
```

따라서 ECR용 interface endpoint를 추가하더라도 S3 gateway endpoint는 유지하는 것이 맞다.

서비스별 용도는 아래와 같다.

| Endpoint | Type | 용도 |
| --- | --- | --- |
| `s3` | Gateway | ECR image layer 다운로드, S3 객체 접근 |
| `ecr.api` | Interface | ECR 인증 토큰, 이미지 메타데이터, tag/digest 조회 |
| `ecr.dkr` | Interface | Docker Registry API, image manifest 조회 |
| `monitoring` | Interface | CloudWatch Metrics API. YACE, CloudWatch scaler가 `GetMetricData`, `ListMetrics` 등을 호출할 때 사용 |
| `sqs` | Interface | KEDA SQS scaler, ticket-service, ticket-worker-service의 SQS API 호출 |
| `sts` | Interface | IRSA/WebIdentity 기반 Pod가 AWS 임시 자격증명을 받을 때 사용 |

## EKS 연동 태그

`eks_cluster_name`을 입력하면 subnet에 아래 태그가 추가된다.

```hcl
"kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
```

EKS 클러스터 이름이 아직 정해지지 않았다면 빈 문자열로 두면 된다.

## 주요 입력 변수

| Variable | Description |
| --- | --- |
| `project_name` | 리소스 이름 prefix에 사용할 프로젝트 이름 |
| `environment` | dev/prod 같은 환경 이름 |
| `vpc_cidr` | VPC CIDR |
| `availability_zones` | subnet을 생성할 AZ 목록 |
| `public_subnet_cidrs` | public subnet CIDR 목록 |
| `private_app_subnet_cidrs` | private app subnet CIDR 목록 |
| `private_data_subnet_cidrs` | private data subnet CIDR 목록 |
| `enable_nat_gateway` | NAT Gateway 생성 여부 |
| `single_nat_gateway` | NAT Gateway를 1개만 만들지 여부 |
| `interface_endpoint_services` | Interface VPC Endpoint를 만들 AWS service suffix 목록 |
| `interface_endpoint_private_dns_enabled` | Interface VPC Endpoint private DNS 활성화 여부 |
| `eks_cluster_name` | EKS subnet discovery tag에 사용할 클러스터 이름 |

## 주요 출력값

| Output | Description |
| --- | --- |
| `vpc_id` | 생성된 VPC ID |
| `public_subnet_ids` | Public subnet ID 목록 |
| `private_app_subnet_ids` | Private app subnet ID 목록 |
| `private_data_subnet_ids` | Private data subnet ID 목록 |
| `public_route_table_id` | Public route table ID |
| `private_route_table_id` | 첫 번째 private route table ID |
| `private_route_table_ids` | Private route table ID 목록 |
| `nat_gateway_id` | 첫 번째 NAT Gateway ID |
| `nat_gateway_ids` | NAT Gateway ID 목록 |
| `internet_gateway_id` | Internet Gateway ID |
| `s3_gateway_endpoint_id` | S3 Gateway VPC Endpoint ID |
| `interface_endpoint_ids` | Service suffix별 Interface VPC Endpoint ID |
| `interface_endpoint_security_group_id` | Interface VPC Endpoint Security Group ID |

## dev 환경 호출 위치

dev 환경에서는 아래 파일에서 이 모듈을 호출한다.

```text
env/dev/infra/main.tf
```

현재 backend state key는 아래 위치를 사용한다.

```text
dev/infra/terraform.tfstate
```

## 주의사항

- `enable_nat_gateway = true`이면 NAT Gateway 비용이 발생한다.
- `single_nat_gateway = false`는 NAT Gateway를 AZ별로 만들기 때문에 가용성과 AZ-local routing에는 유리하지만 NAT Gateway 시간 비용은 증가한다.
- `single_nat_gateway = true`는 비용 절감에는 좋지만, 하나의 AZ 장애에 더 취약하고 다른 AZ private subnet의 외부 통신이 cross-AZ NAT 경로를 탈 수 있다.
- ECR image pull의 NAT 의존도를 줄이려면 `ecr.api`, `ecr.dkr` interface endpoint와 S3 gateway endpoint가 함께 필요하다.
- YACE처럼 CloudWatch metric을 읽는 Pod가 있으면 `monitoring` endpoint가 필요하다.
- SQS를 직접 호출하는 Pod나 KEDA SQS scaler가 있으면 `sqs` endpoint가 필요하다.
- IRSA를 사용하는 Pod가 있으면 `sts` endpoint를 함께 두는 것이 NAT 의존도 감소에 유리하다.
- 팀 공통 태그 정책은 아직 합의 전이므로 이 모듈에는 공통 태그를 적용하지 않았다.
- Public ALB 직접 접근 제한은 이 모듈만으로 완성되지 않는다. ALB Security Group, CloudFront prefix list, Listener Rule header 검증과 함께 설계해야 한다.
